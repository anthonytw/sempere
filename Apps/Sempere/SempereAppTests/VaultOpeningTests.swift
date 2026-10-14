import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Holds the first piece of off-main work after `arm()` until `release()`;
/// all other work passes.
actor HeldRead {
    private var armed = false
    private var holding = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func arm() { armed = true; released = false }

    func passIfArmed() async {
        guard armed else { return }
        armed = false
        holding = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilHolding() async {
        while !holding { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// Opening a vault: the note list loads in the background with progress,
/// fills in batch by batch, comes from the summary cache on a reopen, and
/// says why whenever it is empty.
@MainActor
struct VaultOpeningTests {
    static let lecture = AppModelTests.lecture
    static let other = AppModelTests.deleted

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sempere-opening-\(UUID().uuidString)")
    }

    static func key(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// A locked model on a private copy of the fixture vault.
    static func lockedModel(cache: URL? = nil, gate: Gate? = nil) async throws -> (AppModel, key: String, vault: URL) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        var afterIO: (@Sendable () async -> Void)?
        if let gate { afterIO = { await gate.pass() } }
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cache, afterIO: afterIO)
        try await model.openVault(at: url)
        return (model, try key(keyURL), url)
    }

    /// Unlocks with `gate` closed: lets the key check (one piece of off-main
    /// work) through and returns how many arrivals the gate had before it.
    static func unlockGated(_ model: AppModel, key: String, gate: Gate) async throws -> Int {
        await gate.close()
        let start = await gate.arrivals
        let unlocking = Task { try await model.unlock(identityText: key, awaitNotes: false) }
        await gate.waitForArrivals(start + 1)
        await gate.releaseOne()
        try await unlocking.value
        return start
    }

    @Test func unlockReturnsBeforeTheNotesAreReadAndTheListSaysItIsLoading() async throws {
        let gate = Gate()
        let (model, key, _) = try await Self.lockedModel(gate: gate)
        let start = try await Self.unlockGated(model, key: key, gate: gate)
        // The key is accepted: the sheet can go, although nothing was read yet.
        #expect(model.phase == .unlocked)
        #expect(model.notes.isEmpty)
        #expect(!model.listLoaded)
        guard case .loading = model.emptyListReason else {
            Issue.record("expected .loading, got \(String(describing: model.emptyListReason))")
            return
        }
        await gate.waitForArrivals(start + 2)   // the listing waits at the gate
        #expect(model.notes.isEmpty)
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded })
        try await model.notesLoaded()
        #expect(Set(model.notes.map(\.id)) == [Self.lecture, Self.other])
        #expect(model.loading == nil)
        #expect(model.emptyListReason == nil)
    }

    /// The listing belongs to the model: the task that unlocked (an unlock
    /// sheet's `.task`, which SwiftUI cancels when the sheet goes away) can
    /// be cancelled without the list staying empty.
    @Test func cancellingTheUnlockingTaskDoesNotStopTheListing() async throws {
        let gate = Gate()
        let (model, key, _) = try await Self.lockedModel(gate: gate)
        await gate.close()
        let start = await gate.arrivals
        // Awaiting the notes: the task is cancelled while the listing waits at the gate.
        let unlocking = Task { _ = try? await model.unlock(identityText: key, awaitNotes: true) }
        await gate.waitForArrivals(start + 1)
        await gate.releaseOne()                  // the key check
        await gate.waitForArrivals(start + 2)    // the listing, held
        unlocking.cancel()
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded })
        #expect(model.notes.count == 2)
    }

    // MARK: - Edits while the list is loading

    /// A model whose I/O hook holds exactly one piece of off-main work, the
    /// first one after `hold.arm()`; everything else goes through.
    static func modelHoldingOneRead(cache: URL? = nil) throws -> (AppModel, HeldRead, key: String, vault: URL) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let held = HeldRead()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cache,
                             afterIO: { await held.passIfArmed() })
        return (model, held, try key(keyURL), url)
    }

    /// While the first listing is under way, notes not read yet have no known
    /// notebook: renaming a notebook would leave them behind.
    @Test func aNotebookRenameWaitsForTheListing() async throws {
        let gate = Gate()
        let (model, key, _) = try await Self.lockedModel(gate: gate)
        model.loadBatchSize = 1
        let start = try await Self.unlockGated(model, key: key, gate: gate)
        await gate.waitForArrivals(start + 2)
        await gate.releaseOne()                  // the note folders
        await gate.waitForArrivals(start + 3)
        await gate.releaseOne()                  // the first note
        #expect(await TS.waitUntil { model.notes.count == 1 })
        await #expect(throws: AppModel.ModelError.notesStillDownloading) { try await model.renameNotebook("Fixture", to: "Other") }
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded })
        try await model.renameNotebook("Nothing here", to: "Other")   // allowed once every note is read
    }

    /// A reopen shows an earlier launch's summaries: an edit that decides
    /// from the summary (here: "the title is already that") re-reads the note
    /// first instead of trusting the cache.
    @Test func anEditDuringAReopenDecidesFromTheNoteNotTheCache() async throws {
        let cacheDir = Self.tempDir()
        let (first, key, url) = try await Self.lockedModel(cache: cacheDir)
        try await first.unlock(identityText: key)
        let cachedTitle = try #require(first.notes.first { $0.id == Self.lecture }?.title)
        await first.summaryCacheSave?.value   // written after the listing, in the background
        first.close()
        #expect(await TS.waitUntil {
            TS.summaryFiles(cacheDir).count == 1
        })
        let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(key)])
        _ = try vault.apply([.setMeta(.title("Renamed elsewhere"))], to: Self.lecture,
                            deviceState: Self.tempDir().appendingPathComponent("device.json"), app: "test/0")

        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir,
                             afterIO: { await gate.pass() })
        try await model.openVault(at: url)
        let start = try await Self.unlockGated(model, key: key, gate: gate)
        await gate.waitForArrivals(start + 2)
        await gate.releaseOne()                  // the cache file: the old title is shown
        #expect(await TS.waitUntil { model.notes.first { $0.id == Self.lecture }?.title == cachedTitle })
        let renaming = Task { try await model.renameNote(Self.lecture, to: cachedTitle) }
        await gate.open()
        try await renaming.value
        #expect(await TS.waitUntil { model.listLoaded })
        #expect(try vault.reconstruct(noteId: Self.lecture).meta.title == cachedTitle, "the rename was written")
        model.close()
    }

    /// A listing batch read before an edit must not put its older summary
    /// back over the edit's.
    @Test func aBatchReadBeforeAnEditDoesNotUndoIt() async throws {
        let (model, held, key, url) = try Self.modelHoldingOneRead()
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)
        await held.arm()
        let reading = Task { try await model.readSummaries([Self.lecture]) }
        await held.waitUntilHolding()            // read with the old title, not merged yet
        try await model.renameNote(Self.lecture, to: "Newer title")
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Newer title")
        await held.release()
        try await reading.value
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Newer title")
    }

    /// A note created while the note folders are being listed is not in that
    /// listing, and must not be taken out of the list (or unselected) by it.
    @Test func aNoteCreatedDuringAListingStays() async throws {
        let (model, held, key, url) = try Self.modelHoldingOneRead()
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)
        await held.arm()
        let listing = Task { try await model.listLocalNotes() }
        await held.waitUntilHolding()            // the folders were listed
        let id = try await model.createNote(title: "Made meanwhile", paper: .blank, notebook: nil)
        model.selectedNoteID = id
        await held.release()
        try await listing.value
        #expect(model.notes.contains { $0.id == id })
        #expect(model.selectedNoteID == id)
    }

    @Test func notesArriveBatchByBatchWithACount() async throws {
        let gate = Gate()
        let (model, key, _) = try await Self.lockedModel(gate: gate)
        model.loadBatchSize = 1
        let start = try await Self.unlockGated(model, key: key, gate: gate)
        // Listing the note folders, then one read per note.
        await gate.waitForArrivals(start + 2)
        await gate.releaseOne()
        await gate.waitForArrivals(start + 3)
        #expect(model.loading == NoteLoading(done: 0, total: 2, refreshing: false))
        #expect(model.loading?.headline == "Opening vault: 0 of 2 notes")
        await gate.releaseOne()
        #expect(await TS.waitUntil { model.notes.count == 1 })
        #expect(model.loading?.done == 1)
        #expect(model.loading?.headline == "Opening vault: 1 of 2 notes")
        #expect(model.emptyListReason == nil)   // one note shown, the other on its way
        #expect(!model.listLoaded)
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded })
        #expect(model.notes.count == 2)
        #expect(model.loading == nil)
    }

    /// A reopen shows the cached summaries before anything is read, then
    /// checks for changes in the background ("Updating notes"), and picks up
    /// a note changed since.
    @Test func reopenShowsCachedSummariesAtOnceThenRefreshes() async throws {
        let cacheDir = Self.tempDir()
        let (first, key, url) = try await Self.lockedModel(cache: cacheDir)
        try await first.unlock(identityText: key)
        let listed = first.notes
        #expect(listed.count == 2)
        await first.summaryCacheSave?.value   // written after the listing, in the background
        first.close()
        #expect(await TS.waitUntil {
            TS.summaryFiles(cacheDir).count == 1
        })
        // Another device renames a note meanwhile.
        let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(key)])
        _ = try vault.apply([.setMeta(.title("Renamed elsewhere"))], to: Self.lecture,
                            deviceState: Self.tempDir().appendingPathComponent("device.json"), app: "test/0")

        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir,
                             afterIO: { await gate.pass() })
        model.loadBatchSize = 1
        try await model.openVault(at: url)
        let start = try await Self.unlockGated(model, key: key, gate: gate)
        // The cache file is decrypted off the main thread: then the list is full.
        await gate.waitForArrivals(start + 2)
        await gate.releaseOne()
        #expect(await TS.waitUntil { model.notes.count == 2 })
        #expect(Set(model.notes) == Set(listed))
        #expect(!model.listLoaded)
        #expect(model.emptyListReason == nil)
        // The note folders are listed, then each note checked: shown as an update.
        await gate.waitForArrivals(start + 3)
        await gate.releaseOne()
        await gate.waitForArrivals(start + 4)
        #expect(model.loading?.refreshing == true)
        #expect(model.loading?.headline.hasPrefix("Updating ") == true)
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded })
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Renamed elsewhere")
        #expect(model.loading == nil)
        model.close()
    }

    /// iCloud: a note whose files were evicted since the last launch, but
    /// whose revision names are the ones its indexed summary was made from,
    /// is shown from the index as it is: not downloaded, not read, not
    /// pending, and editable (its summary is current).
    @Test func evictedICloudNoteWithUnchangedNamesIsShownFromTheIndex() async throws {
        let cacheDir = Self.tempDir()
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let key = try Self.key(keyURL)
        let cloud = FakeCloud(vault: url)
        let first = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        first.cloudHooks = cloud.hooks
        first.cloudPollInterval = .milliseconds(10)
        try await first.openVault(at: url)
        try await first.unlock(identityText: key)
        let cached = try #require(first.notes.first { $0.id == Self.lecture })
        #expect(!cached.title.isEmpty)
        await first.summaryCacheSave?.value   // written after the listing, in the background
        first.close()
        #expect(await TS.waitUntil { TS.summaryFiles(cacheDir).count == 1 })

        try cloud.evict(Self.lecture)
        try cloud.evictDataless(Self.other)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        try await model.openVault(at: url)
        #expect(model.hasLocalIndex)
        try await model.unlock(identityText: key)
        #expect(model.pendingNoteIDs.isEmpty)
        #expect(model.placeholderNoteIDs.isEmpty)
        #expect(model.notes.first { $0.id == Self.lecture } == cached)
        #expect(model.verifiedNoteIDs.isSuperset(of: [Self.lecture, Self.other]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(cloud.requestedNotes.isEmpty, "nothing downloaded for the list: \(cloud.requestedNotes)")
        #expect(model.cloudSync?.isDownloading == false)
        model.close()
    }

    /// iCloud: a revision another device added since the last launch changes
    /// the note's names: the note keeps its indexed summary (marked
    /// downloading), is downloaded and read, and only it is read.
    @Test func aNoteChangedElsewhereIsDownloadedAndReadAlone() async throws {
        let cacheDir = Self.tempDir()
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let key = try Self.key(keyURL)
        let cloud = FakeCloud(vault: url)
        let first = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        first.cloudHooks = cloud.hooks
        try await first.openVault(at: url)
        try await first.unlock(identityText: key)
        let cached = try #require(first.notes.first { $0.id == Self.lecture })
        await first.summaryCacheSave?.value
        first.close()
        #expect(await TS.waitUntil { TS.summaryFiles(cacheDir).count == 1 })

        try TS.writeAsAnotherDevice([.setMeta(.title("Renamed on the Mac"))], to: Self.lecture, vault: url, key: keyURL)
        try cloud.evictDataless(Self.lecture)   // listed, not downloaded yet
        try cloud.evictDataless(Self.other)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)
        #expect(model.pendingNoteIDs == [Self.lecture])
        #expect(!model.placeholderNoteIDs.contains(Self.lecture))
        #expect(model.notes.first { $0.id == Self.lecture } == cached)
        #expect(cloud.requestedNotes == [Self.lecture.uuidString.lowercased()], "only the changed note")
        try cloud.deliver(Self.lecture)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Renamed on the Mac")
        #expect(cloud.requestedNotes == [Self.lecture.uuidString.lowercased()])
        model.close()
    }

    @Test func emptyListExplainsDownloadingFromICloud() async throws {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evict(Self.lecture)
        try cloud.evict(Self.other)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try Self.key(keyURL))
        // Placeholders are rows: the list is not empty, but a tag filter is.
        #expect(model.emptyListReason == nil)
        model.sidebarSelection = .tag("fixture")
        guard case .downloading(let sync) = model.emptyListReason else {
            Issue.record("expected .downloading, got \(String(describing: model.emptyListReason))")
            return
        }
        #expect(sync.pendingNotes == 2)
        try cloud.deliver(Self.lecture)
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        #expect(model.emptyListReason == nil)
        model.close()
    }

    @Test func emptyListReasons() async throws {
        let (model, key, url) = try await Self.lockedModel()
        #expect(model.emptyListReason == nil)            // locked: the unlock sheet explains
        try await model.unlock(identityText: key)
        #expect(model.emptyListReason == nil)
        model.searchText = "no such title"
        #expect(model.emptyListReason == .noMatches("no such title"))
        model.searchText = ""
        model.sidebarSelection = .tag("no-such-tag")
        #expect(model.emptyListReason == .emptySelection)
        model.sidebarSelection = .allNotes

        // A vault with no notes at all.
        let identity = try IdentityFile.parse(key)
        let emptyURL = Self.tempDir().appendingPathComponent("Empty.sempere")
        try FileManager.default.createDirectory(at: emptyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try Vault.create(at: emptyURL, recipients: [identity.recipient], labels: ["test"], identities: [identity])
        try await model.openVault(at: emptyURL)
        try await model.unlock(identityText: key)
        #expect(model.emptyListReason == .emptyVault)

        // A listing that fails says why (and the list offers to try again).
        try await model.openVault(at: url)
        let notesDir = url.appendingPathComponent("notes")
        let moved = url.appendingPathComponent("notes-moved")
        try FileManager.default.moveItem(at: notesDir, to: moved)
        try Data("not a folder".utf8).write(to: notesDir)
        await #expect(throws: (any Error).self) { try await model.unlock(identityText: key) }
        guard case .failed = model.emptyListReason else {
            Issue.record("expected .failed, got \(String(describing: model.emptyListReason))")
            return
        }
        try FileManager.default.removeItem(at: notesDir)
        try FileManager.default.moveItem(at: moved, to: notesDir)
        try await model.reload()
        #expect(model.emptyListReason == nil)
        #expect(model.loadFailure == nil)
    }

    @Test func backgroundListingFailureIsReported() async throws {
        let (model, key, url) = try await Self.lockedModel()
        let notesDir = url.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: notesDir)
        try Data("not a folder".utf8).write(to: notesDir)
        try await model.unlock(identityText: key, awaitNotes: false)
        #expect(await TS.waitUntil { model.errorMessage != nil })
        #expect(model.phase == .unlocked)
        guard case .failed = model.emptyListReason else {
            Issue.record("expected .failed, got \(String(describing: model.emptyListReason))")
            return
        }
    }

    @Test func loadingHeadlines() {
        #expect(NoteLoading(done: 3, total: 640).headline == "Opening vault: 3 of 640 notes")
        #expect(NoteLoading(done: 1, total: 1, refreshing: true).headline == "Updating 1 changed note: 1 done")
        #expect(NoteLoading(done: 120, total: 640, refreshing: true).headline == "Updating 640 changed notes: 120 done")
        #expect(NoteLoading(done: 0, total: 0).fractionCompleted == 1)
        #expect(NoteLoading(done: 5, total: 10).fractionCompleted == 0.5)
    }

    @Test func closingForgetsTheListingState() async throws {
        let cacheDir = Self.tempDir()
        let (model, key, _) = try await Self.lockedModel(cache: cacheDir)
        try await model.unlock(identityText: key)
        #expect(model.listLoaded)
        #expect(model.summaryCache != nil)
        model.close()
        #expect(!model.listLoaded)
        #expect(model.loading == nil)
        #expect(model.summaryCache == nil)
        #expect(model.loadFailure == nil)
    }
}
