import Foundation
import XCTest
@testable import Sempere

/// A randomized property test of fork resolution (docs/design/key-hierarchy.md §5.6), asked for by
/// the second KH1 code review to end case-by-case fixes.
///
/// Each seed builds an honest history (a real chain with removals of the devices X and Z and of Y,
/// joins, a recovery replacement, and honest devices' offline stale forks) and an attacker coalition:
/// every device the real chain removed may author any number of epochs under any epoch it was listed
/// in (real epochs before its removal, honest stale forks, its coalition's epochs), with any epoch
/// ids and any removals, including resolve epochs. The tree is resolved from every honest device's
/// point of view, unpinned, pinned at every prefix of the real chain, and after the user rejected the
/// removed devices, and checked:
///
/// - I-a: no epoch of the attackers is on the kept chain, and no removed device is still listed at its
///   end (unless re-applied), unless the function returned a question;
/// - I-b: no device the real chain removed is listed at the end of the kept chain without being in
///   the re-application set, unless the function returned a question;
/// - I-c: the result does not depend on the order of the input;
/// - I-d: re-application never removes a recovery key;
/// - I-e: once the user rejected every removed device, nothing is asked;
/// - I-f: without attacker epochs (honest forks only), nothing is asked.
///
/// `SEMPERE_FORK_PROPERTY_SEEDS` sets the number of seeds (quick mode: 2000). Every test-only mutation
/// must make the property fail within the quick seeds.
final class EpochForkPropertyTests: XCTestCase {
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    static func d(_ s: String) -> Data { Data(s.utf8) }

    struct World {
        var nodes: [ForkNode] = []
        var real: [Data] = []
        var honest: [String] = []
        var removedOnReal: Set<Data> = []
        var attackers: Set<String> = []
        var attackerEpochs: Set<Data> = []
    }

    static func world(seed: UInt64) -> World {
        var rng = RNG(state: seed)
        var w = World()
        var usedIds: Set<String> = []
        func newId() -> Data {
            while true {
                let s = String(format: "%04x", rng.int(65536))
                if usedIds.insert(s).inserted { return d(s) }
            }
        }
        let honest = ["A", "B", "C", "D"]
        w.honest = honest
        var list: Set<String> = Set(honest + ["X", "Z", "Y", "R"])
        var recovery = "R"
        func node(_ id: Data, _ parent: Data?, _ author: String, _ list: Set<String>, _ removes: Set<String>,
                  _ reason: EpochReason, _ recovery: String, rejected: String? = nil) -> ForkNode {
            ForkNode(epochId: id, parent: parent, author: d(author), removals: Set(removes.map(d)), list: Set(list.map(d)),
                     reason: reason, recovery: d(recovery), rejected: rejected.map(d))
        }
        // The real chain.
        let length = 2 + rng.int(5)
        let removeX = 2 + rng.int(length - 1)
        let removeZ = rng.chance(0.5) ? 2 + rng.int(length - 1) : nil
        let removeY = rng.chance(0.6) ? 2 + rng.int(length - 1) : nil
        let replaceKit = rng.chance(0.3) ? 2 + rng.int(length - 1) : nil
        var lists: [Data: Set<String>] = [:]
        let e1 = newId()
        w.nodes.append(node(e1, nil, "A", list, [], .create, recovery))
        w.real = [e1]
        lists[e1] = list
        var joined = 0
        for i in 2...max(2, length) {
            var removes: Set<String> = []
            if i == removeX { removes.insert("X") }
            if i == removeZ { removes.insert("Z") }
            if i == removeY { removes.insert("Y") }
            var reason: EpochReason = .remove
            var newList = list.subtracting(removes)
            if i == replaceKit {
                reason = .recovery; newList.remove(recovery); removes.insert(recovery)
                recovery = recovery == "R" ? "R2" : "R3"; newList.insert(recovery)
            }
            // A join during the previous epoch, carried into this one.
            if rng.chance(0.3) { joined += 1; newList.insert("N\(joined)"); list.insert("N\(joined)") }
            let author = rng.pick(honest)
            let id = newId()
            w.nodes.append(node(id, w.real.last, author, newList, removes, reason, recovery))
            w.real.append(id)
            w.removedOnReal.formUnion(removes.filter { $0 != "R" && $0 != "R2" }.map(d))
            list = newList
            lists[id] = newList
        }
        // Honest offline stale forks: a device listed at epoch j removes Y (or nothing) from there.
        for _ in 0..<rng.int(3) {
            let j = rng.int(w.real.count - 1)
            let parent = w.real[j]
            let parentList = lists[parent] ?? []
            let candidates = honest.filter { parentList.contains($0) }
            guard !candidates.isEmpty else { continue }
            let author = rng.pick(candidates)
            // Honest devices remove only what the honest world removes (Y, or X concurrently).
            var removes: Set<String> = []
            if parentList.contains("Y") && rng.chance(0.6) { removes.insert("Y") }
            if parentList.contains("X") && rng.chance(0.3) { removes.insert("X") }
            let id = newId()
            let parentRecovery = w.nodes.first { $0.epochId == parent }.flatMap { $0.recovery }.map { String(decoding: $0, as: UTF8.self) } ?? "R"
            let forkList = parentList.subtracting(removes)
            w.nodes.append(node(id, parent, author, forkList, removes, .remove, parentRecovery))
            lists[id] = forkList
            if rng.chance(0.3) {
                let child = newId()
                w.nodes.append(node(child, id, author, forkList, [], .reapply, parentRecovery))
                lists[child] = forkList
            }
        }
        // The attacker coalition: every device the real chain removed (X always, Z sometimes).
        w.attackers = Set(["X", "Z"].filter { w.removedOnReal.contains(d($0)) })
        let everyone = Array(Set(lists.values.flatMap { $0 })).sorted()
        for _ in 0..<rng.int(7) {
            let hosts = w.nodes.filter { n in w.attackers.contains { lists[n.epochId]?.contains($0) ?? false } }
            guard !hosts.isEmpty else { break }
            let parent = rng.pick(hosts)
            let parentList = lists[parent.epochId] ?? []
            let author = rng.pick(w.attackers.filter { parentList.contains($0) }.sorted())
            var removes: Set<String> = []
            for _ in 0..<rng.int(4) { removes.insert(rng.pick(everyone.filter { $0 != author })) }
            removes.formIntersection(parentList)
            let id = newId()
            let forkList = parentList.subtracting(removes)
            let resolve = rng.chance(0.15)
            let parentRecovery = parent.recovery.map { String(decoding: $0, as: UTF8.self) } ?? "R"
            w.nodes.append(node(id, parent.epochId, author, forkList, resolve ? [] : removes, resolve ? .resolve : .remove,
                                parentRecovery, rejected: resolve ? rng.pick(honest) : nil))
            lists[id] = forkList
            w.attackerEpochs.insert(id)
        }
        return w
    }

    struct Violation: Error, CustomStringConvertible { var description: String }

    static func check(seed: UInt64, mutations: Set<ForkMutation> = []) throws {
        let w = world(seed: seed)
        let realSet = Set(w.real)
        var contexts: [(String, ForkContext)] = []
        for me in w.honest {
            contexts.append(("\(me) unpinned", ForkContext(me: d(me))))
            for k in 1...w.real.count {
                contexts.append(("\(me) pinned \(k)", ForkContext(me: d(me), pinned: Array(w.real.prefix(k)))))
            }
            contexts.append(("\(me) rejected", ForkContext(me: d(me), rejectedAuthors: Set(w.attackers.map(d)))))
            contexts.append(("\(me) rejected, pinned 1", ForkContext(me: d(me), rejectedAuthors: Set(w.attackers.map(d)),
                                                                     pinned: [w.real[0]])))
        }
        contexts.append(("no device", ForkContext()))
        // I-f: honest forks alone never make a question (the property is not met by asking always).
        let honestOnly = w.nodes.filter { !w.attackerEpochs.contains($0.epochId) }
        for me in w.honest {
            var context = ForkContext(me: d(me))
            context.mutations = mutations
            if try EpochForks.resolve(honestOnly, context: context).question != nil {
                throw Violation(description: "seed \(seed), \(me): a question without any attacker epoch")
            }
        }
        var rng = RNG(state: seed ^ 0x5eed)
        for (index, (label, original)) in contexts.enumerated() {
            var context = original
            context.mutations = mutations
            let r = try EpochForks.resolve(w.nodes, context: context)
            let at = "seed \(seed), \(label)"
            if r.question == nil {
                // I-a.
                if let bad = r.keptChain.first(where: { w.attackerEpochs.contains($0) }) {
                    throw Violation(description: "\(at): an attacker epoch \(bad.map { String(format: "%02x", $0) }.joined()) is kept")
                }
                // I-b.
                let end = Set(w.nodes.first { $0.epochId == r.keptChain.last }?.list ?? [])
                for k in w.removedOnReal where end.contains(k) && !r.reapply.contains(k) {
                    throw Violation(description: "\(at): \(String(decoding: k, as: UTF8.self)) stays listed without a question")
                }
                _ = realSet
            }
            // I-d.
            let recoveryKeys = Set(w.nodes.compactMap(\.recovery))
            if !r.reapply.isDisjoint(with: recoveryKeys) { throw Violation(description: "\(at): a recovery key re-applied") }
            // I-e.
            if !context.rejectedAuthors.isEmpty, r.question != nil {
                throw Violation(description: "\(at): asked again after the user rejected every removed device")
            }
            // I-c (on every third context, to keep quick mode quick).
            guard index % 3 == 0 else { continue }
            var shuffled = w.nodes
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, rng.int(i + 1)) }
            if try EpochForks.resolve(shuffled, context: context) != r {
                throw Violation(description: "\(at): depends on the input order")
            }
        }
    }

    static var seeds: UInt64 {
        UInt64(ProcessInfo.processInfo.environment["SEMPERE_FORK_PROPERTY_SEEDS"] ?? "") ?? 2000
    }

    func testForkResolutionProperties() throws {
        var failures: [String] = []
        for seed in 1...Self.seeds {
            do { try Self.check(seed: seed) } catch {
                failures.append("\(error)")
                if failures.count >= 5 { break }
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    /// Each mutation breaks one safeguard, and the property must notice within the quick seeds.
    func testEveryMutationIsCaught() throws {
        for mutation in [ForkMutation.deadlockAsUncounted, .childrenAlwaysCount, .noWholesaleExclusion] {
            var caught = false
            for seed in 1...UInt64(2000) {
                do { try Self.check(seed: seed, mutations: [mutation]) } catch { caught = true; break }
            }
            XCTAssertTrue(caught, "\(mutation) was not caught")
        }
    }
}
