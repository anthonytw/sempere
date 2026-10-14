import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Before and after timings for performance round 3 (TestFlight build 6
/// feedback) on a generated vault shaped like the maintainer's: 640 notes,
/// each with an image attachment, imported, listed on this device, then all
/// re-imported with `--overwrite` (a second full delta per note, dated, as the
/// importer used to, by the note's creation). Prints `PERF-REPORT` lines (read
/// them in the CI `app` log); asserts only that the new paths do the same
/// work with fewer iCloud queries and no more time.
///
/// "Before" is today's code configured as the previous build behaved:
/// - iCloud passes: every pass asked for the state of every arriving note's
///   files (`cloudCheckLimit` unlimited), downloads were requested 16 notes
///   at a time (`cloudWindow`), and the index was saved after every pass;
/// - reads: batches of 24 whatever the count (`loadBatchLimit` 0);
/// - thinning: every note read in full and planned, one after another.
/// The simulator answers file-state queries in microseconds; on a device each
/// is a round trip to the file provider, so the query counts are the numbers
/// that matter there.
@MainActor
@Suite(.serialized)
struct MassReimportReportTests {
    static let noteCount = Int(ProcessInfo.processInfo.environment["SEMPERE_PERF_REIMPORT_NOTES"] ?? "") ?? 640
    static let created = Date(timeIntervalSince1970: 1_600_000_000)

    /// One import of note `id` as the importer wrote it before imports were
    /// checkpoints: pages, title, strokes and an image, after removing `old` pages.
    static func importDelta(_ id: UUID, index: Int, seq: Int, hlcMs: Int64, old: [UUID], blob: BlobRef,
                            rng: inout PerformanceReportTests.RNG, device: DeviceID) -> (Revision, [UUID]) {
        let page = Page(order: "a0")
        var ops: [Op] = old.map { .removePage(pageId: $0) }
        ops += [.setMeta(.title(seq == 1 ? "Note \(index)" : "Note \(index) (re-imported)")),
                .setMeta(.notebook("Course \(index % 7)")), .addPage(page)]
        for _ in 0..<80 { ops.append(.addStroke(page: page.id, stroke: PerformanceReportTests.stroke(&rng, points: 25))) }
        ops.append(.addItem(page: page.id, item: .image(blob: blob, pixelSize: Size(w: 4, h: 3),
                                                        frame: Rect(x: 40, y: 40, w: 120, h: 90), z: "a")))
        let r = Revision(noteId: id, device: device, seq: seq, hlc: HLC(millis: hlcMs, counter: 0)!, wall: created,
                         app: "sempere-import/0.1", body: .delta(ops: ops))
        return (r, [page.id])
    }

    static func ms(_ d: Duration) -> String { PerformanceReportTests.ms(d) }

    static func copy(_ dir: URL) throws -> URL {
        let to = FileManager.default.temporaryDirectory.appendingPathComponent("perf3-cache-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: dir, to: to)
        return to
    }

    @Test func massReimportTimings() async throws {
        let (vault, url) = try TS.unlockedFixture()
        let key = try String(contentsOf: try AppModelTests.fixtureVault().key, encoding: .utf8)
        let device = DeviceID("9e7f0003")!
        var rng = PerformanceReportTests.RNG(state: 7)
        let png = AttachmentEditorTests.png()
        var pages: [UUID: [UUID]] = [:]
        var blobs: [UUID: BlobRef] = [:]
        var ids: [UUID] = []
        let base: Int64 = 1_780_000_000_000
        var start = ContinuousClock.now
        for i in 0..<Self.noteCount {
            let id = UUID()
            ids.append(id)
            let blob = try vault.writeBlob(note: id, png + Data("note \(i)".utf8), type: "image/png")
            blobs[id] = blob
            let (r, p) = Self.importDelta(id, index: i, seq: 1, hlcMs: base + Int64(i) * 1000, old: [], blob: blob,
                                          rng: &rng, device: device)
            try vault.write(r)
            pages[id] = p
        }
        let total = Self.noteCount + 2
        print("PERF-REPORT round3 generated \(Self.noteCount) imported notes with an image each in \(ContinuousClock.now - start)")

        // This device lists the vault: its index knows every note as first imported.
        let indexDir = FileManager.default.temporaryDirectory.appendingPathComponent("perf3-\(UUID().uuidString)")
        var model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: indexDir)
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)
        #expect(model.notes.count == total)
        await model.summaryCacheSave?.value
        model.close()

        // The mass re-import, from another machine.
        start = ContinuousClock.now
        for (i, id) in ids.enumerated() {
            let (r, _) = Self.importDelta(id, index: i, seq: 2, hlcMs: base + 10_000_000 + Int64(i) * 1000, old: pages[id] ?? [],
                                          blob: blobs[id]!, rng: &rng, device: device)
            try vault.write(r)
        }
        print("PERF-REPORT round3 re-imported \(Self.noteCount) notes in \(ContinuousClock.now - start)")
        func reimported(_ m: AppModel) -> Int { m.notes.filter { $0.title.hasSuffix("(re-imported)") }.count }

        // 1. A local vault (no iCloud): the first open after the re-import reads every changed note.
        var local: [String: Duration] = [:]
        for label in ["BEFORE", "AFTER"] {
            model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: try Self.copy(indexDir))
            if label == "BEFORE" { model.loadBatchLimit = 0 }
            try await model.openVault(at: url)
            start = ContinuousClock.now
            try await model.unlock(identityText: key)
            local[label] = ContinuousClock.now - start
            #expect(reimported(model) == Self.noteCount)
            model.close()
        }
        print("PERF-REPORT round3 open after mass re-import, local vault, \(Self.noteCount) changed notes read: "
              + "BEFORE \(Self.ms(local["BEFORE"]!)), AFTER \(Self.ms(local["AFTER"]!))")

        // 2. iCloud: every changed note arrives later, 32 notes per pass, in the order they were requested.
        var cloudReport: [String: (passes: Int, queries: Int, time: Duration)] = [:]
        for label in ["BEFORE", "AFTER"] {
            let cloud = FakeCloud(vault: url)
            for id in ids { try cloud.evict(id) }
            let queries = Counter()
            var hooks = cloud.hooks
            let state = hooks.state
            hooks.state = { queries.add(1); return state($0) }
            model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: try Self.copy(indexDir))
            model.cloudHooks = hooks
            model.cloudPollInterval = .seconds(3600)   // the passes below are the test's own
            model.cloudIdleInterval = .seconds(3600)
            if label == "BEFORE" {
                model.cloudWindow = 16
                model.cloudCheckLimit = .max
                model.loadBatchLimit = 0
                model.summaryCacheSaveInterval = .zero
            }
            start = ContinuousClock.now
            try await model.openVault(at: url)
            try await model.unlock(identityText: key)
            var delivered = Set<String>()
            var passes = 1
            while !model.pendingNoteIDs.isEmpty && passes < 500 {
                let next = cloud.requestedNotes.filter { !delivered.contains($0) }.prefix(32)
                var arrived = Set<UUID>()
                for name in next {
                    delivered.insert(name)
                    if let id = UUID(uuidString: name) { try cloud.deliver(id); arrived.insert(id) }
                }
                model.noteFoldersChanged(arrived)
                _ = model.nextSyncScope(lastFullPass: .now)
                try await model.reconcile(scope: model.pendingNoteIDs.union(arrived))
                passes += 1
            }
            let time = ContinuousClock.now - start
            #expect(model.pendingNoteIDs.isEmpty, "\(label)")
            #expect(reimported(model) == Self.noteCount, "\(label)")
            cloudReport[label] = (passes, queries.value, time)
            model.close()
        }
        let b = cloudReport["BEFORE"]!, a = cloudReport["AFTER"]!
        print("PERF-REPORT round3 iCloud, \(Self.noteCount) changed notes arriving 32 per pass: "
              + "BEFORE \(b.passes) passes, \(b.queries) file-state queries, \(Self.ms(b.time)); "
              + "AFTER \(a.passes) passes, \(a.queries) file-state queries, \(Self.ms(a.time))")
        #expect(a.queries < b.queries)

        // 3. Thinning, 30 days, a year later: every note's first import is an old autosave of the
        //    same "session" as the re-import (legacy importer), so every note has something to thin.
        let later = Date(timeIntervalSince1970: Double(base) / 1000 + 400 * 86_400)
        let mode = CompactionMode.thin(olderThan: 30 * 86_400)
        start = ContinuousClock.now
        var beforeDeletions = 0
        for id in try vault.noteIDs() {
            var clock = HybridClock()
            let plan = try vault.planCompaction(id, loaded: try vault.loadNote(id), mode: mode, now: later, device: device,
                                                clock: &clock, app: "perf")
            _ = try vault.addedBytes(plan)
            beforeDeletions += plan.deletions.count
        }
        let thinBefore = ContinuousClock.now - start
        model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: try Self.copy(indexDir))
        try await model.openVault(at: url)
        try await model.unlock(identityText: key)   // the listing stores every note's revision metadata
        start = ContinuousClock.now
        let preview = try await model.thinVault(rule: .olderThan(days: 30), dryRun: true, now: later)
        let previewTime = ContinuousClock.now - start
        #expect(preview.deletions == beforeDeletions)
        start = ContinuousClock.now
        let run = try await model.thinVault(rule: .olderThan(days: 30), dryRun: false, now: later)
        let runTime = ContinuousClock.now - start
        #expect(run.deletions == beforeDeletions)
        start = ContinuousClock.now
        let again = try await model.thinVault(rule: .olderThan(days: 30), dryRun: true, now: later)
        let againTime = ContinuousClock.now - start
        #expect(again.isEmpty)
        print("PERF-REPORT round3 thinning preview, \(total) notes, \(beforeDeletions) deletions: BEFORE \(Self.ms(thinBefore)) "
              + "(one note at a time, each read in full); AFTER preview \(Self.ms(previewTime)), run \(Self.ms(runTime)), "
              + "preview with nothing left to thin \(Self.ms(againTime)) (decided from the index)")
        model.close()
    }
}
