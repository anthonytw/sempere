import Foundation
import XCTest
@testable import Sempere

/// A randomized property test of the simple fork rule (docs/design/key-hierarchy.md §5.6, P1–P6).
///
/// Each seed builds an honest history: a real chain removing X (sometimes Z and Y), on which X and Z
/// may author legitimate epochs before their removal; honest devices' offline stale forks. Then an
/// attacker coalition (the removed devices) authors any epochs under any epoch it was listed in, with
/// any ids, removals and resolve epochs; honest devices and a puppet P (listed, but X's) author epochs
/// under attacker epochs, as a stale device that took X's fork would. Devices are pinned unpinned, at
/// every prefix of the real chain, on honest fork paths and on paths through attacker epochs. A
/// truthful scripted user answers "yes" to honest devices, "no" to X, Z and P, and chooses the real
/// chain where it is a side.
///
/// - P1 no automatic choice: beyond its pin, a device's chain only extends linearly or along a
///   resolve epoch it followed, and never through an author its chain removed.
/// - P2 attacker-free questions: a device pinned through every removal is asked about no removed
///   device; without honest forks and puppet epochs it is asked nothing.
/// - P3 safety after truthful answers: no attacker epoch on the chain, no removed device listed at
///   its end, no recovery key re-applied.
/// - P4 bounded questions: per device, at most one question per branch seen, and each removed device
///   or puppet appears in questions of one round only (after the answer it is ignored).
/// - P5 convergence: with every honest device answering truthfully in turn and writing its resolve
///   epoch, all honest devices end on the same chain; on honest-only trees, at most one device is
///   asked per branch.
/// - P6 order independence.
///
/// `SEMPERE_FORK_PROPERTY_SEEDS` sets the number of seeds (quick mode 600). Each required mutation
/// must fail the property within the quick seeds.
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
    static let honest = ["A", "B", "C", "D"]
    /// P is X's puppet: X approved it.
    static let puppetChains: [Data: [Data]] = [d("P"): [d("X")]]

    struct World {
        var nodes: [ForkNode] = []
        var real: [Data] = []
        var removedOnReal: Set<Data> = []
        var attackerEpochs: Set<Data> = []
        var honestForkEpochs: Set<Data> = []
        var paths: [[Data]] = []
        var lastRemovalIndex = 0
        /// The removed devices that act (X, and Z when removed) and the puppet P.
        var malicious: Set<Data> = [d("P")]
    }

    struct Options { var legitX = true, underAttacker = true, honestForks = true, attackers = true }

    static func world(seed: UInt64, _ o: Options) -> World {
        var rng = RNG(state: seed)
        var w = World()
        var used: Set<String> = []
        func newId() -> Data {
            while true { let s = String(format: "%04x", rng.int(65536)); if used.insert(s).inserted { return d(s) } }
        }
        var list: Set<String> = Set(honest + ["X", "Z", "Y", "P", "R"])
        var lists: [Data: Set<String>] = [:]
        var parents: [Data: Data] = [:]
        func add(_ id: Data, _ parent: Data?, _ author: String, _ l: Set<String>, _ removes: Set<String>, _ reason: EpochReason,
                 rejected: String? = nil) {
            w.nodes.append(ForkNode(epochId: id, parent: parent, author: d(author), removals: Set(removes.map(d)), list: Set(l.map(d)),
                                    reason: reason, recovery: d("R"), rejected: rejected.map(d)))
            lists[id] = l
            parents[id] = parent
        }
        func path(_ id: Data) -> [Data] {
            var out = [id]; var cur = parents[id] ?? nil
            while let c = cur { out.insert(c, at: 0); cur = parents[c] ?? nil }
            return out
        }
        let length = 2 + rng.int(5)
        let removeX = 2 + rng.int(length - 1)
        let removeZ = rng.chance(0.5) ? 2 + rng.int(length - 1) : nil
        let removeY = rng.chance(0.6) ? 2 + rng.int(length - 1) : nil
        let e1 = newId()
        add(e1, nil, "A", list, [], .create)
        w.real = [e1]
        for i in 2...max(2, length) {
            var removes: Set<String> = []
            if i == removeX { removes.insert("X") }
            if i == removeZ { removes.insert("Z") }
            if i == removeY { removes.insert("Y") }
            var authors = honest
            if o.legitX { authors += ["X", "Z"].filter { list.contains($0) && !removes.contains($0) } }
            let id = newId()
            add(id, w.real.last, rng.pick(authors), list.subtracting(removes), removes, .remove)
            w.real.append(id)
            w.removedOnReal.formUnion(removes.map(d))
            if !removes.isDisjoint(with: ["X", "Z"]) { w.lastRemovalIndex = w.real.count - 1 }
            list.subtract(removes)
        }
        if o.honestForks && list.contains("Y") && rng.chance(0.5) {
            // Y, still listed, writes the real chain's last epoch: a fork that removed Y concurrently and
            // is confirmed prunes it (amendment 2).
            let id = newId()
            add(id, w.real.last, "Y", list, [], .remove)
            w.real.append(id)
        }
        if o.honestForks {
            for _ in 0..<rng.int(3) {
                let j = rng.int(w.real.count - 1)
                let parent = w.real[j]
                let pl = lists[parent] ?? []
                let candidates = honest.filter { pl.contains($0) }
                guard !candidates.isEmpty else { continue }
                var removes: Set<String> = []
                if pl.contains("Y") && rng.chance(0.6) { removes.insert("Y") }
                if pl.contains("X") && rng.chance(0.3) { removes.insert("X") }
                let id = newId()
                let author = rng.pick(candidates)
                add(id, parent, author, pl.subtracting(removes), removes, .remove)
                w.honestForkEpochs.insert(id)
                w.paths.append(path(id))
                if rng.chance(0.3) {
                    let c = newId()
                    add(c, id, author, pl.subtracting(removes), [], .remove)
                    w.honestForkEpochs.insert(c)
                }
            }
        }
        let attackers = ["X", "Z"].filter { w.removedOnReal.contains(d($0)) }
        w.malicious.formUnion(attackers.map(d))
        if o.attackers {
            let everyone = Array(Set(lists.values.flatMap { $0 })).sorted()
            for _ in 0..<rng.int(7) {
                let hosts = w.nodes.filter { n in attackers.contains { lists[n.epochId]?.contains($0) ?? false } }
                guard !hosts.isEmpty else { break }
                let parent = rng.pick(hosts).epochId
                let pl = lists[parent] ?? []
                let author = rng.pick(attackers.filter { pl.contains($0) })
                var removes: Set<String> = []
                for _ in 0..<rng.int(4) { removes.insert(rng.pick(everyone.filter { $0 != author })) }
                removes.formIntersection(pl)
                let id = newId()
                let resolve = rng.chance(0.15)
                add(id, parent, author, pl.subtracting(removes), resolve ? [] : removes, resolve ? .resolve : .remove,
                    rejected: resolve ? rng.pick(honest) : nil)
                w.attackerEpochs.insert(id)
                if rng.chance(0.3) { w.paths.append(path(id)) }
            }
            if o.underAttacker {
                for _ in 0..<rng.int(3) {
                    let hosts = Array(w.attackerEpochs).sorted { $0.lexicographicallyPrecedes($1) }
                    guard !hosts.isEmpty else { break }
                    let parent = rng.pick(hosts)
                    let pl = lists[parent] ?? []
                    let candidates = (honest + ["P"]).filter { pl.contains($0) }
                    guard !candidates.isEmpty else { continue }
                    let author = rng.pick(candidates)
                    var removes: Set<String> = []
                    for a in attackers where pl.contains(a) && rng.chance(0.6) { removes.insert(a) }
                    if pl.contains("Y") && rng.chance(0.3) { removes.insert("Y") }
                    let id = newId()
                    let resolve = author == "P" && rng.chance(0.4)
                    add(id, parent, author, pl.subtracting(removes), resolve ? [] : removes, resolve ? .resolve : .remove)
                    if author == "P" { w.attackerEpochs.insert(id) } else { w.honestForkEpochs.insert(id) }
                    w.paths.append(path(id))
                }
            }
        }
        return w
    }

    struct Violation: Error, CustomStringConvertible { var description: String }

    /// The truthful user's answers to `questions`.
    static func answers(_ questions: [ForkQuestion], world w: World) -> [ForkAnswer] {
        questions.map { q in
            let malicious = w.malicious
            let all = q.sides.flatMap(\.authors) + q.sides.flatMap { $0.epochs.map { e in w.nodes.first { $0.epochId == e }?.author ?? Data() } }
            let chosen = q.sides.first { w.real.contains($0.child) }?.child
                ?? q.current
                ?? q.sides.first { side in !side.epochs.contains { e in malicious.contains(w.nodes.first { $0.epochId == e }?.author ?? Data()) } }?.child
                ?? q.suggested
            return ForkAnswer(branch: q.branch, chosen: chosen, confirmed: Set(all.filter { !malicious.contains($0) }),
                              rejected: Set(all.filter { malicious.contains($0) }))
        }
    }

    /// Resolve, answering truthfully until nothing is asked. Returns the final result, the stored
    /// answers, and the questions of each round.
    static func settle(_ nodes: [ForkNode], _ context: ForkContext, world w: World) throws
        -> (ForkResolution, [ForkAnswer], [[ForkQuestion]]) {
        var ctx = context
        var rounds: [[ForkQuestion]] = []
        for _ in 0..<12 {
            let r = try EpochForks.resolve(nodes, context: ctx)
            if r.questions.isEmpty { return (r, ctx.answers, rounds) }
            rounds.append(r.questions)
            var byBranch = Dictionary(ctx.answers.map { ($0.branch, $0) }, uniquingKeysWith: { a, _ in a })
            for a in answers(r.questions, world: w) {
                // A repeated question (a new side appeared) may change the choice; the authors answered stay.
                var merged = a
                if let old = byBranch[a.branch] {
                    merged.confirmed.formUnion(old.confirmed.subtracting(a.rejected))
                    merged.rejected.formUnion(old.rejected.subtracting(a.confirmed))
                }
                byBranch[a.branch] = merged
            }
            ctx.answers = byBranch.values.sorted { $0.branch.lexicographicallyPrecedes($1.branch) }
        }
        throw Violation(description: "answers never settle")
    }

    static func contexts(_ w: World) -> [(String, ForkContext)] {
        var out: [(String, ForkContext)] = []
        for me in honest {
            out.append(("\(me) unpinned", ForkContext(me: d(me), approverChains: puppetChains)))
            for k in 1...w.real.count { out.append(("\(me) pinned \(k)", ForkContext(me: d(me), pinned: Array(w.real.prefix(k)), approverChains: puppetChains))) }
            for (i, p) in w.paths.enumerated() { out.append(("\(me) path \(i)", ForkContext(me: d(me), pinned: p, approverChains: puppetChains))) }
        }
        return out
    }

    static func check(seed: UInt64, mutations: Set<ForkMutation> = []) throws {
        let w = world(seed: seed, Options())
        let byId = Dictionary(uniqueKeysWithValues: w.nodes.map { ($0.epochId, $0) })
        let children = Dictionary(grouping: w.nodes.filter { $0.parent != nil }, by: { $0.parent ?? Data() })
        func path(_ id: Data) -> [Data] {
            var out: [Data] = []; var cur: Data? = id
            while let c = cur { out.insert(c, at: 0); cur = byId[c]?.parent }
            return out
        }
        var rng = RNG(state: seed ^ 0x5eed)
        for (index, (label, original)) in contexts(w).enumerated() {
            var context = original
            context.mutations = mutations
            let at = "seed \(seed), \(label)"
            let first = try EpochForks.resolve(w.nodes, context: context)
            // P1 (no answers yet).
            let pinCount = max(1, context.pinned.count)
            let followedPaths = Set(first.followed.flatMap { r -> [Data] in
                var out: [Data] = []; var cur: Data? = r
                while let c = cur { out.append(c); cur = byId[c]?.parent }
                return out
            })
            var removed: Set<Data> = []
            for (i, e) in first.keptChain.enumerated() {
                guard let n = byId[e] else { continue }
                if i >= pinCount {
                    if removed.contains(n.author) && !followedPaths.contains(e) {
                        throw Violation(description: "P1 \(at): an epoch by a device the chain removed")
                    }
                    let p = first.keptChain[i - 1]
                    let candidates = (children[p] ?? []).filter { c in
                        (byId[p]?.list.contains(c.author) ?? false) && !removed.contains(c.author)
                    }
                    if candidates.count > 1 && !followedPaths.contains(e) {
                        throw Violation(description: "P1 \(at): a sibling followed without an answer or a resolve")
                    }
                }
                if i > 0 { removed.formUnion(n.removals) }
            }
            // P2.
            let pinnedThroughAll = context.pinned.count > w.lastRemovalIndex && Array(context.pinned.prefix(w.real.count)) == w.real
            if pinnedThroughAll {
                for q in first.questions where q.sides.contains(where: { !Set($0.authors).isDisjoint(with: w.removedOnReal) }) {
                    throw Violation(description: "P2 \(at): asked about a removed device")
                }
            }
            // P3, P4.
            let (final, stored, rounds) = try settle(w.nodes, context, world: w)
            // Amendment 2: below an answered branch, the kept chain has no epoch by an author whose
            // removal the answer re-applied or whom it rejected.
            for a in stored {
                guard let k = final.keptChain.firstIndex(of: a.branch) else { continue }
                // This answer's re-application set: the removals of the other sides by confirmed authors.
                let other = rounds.flatMap { $0 }.filter { $0.branch == a.branch }.flatMap(\.sides).filter { $0.child != a.chosen }
                let gone = Set(other.flatMap(\.epochs).compactMap { byId[$0] }.filter { a.confirmed.contains($0.author) }
                    .flatMap(\.removals)).intersection(final.reapply)
                for e in final.keptChain.dropFirst(max(k + 1, pinCount)) where gone.contains(byId[e]?.author ?? Data()) {
                    // A chosen child is the user's explicit pick (its epoch predates the removal).
                    if first.followed.contains(e) || stored.contains(where: { $0.chosen == e }) { continue }
                    throw Violation(description: "P1 \(at): an epoch by an author the answer removed or rejected")
                }
            }
            if context.pinned.contains(where: { w.attackerEpochs.contains($0) }) {
                // A device pinned through an attacker's epoch (design §5.6 residual): no silent island when
                // the real sibling at its divergence is visible to it.
                if let k = context.pinned.indices.first(where: { $0 >= w.real.count || context.pinned[$0] != w.real[$0] }),
                   k < w.real.count, let realChild = byId[w.real[k]] {
                    let removedOnPin = context.pinned.dropFirst().reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.removals ?? []) }
                    // Residual (design §5.6): an attacker's own resolve below its fork settles the branch
                    // for the island under rule 4, so only an island without one must be asked.
                    let settledByAttacker = w.nodes.contains { n in
                        n.reason == .resolve && w.attackerEpochs.contains(n.epochId) && path(n.epochId).contains(context.pinned[k])
                            && n.epochId != context.pinned[k]
                    }
                    if !removedOnPin.contains(realChild.author) && !settledByAttacker && rounds.isEmpty && first.followed.isEmpty {
                        throw Violation(description: "P3 \(at): an island device never asked although the real side is visible")
                    }
                }
                continue
            }
            if let k = context.pinned.indices.first(where: { $0 >= w.real.count || context.pinned[$0] != w.real[$0] }),
               k < w.real.count, w.honestForkEpochs.contains(context.pinned[k]), let realChild = byId[w.real[k]],
               context.pinned.dropFirst().contains(where: { byId[$0]?.removals.contains(realChild.author) ?? false }),
               !w.nodes.contains(where: { $0.reason == .resolve && !w.attackerEpochs.contains($0.epochId) }) {
                // Pinned on an honest stale fork that removed the real side's author: rule 6 hides the
                // real side until a device there writes its resolve (amendment (b)); P5 covers that.
                continue
            }
            if final.keptChain.contains(where: { w.attackerEpochs.contains($0) }) {
                throw Violation(description: "P3 \(at): an attacker epoch on the chain after truthful answers")
            }
            let end = byId[final.keptChain.last ?? Data()]?.list ?? []
            for k in w.removedOnReal where end.contains(k) && !final.reapply.contains(k) {
                throw Violation(description: "P3 \(at): \(String(decoding: k, as: UTF8.self)) still listed after truthful answers")
            }
            if final.reapply.contains(d("R")) { throw Violation(description: "P3 \(at): the recovery key re-applied") }
            var branchesAsked: [Data: Int] = [:]
            var maliciousRounds: [Data: Int] = [:]
            for round in rounds {
                for q in round { branchesAsked[q.branch, default: 0] += 1 }
                for m in Set(round.flatMap { $0.sides.flatMap(\.authors) }).intersection(w.malicious) { maliciousRounds[m, default: 0] += 1 }
            }
            if let (m, n) = maliciousRounds.first(where: { $0.value > 1 }) {
                throw Violation(description: "P4 \(at): \(String(decoding: m, as: UTF8.self)) asked about in \(n) rounds")
            }
            if branchesAsked.values.contains(where: { $0 > 2 }) { throw Violation(description: "P4 \(at): a branch asked about repeatedly") }
            // P6.
            if index % 3 == 0 {
                var shuffled = w.nodes
                for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, rng.int(i + 1)) }
                if try EpochForks.resolve(shuffled, context: context) != first {
                    throw Violation(description: "P6 \(at): depends on the input order")
                }
            }
        }
        // P2, second half: no honest forks, no puppet or honest epochs under attackers: nothing asked.
        let quiet = world(seed: seed, Options(legitX: true, underAttacker: false, honestForks: false, attackers: true))
        for me in honest {
            var context = ForkContext(me: d(me), pinned: quiet.real, approverChains: puppetChains)
            context.mutations = mutations
            if !(try EpochForks.resolve(quiet.nodes, context: context)).questions.isEmpty {
                throw Violation(description: "P2 seed \(seed), \(me): asked without any honest fork")
            }
        }
        try convergence(seed: seed, mutations: mutations)
    }

    /// P5: every honest device, in turn, settles with truthful answers and writes its resolve epoch.
    static func convergence(seed: UInt64, mutations: Set<ForkMutation>) throws {
        for honestOnly in [false, true] {
            var w = world(seed: seed, honestOnly ? Options(legitX: true, underAttacker: false, honestForks: true, attackers: false) : Options())
            var rng = RNG(state: seed ^ 0xc0)
            var pins: [String: [Data]] = [:]
            for me in honest {
                let choices: [[Data]] = [[]] + (1...w.real.count).map { Array(w.real.prefix($0)) }
                    + w.paths.filter { !$0.contains { w.attackerEpochs.contains($0) } }
                pins[me] = rng.pick(choices)
            }
            var answers: [String: [ForkAnswer]] = [:]
            var asked: [Data: Int] = [:]
            var counter = 0
            for _ in 0..<2 {
                for me in honest {
                    var context = ForkContext(me: d(me), pinned: pins[me] ?? [], answers: answers[me] ?? [], approverChains: puppetChains)
                    context.mutations = mutations
                    let (r, stored, rounds) = try settle(w.nodes, context, world: w)
                    for round in rounds { for q in round { asked[q.branch, default: 0] += 1 } }
                    answers[me] = stored
                    var chain = r.keptChain
                    if !r.resolveFor.isEmpty, let end = w.nodes.first(where: { $0.epochId == chain.last }) {
                        counter += 1
                        let id = d(String(format: "r%03d-%@", counter, me))
                        w.nodes.append(ForkNode(epochId: id, parent: end.epochId, author: d(me), removals: r.reapply,
                                                list: end.list.subtracting(r.reapply), reason: .resolve, recovery: d("R")))
                        chain.append(id)
                    }
                    pins[me] = chain
                }
            }
            var ends: Set<Data> = []
            for me in honest {
                var context = ForkContext(me: d(me), pinned: pins[me] ?? [], answers: answers[me] ?? [], approverChains: puppetChains)
                context.mutations = mutations
                let r = try EpochForks.resolve(w.nodes, context: context)
                if r.keptChain.contains(where: { w.attackerEpochs.contains($0) }) {
                    // Residual (design §5.6): a device whose chain runs through an attacker's epoch (here
                    // reached linearly from its own stale fork, whose removals hide the real sibling)
                    // recovers only once it sees a real sibling. P3 checks it is asked when it does.
                    continue
                }
                ends.insert(r.keptChain.last ?? Data())
                if !r.questions.isEmpty { throw Violation(description: "P5 seed \(seed): \(me) still asked") }
            }
            if ends.count > 1 { throw Violation(description: "P5 seed \(seed) honestOnly \(honestOnly): devices end on \(ends.count) chains") }
            if honestOnly, let (b, n) = asked.first(where: { $0.value > 1 }) {
                throw Violation(description: "P5 seed \(seed): a branch of an honest-only tree asked \(n) times (\(b.count) bytes)")
            }
        }
    }

    static var seeds: UInt64 { UInt64(ProcessInfo.processInfo.environment["SEMPERE_FORK_PROPERTY_SEEDS"] ?? "") ?? 600 }

    func testSimpleForkRuleProperties() throws {
        var failures: [String] = []
        for seed in 1...Self.seeds {
            do { try Self.check(seed: seed) } catch {
                failures.append("\(error)")
                if failures.count >= 5 { break }
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }

    /// Each required mutation breaks one safeguard, and the property must notice within the quick seeds.
    func testEveryRequiredMutationIsCaught() throws {
        let required: [ForkMutation] = [.ruleSixOff, .siblingsFollowedAutomatically, .resolvesWithoutAuthorCheck,
                                        .noAnswersDoNotReject, .noReapplyPruning]
        for mutation in required {
            var caught: String?
            for seed in 1...UInt64(600) {
                do { try Self.check(seed: seed, mutations: [mutation]) } catch { caught = "\(error)"; break }
            }
            XCTAssertNotNil(caught, "\(mutation) was not caught")
        }
    }
}
