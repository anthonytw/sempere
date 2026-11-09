import Foundation
import XCTest
@testable import Sempere

/// The app's async thinning of one note (`NoteWriter.thin`) and the CLI's threaded pass (`prepareCompaction(s)`) are
/// two paths over the same stages; they must plan the same deletions and snapshots (docs/design/thin-app.md,
/// "Duplicates to remove first" item 6).
final class NoteThinningTests: VaultTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mode = CompactionMode.thin(olderThan: 30 * 86_400)

    private func vault(count: Int, plainCount: Int) throws -> Vault {
        let vault = try makeVault(pqIdentity())
        var rng = SeededRNG(5)
        for i in 0..<count {
            for r in SyntheticVault.reimportedNote(index: i, strokes: 4, points: 5, rng: &rng, baseMillis: 1_600_000_000_000,
                                                   reimportMillis: 1_790_000_000_000, withoutCheckpoints: i < plainCount) {
                try vault.write(r)
            }
        }
        return vault
    }

    /// Cold cache and warm cache, dry run and real: the same plan as `prepareCompaction`, the same files left after.
    func testAsyncThinningPlansWhatTheThreadedPassPlans() async throws {
        let vault = try vault(count: 6, plainCount: 3)
        let ids = try vault.noteIDs()
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        let clock = try DeviceClock(url: tmp.appendingPathComponent("device.json"), app: "t")
        var expected: [UUID: CompactionPlan] = [:]
        for id in ids {
            var c = HybridClock()
            expected[id] = try vault.prepareCompaction(id, mode: mode, now: now, device: clock.device, clock: &c, app: "t",
                                                       cache: nil).plan
        }
        XCTAssertEqual(expected.values.filter { !$0.deletions.isEmpty }.count, 3)
        for warm in [false, true] {
            if warm { _ = try vault.summaries(of: nil, cache: cache) }
            for id in ids {
                let got = try await NoteWriter.thin(id, mode: mode, vault: vault, clock: clock, cache: warm ? cache : nil,
                                                    coordinated: false, verify: nil, dryRun: true, now: now)
                let want = try XCTUnwrap(expected[id])
                XCTAssertEqual(got.plan.deletions, want.deletions, "warm: \(warm)")
                XCTAssertEqual(got.plan.snapshots.count, want.snapshots.count, "warm: \(warm)")
                XCTAssertEqual(got.plan.witnesses, want.witnesses, "warm: \(warm)")
            }
        }
        // A real run leaves exactly the revisions the threaded pass leaves on a copy.
        let before = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try vault.revisionNames(of: $0).count) })
        for id in ids {
            let done = try await NoteWriter.thin(id, mode: mode, vault: vault, clock: clock, cache: cache, coordinated: false,
                                                 verify: nil, dryRun: false, now: now)
            let after = try vault.revisionNames(of: id).count
            XCTAssertEqual(after, (before[id] ?? 0) - done.plan.deletions.count + done.plan.snapshots.count)
            XCTAssertEqual(done.plan.deletions, expected[id]?.deletions)
        }
    }

    /// A note opened after the plan is left alone, and nothing is written.
    func testOpenNoteIsLeftAlone() async throws {
        let vault = try vault(count: 1, plainCount: 1)
        let id = try XCTUnwrap(vault.noteIDs().first)
        let clock = try DeviceClock(url: tmp.appendingPathComponent("device.json"), app: "t")
        let before = try vault.revisionNames(of: id)
        do {
            _ = try await NoteWriter.thin(id, mode: mode, vault: vault, clock: clock, cache: nil, coordinated: false,
                                          verify: nil, dryRun: false, now: now, isOpen: { true })
            XCTFail("an open note must not be thinned")
        } catch is ThinningSkippedOpen {}
        XCTAssertEqual(try vault.revisionNames(of: id), before)
    }

    /// With `coordinated`, the write that deletes is coordinated on the note's folder (a directory URL), never the vault.
    func testCoordinatedWriteIsOnTheNoteFolder() async throws {
        final class Recorder: FileCoordinating, @unchecked Sendable {
            let lock = NSLock()
            var writes: [URL] = []
            func coordinateReading<T>(_ url: URL, _ body: () throws -> T) throws -> T { try body() }
            func coordinateWriting<T>(_ url: URL, _ body: () throws -> T) throws -> T {
                lock.withLock { writes.append(url) }
                return try body()
            }
        }
        let vault = try vault(count: 1, plainCount: 1)
        let id = try XCTUnwrap(vault.noteIDs().first)
        let clock = try DeviceClock(url: tmp.appendingPathComponent("device.json"), app: "t")
        let files = Recorder()
        let done = try await NoteWriter.thin(id, mode: mode, vault: vault, clock: clock, cache: nil, coordinated: true,
                                             files: files, verify: nil, dryRun: false, now: now)
        XCTAssertFalse(done.plan.deletions.isEmpty)
        XCTAssertEqual(files.writes.count, 1)
        let url = try XCTUnwrap(files.writes.first)
        XCTAssertTrue(url.hasDirectoryPath)
        XCTAssertEqual(url.standardizedFileURL.path, vault.noteURL(id).standardizedFileURL.path)
    }

    /// The cache's verdict is the rule behind both paths' shortcut: nil without metadata, then what `mayDelete` says.
    func testCachedVerdictIsTheSharedShortcut() throws {
        let vault = try vault(count: 2, plainCount: 1)
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        let ids = try vault.noteIDs()
        for id in ids {
            let names = try vault.revisionNames(of: id)
            XCTAssertNil(Vault.cachedCompactionVerdict(id, revisions: names, mode: mode, now: now, cache: cache))
            XCTAssertNil(Vault.cachedCompactionVerdict(id, revisions: names, mode: mode, now: now, cache: nil))
        }
        _ = try vault.summaries(of: nil, cache: cache)
        for id in ids {
            let names = try vault.revisionNames(of: id)
            let verdict = try XCTUnwrap(Vault.cachedCompactionVerdict(id, revisions: names, mode: mode, now: now, cache: cache))
            var c = HybridClock()
            let plan = try vault.prepareCompaction(id, mode: mode, now: now, device: .random(), clock: &c, app: "t", cache: nil).plan
            XCTAssertEqual(verdict, !plan.deletions.isEmpty)
        }
    }
}
