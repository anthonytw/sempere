import Age
import Foundation
import Sempere
import SempereWebDAV
import Testing
@testable import SempereApp

/// A WebDAV server as the app sees it (`WebDAVRemote`): downloads copy a vault
/// folder (the "server"), pushes and re-downloads return scripted results.
/// The library's sync itself is tested in `Tests/SempereWebDAVTests`.
final class FakeWebDAVRemote: WebDAVRemote, @unchecked Sendable {
    private let lock = NSLock()
    let server: URL
    private var _downloads = 0, _pushes = 0, _redownloads = 0
    private var _pushedUnlocked: [Bool] = []
    private var _redownloadKeys: [Int] = []
    var downloadError: (any Error)?
    var downloadReport = SyncReport()
    var pushError: (any Error)?
    var pushReport = SyncReport()
    var redownloadReplaces = true
    var probe: WebDAVProbe = .reachable(WebDAVCheckResult(outcome: .noVault, vaults: [], foldersChecked: 0,
                                                          foldersSkipped: 0, unreadable: []))
    private(set) var passwordsSeen: [String?] = []

    init(server: URL) { self.server = server }

    var downloads: Int { lock.lock(); defer { lock.unlock() }; return _downloads }
    var pushes: Int { lock.lock(); defer { lock.unlock() }; return _pushes }
    var redownloads: Int { lock.lock(); defer { lock.unlock() }; return _redownloads }
    var pushedUnlocked: [Bool] { lock.lock(); defer { lock.unlock() }; return _pushedUnlocked }
    /// How many identities each re-download was given (the new copy is checked under them).
    var redownloadKeys: [Int] { lock.lock(); defer { lock.unlock() }; return _redownloadKeys }

    func set(_ change: (FakeWebDAVRemote) -> Void) { lock.lock(); change(self); lock.unlock() }

    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe {
        lock.lock(); defer { lock.unlock() }
        passwordsSeen.append(endpoint.password)
        return probe
    }

    func download(_ endpoint: WebDAVEndpoint, into copy: WebDAVLocalCopy) throws -> SyncReport {
        lock.lock(); _downloads += 1; let error = downloadError, report = downloadReport
        passwordsSeen.append(endpoint.password); lock.unlock()
        if let error { throw error }
        try place(into: copy)
        return report
    }

    func push(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy, vault: Vault?, options: WebDAVSyncOptions) throws -> SyncReport {
        lock.lock(); defer { lock.unlock() }
        _pushes += 1
        _pushedUnlocked.append(vault?.canRead == true)
        if let pushError { throw pushError }
        return pushReport
    }

    func redownload(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy,
                    identities: [any AgeIdentity]) throws -> (report: SyncReport, replaced: Bool) {
        lock.lock(); _redownloads += 1; _redownloadKeys.append(identities.count); let replaces = redownloadReplaces; lock.unlock()
        if replaces { try place(into: copy) }
        return (SyncReport(), replaces)
    }

    private func place(into copy: WebDAVLocalCopy) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: copy.directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: copy.folder)
        try fm.copyItem(at: server, to: copy.folder)
    }
}

@MainActor
struct WebDAVAppTests {
    struct Setup {
        var model: AppModel
        var library: VaultLibrary
        var remote: FakeWebDAVRemote
        var passwords: MemoryWebDAVPasswordStore
        var key: String
        var listing: WebDAVVaultListing
    }

    static func setup() throws -> Setup {
        let (server, keyURL) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let remote = FakeWebDAVRemote(server: server)
        let passwords = MemoryWebDAVPasswordStore()
        model.webdavRemote = remote
        model.webdavPasswords = passwords
        model.webdavTick = .milliseconds(20)
        model.webdavWriteDelay = 0.05
        let library = VaultLibrary(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString).json"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: server.appendingPathComponent("vault.json")))
        let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
        let listing = WebDAVVaultListing(path: [], name: "Notes", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/notes/")
        return Setup(model: model, library: library, remote: remote, passwords: passwords,
                     key: try String(contentsOf: keyURL, encoding: .utf8), listing: listing)
    }

    /// Review of #137: when the server folder holds another vault, the old copy was deleted outright,
    /// notes never uploaded included, even while it was open, and its Keychain password was left behind.
    @Test func anotherVaultAtTheAddressNeverDeletesUnuploadedChanges() async throws {
        let s = try Self.setup()
        let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
        let location = try #require(s.model.webdavLocations.location(id))
        let copy = s.model.webdavLocations.copy(of: location)
        #expect(copy.unconfirmedChanges() > 0, "the fake download records no sync: everything is unconfirmed")
        var other = s.listing
        other.vaultId = UUID().uuidString.lowercased()
        await #expect(throws: WebDAVVaultError.replacedWithChanges(copy.unconfirmedChanges())) {
            try await s.model.connectWebDAV(other, user: "me", password: "pw2", pin: nil, library: s.library)
        }
        #expect(s.model.webdavLocations.location(id) != nil)
        #expect(copy.exists)
        #expect(try s.passwords.password(for: id) == "pw")
        #expect(s.model.isWebDAVVault, "the open copy stays open")
        s.model.close()
    }

    @Test func anotherVaultAtTheAddressReplacesACleanCopyAndItsPassword() async throws {
        let s = try Self.setup()
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
        s.model.close()
    }

    @Test func connectingStoresThePasswordDownloadsAndOpensLocked() async throws {
        let s = try Self.setup()
        let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
        #expect(s.model.phase == .locked)
        #expect(s.model.isWebDAVVault)
        #expect(s.remote.downloads == 1)
        #expect(try s.passwords.password(for: id) == "pw")
        let location = try #require(s.model.webdavLocations.location(id))
        #expect(location.downloaded)
        #expect(location.folderName == "Notes.sempere")
        #expect(s.model.vaultURL?.standardizedFileURL == s.model.webdavLocations.copy(of: location).folder.standardizedFileURL)
        #expect(s.library.recents.first?.webdav == id)
        // Nothing is pushed while the vault is locked.
        try await Task.sleep(for: .milliseconds(150))
        #expect(s.remote.pushes == 0)
        // The same folder and user again: the location is reused, not duplicated.
        s.model.close()
        let again = try await s.model.connectWebDAV(s.listing, user: "me", password: "new", pin: nil, library: s.library)
        #expect(again == id)
        #expect(s.model.webdavLocations.locations.count == 1)
        #expect(try s.passwords.password(for: id) == "new")
        #expect(s.remote.downloads == 1, "a complete copy is not downloaded again")
    }

    @Test func unlockingPushesAndAWritePushesAgain() async throws {
        let s = try Self.setup()
        _ = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil { s.remote.pushes == 1 })
        #expect(s.remote.pushedUnlocked == [true], "deletions are checked against the unlocked vault")
        let session = try #require(s.model.webdav)
        #expect(await TS.waitUntil { !session.isPushing && session.lastPush != nil })
        #expect(s.model.webdavLocations.locations.first?.lastPush != nil)
        _ = try await s.model.createNote(title: "Written on the iPad", paper: .ruled, notebook: nil)
        #expect(await TS.waitUntil { s.remote.pushes == 2 })
        // Sync Now runs one more (a write landing meanwhile may have added one).
        let before = s.remote.pushes
        await s.model.webdavSyncNow()
        #expect(s.remote.pushes > before)
    }

    @Test func offlineKeepsWorkingAndSaysSo() async throws {
        let s = try Self.setup()
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
        #expect(await TS.waitUntil { session.problems == [.offline] && !session.isPushing })
        #expect(session.headline.hasPrefix("Offline."))
        #expect(!session.needsAttention)
        #expect(session.schedule.failures >= 1)
        // Notes are still written to the copy.
        let note = try await s.model.createNote(title: "Offline note", paper: .ruled, notebook: nil)
        #expect(s.model.notes.contains { $0.id == note })
        // Back online: the next push clears the problem.
        s.remote.set { $0.pushError = nil }
        await s.model.webdavSyncNow()
        #expect(session.problems.isEmpty)
        #expect(!session.headline.hasPrefix("Offline."))
    }

    @Test func anIncompleteDownloadIsNotOpenedAndContinuesNextTime() async throws {
        let s = try Self.setup()
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

    @Test func keyChangesAreRefusedForAWebDAVVault() async throws {
        let s = try Self.setup()
        _ = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        try await s.model.unlock(identityText: s.key)
        let other = try NativeIdentity.generate(.postQuantum)
        await #expect(throws: WebDAVVaultError.keyChangesUnavailable) {
            try await s.model.addDeviceKey(recipient: other.recipient.string, label: "Other",
                                           authenticator: PassingOwnerAuthenticator())
        }
        await #expect(throws: WebDAVVaultError.keyChangesUnavailable) {
            try await s.model.generateDeviceKey(label: "Other", authenticator: PassingOwnerAuthenticator())
        }
        #expect(throws: WebDAVVaultError.keyChangesUnavailable) { try s.model.requireLocalKeyChanges() }
        #expect(s.model.vault?.recipients.count == 1)
    }

    @Test func aRecentWebDAVVaultReopensFromItsCopy() async throws {
        let s = try Self.setup()
        let id = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
        s.model.close()
        #expect(!s.model.isWebDAVVault)
        let entry = try #require(s.library.recents.first)
        #expect(entry.webdav == id)
        #expect(throws: VaultLibrary.LibraryError.self) { try s.library.resolve(entry) }
        try await s.model.open(recent: entry, library: s.library)
        #expect(s.model.isWebDAVVault)
        #expect(s.model.webdav?.locationID == id)
        #expect(s.remote.downloads == 1)
    }

    @Test func removingDeletesTheCopyThePasswordAndTheRecentEntry() async throws {
        let s = try Self.setup()
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

    @Test func downloadingAgainPushesFirstAndReopensUnlocked() async throws {
        let s = try Self.setup()
        _ = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil { s.remote.pushes == 1 && s.model.webdav?.isPushing == false })
        try await s.model.downloadWebDAVAgain(library: s.library)
        #expect(s.remote.pushes >= 2, "a push before the download")
        #expect(s.remote.redownloads == 1)
        #expect(s.remote.redownloadKeys == [1], "the new copy is checked under the vault's key")
        #expect(s.model.phase == .unlocked)
        #expect(s.model.isWebDAVVault)

        // A push that fails: nothing is downloaded, the vault is open again.
        var bad = SyncReport()
        bad.errors = [.init(path: "notes/a/b.age", message: "HTTP 507")]
        s.remote.set { $0.pushReport = bad }
        await #expect(throws: WebDAVVaultError.self) { try await s.model.downloadWebDAVAgain(library: s.library) }
        #expect(s.remote.redownloads == 1)
        #expect(s.model.phase == .unlocked)
        #expect(s.model.isWebDAVVault)
    }

    @Test func statusTextsSayWhatToDo() {
        #expect(WebDAVSession.text(for: .unauthorized).contains("password"))
        #expect(WebDAVSession.text(for: .serverChangedManifest).contains("Download the vault again"))
        #expect(WebDAVSession.text(for: .redirect("https://x/")).contains("https://x/"))
    }

    @Test func locationURLsCompareAsFolders() {
        #expect(WebDAVLocationStore.sameFolder("https://DAV.example.org/notes/", "https://dav.example.org/notes"))
        #expect(!WebDAVLocationStore.sameFolder("https://dav.example.org/notes/", "https://dav.example.org/Notes/"))
        #expect(WebDAVLocationStore.folderName(for: "Work") == "Work.sempere")
        #expect(WebDAVLocationStore.folderName(for: "../x") == "Vault.sempere")
    }

    @Test func connectSheetAcceptsOnlyUsableURLs() {
        #expect(WebDAVConnectSheet.collectionURL("dav.example.org/notes")?.absoluteString == "https://dav.example.org/notes/")
        #expect(WebDAVConnectSheet.collectionURL("http://dav.example.org/") == nil)
        #expect(WebDAVConnectSheet.collectionURL("http://localhost:8080/v")?.absoluteString == "http://localhost:8080/v/")
        #expect(WebDAVConnectSheet.collectionURL("https://me:pw@dav.example.org/") == nil)
        #expect(WebDAVConnectSheet.collectionURL("  ") == nil)
        #expect(WebDAVConnectSheet.fingerprint("ab01") == "AB:01")
    }
}

/// Where a vault lives decides whether its files are coordinated (docs/io.md, "Other Files providers").
struct StorageLocationTests {
    let home = "/private/var/mobile/Containers/Data/Application/1111-AAAA"

    func classify(_ path: String) -> StorageLocation {
        StorageLocation.classify(URL(fileURLWithPath: path), container: home)
    }

    @Test func iCloudDriveAndProvidersAreCoordinated() {
        #expect(classify("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Notes.sempere") == .iCloudDrive)
        #expect(classify("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Notes.sempere") == .iCloudDrive)
        #expect(classify("/Users/me/Library/CloudStorage/ProtonDrive-me@proton.me-folder/Notes.sempere")
                == .fileProvider(name: "ProtonDrive"))
        #expect(classify("/Users/me/Library/CloudStorage/Dropbox/Notes.sempere") == .fileProvider(name: "Dropbox"))
        #expect(classify("/private/var/mobile/Containers/Shared/AppGroup/2222-BBBB/File Provider Storage/Notes.sempere")
                == .fileProvider(name: nil))
        #expect(classify("/private/var/mobile/Containers/Shared/AppGroup/2222-BBBB/Notes.sempere") == .fileProvider(name: nil))
        for path in ["/private/var/mobile/Library/Mobile Documents/x/V.sempere",
                     "/Users/me/Library/CloudStorage/ProtonDrive-x/V.sempere"] {
            #expect(classify(path).needsCoordination, "\(path)")
        }
    }

    @Test func localFoldersAreNot() {
        #expect(classify(home + "/Documents/Notes.sempere") == .appContainer)
        #expect(classify(home + "/Library/Application Support/Sempere/WebDAV/x/V.sempere") == .appContainer)
        #expect(classify("/private/var/mobile/Containers/Data/Application/3333-CCCC/Documents/V.sempere") == .other)
        #expect(classify("/Volumes/USB/V.sempere") == .other)
        #expect(classify(home + "x/V.sempere") == .other, "a sibling with the same prefix is not the container")
        #expect(!classify(home + "/Documents/V.sempere").needsCoordination)
        #expect(!classify("/Volumes/USB/V.sempere").needsCoordination)
    }
}
