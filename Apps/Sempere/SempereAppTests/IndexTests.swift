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
        TestTemp.root.appendingPathComponent("sempere-index-\(UUID().uuidString)")
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
