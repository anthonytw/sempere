import Crypto
import Foundation
import XCTest
@testable import Sempere

/// The single-writer precedence rule (docs/design/key-hierarchy.md §5.6): the shared vectors and a small
/// randomized property test with required-failing mutations.
final class EpochPrecedenceTests: XCTestCase {
    struct Vectors: Decodable {
        struct Node: Decodable {
            var id: String; var parent: String?; var signer: String; var reason: String; var home: String
            var list: [String]; var recovery: String; var recoverySigner: String?
        }
        struct Expect: Decodable { var kept, dropped, ignored, homeConflicts, stopped: [String] }
        struct Case: Decodable {
            var name: String; var nodes: [Node]; var pinned: [String]; var picked: [String: String]?; var expect: Expect
        }
        var cases: [Case]
    }

    static func d(_ s: String) -> Data { Data(s.utf8) }
    static func s(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    func testPrecedenceVectors() throws {
        let url = try FixtureTests.bundled("epoch-precedence-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 22)
        for c in v.cases {
            let nodes = try c.nodes.map { n in
                EpochNode(epochId: Self.d(n.id), parent: n.parent.map(Self.d), signer: Self.d(n.signer),
                          reason: try XCTUnwrap(EpochReason(rawValue: n.reason), c.name), home: Self.d(n.home),
                          list: Set(n.list.map(Self.d)), recovery: Self.d(n.recovery), recoverySigner: n.recoverySigner.map(Self.d))
            }
            let picked = Dictionary(uniqueKeysWithValues: (c.picked ?? [:]).map { (Self.d($0.key), Self.d($0.value)) })
            let r = try EpochPrecedence.resolve(nodes, pinned: c.pinned.map(Self.d), picked: picked)
            XCTAssertEqual(r.keptChain.map(Self.s), c.expect.kept, c.name)
            XCTAssertEqual(r.dropped.map(Self.s), c.expect.dropped, c.name)
            XCTAssertEqual(r.ignored.map(Self.s), c.expect.ignored, c.name)
            XCTAssertEqual(r.homeConflicts.map { Self.s($0.epoch) }, c.expect.homeConflicts, c.name)
            XCTAssertEqual(r.homeConflicts.filter { $0.followed == nil }.map { Self.s($0.epoch) }, c.expect.stopped, c.name)
            var rng = SystemRandomNumberGenerator()
            XCTAssertEqual(try EpochPrecedence.resolve(nodes.shuffled(using: &rng), pinned: c.pinned.map(Self.d), picked: picked),
                           r, c.name)
        }
    }

    func testMalformedTreesAreRefused() {
        let n = { (id: String, parent: String?) in
            EpochNode(epochId: Self.d(id), parent: parent.map(Self.d), signer: Self.d("A"), reason: parent == nil ? .create : .remove,
                      home: Self.d("A"), list: [Self.d("A"), Self.d("R")], recovery: Self.d("R"))
        }
        XCTAssertThrowsError(try EpochPrecedence.resolve([])) { XCTAssertEqual($0 as? EpochTreeError, .noRoot) }
        XCTAssertThrowsError(try EpochPrecedence.resolve([n("1", nil), n("1b", nil)])) { XCTAssertEqual($0 as? EpochTreeError, .noRoot) }
        XCTAssertThrowsError(try EpochPrecedence.resolve([n("1", nil), n("2", "9")])) { XCTAssertEqual($0 as? EpochTreeError, .detached) }
        XCTAssertEqual(try EpochPrecedence.resolve([n("1", nil)]).keptChain, [Self.d("1")])
    }

    /// Round 7, H1: a ledger entry is pruned only when its sealing record is on the pinned chain with a
    /// later pinned epoch above it; Repair keeps, in bulk, the dropped epochs' files this device wrote.
    func testLedgerPruningAndBulkKeep() {
        let pinned = ["e1", "e2", "m", "e4"].map(Self.d)
        XCTAssertTrue(LedgerRule.sealIsFinal(sealer: Self.d("m"), pinned: pinned))
        XCTAssertFalse(LedgerRule.sealIsFinal(sealer: Self.d("e4"), pinned: pinned), "the pinned end can still be dropped")
        XCTAssertFalse(LedgerRule.sealIsFinal(sealer: Self.d("x"), pinned: pinned), "a sealer off the pinned chain")
        // A takeover dropped m and e4: the device's entries sealed by e4 were kept, so its files come back.
        let f = { (p: String, e: String) in LedgerRule.FileRef(path: p, sha256: Data(SHA256.hash(data: Data(p.utf8))), epochId: Self.d(e)) }
        let setAside = [f("notes/a", "m"), f("notes/b", "m"), f("notes/c", "e1"), f("notes/d", "e4")]
        let ledger = [f("notes/a", "m"), f("notes/c", "e1"), f("notes/d", "e4")]
        XCTAssertEqual(LedgerRule.keepable(setAside: setAside, ledger: ledger, dropped: [Self.d("m"), Self.d("e4")]),
                       [f("notes/a", "m"), f("notes/d", "e4")], "not b (another device's), not c (not dropped)")
    }

    /// Round 7, M3: the parent's home is required to take an epoch above epoch 1 (see EpochChainTests for
    /// the vault.json form); here, a takeover's list re-admits only devices of its ancestry.
    func testTakeoverListRule() {
        let anc: Set<Data> = ["A", "B", "C", "R"].map(Self.d).reduce(into: []) { $0.insert($1) }
        XCTAssertTrue(TakeoverRule.listAllowed([Self.d("K"), Self.d("B"), Self.d("R")], home: Self.d("K"), ancestorLists: anc))
        XCTAssertFalse(TakeoverRule.listAllowed([Self.d("K"), Self.d("Z"), Self.d("R")], home: Self.d("K"), ancestorLists: anc))
        XCTAssertEqual(TakeoverRule.recoveryKey(parentRecovery: Self.d("R")), Self.d("R"))
    }

    // MARK: - Property test

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

    struct Violation: Error, CustomStringConvertible { var description: String }

    /// A random tree: honest home epochs (removals, handoffs) from random parents (so the home key also
    /// signs twice under one epoch, as a stolen or replayed home would), epochs by devices that are not
    /// home (listed ones, removed ones, and the home before a takeover), and takeovers, some without the
    /// recovery key's signature, with random new homes (some new devices) and random lists.
    static func tree(seed: UInt64) -> [EpochNode] {
        var rng = RNG(state: seed)
        let devices = ["A", "B", "C", "D", "E"].map(d)
        let r = d("R")
        var used: Set<Data> = []
        func newId() -> Data {
            while true { let id = d(String(format: "%04x", rng.int(65536))); if used.insert(id).inserted { return id } }
        }
        let root = EpochNode(epochId: newId(), parent: nil, signer: devices[0], reason: .create, home: devices[0],
                             list: Set(devices + [r]), recovery: r)
        var kits = [r]
        var nodes = [root]
        var byId = [root.epochId: root]
        var homeBefore: [Data: Data] = [:]   // after a takeover: the home before it
        for _ in 0..<(3 + rng.int(12)) {
            // Prefer recent epochs as parents.
            let p = nodes[max(0, nodes.count - 1 - rng.int(min(nodes.count, 4)))]
            let others = p.list.filter { !kits.contains($0) && $0 != p.home }.sorted { $0.lexicographicallyPrecedes($1) }
            var n: EpochNode
            switch rng.int(12) {
            case 10, 11:
                // A kit replacement or re-encryption by home: the recovery key changes.
                let r2 = d("R\(kits.count)"); kits.append(r2)
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: p.home, reason: rng.chance(0.5) ? .recovery : .reencrypt,
                              home: p.home, list: p.list.subtracting([p.recovery]).union([r2]), recovery: r2)
            case 0...3:
                var list = p.list
                if let x = others.isEmpty ? nil : rng.pick(others), rng.chance(0.7) { list.remove(x) }
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: p.home, reason: .remove, home: p.home, list: list,
                              recovery: p.recovery)
            case 4:
                guard !others.isEmpty else { continue }
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: p.home, reason: .handoff, home: rng.pick(others),
                              list: p.list, recovery: p.recovery)
            case 5, 6:
                // Not the home: a listed device, a removed one, or the home before a takeover.
                var candidates = devices.filter { $0 != p.home }
                if let old = homeBefore[p.epochId] ?? (p.parent.flatMap { homeBefore[$0] }) { candidates += [old, old] }
                let signer = rng.pick(candidates)
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: signer, reason: .remove, home: signer,
                              list: p.list.subtracting([p.home]).union([signer]), recovery: p.recovery)
            default:
                let newHome = rng.chance(0.3) ? d("K\(rng.int(3))") : rng.pick(devices)
                var list = Set(p.list.filter { $0 == p.recovery || rng.chance(0.6) }).union([newHome, p.recovery])
                if rng.chance(0.2) { list.insert(rng.pick(devices)) }   // a device of an ancestor list, re-admitted
                if rng.chance(0.1) { list.insert(d("Z")) }   // a takeover that introduces a device: invalid
                // Signed by the parent's recovery key, mostly; sometimes by another kit, or not at all.
                let signer: Data? = rng.chance(0.75) ? p.recovery : (rng.chance(0.5) ? rng.pick(kits) : nil)
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: newHome, reason: .takeover, home: newHome,
                              list: list, recovery: p.recovery, recoverySigner: signer)
                homeBefore[n.epochId] = p.home
            }
            nodes.append(n); byId[n.epochId] = n
            if n.reason != .takeover, let hb = homeBefore[p.epochId] { homeBefore[n.epochId] = hb }
        }
        return nodes
    }

    /// The oracle's own validity (independent of the code): a takeover signed by the recovery key and its
    /// new home, listing nothing new but that home; any other epoch signed by its parent's home, keeping it
    /// (a handoff: naming another).
    static func valid(_ c: EpochNode, under p: EpochNode, ancestry: Set<Data>) -> Bool {
        guard c.list.contains(c.home), c.home != c.recovery else { return false }
        if c.reason == .takeover {
            return c.recoverySigner == p.recovery && c.recovery == p.recovery && c.signer == c.home
                && c.list.isSubset(of: ancestry.union([c.home]))
        }
        return c.signer == p.home && (c.reason == .handoff ? c.home != p.home : c.home == p.home)
    }

    static func check(seed: UInt64, mutations: Set<PrecedenceMutation> = []) throws {
        let nodes = tree(seed: seed)
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.epochId, $0) })
        func path(_ id: Data) -> [Data] {
            var out: [Data] = []; var cur: Data? = id
            while let c = cur { out.insert(c, at: 0); cur = byId[c]?.parent }
            return out
        }
        func ancestry(_ id: Data) -> Set<Data> { path(id).reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.list ?? []) } }
        /// (f) Was the kit that signs a takeover under `parent` retired on `pinned`: replaced by a `recovery`
        /// or `reencrypt` epoch of the pinned chain after the point where the parent's ancestry leaves it?
        func retired(under parent: Data, pinned: [Data]) -> Bool {
            let ancestry = path(parent)
            var shared = 0
            while shared < min(ancestry.count, pinned.count), ancestry[shared] == pinned[shared] { shared += 1 }
            guard shared > 0 else { return !pinned.isEmpty }
            return pinned[shared...].contains { byId[$0]?.reason == .recovery || byId[$0]?.reason == .reencrypt }
        }
        var rng = RNG(state: seed ^ 0x5eed)
        var pins: [[Data]] = [[]]
        for _ in 0..<4 { pins.append(path(rng.pick(nodes).epochId)) }
        for pinned in pins {
            let at = "seed \(seed), pinned \(pinned.count)"
            func validStep(_ c: Data, _ parent: Data) -> Bool {
                guard let cn = byId[c], let pn = byId[parent] else { return false }
                if cn.reason == .takeover && retired(under: parent, pinned: pinned) { return false }
                return valid(cn, under: pn, ancestry: ancestry(parent))
            }
            let validNodes = Set(nodes.filter { n in
                let p = path(n.epochId)
                return zip(p.dropFirst(), p).allSatisfy { validStep($0, $1) }
            }.map(\.epochId))
            let takeovers = nodes.filter { $0.reason == .takeover && validNodes.contains($0.epochId) }
            let r = try EpochPrecedence.resolve(nodes, pinned: pinned, mutations: mutations)
            let chain = r.keptChain
            // (a) Every followed epoch is signed by the home of its parent, or is a takeover by the recovery key.
            for (c, p) in zip(chain.dropFirst(), chain) {
                guard validStep(c, p) else {
                    throw Violation(description: "(a) \(at): an epoch not signed by the home of its parent was followed")
                }
            }
            // (b) Takeover precedence: no valid takeover below the chain's end; each valid takeover off the chain
            // lost to a takeover on it with a smaller id (at their branch), or sits below a home conflict the pin settled.
            guard let end = chain.last else { throw Violation(description: "(b) \(at): empty chain") }
            let onChain = Set(chain)
            for t in takeovers where !onChain.contains(t.epochId) {
                let p = path(t.epochId)
                if p.contains(end) { throw Violation(description: "(b) \(at): a takeover below the chain's end was not followed") }
                guard let branch = p.last(where: { onChain.contains($0) }), let i = chain.firstIndex(of: branch) else { continue }
                // The takeovers between the branch and t: t competes only if there are none.
                let between = p.drop { $0 != branch }.dropFirst().dropLast().contains { byId[$0]?.reason == .takeover }
                guard !between else { continue }
                guard let winner = chain[(i + 1)...].first(where: { byId[$0]?.reason == .takeover }) else {
                    throw Violation(description: "(b) \(at): a home epoch beat a takeover")
                }
                if winner.lexicographicallyPrecedes(t.epochId) == false, path(winner).contains(t.epochId) == false {
                    throw Violation(description: "(b) \(at): the larger of two takeovers won")
                }
            }
            // ... and a pinned epoch is dropped only by a takeover after the point where the chain leaves the pin.
            if let firstDropped = r.dropped.first, let parent = byId[firstDropped]?.parent, let i = chain.firstIndex(of: parent),
               !chain[(i + 1)...].contains(where: { byId[$0]?.reason == .takeover }) {
                throw Violation(description: "(b) \(at): pinned epochs dropped without a takeover")
            }
            // (d) No device a takeover left out signs or is home on the chain after it.
            if let ti = chain.lastIndex(where: { byId[$0]?.reason == .takeover }), let t = byId[chain[ti]] {
                for e in chain[(ti + 1)...] {
                    guard let en = byId[e], t.list.contains(en.signer), t.list.contains(en.home) else {
                        throw Violation(description: "(d) \(at): a device the takeover removed is on the chain after it")
                    }
                }
            }
            // (f) No takeover on the chain was signed by a kit this device's pinned chain retired.
            for c in chain where byId[c]?.reason == .takeover {
                if let p = byId[c]?.parent, retired(under: p, pinned: pinned) {
                    throw Violation(description: "(f) \(at): a retired kit's takeover was followed")
                }
            }
            // (e) A home conflict (two valid home-signed children, no takeover below) that neither the pin
            // nor the user settles stops the chain: never settled by id.
            let validChildren = { (x: Data) in nodes.filter { $0.parent == x && validNodes.contains($0.epochId) }.map(\.epochId) }
            let hasTakeoverBelow = { (x: Data) in takeovers.contains { path($0.epochId).dropLast().contains(x) } }
            let pinSet = Set(pinned)
            for (c, p) in zip(chain.dropFirst(), chain) {
                let siblings = validChildren(p)
                if siblings.count > 1, !hasTakeoverBelow(p), !pinSet.contains(c) {
                    throw Violation(description: "(e) \(at): a home conflict settled without the pin or the user")
                }
            }
            // (c) Order independence.
            var shuffled = nodes
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, rng.int(i + 1)) }
            if try EpochPrecedence.resolve(shuffled, pinned: pinned, mutations: mutations) != r {
                throw Violation(description: "(c) \(at): depends on the input order")
            }
        }
    }

    static var seeds: UInt64 { UInt64(ProcessInfo.processInfo.environment["SEMPERE_PRECEDENCE_PROPERTY_SEEDS"] ?? "") ?? 2000 }

    func testPrecedenceProperties() throws {
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
        for mutation in [PrecedenceMutation.nonHomeSignerAccepted, .takeoverIgnored, .olderHomeKept, .conflictSettledById,
                         .retiredKitAccepted] {
            var caught: String?
            for seed in 1...UInt64(2000) {
                do { try Self.check(seed: seed, mutations: [mutation]) } catch { caught = "\(error)"; break }
            }
            XCTAssertNotNil(caught, "\(mutation) was not caught")
        }
    }
}
