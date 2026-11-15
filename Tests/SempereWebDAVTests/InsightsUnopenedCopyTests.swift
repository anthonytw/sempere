import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Insights files only on the target that open under no key this device holds: fetched until their version tag
/// settles, then not again while it stands (format.md §16.6; `InsightsSync.swift`), and counted with the run's refused
/// files.
final class InsightsUnopenedCopyTests: InsightsSyncScenarioCase {
    override func transport() throws -> TransportUnderTest { .memory() }

    private let clock = Locked(Date(timeIntervalSince1970: 1_900_000_000))
    private let uptime = Locked(TimeInterval(1_000))

    override func setUpWithError() throws {
        try super.setUpWithError()
        let clock = clock, uptime = uptime
        SyncEngine.stampClock = { clock.value }
        SyncEngine.stampUptime = { uptime.value }
    }

    override func tearDown() {
        SyncEngine.stampClock = { Date() }
        SyncEngine.stampUptime = { ProcessInfo.processInfo.systemUptime }
        super.tearDown()
    }

    private func tick() {
        clock.value = clock.value.addingTimeInterval(10)
        uptime.value += 10
    }

    /// Files under names the scheme accepts whose bodies open under no key.
    private func plantUnopenable(_ count: Int) throws -> [String] {
        try t.inspector.makeCollection(["insights"])
        var planted: [String] = []
        for i in 0..<count {
            let name = "\(UUID().uuidString.lowercased()).deadbe\(String(format: "%02x", i))\(InsightsFileName.suffix)"
            XCTAssertNotNil(InsightsFileName(name))
            try t.inspector.write(["insights", name], .data(Data(repeating: 0x41, count: 4 << 10)), condition: .unconditional)
            planted.append(name)
        }
        return planted
    }

    private func insightsReads(_ name: String) throws -> (SyncReport, Int) {
        let faults = MemoryFaults(seed: 1)
        let mem = try XCTUnwrap(t.remote as? MemoryRemote)
        let r = try run(name, via: mem.with(faults: faults))
        return (r, faults.log.filter { $0.path.first == "insights" && ($0.verb == .read || $0.verb == .download) }.count)
    }

    func testAnUnopenableTargetOnlyCopyIsNotFetchedAgainOnceSettled() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        let planted = try plantUnopenable(6)
        tick()
        let (first, reads1) = try insightsReads("B")
        XCTAssertEqual(reads1, planted.count)
        XCTAssertEqual(Set(first.skipped.map(\.path)), Set(planted.map { "insights/\($0)" }), "\(first.skipped)")
        tick()
        let (_, reads2) = try insightsReads("B")
        XCTAssertEqual(reads2, planted.count, "read again once, which settles the version tags")
        for _ in 0..<2 {
            tick()
            let (later, reads) = try insightsReads("B")
            XCTAssertEqual(reads, 0)
            XCTAssertTrue(later.isEmpty, StressWorld.brief(later))
        }
        XCTAssertTrue(localInsights("B").isEmpty, "never placed")

        // A changed copy is fetched again.
        try t.inspector.write(["insights", planted[0]], .data(Data(repeating: 0x42, count: 4 << 10)), condition: .unconditional)
        tick()
        let (_, reads3) = try insightsReads("B")
        XCTAssertEqual(reads3, 1)
    }

    func testUnopenableCopiesCountAsRefusedFiles() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        _ = try plantUnopenable(6)
        let r = try run("B") { $0.limits.maxRefusedFiles = 3 }
        XCTAssertNotNil(r.stoppedEarly, StressWorld.brief(r))
    }

    /// A run stopped by the refused-files limit keeps the records of the files it judged: later runs go on from them and
    /// the pass comes to rest.
    func testARunStoppedByTheRefusedLimitKeepsItsRecords() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        _ = try plantUnopenable(6)
        let mem = try XCTUnwrap(t.remote as? MemoryRemote)
        var last: (stopped: String?, reads: Int) = ("never ran", -1)
        for _ in 0..<6 {
            tick()
            let faults = MemoryFaults(seed: 1)
            let r = try run("B", via: mem.with(faults: faults)) { $0.limits.maxRefusedFiles = 3 }
            last = (r.stoppedEarly, faults.log.filter { $0.path.first == "insights" && ($0.verb == .read || $0.verb == .download) }.count)
        }
        XCTAssertNil(last.stopped)
        XCTAssertEqual(last.reads, 0)
    }

    /// Sidecars on `name` for `count` new notes.
    private func writeSidecars(on name: String, count: Int) throws -> [InsightsFileName] {
        let store = InsightsStore(vault: try openVault(name))
        let gen = InsightsNoteFile.Gen(hash: String(repeating: "a", count: 32), identity: .init(model: "m", os: "27.2", prompt: 1),
                                       summary: "A summary.", keywords: [], concepts: [], dropped: 0)
        return try (0..<count).map { _ in
            try store.write(.note(InsightsNoteFile(noteId: UUID(), device: try store.writer(), written: 0, gen: gen)))
        }
    }

    /// After an epoch change without a re-encryption a device deletes its own files under the earlier key; the target
    /// still holds their earlier copies. Its runs neither fetch them nor count them as refused files.
    func testOwnEarlierKeyCopiesOnTheTargetDoNotStopARun() throws {
        try devices(["A", "B", "X"])
        try setEnabled(true)
        try settle("A"); try settle("B"); try settle("X")
        let own = try writeSidecars(on: "A", count: 5)
        try settle("A")
        XCTAssertTrue(Set(try remoteInsights()).isSuperset(of: own.map(\.fileName)))
        var a = try openVault("A")
        try a.removeDevices([device("X").rawValue])
        let deleted = try InsightsStore(vault: try openVault("A")).removeOwnEarlierKey()
        XCTAssertEqual(Set(deleted), Set(own.map { "insights/\($0.fileName)" }))
        tick()
        let mem = try XCTUnwrap(t.remote as? MemoryRemote)
        for round in 0..<2 {
            let faults = MemoryFaults(seed: 1)
            let r = try run("A", via: mem.with(faults: faults)) { $0.limits.maxRefusedFiles = 3 }
            XCTAssertNil(r.stoppedEarly, "round \(round): \(StressWorld.brief(r))")
            let reads = faults.log.filter { f in
                f.path.first == "insights" && own.contains { $0.fileName == f.path.last } && (f.verb == .read || f.verb == .download)
            }
            XCTAssertEqual(reads.count, 0, "round \(round)")
            tick()
        }
    }

    /// Another device's copies under an earlier key this device holds, only on the target: fetched until their version
    /// tags settle, not counted as refused files, and then not fetched again.
    func testEarlierKeyCopiesOfAnotherDeviceAreNotRefusedFiles() throws {
        try devices(["A", "B", "X"])
        try setEnabled(true)
        try settle("A"); try settle("B"); try settle("X")
        let theirs = try writeSidecars(on: "B", count: 5)
        try settle("B"); try settle("A")
        for n in theirs { try FileManager.default.removeItem(at: dir("A").appendingPathComponent("insights/\(n.fileName)")) }
        var a = try openVault("A")
        try a.removeDevices([device("X").rawValue])
        tick()
        let mem = try XCTUnwrap(t.remote as? MemoryRemote)
        var reads: [Int] = []
        for round in 0..<3 {
            let faults = MemoryFaults(seed: 1)
            let r = try run("A", via: mem.with(faults: faults)) { $0.limits.maxRefusedFiles = 3 }
            XCTAssertNil(r.stoppedEarly, "round \(round): \(StressWorld.brief(r))")
            reads.append(faults.log.filter { f in
                f.path.first == "insights" && theirs.contains { $0.fileName == f.path.last } && (f.verb == .read || f.verb == .download)
            }.count)
            tick()
        }
        XCTAssertEqual(reads.first, theirs.count, "\(reads)")
        XCTAssertEqual(reads.last, 0, "\(reads)")
    }
}
