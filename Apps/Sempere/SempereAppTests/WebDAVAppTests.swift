import Age
import Foundation
import Sempere
import SempereSync
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
    private var _releases = 0
    /// How often the app told the remote the open vault closed (`releaseConnections`).
    var releases: Int { lock.lock(); defer { lock.unlock() }; return _releases }
    func releaseConnections() { lock.lock(); _releases += 1; lock.unlock() }
    var downloadError: (any Error)?
    var downloadReport = SyncReport()
    var pushError: (any Error)?
    var pushReport = SyncReport()
    var redownloadReplaces = true
    /// When set, a download reports these as its progress, then waits for `downloadGate`
    /// (or a cancellation) before it places the copy.
    var downloadSteps: [WebDAVSyncProgress] = []
    var downloadGate: DispatchSemaphore?
    private var _optionsSeen: [Int] = []
    /// The concurrency each download was given.
    var concurrencySeen: [Int] { lock.lock(); defer { lock.unlock() }; return _optionsSeen }
    /// When set, a push waits for it before it returns (a slow upload).
    var pushGate: DispatchSemaphore?
    /// When set, a fetch waits for it before it starts (a slow server).
    var fetchGate: DispatchSemaphore?
    var fetchError: (any Error)?
    private var _fetchScopes: [WebDAVFetchScope] = []
    private var _fetchedUnlocked: [Bool] = []
    private var _inFlight = 0, _mostInFlight = 0
    var probe: WebDAVProbe = .reachable(WebDAVCheckResult(outcome: .noVault, vaults: [], foldersChecked: 0,
                                                          foldersSkipped: 0, unreadable: []))
    private(set) var passwordsSeen: [String?] = []

    init(server: URL) { self.server = server }

    var downloads: Int { lock.lock(); defer { lock.unlock() }; return _downloads }
    var pushes: Int { lock.lock(); defer { lock.unlock() }; return _pushes }
    var redownloads: Int { lock.lock(); defer { lock.unlock() }; return _redownloads }
    /// The most pushes and re-downloads of the copy that ever ran at once.
    var mostInFlight: Int { lock.lock(); defer { lock.unlock() }; return _mostInFlight }
    var pushedUnlocked: [Bool] { lock.lock(); defer { lock.unlock() }; return _pushedUnlocked }
    /// How many identities each re-download was given (the new copy is checked under them).
    var redownloadKeys: [Int] { lock.lock(); defer { lock.unlock() }; return _redownloadKeys }
    /// Every fetch's scope, in order.
    var fetchScopes: [WebDAVFetchScope] { lock.lock(); defer { lock.unlock() }; return _fetchScopes }
    /// Whether each fetch was given the unlocked vault (checks under the key).
    var fetchedUnlocked: [Bool] { lock.lock(); defer { lock.unlock() }; return _fetchedUnlocked }

    /// A client of the fixture `server` folder (read-only, `FolderDAVTransport`): the
    /// metadata pull, fetches and re-downloads run the real library against it.
    func folderClient() throws -> WebDAVClient {
        try WebDAVClient(baseURL: URL(string: "https://dav.example.org/notes/")!,
                         transport: FolderDAVTransport(root: server, base: "/notes"))
    }

    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: WebDAVLocalCopy, options: WebDAVSyncOptions) throws -> SyncReport {
        lock.lock(); _downloads += 1; let error = downloadError, report = downloadReport
        let steps = downloadSteps, gate = downloadGate
        _optionsSeen.append(options.concurrency)
        passwordsSeen.append(endpoint.password); lock.unlock()
        if let error { throw error }
        for step in steps { options.progress?(step) }
        if let gate {
            // Waits like a slow server, checking the Cancel as the library does between requests.
            while gate.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
                if options.isCancelled?() == true {
                    var stopped = report
                    stopped.stoppedEarly = SyncError.cancelled.errorDescription
                    return stopped
                }
            }
        }
        let pulled = try copy.downloadMetadata(client: try folderClient(), options: options)
        return report.errors.isEmpty ? pulled : report
    }

    func fetch(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy, vault: Vault?, scope: WebDAVFetchScope) throws -> SyncReport {
        lock.lock(); _fetchScopes.append(scope); _fetchedUnlocked.append(vault?.canRead == true)
        let gate = fetchGate, error = fetchError; lock.unlock()
        gate?.wait()
        if let error { throw error }
        return try copy.fetch(client: try folderClient(), vault: vault, scope: scope)
    }

    /// Lets every fetch through from now on (and the ones waiting).
    func openFetchGate() {
        lock.lock(); let gate = fetchGate; fetchGate = nil; lock.unlock()
        for _ in 0..<64 { gate?.signal() }
    }

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

    private func enter() { lock.lock(); _inFlight += 1; _mostInFlight = max(_mostInFlight, _inFlight); lock.unlock() }
    private func leave() { lock.lock(); _inFlight -= 1; lock.unlock() }

    func push(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy, vault: Vault?, options: WebDAVSyncOptions) throws -> SyncReport {
        enter()
        defer { leave() }
        lock.lock()
        _pushes += 1
        _pushedUnlocked.append(vault?.canRead == true)
        let gate = pushGate, error = pushError, report = pushReport
        lock.unlock()
        gate?.wait()
        if let error { throw error }
        return report
    }

    func redownload(_ endpoint: WebDAVEndpoint, copy: WebDAVLocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: WebDAVSyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        enter()
        defer { leave() }
        lock.lock(); _redownloads += 1; _redownloadKeys.append(identities.count); let replaces = redownloadReplaces; lock.unlock()
        guard replaces else { return (SyncReport(), false) }
        return try copy.redownload(client: try folderClient(), identities: identities, partial: partial, options: options)
    }

    private func place(into copy: WebDAVLocalCopy) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: copy.directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: copy.folder)
        try fm.copyItem(at: server, to: copy.folder)
    }
}

@MainActor
final class SeenProgress {
    var files: [Int] = []
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
        try await s.model.unlock(identityText: s.key)
        _ = try await s.model.createNote(title: "Never uploaded", paper: .ruled, notebook: nil)
        // The copy is partial (W2): its background fetch marks a note complete as it places its
        // revisions but records them as synced only when the run ends, so mid-run the count is
        // higher. Let the run in flight end first, so the count read here is the one the model reads.
        await s.model.webdavFetcher?.stop()?.value
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
        s.model.close()
    }

    @Test func closingTheVaultReleasesItsPooledConnections() async throws {
        let s = try Self.setup()
        _ = try await s.model.connectWebDAV(s.listing, user: "me", password: "pw", pin: nil, library: s.library)
        let before = s.remote.releases
        s.model.close()
        #expect(s.remote.releases > before)
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

    /// W1: the first download shows its progress, and Cancel stops it without an alert, keeping a
    /// copy that the next open continues.
    @Test func downloadShowsProgressAndCancelKeepsAResumableCopy() async throws {
        let s = try Self.setup()
        var listing = WebDAVSyncProgress()
        listing.notesTotal = 4
        listing.notesListed = 2
        var downloading = WebDAVSyncProgress()
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
        #expect(await TS.waitUntil { s.model.webdavDownload?.progress == downloading })
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
        s.model.close()
    }

    /// W1: the vault's label (vault.json, format.md §2) names it in the WebDAV list and the recents,
    /// not the server folder; a label set later is taken when the copy is opened again.
    @Test func theVaultsLabelNamesItsLocationAndRecentRow() async throws {
        let s = try Self.setup()
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
        #expect(s.library.recents.first { $0.webdav == id }?.name == "Server Notes")
        s.model.close()

        // Renamed on the server: a fresh pull of the copy brings it.
        try label("Renamed")
        let location = try #require(s.model.webdavLocations.location(id))
        try FileManager.default.removeItem(at: s.model.webdavLocations.copy(of: location).directory)
        try await s.model.openWebDAV(id, library: s.library)
        #expect(s.model.webdavLocations.location(id)?.name == "Renamed")
        #expect(s.library.recents.first { $0.webdav == id }?.name == "Renamed")
        s.model.close()
    }

    @Test func downloadStatusDescribesEachStage() {
        var status = WebDAVDownloadStatus(name: "Notes")
        #expect(status.fractionCompleted == nil, "nothing known yet: an indeterminate bar")
        #expect(!status.description.isEmpty)
        status.progress.notesTotal = 10
        status.progress.notesListed = 5
        #expect(status.fractionCompleted == 0.5)
        #expect(status.description.contains("5"))
        status.progress.stage = .downloading
        status.progress.filesTotal = 800
        status.progress.filesDone = 12
        status.progress.bytesTotal = 1_000_000_000
        status.progress.bytesDone = 250_000_000
        #expect(status.fractionCompleted == 0.25, "bytes when they are known")
        #expect(status.description.contains("12"))
        #expect(status.description.contains("800"))
        #expect(status.description.contains(WebDAVDownloadStatus.bytes(250_000_000)))
        #expect(status.description.contains(WebDAVDownloadStatus.bytes(1_000_000_000)))
        status.progress.bytesTotal = 0
        #expect(status.fractionCompleted == 12.0 / 800.0, "files when no sizes are listed")
        status.progress.stage = .syncingNotes
        status.progress.notesSynced = 10
        #expect(status.fractionCompleted == 1)
        status.cancelling = true
        #expect(status.description != WebDAVDownloadStatus(name: "Notes").description)
    }

    @Test func progressRelayDeliversTheNewestAndNothingAfterClose() async throws {
        let box = SeenProgress()
        let relay = WebDAVProgressRelay { box.files.append($0.filesDone) }
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            var p = WebDAVSyncProgress()
            p.filesDone = i
            relay.send(p)
        }
        #expect(await TS.waitUntil { !box.files.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.files.count < 50, "coalesced, one main-actor task at a time")
        relay.close()
        relay.send(WebDAVSyncProgress())
        let count = box.files.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.files.count == count)
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

    /// A push still running when "Download Again" starts finishes first: two
    /// runs on the copy's one state file would undo each other's work.
    @Test func downloadingAgainWaitsForThePushInFlight() async throws {
        let s = try Self.setup()
        _ = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let gate = DispatchSemaphore(value: 0)
        s.remote.set { $0.pushGate = gate }
        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil { s.remote.pushes == 1 })
        let again = Task { try await s.model.downloadWebDAVAgain(library: s.library) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(s.remote.pushes == 1, "no second push while the first runs")
        s.remote.set { $0.pushGate = nil }
        gate.signal()
        gate.signal()   // a second push already waiting, if any
        try await again.value
        #expect(s.remote.mostInFlight == 1)
        #expect(s.remote.redownloads == 1)
        #expect(s.model.phase == .unlocked)
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
