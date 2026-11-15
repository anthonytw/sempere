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
}
