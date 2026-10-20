import Foundation
import XCTest
@testable import Sempere

/// The single-writer precedence rule (docs/design/key-hierarchy.md §5.6): the shared vectors and a small
/// randomized property test with required-failing mutations.
final class EpochPrecedenceTests: XCTestCase {
    struct Vectors: Decodable {
        struct Node: Decodable {
            var id: String; var parent: String?; var signer: String; var reason: String; var home: String
            var list: [String]; var recovery: String; var recoverySigned: Bool?
        }
        struct Expect: Decodable { var kept, dropped, ignored, homeConflicts: [String] }
        struct Case: Decodable { var name: String; var nodes: [Node]; var pinned: [String]; var expect: Expect }
        var cases: [Case]
    }

    static func d(_ s: String) -> Data { Data(s.utf8) }
    static func s(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    func testPrecedenceVectors() throws {
        let url = try FixtureTests.bundled("epoch-precedence-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 15)
        for c in v.cases {
            let nodes = try c.nodes.map { n in
                EpochNode(epochId: Self.d(n.id), parent: n.parent.map(Self.d), signer: Self.d(n.signer),
                          reason: try XCTUnwrap(EpochReason(rawValue: n.reason), c.name), home: Self.d(n.home),
                          list: Set(n.list.map(Self.d)), recovery: Self.d(n.recovery), recoverySigned: n.recoverySigned ?? false)
            }
            let r = try EpochPrecedence.resolve(nodes, pinned: c.pinned.map(Self.d))
            XCTAssertEqual(r.keptChain.map(Self.s), c.expect.kept, c.name)
            XCTAssertEqual(r.dropped.map(Self.s), c.expect.dropped, c.name)
            XCTAssertEqual(r.ignored.map(Self.s), c.expect.ignored, c.name)
            XCTAssertEqual(r.homeConflicts.map(Self.s), c.expect.homeConflicts, c.name)
            var rng = SystemRandomNumberGenerator()
            XCTAssertEqual(try EpochPrecedence.resolve(nodes.shuffled(using: &rng), pinned: c.pinned.map(Self.d)), r, c.name)
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
        var nodes = [root]
        var byId = [root.epochId: root]
        var homeBefore: [Data: Data] = [:]   // after a takeover: the home before it
        for _ in 0..<(3 + rng.int(12)) {
            // Prefer recent epochs as parents.
            let p = nodes[max(0, nodes.count - 1 - rng.int(min(nodes.count, 4)))]
            let others = p.list.filter { $0 != r && $0 != p.home }.sorted { $0.lexicographicallyPrecedes($1) }
            var n: EpochNode
            switch rng.int(10) {
            case 0...3:
                var list = p.list
                if let x = others.isEmpty ? nil : rng.pick(others), rng.chance(0.7) { list.remove(x) }
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: p.home, reason: .remove, home: p.home, list: list,
                              recovery: r)
            case 4:
                guard !others.isEmpty else { continue }
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: p.home, reason: .handoff, home: rng.pick(others),
                              list: p.list, recovery: r)
            case 5, 6:
                // Not the home: a listed device, a removed one, or the home before a takeover.
                var candidates = devices.filter { $0 != p.home }
                if let old = homeBefore[p.epochId] ?? (p.parent.flatMap { homeBefore[$0] }) { candidates += [old, old] }
                let signer = rng.pick(candidates)
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: signer, reason: .remove, home: signer,
                              list: p.list.subtracting([p.home]).union([signer]), recovery: r)
            default:
                let newHome = rng.chance(0.3) ? d("K\(rng.int(3))") : rng.pick(devices)
                var list = Set(p.list.filter { $0 == r || rng.chance(0.6) }).union([newHome, r])
                if rng.chance(0.1) { list.insert(d("Z")) }   // a takeover that introduces a device: invalid
                n = EpochNode(epochId: newId(), parent: p.epochId, signer: newHome, reason: .takeover, home: newHome,
                              list: list, recovery: r, recoverySigned: rng.chance(0.85))
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
    static func valid(_ c: EpochNode, under p: EpochNode) -> Bool {
        guard c.list.contains(c.home) else { return false }
        if c.reason == .takeover {
            return c.recoverySigned && c.signer == c.home && c.list.isSubset(of: p.list.union([c.home]))
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
        let validNodes = Set(nodes.filter { n in
            let p = path(n.epochId)
            return zip(p.dropFirst(), p).allSatisfy { c, parent in
                guard let cn = byId[c], let pn = byId[parent] else { return false }
                return valid(cn, under: pn)
            }
        }.map(\.epochId))
        let takeovers = nodes.filter { $0.reason == .takeover && validNodes.contains($0.epochId) }
        var rng = RNG(state: seed ^ 0x5eed)
        var pins: [[Data]] = [[]]
        for _ in 0..<4 { pins.append(path(rng.pick(nodes).epochId)) }
        for pinned in pins {
            let at = "seed \(seed), pinned \(pinned.count)"
            let r = try EpochPrecedence.resolve(nodes, pinned: pinned, mutations: mutations)
            let chain = r.keptChain
            // (a) Every followed epoch is signed by the home of its parent, or is a takeover by the recovery key.
            for (c, p) in zip(chain.dropFirst(), chain) {
                guard let cn = byId[c], let pn = byId[p], valid(cn, under: pn) else {
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
        for mutation in [PrecedenceMutation.nonHomeSignerAccepted, .takeoverIgnored, .olderHomeKept] {
            var caught: String?
            for seed in 1...UInt64(2000) {
                do { try Self.check(seed: seed, mutations: [mutation]) } catch { caught = "\(error)"; break }
            }
            XCTAssertNotNil(caught, "\(mutation) was not caught")
        }
    }
}
