import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// The invariants of the CloudKit transport's conditional writes and deletes (docs/design/1.4-cloudkit.md §2.2 to §2.5),
/// on seeded random runs: three devices, each with a mirror of its own, create, replace and delete five files on one
/// `MemoryCloudDatabase` (one of them split into parts), sync, and meet transport faults. An oracle holds what the
/// zone must contain; after every operation the answer is compared with it:
///
/// - **C1** a create never replaces a file that is there, and succeeds on one that is not;
/// - **C2** a conditional replace applies over the version it names and over no other;
/// - **C3** a conditional delete deletes only the version it names;
/// - **C4** a file deleted and written again arrives (a create over a tombstone);
/// - **C5** after `prepareRun()` a device lists exactly what the zone holds, tombstones absent;
/// - **C6** a delete that says it deleted, deleted;
/// - **C7** a device reads its own writes without waiting for the feed.
///
/// Each test-only mutation (`CloudRemoteMutation`) must break ITS invariant on a seed whose unmutated run is clean
/// (`testMutation…`; `testEveryMutationHasItsTest` fails when one has none), so none is vacuous. The epoch invariants
/// J1 to J10 over CloudKit targets run in `EpochInterleavingTests`. Quick mode: 3 seeds in every `swift test`;
/// `SEMPERE_SYNC_STRESS_LONG=1` runs `SEMPERE_SYNC_STRESS_SEEDS` (60) of 400 steps; `SEMPERE_CLOUD_SEED=N` replays one seed;
/// `SEMPERE_CLOUD_TRACE=1` prints a failing run's operations.
final class CloudInterleavingTests: TempDirTestCase {
    override func tearDown() {
        CloudRecordRemote.mutations = []
        super.tearDown()
    }

    enum Mutation: CaseIterable {
        case createReplaces, replaceIgnoresTag, deleteIgnoresTag, createOverTombstoneRefused, tombstonesListed
        case deleteSkipsTombstone, ownWritesNotMirrored

        var breaks: String {
            switch self {
            case .createReplaces: return "C1"
            case .replaceIgnoresTag: return "C2"
            case .deleteIgnoresTag: return "C3"
            case .createOverTombstoneRefused: return "C4"
            case .tombstonesListed: return "C5"
            case .deleteSkipsTombstone: return "C6"
            case .ownWritesNotMirrored: return "C7"
            }
        }

        var remote: CloudRemoteMutation {
            switch self {
            case .createReplaces: return .createReplacesExisting
            case .replaceIgnoresTag: return .replaceIgnoresTag
            case .deleteIgnoresTag: return .deleteIgnoresTag
            case .createOverTombstoneRefused: return .createOverTombstoneRefused
            case .tombstonesListed: return .tombstonesListAsPresent
            case .deleteSkipsTombstone: return .deleteSkipsTombstone
            case .ownWritesNotMirrored: return .ownWritesNotMirrored
            }
        }
    }

    static var seeds: [UInt64] {
        let env = ProcessInfo.processInfo.environment
        if let one = env["SEMPERE_CLOUD_SEED"].flatMap(UInt64.init) { return [one] }
        return env["SEMPERE_SYNC_STRESS_LONG"] == "1" ? Array(1...max(env["SEMPERE_SYNC_STRESS_SEEDS"].flatMap(UInt64.init) ?? 60, 1)) : [1, 2, 3]
    }

    static var steps: Int { ProcessInfo.processInfo.environment["SEMPERE_SYNC_STRESS_LONG"] == "1" ? 400 : 150 }

    func testInvariantsHold() throws {
        var all: [String] = []
        for seed in Self.seeds {
            let found = run(seed: seed, steps: Self.steps)
            print("CLOUD-INTERLEAVING seed \(seed): \(found.isEmpty ? "clean" : "\(found.count) violations")")
            all += found.map { "seed \(seed): \($0)" }
        }
        XCTAssertTrue(all.isEmpty, all.prefix(15).joined(separator: "\n"))
    }

    func testInvariantsHoldWithFaultsOff() throws {
        let found = run(seed: 77, steps: 120, faultRate: 0)
        XCTAssertTrue(found.isEmpty, found.prefix(10).joined(separator: "\n"))
    }

    func testMutationCreateReplaces() throws { try checkMutation(.createReplaces) }
    func testMutationReplaceIgnoresTag() throws { try checkMutation(.replaceIgnoresTag) }
    func testMutationDeleteIgnoresTag() throws { try checkMutation(.deleteIgnoresTag) }
    func testMutationCreateOverTombstoneRefused() throws { try checkMutation(.createOverTombstoneRefused) }
    func testMutationTombstonesListed() throws { try checkMutation(.tombstonesListed) }
    func testMutationDeleteSkipsTombstone() throws { try checkMutation(.deleteSkipsTombstone) }
    func testMutationOwnWritesNotMirrored() throws { try checkMutation(.ownWritesNotMirrored) }

    func testEveryMutationHasItsTest() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let missing = Mutation.allCases.map { "\($0)" }.filter { name in
            !source.contains("func testMutation\(name.prefix(1).uppercased() + name.dropFirst())() throws { try checkMutation(.\(name)) }")
        }
        XCTAssertTrue(missing.isEmpty, "mutations without a testMutation… test that runs them: \(missing)")
        XCTAssertEqual(Set(Mutation.allCases.map(\.remote)), Set(CloudRemoteMutation.allCases), "a transport mutation no test runs")
    }

    private func checkMutation(_ m: Mutation, file: StaticString = #filePath, line: UInt = #line) throws {
        for seed in UInt64(100)..<UInt64(130) {
            CloudRecordRemote.mutations = [m.remote]
            let mutated = run(seed: seed, steps: 120).filter { $0.hasPrefix(m.breaks + ":") }
            CloudRecordRemote.mutations = []
            guard !mutated.isEmpty else { continue }
            let clean = run(seed: seed, steps: 120)
            XCTAssertTrue(clean.isEmpty, "seed \(seed) fails without \(m): \(clean.prefix(3))", file: file, line: line)
            return
        }
        XCTFail("\(m) did not break \(m.breaks)", file: file, line: line)
    }

    // MARK: One run

    private enum Op: CaseIterable { case create, replace, delete, deleteUntagged, sync, read }

    private func run(seed: UInt64, steps: Int, faultRate: Double = 0.03) -> [String] {
        var rng = SeededRNG(seed)
        var layout = CloudRecordRemote.Layout()
        layout.inlineLimit = 40
        layout.partThreshold = 300
        layout.partSize = 128
        let fx = CloudFixture(layout: layout)
        let names = ["A", "B", "C"]
        let faultsOn = Locked(faultRate > 0)
        let counter = Locked(UInt64(0))
        func clean(_ d: String) -> CloudRecordRemote { fx.remote(for: d) }
        func device(_ d: String) -> CloudRecordRemote {
            guard faultsOn.value else { return clean(d) }
            counter.value &+= 1
            var f = TransportFaults()
            f.dropBefore = faultRate; f.serverError = faultRate / 3; f.loseAnswer = faultRate; f.cutBody = faultRate
            return fx.faulty(for: d, seed: seed &* 7919 &+ counter.value, f)
        }
        let inspector = fx.remote(for: "inspector")
        let paths = (0..<5).map { ["notes", "n1", "p\($0)"] }
        let dir = ["notes", "n1"]
        var out: [String] = []
        var trace: [String] = []
        let tracing = ProcessInfo.processInfo.environment["SEMPERE_CLOUD_TRACE"] == "1"
        defer { if tracing, !out.isEmpty { print(trace.joined(separator: "\n")) } }
        func fail(_ code: String, _ message: String, step: Int) { out.append("\(code): step \(step): \(message)") }

        do {
            let a = clean("A")
            try a.createBase()
            _ = try a.makeCollection(["notes"]); _ = try a.makeCollection(dir)
            for d in names where d != "A" { try clean(d).prepareRun(); _ = try clean(d).makeCollection(["notes"]); _ = try clean(d).makeCollection(dir) }
        } catch { return ["setup: \(error)"] }

        /// What the zone holds, by the inspector (never faulted): bytes and version token of each path.
        func truth() -> [String: (data: Data, etag: String)] {
            var t: [String: (Data, String)] = [:]
            for p in paths {
                guard let e = try? inspector.stat(p), let r = try? inspector.read(p, maxBytes: 1 << 20) else { continue }
                t[p.last ?? ""] = (r.data, e.etag ?? "")
            }
            return t
        }
        /// A payload of a size that exercises inline, asset and parts (p4 is split).
        func payload(_ p: [String]) -> Data {
            let sizes = [10, 100, 250, 700, 900]
            let i = Int(rng.next() % UInt64(sizes.count))
            return Data((0..<sizes[i]).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        var known: [String: [String: String]] = [:]   // device -> path -> etag it last saw
        var deleted = Set<String>()                    // paths deleted at least once

        for step in 0..<steps {
            let d = names[Int(rng.next() % UInt64(names.count))]
            let p = paths[Int(rng.next() % UInt64(paths.count))]
            let key = p.last ?? ""
            let op = Op.allCases[Int(rng.next() % UInt64(Op.allCases.count))]
            let before = truth()
            let r = device(d)
            switch op {
            case .create:
                let data = payload(p)
                do {
                    let ok = try r.write(p, .data(data), condition: .create)
                    let after = truth()
                    if ok != (before[key] == nil) {
                        if before[key] == nil { do { _ = try inspector.read(p, maxBytes: 1 << 20) } catch { trace.append("DIAG read error \(error) names \(fx.database.recordNames(zone: fx.zone).filter { $0.hasPrefix("p-" + String(CloudRecordNaming.fileName(p).dropFirst(2))) })") } }
                        if before[key] == nil, deleted.contains(key) { fail("C4", "\(d) create of deleted \(key) said \(ok)", step: step) }
                        else { fail("C1", "\(d) create of \(key) said \(ok), it was \(before[key] == nil ? "absent" : "there")", step: step) }
                    }
                    if ok, after[key]?.data != data { fail("C1", "\(d) created \(key) and the zone holds other bytes", step: step) }
                    if !ok, let old = before[key], after[key]?.data != old.data { fail("C1", "\(d) create of \(key) failed but the bytes changed", step: step) }
                    if ok, try clean(d).stat(p)?.etag != after[key]?.etag { fail("C7", "\(d) does not see its own create of \(key)", step: step) }
                    trace.append("\(step) \(d) create \(key) -> \(ok)")
                } catch { trace.append("\(step) \(d) create \(key) threw \(error)") }
            case .replace:
                // A version the device saw: its own view if it has one, else the zone's; sometimes a stale one.
                let etag = known[d]?[key] ?? before[key]?.etag ?? "\"none\""
                let data = payload(p)
                do {
                    let ok = try r.write(p, .data(data), condition: .replace(etag: etag))
                    let after = truth()
                    let current = before[key]?.etag
                    if ok != (current == etag) {
                        fail("C2", "\(d) replace of \(key) over \(etag) said \(ok), the zone was at \(current ?? "absent")", step: step)
                    }
                    if !ok, let old = before[key], after[key]?.data != old.data { fail("C2", "\(d) replace of \(key) failed but the bytes changed", step: step) }
                    if ok, after[key]?.data != data { fail("C2", "\(d) replaced \(key) and the zone holds other bytes", step: step) }
                    if ok, try clean(d).stat(p)?.etag != after[key]?.etag { fail("C7", "\(d) does not see its own replace of \(key)", step: step) }
                    trace.append("\(step) \(d) replace \(key) over \(etag) -> \(ok)")
                } catch { trace.append("\(step) \(d) replace \(key) threw \(error)") }
            case .delete:
                let etag = known[d]?[key] ?? before[key]?.etag
                guard let etag else { break }
                // Half of them cannot finish: the second step (the delete) fails and the tombstone stays for a sweep.
                let arm = rng.next() % 2 == 0
                if arm {
                    let f = CloudFaults(seed: seed)
                    f.script(.modify, after: 1, .error(CloudStoreError(.networkFailure, "step two")))
                    fx.database.faults = f
                }
                defer { fx.database.faults = nil }
                do {
                    let ok = try (arm ? clean(d) : r).delete(p, ifETag: etag)
                    let after = truth()
                    let current = before[key]?.etag
                    if let current, current != etag {
                        if ok { fail("C3", "\(d) delete of \(key) over \(etag) said true, the zone was at \(current)", step: step) }
                        if after[key] == nil { fail("C3", "\(d) delete of \(key) over a stale \(etag) removed it", step: step) }
                    } else {
                        if !ok { fail("C3", "\(d) delete of \(key) over its current version said false", step: step) }
                        if after[key] != nil { fail("C6", "\(d) delete of \(key) said \(ok), the file is still there", step: step) }
                        if before[key] != nil { deleted.insert(key) }
                    }
                    trace.append("\(step) \(d) delete \(key) over \(etag) -> \(ok)")
                } catch { trace.append("\(step) \(d) delete \(key) threw \(error)") }
            case .deleteUntagged:
                do {
                    let ok = try r.delete(p, ifETag: nil)
                    if !ok { fail("C6", "\(d) untagged delete of \(key) said false", step: step) }
                    if truth()[key] != nil { fail("C6", "\(d) untagged delete of \(key) left it", step: step) }
                    if before[key] != nil { deleted.insert(key) }
                    trace.append("\(step) \(d) delete \(key)")
                } catch { trace.append("\(step) \(d) delete \(key) threw \(error)") }
            case .sync:
                do {
                    try r.prepareRun()
                    let listed = try r.list(dir) ?? []
                    let now = truth()
                    let seen = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })
                    for k in Set(now.keys).union(seen.keys) {
                        // What the feed lags behind is not shown (the database has no lag here, so none).
                        if (now[k] == nil) != (seen[k] == nil) {
                            fail("C5", "\(d) lists \(k) \(seen[k] == nil ? "missing" : "present") after prepareRun; the zone has it \(now[k] == nil ? "absent" : "there")", step: step)
                        } else if let n = now[k], let s = seen[k], s.etag != n.etag || s.size != n.data.count {
                            fail("C5", "\(d) lists \(k) as \(s.etag ?? "-")/\(s.size ?? -1), the zone has \(n.etag)/\(n.data.count)", step: step)
                        }
                    }
                    var view: [String: String] = [:]
                    for e in listed { view[e.name] = e.etag }
                    known[d] = view
                    trace.append("\(step) \(d) sync -> \(listed.count) files")
                } catch { trace.append("\(step) \(d) sync threw \(error)") }
            case .read:
                if let t = before[key] {
                    do {
                        let got = try r.read(p, maxBytes: 1 << 20)
                        if got.data != t.data || got.etag != t.etag { fail("C5", "\(d) read \(key): not what the zone holds", step: step) }
                    } catch { trace.append("\(step) \(d) read \(key) threw \(error)") }
                }
            }
            if d != "" { known[d, default: [:]][key] = try? clean(d).stat(p)?.etag }
        }
        return out
    }
}
