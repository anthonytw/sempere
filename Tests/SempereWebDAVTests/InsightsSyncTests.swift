import Age
import Foundation
import FuzzSupport
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// `insights/` through the engine (format.md §16.6; docs/design/1.2-note-insights.md §3.5, §9 "Vault paths"), over
/// `MemoryRemote`, `WebDAVSyncRemote` on `MockDAV` and wsgidav: own files up, others' down only when they open under the
/// current key, the later `written` wins (a device bridging two targets settles), a locked run skips, off deletes
/// everywhere, unset leaves everything alone, a removed device's file is deleted; and an old reader's paths (no
/// insights setting: open, sync, push-only with delete-extraneous, verify, back up, copy-merge) leave `insights/` as it is.
class InsightsSyncScenarioCase: SyncTestCase {
    func transport() throws -> TransportUnderTest { throw XCTSkip("abstract") }

    private(set) var t: TransportUnderTest!
    private var label: String { t.kind }
    let identityB = pqIdentity()
    let identityX = pqIdentity()
    let note = UUID(uuidString: "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        t = try transport()
    }

    func identity(of name: String) -> NativeIdentity { name == "B" ? identityB : name == "X" ? identityX : identity }

    override func openVault(_ name: String) throws -> Vault {
        try Vault.open(at: dir(name), identities: [identity(of: name)], signing: TestVaults.signing(identity(of: name)))
    }

    func device(_ name: String) -> DeviceID { DeviceID(TestVaults.device(identity(of: name)).id)! }

    @discardableResult
    func run(_ name: String, via remote: (any SyncRemote)? = nil, locked: Bool = false, state: String? = nil,
             _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        let v: Vault? = !exists ? nil : locked ? try Vault.open(at: dir(name)) : try openVault(name)
        var o = SyncOptions(deviceLabel: name)
        o.deviceID = device(name)
        if !locked { o.firstPullIdentities = [identity(of: name)] }
        edit(&o)
        return try SyncEngine(directory: dir(name), vault: v, remote: remote ?? t.remote,
                              stateURL: tmp.appendingPathComponent("state-\(state ?? name).json"), options: o).run()
    }

    @discardableResult
    func settle(_ name: String, rounds: Int = 6, file: StaticString = #filePath, line: UInt = #line) throws -> SyncReport {
        var last = SyncReport()
        for _ in 0..<rounds {
            last = try run(name)
            if last.isEmpty { return last }
        }
        XCTFail("\(label) \(name): never quiet: \(StressWorld.brief(last))", file: file, line: line)
        return last
    }

    /// A vault of A (home), B and X, uploaded by A and pulled by B (and X).
    func devices(_ names: [String] = ["A", "B"]) throws {
        try TestVaults.create(at: dir("A"), identities: names.map(identity(of:)), names: names)
        try settle("A")
        for n in names.dropFirst() { try settle(n) }
    }

    func setEnabled(_ on: Bool?, on name: String = "A") throws {
        try openVault(name).updateSharedSettings { s in
            try s.write(SharedSettingsCatalog.spec(named: "insights.enabled")!, on.map { .bool($0) }, block: nil, type: nil, now: Date())
        }
    }

    @discardableResult
    func writeSidecar(on name: String, summary: String = "A summary.", now: Date = Date()) throws -> InsightsFileName {
        let v = try openVault(name)
        let store = InsightsStore(vault: v)
        let gen = InsightsNoteFile.Gen(hash: String(repeating: "a", count: 32), identity: .init(model: "m", os: "27.2", prompt: 1),
                                       summary: summary, keywords: [], concepts: [], dropped: 0)
        return try store.write(.note(InsightsNoteFile(noteId: note, device: try store.writer(), written: 0, gen: gen)), now: now)
    }

    func localInsights(_ name: String) -> [String] {
        InsightsStore.names(in: dir(name).appendingPathComponent("insights")).map(\.fileName)
    }

    func remoteInsights() throws -> [String] {
        (try t.inspector.list(["insights"]) ?? []).map(\.name).filter { !$0.hasPrefix(".") }.sorted()
    }

    func summary(on name: String, _ file: InsightsFileName) throws -> String? {
        guard case .note(let f)? = try InsightsStore(vault: openVault(name)).read(file) else { return nil }
        return f.gen?.summary
    }

    // MARK: Scenarios

    func scenarioOwnUpOthersDownLaterWins() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        let name = try writeSidecar(on: "A", summary: "First.")
        let up = try run("A")
        XCTAssertTrue(up.uploaded.contains("insights/\(name.fileName)"), "\(label): \(StressWorld.brief(up))")
        let down = try run("B")
        XCTAssertTrue(down.downloaded.contains("insights/\(name.fileName)"), "\(label): \(StressWorld.brief(down))")
        XCTAssertEqual(try summary(on: "B", name), "First.")
        // A later copy reaches B through another target (a bridge): B puts it up; A takes the same bytes.
        try writeSidecar(on: "A", summary: "Second.", now: Date().addingTimeInterval(5))
        try FileManager.default.removeItem(at: dir("B").appendingPathComponent("insights/\(name.fileName)"))
        try FileManager.default.copyItem(at: dir("A").appendingPathComponent("insights/\(name.fileName)"),
                                         to: dir("B").appendingPathComponent("insights/\(name.fileName)"))
        let bridge = try run("B")
        XCTAssertTrue(bridge.uploaded.contains("insights/\(name.fileName)"), "\(label): \(StressWorld.brief(bridge))")
        try settle("A"); try settle("B")
        XCTAssertEqual(try summary(on: "B", name), "Second.")
        XCTAssertEqual(try summary(on: "A", name), "Second.")
        // An earlier copy planted on the target never wins over a later one.
        let older = try Data(contentsOf: dir("A").appendingPathComponent("insights/\(name.fileName)"))
        try writeSidecar(on: "A", summary: "Third.", now: Date().addingTimeInterval(10))
        try t.inspector.write(["insights", name.fileName], .data(older), condition: .unconditional)
        try settle("A"); try settle("B")
        XCTAssertEqual(try summary(on: "B", name), "Third.")
    }

    func scenarioOnlyCurrentKeyCopiesTravel() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        // Junk under B's name for the note: never placed on A; B's own copy replaces it.
        let junkName = InsightsFileName(note: note, device: device("B")).fileName
        try t.inspector.makeCollection(["insights"])
        try t.inspector.write(["insights", junkName], .data(Data("not an insights file".utf8)), condition: .unconditional)
        let a = try run("A")
        XCTAssertFalse(a.downloaded.contains("insights/\(junkName)"), "\(label): \(StressWorld.brief(a))")
        XCTAssertFalse(localInsights("A").contains(junkName))
        try writeSidecar(on: "B", summary: "Real.")
        try settle("B"); try settle("A")
        XCTAssertEqual(try summary(on: "A", InsightsFileName(junkName)!), "Real.")
    }

    func scenarioLockedRunSkipsAndUnsetLeavesAlone() throws {
        try devices()
        // Unset: a device's file is neither uploaded nor deleted.
        try writeSidecar(on: "A")
        let unset = try run("A")
        XCTAssertFalse(unset.uploaded.contains { $0.hasPrefix("insights/") }, "\(label): \(StressWorld.brief(unset))")
        XCTAssertEqual(localInsights("A").count, 1)
        // On, but locked: nothing about insights.
        try setEnabled(true)
        try settle("A")
        try writeSidecar(on: "B")
        let locked = try run("B", locked: true)
        XCTAssertFalse((locked.uploaded + locked.downloaded).contains { $0.hasPrefix("insights/") }, "\(label): \(StressWorld.brief(locked))")
        let unlocked = try run("B")
        XCTAssertTrue((unlocked.uploaded + unlocked.downloaded).contains { $0.hasPrefix("insights/") }, "\(label): \(StressWorld.brief(unlocked))")
    }

    func scenarioOffDeletesEverywhere() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        try writeSidecar(on: "A"); try writeSidecar(on: "B")
        try settle("A"); try settle("B"); try settle("A")
        XCTAssertEqual(try remoteInsights().count, 2)
        try setEnabled(false, on: "B")
        try run("B")
        XCTAssertEqual(try remoteInsights(), [], label)
        XCTAssertEqual(localInsights("B"), [])
        try settle("A")
        XCTAssertEqual(localInsights("A"), [], "\(label): every device deletes them")
        XCTAssertEqual(try remoteInsights(), [])
    }

    func scenarioRemovedDevicesFileIsDeleted() throws {
        try devices(["A", "B", "X"])
        try setEnabled(true)
        try settle("A"); try settle("B"); try settle("X")
        try writeSidecar(on: "X")
        try settle("X")
        try settle("A")
        let xName = InsightsFileName(note: note, device: device("X")).fileName
        XCTAssertTrue(localInsights("A").contains(xName))
        var a = try openVault("A")
        try a.removeDevices([device("X").rawValue])
        let r = try run("A")
        XCTAssertTrue(r.deleted.contains { $0.path == "insights/\(xName)" && $0.side == "local" }, "\(label): \(StressWorld.brief(r))")
        try settle("A")
        XCTAssertFalse(try remoteInsights().contains(xName), label)
        try settle("B")
        XCTAssertFalse(localInsights("B").contains(xName), label)
    }

    /// What a reader that does not know `insights/` does (main before 1.2, and 1.2 with the setting unset): every vault
    /// path leaves the folder as it is.
    func scenarioOldReaderLeavesInsightsUntouched() throws {
        try devices()
        try writeSidecar(on: "A")
        try Data("unknown".utf8).write(to: dir("A").appendingPathComponent("insights/notes-from-the-future.txt"))
        let before = try FileTree.snapshotOf(dir("A").appendingPathComponent("insights"))
        try settle("A")
        let mirror = MemoryRemote(store: MemoryStore(name: "mirror"), base: ["vault"])
        try run("A", via: mirror, state: "mirror") { $0.pushOnly = true; $0.deleteExtraneous = true }
        let v = try openVault("A")
        XCTAssertTrue(v.verify().isHealthy)
        XCTAssertEqual(v.verify().insights.map(\.state), [.open])
        let backup = tmp.appendingPathComponent("backup")
        _ = try Backup.run(source: v, to: backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("insights").path), "backups exclude insights/")
        try FileManager.default.copyItem(at: dir("B"), to: tmp.appendingPathComponent("B2.sempere"))
        _ = try v.mergeCopy(from: tmp.appendingPathComponent("B2.sempere"))
        XCTAssertEqual(try FileTree.snapshotOf(dir("A").appendingPathComponent("insights")), before, label)
        XCTAssertEqual(try remoteInsights(), [], "nothing uploaded while the setting is unset")
    }
}

extension FileTree {
    /// Every regular file under `dir` with its bytes (empty when the folder is missing).
    static func snapshotOf(_ dir: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }
        return try FileTree.snapshot(of: dir)
    }
}

final class InsightsSyncOverMemoryTests: InsightsSyncScenarioCase {
    override func transport() throws -> TransportUnderTest { .memory() }
    func testOwnUpOthersDownLaterWins() throws { try scenarioOwnUpOthersDownLaterWins() }
    func testOnlyCurrentKeyCopiesTravel() throws { try scenarioOnlyCurrentKeyCopiesTravel() }
    func testLockedRunSkipsAndUnsetLeavesAlone() throws { try scenarioLockedRunSkipsAndUnsetLeavesAlone() }
    func testOffDeletesEverywhere() throws { try scenarioOffDeletesEverywhere() }
    func testRemovedDevicesFileIsDeleted() throws { try scenarioRemovedDevicesFileIsDeleted() }
    func testOldReaderLeavesInsightsUntouched() throws { try scenarioOldReaderLeavesInsightsUntouched() }

    /// Insights count against the run's bounds (D17): a run that may download nothing more stops, reported.
    func testInsightsCountAgainstTheRunBounds() throws {
        try devices()
        try setEnabled(true)
        try settle("A"); try settle("B")
        try writeSidecar(on: "A")
        try settle("A")
        let r = try run("B") { $0.limits.maxDownloadBytes = 1 }
        XCTAssertFalse(r.downloaded.contains { $0.hasPrefix("insights/") }, StressWorld.brief(r))
    }
}

final class InsightsSyncOverWebDAVMockTests: InsightsSyncScenarioCase {
    override func transport() throws -> TransportUnderTest { try .mockDAV() }
    func testOwnUpOthersDownLaterWins() throws { try scenarioOwnUpOthersDownLaterWins() }
    func testOffDeletesEverywhere() throws { try scenarioOffDeletesEverywhere() }
    func testOldReaderLeavesInsightsUntouched() throws { try scenarioOldReaderLeavesInsightsUntouched() }
}

final class InsightsSyncOverWsgidavTests: InsightsSyncScenarioCase {
    override func transport() throws -> TransportUnderTest { try .wsgidav() }
    func testOwnUpOthersDownLaterWins() throws { try scenarioOwnUpOthersDownLaterWins() }
    func testOnlyCurrentKeyCopiesTravel() throws { try scenarioOnlyCurrentKeyCopiesTravel() }
    func testOffDeletesEverywhere() throws { try scenarioOffDeletesEverywhere() }
    func testRemovedDevicesFileIsDeleted() throws { try scenarioRemovedDevicesFileIsDeleted() }
}
