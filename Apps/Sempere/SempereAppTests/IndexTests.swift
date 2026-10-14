import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The local index and change-driven listing (docs/io.md "Opening a vault
/// fast"): what the list shows always equals what full reconstruction says,
/// whatever other devices do between passes and launches.
@MainActor
struct IndexTests {
    /// Deterministic generator (SplitMix64).
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sempere-index-\(UUID().uuidString)")
    }

    /// The reference: every note's summary from a full read and reconstruction.
    static func reference(_ vault: Vault) throws -> Set<NoteSummary> {
        Set(try vault.noteIDs().map { vault.summary(of: $0, loaded: try vault.loadNote($0, detail: .full)) })
    }

    /// Another device's edits: titles, tags, notebooks, strokes, deletions,
    /// new notes, and whole note folders going away.
    static func mutate(_ vault: Vault, rng: inout RNG, devices: [URL]) throws {
        let device = devices[Int(rng.next() % UInt64(devices.count))]
        for _ in 0..<Int(rng.next() % 4 + 1) {
            let ids = try vault.noteIDs()
            switch rng.next() % 7 {
            case 0, 1:
                guard let id = ids.randomElement(using: &rng) else { continue }
                _ = try vault.apply([.setMeta(.title("Note \(rng.next() % 1000)"))], to: id, deviceState: device, app: "t/1")
            case 2:
                guard let id = ids.randomElement(using: &rng) else { continue }
                _ = try vault.apply([.addTag("tag\(rng.next() % 5)"), .setMeta(.notebook("Course \(rng.next() % 3)"))],
                                    to: id, deviceState: device, app: "t/1")
            case 3:
                guard let id = ids.randomElement(using: &rng), let page = try vault.reconstruct(noteId: id).pages.first
                else { continue }
                _ = try vault.apply([.addStroke(page: page.id, stroke: TS.stroke(x: Double(rng.next() % 300), y: 80))],
                                    to: id, deviceState: device, app: "t/1")
            case 4:
                guard let id = ids.randomElement(using: &rng) else { continue }
                _ = try vault.apply([.deleteNote], to: id, deviceState: device, app: "t/1")
            case 5:
                let page = UUID()
                _ = try vault.apply(NoteOps.newNote(title: "New \(rng.next() % 100)", notebook: nil, tags: ["new"], pageId: page)
                                    + [.addStroke(page: page, stroke: TS.stroke())],
                                    to: UUID(), deviceState: device, app: "t/1")
            default:
                guard ids.count > 3, let id = ids.randomElement(using: &rng) else { continue }
                try FileManager.default.removeItem(at: vault.url.appendingPathComponent("notes/\(id.uuidString.lowercased())"))
            }
        }
    }

    /// Property: after any sequence of other devices' edits, a pass (in the
    /// running model, or in a model reopened from the index) shows exactly
    /// the full reconstruction of every note.
    @Test(arguments: [UInt64(1), 2, 3])
    func theListEqualsFullReconstructionAfterAnyChanges(seed: UInt64) async throws {
        let (vault, url) = try TS.unlockedFixture()
        let key = try String(contentsOf: try AppModelTests.fixtureVault().key, encoding: .utf8)
        let cacheDir = Self.tempDir()
        var rng = RNG(state: seed)
        let devices = (0..<3).map { _ in TS.deviceStateURL() }
        for _ in 0..<6 { try Self.mutate(vault, rng: &rng, devices: devices) }

        var model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)
        #expect(Set(model.notes) == (try Self.reference(vault)))
        for round in 0..<8 {
            try Self.mutate(vault, rng: &rng, devices: devices)
            if round % 3 == 2 {
                await model.summaryCacheSave?.value
                model.close()
                model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
                try await model.openVault(at: url)
                try await model.unlock(identityText: key)
            } else {
                try await model.reconcile()
            }
            let shown = Set(model.notes)
            let expected = try Self.reference(vault)
            #expect(shown == expected, "round \(round): \(shown.symmetricDifference(expected).map(\.title))")
            #expect(model.verifiedNoteIDs.isSuperset(of: shown.map(\.id)))
        }
        model.close()
    }

    /// A pass that finds nothing changed reads nothing.
    @Test func anUnchangedVaultIsNotReadAgain() async throws {
        let cacheDir = Self.tempDir()
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let first = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        try await first.openVault(at: url)
        try await first.unlock(identityText: key)
        await first.summaryCacheSave?.value
        first.close()

        let reads = Counter()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)
        let before = model.notes
        model.loadBatchSize = 1
        model.onSummaryRead = { reads.add($0) }
        try await model.reconcile()
        try await model.reconcile(full: true)
        #expect(reads.value == 0)
        #expect(model.notes == before)
        model.close()
    }

    // MARK: - Pieces

    @Test func enumerationListsNamesOnlyAndMapsPlaceholders() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let all = try VaultEnumeration.listNotes(vault: url)
        #expect(all.map(\.id) == [AppModelTests.lecture, AppModelTests.deleted])
        #expect(all.allSatisfy { !$0.isUnlisted && $0.names == $0.names.sorted() })
        try cloud.evict(AppModelTests.lecture)
        let evicted = try VaultEnumeration.listNotes(vault: url, only: [AppModelTests.lecture, UUID()])
        #expect(evicted.map(\.id) == [AppModelTests.lecture], "a folder that is not there is left out")
        #expect(evicted.first?.names == all.first?.names, "placeholders count under their real names")
        try cloud.unlist(AppModelTests.lecture)
        #expect(try VaultEnumeration.listNotes(vault: url, only: [AppModelTests.lecture]).first?.isUnlisted == true)
        #expect(VaultEnumeration.revisionNames(in: ["x.age", ".hidden.age", "notes.txt"]).isEmpty)
    }

    @Test func diffSortsNotesIntoUnchangedChangedAndRemoved() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let listings = [NoteListing(id: a, names: ["1"]), NoteListing(id: b, names: ["1", "2"]), NoteListing(id: c, names: [])]
        let diff = IndexDiff.compute(listings: listings, indexed: [a: ["1"], b: ["1"], c: [], d: ["1"]], known: [a, b, c, d])
        #expect(diff.unchanged == [a])
        #expect(Set(diff.changed) == [b, c], "an unlisted folder is never unchanged")
        #expect(diff.removed == [d])
        // A scoped listing removes only notes in its scope.
        let scoped = IndexDiff.compute(listings: [listings[0]], indexed: [a: ["1"], d: ["1"]], known: [a, d], scope: [a])
        #expect(scoped.removed.isEmpty)
    }

    /// Property: applying differences gives the same list as replacing and re-sorting.
    @Test func listDiffEqualsAFullResort() {
        var rng = RNG(state: 9)
        func summary(_ id: UUID, _ title: String) -> NoteSummary {
            NoteSummary(id: id, title: title, tags: [], notebook: nil, deleted: false, pages: 1, strokes: Int(rng.next() % 3),
                        modified: nil, problem: nil)
        }
        let titles = ["a", "B", "b", "c", "", "Zed", "zed", "m"]
        for _ in 0..<300 {
            let ids = (0..<Int(rng.next() % 12)).map { _ in UUID() }
            let list = AppModel.byTitle(ids.map { summary($0, titles[Int(rng.next() % 8)]) })
            var upserts: [NoteSummary] = []
            for _ in 0..<Int(rng.next() % 6) {
                let id = rng.next() % 2 == 0 && !ids.isEmpty ? ids[Int(rng.next() % UInt64(ids.count))] : UUID()
                upserts.append(summary(id, titles[Int(rng.next() % 8)]))
            }
            let removals = Set(ids.filter { _ in rng.next() % 5 == 0 })
            var byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, n in n })
            for s in upserts where !removals.contains(s.id) { byID[s.id] = s }
            for id in removals { byID[id] = nil }
            let expected = AppModel.byTitle(Array(byID.values))
            let applied = NoteListDiff.apply(upserts: upserts, removals: removals, to: list) ?? list
            #expect(applied == expected)
        }
    }

    @Test func presenterReportsTheNoteAPathBelongsTo() {
        let notes = URL(fileURLWithPath: "/v/Vault.sempere/notes")
        let id = UUID()
        let folder = notes.appendingPathComponent(id.uuidString.lowercased())
        #expect(NotesFolderPresenter.noteID(for: folder, notesFolder: notes) == id)
        #expect(NotesFolderPresenter.noteID(for: folder.appendingPathComponent("1-a-1.delta.age"), notesFolder: notes) == id)
        #expect(NotesFolderPresenter.noteID(for: notes, notesFolder: notes) == nil)
        #expect(NotesFolderPresenter.noteID(for: notes.appendingPathComponent("not-a-note"), notesFolder: notes) == nil)
        #expect(NotesFolderPresenter.noteID(for: URL(fileURLWithPath: "/v/Other/notes/\(id)"), notesFolder: notes) == nil)
    }

    /// A reported change wakes the loop for that note only.
    @Test func aReportedChangeWakesTheLoopForThatNote() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let id = UUID()
        let woke = Flag()
        let sleeper = Task { @MainActor in
            try? await model.syncWakeup.sleep(for: .seconds(30))
            woke.set()
        }
        try await Task.sleep(for: .milliseconds(20))
        model.noteFoldersChanged([id])
        #expect(await TS.waitUntil(timeout: .seconds(2)) { woke.isSet })
        _ = await sleeper.value
        #expect(model.nextSyncScope(lastFullPass: .now) == [id])
        #expect(model.nextSyncScope(lastFullPass: .now) == nil, "reported once")
        model.noteFoldersChanged(nil)
        #expect(model.nextSyncScope(lastFullPass: .now) == nil, "unplaced: everything")
        // A wake while nobody sleeps ends the next sleep at once.
        let start = ContinuousClock.now
        try await model.syncWakeup.sleep(for: .seconds(30))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// Opening and listing a vault never blocks the main actor for long:
    /// decryption, listing and reading run elsewhere, and list updates are
    /// small, throttled differences. End to end, the longest main-thread busy
    /// stretch is reported (other tests share the main actor, so the bound is
    /// loose); each main-actor step is held to a budget on its own, measured
    /// as main-thread CPU time of the synchronous call (nothing else can run
    /// on the main actor during it).
    @Test func listingKeepsTheMainActorResponsive() async throws {
        let (vault, url) = try TS.unlockedFixture()
        let key = try String(contentsOf: try AppModelTests.fixtureVault().key, encoding: .utf8)
        let device = TS.deviceStateURL()
        for i in 0..<300 {
            let page = UUID()
            _ = try vault.apply(NoteOps.newNote(title: "Note \(i)", notebook: "Course \(i % 7)", tags: ["t\(i % 5)"], pageId: page)
                                + [.addStroke(page: page, stroke: TS.stroke())], to: UUID(), deviceState: device, app: "t/1")
        }
        let cacheDir = Self.tempDir()
        for pass in ["first open", "reopen from the index"] {
            let beat = Heartbeat()
            beat.start()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cacheDir)
            try await model.openVault(at: url)
            try await model.unlock(identityText: key)
            _ = (model.visibleNotes, model.tags, model.notebookTree)
            await model.summaryCacheSave?.value
            beat.stop()
            #expect(model.notes.count == 302)
            print("PERF main actor, \(pass), 302 notes: longest gap \(beat.longest), longest busy \(beat.longestBusy)")
            #expect(beat.longestBusy < .seconds(1), "\(pass): main actor busy for \(beat.longestBusy)")
            model.close()
        }
    }

    /// Main-thread CPU time of `body` (synchronous: nothing else runs on the
    /// main actor meanwhile, and other threads do not count).
    static func mainCPU(_ body: () -> Void) -> Duration {
        let start = Heartbeat.threadCPU()
        body()
        return Heartbeat.threadCPU() - start
    }

    /// The main-actor steps of a listing, on a 640-note list, within budget.
    @Test func mainActorStepsStayWithinBudget() {
        var rng = RNG(state: 5)
        let notes = (0..<640).map { i in
            NoteSummary(id: UUID(), title: "Lecture \(rng.next() % 900)", tags: ["t\(i % 9)", "Tag\(i % 4)"],
                        notebook: "Course \(i % 12)/Unit \(i % 5)", deleted: i % 31 == 0, pages: 3, strokes: 400,
                        modified: Date(timeIntervalSince1970: Double(rng.next() % 1_000_000)), problem: nil)
        }
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        var sorted: [NoteSummary] = []
        let show = Self.mainCPU { sorted = AppModel.byTitle(notes) }            // showing the index
        let apply = Self.mainCPU {                                                // one batch of changes
            var batch = Array(notes.shuffled(using: &rng).prefix(24))
            for i in batch.indices { batch[i].title += " (edited)" }
            _ = NoteListDiff.apply(upserts: batch, removals: [notes[0].id], to: sorted)
        }
        model.notes = sorted
        let derive = Self.mainCPU { _ = (model.visibleNotes, model.tags, model.notebookTree) }   // what the views read
        let again = Self.mainCPU { _ = (model.visibleNotes, model.tags, model.notebookTree) }    // memoised
        print("PERF main actor, 640 notes: index shown \(show), batch applied \(apply), lists derived \(derive), again \(again)")
        #expect(show < .milliseconds(100))
        #expect(apply < .milliseconds(30))
        #expect(derive < .milliseconds(100))
        #expect(again < .milliseconds(2))
    }
}

/// Counts from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ n: Int) { lock.withLock { count += n } }
}

/// Watches the main actor with a 2 ms tick: the longest gap between ticks
/// (`longest`, which also counts the main thread waiting for a CPU while
/// other threads decrypt), and the most main-thread CPU time spent between
/// two ticks (`longestBusy`): main-actor work that blocked the UI.
@MainActor
final class Heartbeat {
    private var task: Task<Void, Never>?
    private(set) var longest = Duration.zero
    private(set) var longestBusy = Duration.zero

    static func threadCPU() -> Duration {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return .seconds(ts.tv_sec) + .nanoseconds(ts.tv_nsec)
    }

    func start() {
        task = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            var lastCPU = Heartbeat.threadCPU()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = ContinuousClock.now, cpu = Heartbeat.threadCPU()
                if let self {
                    self.longest = max(self.longest, now - last)
                    self.longestBusy = max(self.longestBusy, cpu - lastCPU)
                }
                last = now
                lastCPU = cpu
            }
        }
    }

    func stop() { task?.cancel() }
}
