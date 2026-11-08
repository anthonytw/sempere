import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

@MainActor
final class SeenProgress {
    var files: [Int] = []
}

extension AppModelSuites {
    /// A WebDAV vault through the model (docs/io.md "WebDAV vaults in the app"): connecting, the first download and
    /// its Cancel, the runs of a locked and an unlocked vault, offline, another vault at the address, removing, and
    /// Add WebDAV Server… on a store vault (moved from the app's `WebDAVAppTests`, which keeps the words).
    @MainActor
    struct WebDAVTests {
        struct Setup {
            var model: AppModel
            var library: VaultLibrary
            var remote: FakeWebDAVRemote
            var passwords: MemoryWebDAVPasswordStore
            var key: String
            var listing: WebDAVVaultListing
        }

        static func setup() async throws -> Setup {
            let (server, keyURL) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            let remote = FakeWebDAVRemote(server: server)
            let passwords = MemoryWebDAVPasswordStore()
            model.webdavRemote = remote
            model.webdavPasswords = passwords
            model.webdavTick = .milliseconds(20)
            model.webdavWriteDelay = 0.05
            let library = VaultLibrary(storeURL: TestTemp.root
                .appendingPathComponent("recents-\(UUID().uuidString).json"))
            let listing = try await WebDAVFixture.listing(of: server, name: "Notes", url: "https://dav.example.org/notes/")
            return Setup(model: model, library: library, remote: remote, passwords: passwords,
                         key: try await ModelFixture.keyText(keyURL), listing: listing)
        }

        /// Review of #137: when the server folder holds another vault, the old copy was deleted outright,
        /// notes never uploaded included, even while it was open, and its Keychain password was left behind.
        @Test func anotherVaultAtTheAddressNeverDeletesUnuploadedChanges() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            let location = try #require(s.model.webdavLocations.location(id))
            let copy = s.model.webdavLocations.copy(of: location)
            try await s.model.unlock(identityText: s.key)
            _ = try await s.model.createNote(title: "Never uploaded", paper: .ruled, notebook: nil)
            // The copy is partial (W2): its background fetch marks a note complete as it places its
            // revisions but records them as synced only when the run ends, so mid-run the count is
            // higher. Let the run in flight end first, so the count read here is the one the model reads.
            #expect(copy.unconfirmedChanges() > 0, "the fake push records no sync: the new note is unconfirmed")
            var other = s.listing
            other.vaultId = UUID().uuidString.lowercased()
            await #expect(throws: WebDAVVaultError.replacedWithChanges(copy.unconfirmedChanges())) {
                try await s.model.connectWebDAV(other, user: "me", password: "pw2", pin: nil, library: s.library)
            }
            #expect(s.model.webdavLocations.location(id) != nil)
            #expect(copy.exists)
            #expect(try s.passwords.password(for: id) == "pw")
            #expect(s.model.isWebDAVVault, "the open copy stays open")
        }

        @Test func closingTheVaultReleasesItsPooledConnections() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            _ = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            let before = s.remote.releases
            s.model.close()
            #expect(s.remote.releases > before)
        }

        @Test func anotherVaultAtTheAddressReplacesACleanCopyAndItsPassword() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            let location = try #require(s.model.webdavLocations.location(id))
            // Nothing unconfirmed: no copy left on disk (as after an interrupted first download was cleared).
            try FileManager.default.removeItem(at: s.model.webdavLocations.copy(of: location).folder)
            var other = s.listing
            other.vaultId = UUID().uuidString.lowercased()
            let fresh = try await s.model.connectWebDAV(other, user: "me", password: "pw2", pin: nil, library: s.library)
            #expect(fresh != id)
            #expect(s.model.webdavLocations.location(id) == nil)
            #expect(throws: (any Error).self) { try s.passwords.password(for: id) }
            #expect(try s.passwords.password(for: fresh) == "pw2")
            #expect(s.library.recents.allSatisfy { $0.webdav != id })
        }

        @Test func connectingStoresThePasswordDownloadsAndOpensLocked() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            #expect(s.model.phase == .locked)
            #expect(s.model.isWebDAVVault)
            #expect(s.remote.downloads == 1)
            #expect(try s.passwords.password(for: id) == "pw")
            let location = try #require(s.model.webdavLocations.location(id))
            #expect(location.downloaded)
            #expect(location.folderName == "Notes.sempere")
            #expect(s.model.vaultURL?.standardizedFileURL == s.model.webdavLocations.copy(of: location).folder.standardizedFileURL)
            #expect(s.library.recents.first?.storeID?.uuidString.lowercased() == s.listing.vaultId.lowercased())
            // Nothing is taken from the server while the vault is locked: runs only upload.
            try await Task.sleep(for: .milliseconds(150))   // kept: a negative check, nothing to wait on
            #expect(s.remote.twoWayRuns == 0)
            #expect(s.remote.pushedUnlocked.allSatisfy { !$0 })
            // The same folder and user again: the location is reused, not duplicated.
            s.model.close()
            let again = try await s.model.connectWebDAV(s.listing, user: "me", password: "new", pin: nil, library: s.library)
            #expect(again == id)
            #expect(s.model.webdavLocations.locations.count == 1)
            #expect(try s.passwords.password(for: id) == "new")
            #expect(s.remote.downloads == 1, "a complete copy is not downloaded again")
        }

        @Test func unlockingPushesAndAWritePushesAgain() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            _ = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            try await s.model.unlock(identityText: s.key)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { s.remote.twoWayRuns == 1 }, "an unlocked vault syncs both ways")
            #expect(s.remote.pushedUnlocked.last == true, "deletions are checked against the unlocked vault")
            let session = try #require(s.model.webdav)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !session.isSyncing && session.lastSuccess != nil })
            #expect(s.model.webdavLocations.locations.first?.lastPush != nil)
            let before = s.remote.twoWayRuns
            _ = try await s.model.createNote(title: "Written on the iPad", paper: .ruled, notebook: nil)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { s.remote.twoWayRuns > before })
            // Sync Now runs one more (a write landing meanwhile may have added one).
            let runs = s.remote.pushes
            await s.model.webdavSyncNow()
            #expect(s.remote.pushes > runs)
        }

        @Test func offlineKeepsWorkingAndSaysSo() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
            s.model.close()
            s.remote.set {
                $0.downloadError = WebDAVError.offline("The Internet connection appears to be offline.")
                $0.pushError = WebDAVError.offline("The Internet connection appears to be offline.")
            }
            // A complete copy opens without the server.
            try await s.model.openWebDAV(id, library: s.library)
            try await s.model.unlock(identityText: s.key)
            let session = try #require(s.model.webdav)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { session.problems == [.offline] && !session.isSyncing })
            #expect(session.status.kind == .offline, "the bar says Offline (the app's words: `WebDAVAppTests`)")
            #expect(!session.needsAttention)
            #expect(session.schedule.failures >= 1)
            // Notes are still written to the copy.
            let note = try await s.model.createNote(title: "Offline note", paper: .ruled, notebook: nil)
            #expect(s.model.notes.contains { $0.id == note })
            // Back online: the next push clears the problem.
            s.remote.set { $0.pushError = nil }
            await s.model.webdavSyncNow()
            #expect(session.problems.isEmpty)
            #expect(session.status.kind != .offline)
        }

        @Test func anIncompleteDownloadIsNotOpenedAndContinuesNextTime() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            var report = SyncReport()
            report.errors = [.init(path: "notes/x/y.age", message: "HTTP 503")]
            s.remote.set { $0.downloadReport = report }
            await #expect(throws: WebDAVVaultError.self) {
                try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
            }
            #expect(s.model.phase == .noVault)
            let location = try #require(s.model.webdavLocations.locations.first)
            #expect(!location.downloaded)
            s.remote.set { $0.downloadReport = SyncReport() }
            try await s.model.openWebDAV(location.id, library: s.library)
            #expect(s.remote.downloads == 2)
            #expect(s.model.phase == .locked)
        }

        /// W1: the first download shows its progress, and Cancel stops it without an alert, keeping a
        /// copy that the next open continues.
        @Test func downloadShowsProgressAndCancelKeepsAResumableCopy() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            var listing = SyncProgress()
            listing.notesTotal = 4
            listing.notesListed = 2
            var downloading = SyncProgress()
            downloading.stage = .downloading
            downloading.notesTotal = 4
            downloading.notesListed = 4
            downloading.filesTotal = 8
            downloading.filesDone = 3
            downloading.bytesTotal = 8_000_000
            downloading.bytesDone = 2_000_000
            let gate = DispatchSemaphore(value: 0)
            s.remote.set { $0.downloadSteps = [listing, downloading]; $0.downloadGate = gate }
            let connecting = Task { try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library) }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { s.model.webdavDownload?.progress == downloading })
            let status = try #require(s.model.webdavDownload)
            #expect(status.name == "Notes")
            #expect(status.fractionCompleted == 0.25)
            #expect(!status.cancelling)
            s.model.cancelWebDAVDownload()
            #expect(s.model.webdavDownload?.cancelling == true)
            await #expect(throws: CancellationError.self) { try await connecting.value }
            #expect(s.model.webdavDownload == nil)
            #expect(s.model.webdavDownloadCancel == nil)
            #expect(s.model.phase == .noVault)
            let location = try #require(s.model.webdavLocations.locations.first)
            #expect(!location.downloaded, "a canceled download is not complete")

            s.remote.set { $0.downloadSteps = []; $0.downloadGate = nil }
            try await s.model.openWebDAV(location.id, library: s.library)
            #expect(s.remote.downloads == 2, "opening it again continues the download")
            #expect(s.remote.concurrencySeen == [TransferPool.defaultWidth, TransferPool.defaultWidth])
            #expect(s.model.phase == .locked)
            #expect(s.model.webdavDownload == nil)
            s.model.cancelWebDAVDownload()   // nothing running: no effect
            #expect(s.model.webdavDownload == nil)
        }

        /// W1: the vault's label (vault.json, format.md §2) names it in the WebDAV list and the recents,
        /// not the server folder; a label set later is taken when the copy is opened again.
        @Test func theVaultsLabelNamesItsLocationAndRecentRow() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let manifestURL = s.remote.server.appendingPathComponent("vault.json")
            func label(_ text: String) throws {
                var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
                json["label"] = text
                try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
            }
            try label("Server Notes")
            var listing = s.listing
            listing.name = "dav"
            let id = try await s.model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: s.library)
            #expect(s.model.webdavLocations.location(id)?.name == "Server Notes")
            #expect(s.library.recents.contains { $0.storeID?.uuidString.lowercased() == listing.vaultId.lowercased() })
            s.model.close()

            // Renamed on the server: a fresh pull of the copy brings it.
            try label("Renamed")
            let location = try #require(s.model.webdavLocations.location(id))
            // The store vault and the target's state gone (as after an interrupted first download was cleared).
            try FileManager.default.removeItem(at: s.model.webdavLocations.copy(of: location).folder.deletingLastPathComponent())
            try FileManager.default.removeItem(at: s.model.webdavLocations.copy(of: location).directory)
            s.model.webdavLocations.update(id) { $0.downloaded = false }
            try await s.model.openWebDAV(id, library: s.library)
            #expect(s.model.webdavLocations.location(id)?.name == "Renamed")
        }

        @Test func progressRelayDeliversTheNewestAndNothingAfterClose() async throws {
            let box = SeenProgress()
            let relay = WebDAVProgressRelay { box.files.append($0.filesDone) }
            DispatchQueue.concurrentPerform(iterations: 50) { i in
                var p = SyncProgress()
                p.filesDone = i
                relay.send(p)
            }
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !box.files.isEmpty })
            try await Task.sleep(for: .milliseconds(50))   // kept: a negative check, nothing to wait on
            #expect(box.files.count < 50, "coalesced, one main-actor task at a time")
            relay.close()
            relay.send(SyncProgress())
            let count = box.files.count
            try await Task.sleep(for: .milliseconds(50))   // kept: a negative check, nothing to wait on
            #expect(box.files.count == count)
        }

        /// A recent WebDAV vault is a store vault with a WebDAV target: its entry names the store vault, which opens
        /// from its copy through its target (`joiningWebDAVLocation`, what the app's Open Recent calls), with no new
        /// download.
        @Test func aRecentWebDAVVaultReopensFromItsCopy() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            s.model.close()
            #expect(!s.model.isWebDAVVault)
            let entry = try #require(s.library.recents.first)
            #expect(entry.storeID?.uuidString.lowercased() == s.listing.vaultId.lowercased())
            #expect(entry.webdav == nil, "named as a store vault, not as a WebDAV location")
            let storeID = try #require(entry.storeID)
            let location = try #require(s.model.joiningWebDAVLocation(of: storeID))
            #expect(location == id)
            try await s.model.openWebDAV(location, library: s.library)
            #expect(s.model.isWebDAVVault)
            #expect(s.model.webdav?.locationID == id)
            #expect(s.remote.downloads == 1)
        }

        @Test func removingDeletesTheCopyThePasswordAndTheRecentEntry() async throws {
            let s = try await Self.setup()
            defer { s.model.close() }
            let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
            let location = try #require(s.model.webdavLocations.location(id))
            let copy = s.model.webdavLocations.copy(of: location)
            #expect(copy.exists)
            try await s.model.removeWebDAVLocation(id, library: s.library)
            #expect(s.model.phase == .noVault)
            #expect(!FileManager.default.fileExists(atPath: copy.directory.path))
            #expect(throws: WebDAVPasswordError.notFound) { try s.passwords.password(for: id) }
            #expect(s.library.recents.isEmpty)
            #expect(s.model.webdavLocations.locations.isEmpty)
        }

        @Test func locationURLsCompareAsFolders() {
            #expect(WebDAVLocationStore.sameFolder("https://DAV.example.org/notes/", "https://dav.example.org/notes"))
            #expect(!WebDAVLocationStore.sameFolder("https://dav.example.org/notes/", "https://dav.example.org/Notes/"))
            #expect(WebDAVLocationStore.folderName(for: "Work") == "Work.sempere")
            #expect(WebDAVLocationStore.folderName(for: "../x") == "Vault.sempere")
        }

        /// Vault Details ▸ Add WebDAV Server… (P9): the server folder is checked, added once as a joined target of the
        /// store vault, and its password kept; the same folder again is refused (the app's `VaultDetailsAppTests`).
        @Test func aWebDAVServerIsAddedOnceAsATarget() async throws {
            let (model, _, _, key, _) = try await SyncRunRuleTests.openStoreVault()
            defer { model.close() }
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            let vaultID = try #require(model.vault?.vaultId)
            model.webdavRemote = FakeWebDAVRemote(server: TestTemp.root.appendingPathComponent("server-\(UUID().uuidString)"))
            model.webdavPasswords = MemoryWebDAVPasswordStore()
            let url = try #require(URL(string: "https://dav.example.org/notes/"))
            guard case .checked(let found) = await model.probeWebDAVTarget(url: url, user: "me", password: "pw", pin: nil,
                                                                          vaultID: vaultID) else {
                Issue.record("the check failed"); return
            }
            #expect(found.acceptable)
            let id = try await model.addWebDAVTarget(url: url, user: "me", password: "pw", pin: nil, to: vaultID)
            #expect(model.openVaultTargets.contains { $0.id == id && $0.kind == .webdav && $0.joined == true })
            #expect(try model.webdavPasswords.password(for: id) == "pw")
            await #expect(throws: SyncTargetProblem.duplicate) {
                try await model.addWebDAVTarget(url: url, user: "me", password: "pw", pin: nil, to: vaultID)
            }
        }
    }
}
