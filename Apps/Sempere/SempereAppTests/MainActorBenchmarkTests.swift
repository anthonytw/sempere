import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Main-actor budgets of opening and listing a vault: wall-clock and CPU-time bounds, so a benchmark, not a gate
/// test (`perf_suites` in scripts/app.sh: `test-mac-perf`, `local-ci.sh --testflight` and `--release`). What they
/// guard structurally is in `ListEpochTests` (`visibleNotesAreComputedOncePerChangeOfListOrFilters`) and `IndexTests`.
@MainActor
struct MainActorBenchmarkTests {
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
        let cacheDir = TestTemp.root.appendingPathComponent("sempere-index-\(UUID().uuidString)")
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
        var rng = SplitMix(state: 5)
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
        let again = Self.mainCPU { _ = (model.visibleNotes, model.tags, model.notebookTree) }    // memoized
        print("PERF main actor, 640 notes: index shown \(show), batch applied \(apply), lists derived \(derive), again \(again)")
        #expect(show < .milliseconds(100))
        #expect(apply < .milliseconds(30))
        #expect(derive < .milliseconds(100))
        #expect(again < .milliseconds(2))
    }
}

/// A seeded generator (SplitMix64), as the index suites' (`IndexTests.RNG`, which moved to SempereAppCoreTests).
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
