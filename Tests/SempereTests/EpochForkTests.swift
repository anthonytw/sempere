import Foundation
import XCTest
@testable import Sempere

/// Fork resolution (docs/design/key-hierarchy.md §5.6) against the fork-tree vectors
/// `Fixtures/epoch-fork-vectors.json` (the §11.1 fork scenarios as trees).
final class EpochForkTests: XCTestCase {
    struct Vectors: Decodable {
        struct Node: Decodable {
            var id: String; var parent: String?; var author: String; var list: [String]; var removes: [String]
            var reason: String; var recovery: String?; var rejected: String?
        }
        struct Context: Decodable {
            var me: String?; var rejected: [String]; var approverChains: [String: [String]]; var pinned: [String]
        }
        struct Question: Decodable {
            var branch: String; var sides: [String]; var authors: [String]; var asked: [String]; var resolves: [String: String]
        }
        struct Expect: Decodable {
            var kept: [String]; var losses: [[String]]; var reapply: [String]; var question: Question?
            var contradictions: [[String]]
        }
        struct Case: Decodable { var name: String; var nodes: [Node]; var context: Context; var expect: Expect }
        var cases: [Case]
    }

    static func d(_ s: String) -> Data { Data(s.utf8) }
    static func s(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    static func nodes(_ c: Vectors.Case) throws -> [ForkNode] {
        try c.nodes.map { n in
            ForkNode(epochId: d(n.id), parent: n.parent.map(d), author: d(n.author), removals: Set(n.removes.map(d)),
                     list: Set(n.list.map(d)), reason: try XCTUnwrap(EpochReason(rawValue: n.reason)),
                     recovery: n.recovery.map(d), rejected: n.rejected.map(d))
        }
    }

    func testForkTreeVectors() throws {
        let url = try FixtureTests.bundled("epoch-fork-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 28)
        for c in v.cases {
            let ctx = ForkContext(me: c.context.me.map(Self.d), rejectedAuthors: Set(c.context.rejected.map(Self.d)),
                                  approverChains: Dictionary(uniqueKeysWithValues: c.context.approverChains.map {
                                      (Self.d($0.key), $0.value.map(Self.d))
                                  }),
                                  pinned: c.context.pinned.map(Self.d))
            let r = try EpochForks.resolve(try Self.nodes(c), context: ctx)
            XCTAssertEqual(r.keptChain.map(Self.s), c.expect.kept, c.name)
            XCTAssertEqual(r.losses.map { [Self.s($0.child), Self.s($0.to), $0.rule.rawValue] }, c.expect.losses, c.name)
            XCTAssertEqual(Set(r.reapply.map(Self.s)), Set(c.expect.reapply), c.name)
            XCTAssertEqual(r.contradictions.map { [Self.s($0.resolveEpoch), Self.s($0.rejected)] }, c.expect.contradictions, c.name)
            if let q = c.expect.question {
                let got = try XCTUnwrap(r.question, c.name)
                XCTAssertEqual(Self.s(got.branch), q.branch, c.name)
                XCTAssertEqual(got.sides.map(Self.s), q.sides, c.name)
                XCTAssertEqual(got.authors.map(Self.s), q.authors, c.name)
                XCTAssertEqual(Set(got.asked.map(Self.s)), Set(q.asked), c.name)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: got.resolves.map { (Self.s($0.key), Self.s($0.value)) }),
                               q.resolves, c.name)
            } else {
                XCTAssertNil(r.question, c.name)
            }
            // Arrival order never matters (J4): the same result from the nodes reversed and shuffled.
            var rng = SystemRandomNumberGenerator()
            for order in [try Self.nodes(c).reversed(), try Self.nodes(c).shuffled(using: &rng)] {
                XCTAssertEqual(try EpochForks.resolve(Array(order), context: ctx), r, c.name)
            }
        }
    }

    static func n(_ id: String, _ parent: String?, _ author: String, list: [String], removes: [String],
                  reason: EpochReason = .remove, rejected: String? = nil) -> ForkNode {
        ForkNode(epochId: d(id), parent: parent.map(d), author: d(author), removals: Set(removes.map(d)),
                 list: Set(list.map(d)), reason: reason, recovery: d("R"), rejected: rejected.map(d))
    }

    /// Review C1 (probe testPoisonedHonestStaleForkHijacksTheKeptChain): X, removed on the real side,
    /// appends one epoch under B's old honest stale fork removing A. Before the fix the kept chain
    /// became e1 → 0b → 1x on every device; now X's epoch counts for nothing and the real side wins by
    /// rule 3, on every device.
    func testRemovedDeviceCannotHijackAnOldStaleFork() throws {
        let honest = [
            Self.n("e1", nil, "A", list: ["A", "B", "C", "X", "Y", "R"], removes: [], reason: .create),
            Self.n("2a", "e1", "A", list: ["A", "B", "C", "Y", "R"], removes: ["X"]),
            Self.n("3a", "2a", "C", list: ["A", "B", "C", "R"], removes: ["Y"]),
            Self.n("0b", "e1", "B", list: ["A", "B", "C", "X", "R"], removes: ["Y"]),
        ]
        for poison in [["A"], ["A", "C"], ["A", "B", "C"]] {
            let nodes = honest + [Self.n("1x", "0b", "X", list: ["B", "C", "X", "R"], removes: poison)]
            for me in ["A", "B", "C", "Y"] {
                let r = try EpochForks.resolve(nodes, context: ForkContext(me: Self.d(me)))
                XCTAssertEqual(r.keptChain.map(Self.s), ["e1", "2a", "3a"], "me \(me), X removes \(poison)")
                XCTAssertEqual(r.losses.map { [Self.s($0.child), $0.rule.rawValue] }, [["0b", "rule3"]], "me \(me)")
                XCTAssertNil(r.question)
            }
        }
        // X adds descendants of its own under its poison: still nothing.
        let deeper = honest + [Self.n("1x", "0b", "X", list: ["B", "C", "X", "R"], removes: ["A"]),
                               Self.n("2x", "1x", "X", list: ["C", "X", "R"], removes: ["B"])]
        XCTAssertEqual(try EpochForks.resolve(deeper, context: ForkContext(me: Self.d("C"))).keptChain.map(Self.s),
                       ["e1", "2a", "3a"])
    }

    /// Review M4 (probe testContradictoryBindingResolves): two binding resolve epochs that disagree are
    /// a contradiction and a question for each author, never settled by the smaller id.
    func testContradictoryBindingResolvesAreAsked() throws {
        let nodes = [
            Self.n("e1", nil, "A", list: ["A", "B", "C", "X", "R"], removes: [], reason: .create),
            Self.n("2a", "e1", "A", list: ["A", "B", "C", "R"], removes: ["X"]),
            Self.n("2x", "e1", "X", list: ["B", "C", "X", "R"], removes: ["A"]),
            Self.n("r3", "2a", "C", list: ["A", "B", "C", "R"], removes: [], reason: .resolve, rejected: "X"),
            Self.n("r2", "2x", "B", list: ["B", "C", "X", "R"], removes: [], reason: .resolve, rejected: "A"),
        ]
        for me in ["A", "X"] {
            let r = try EpochForks.resolve(nodes, context: ForkContext(me: Self.d(me),
                                                                      approverChains: [Self.d("B"): [], Self.d("C"): []]))
            XCTAssertEqual(r.keptChain.map(Self.s), ["e1"], me)
            XCTAssertNotNil(r.question, me)
            XCTAssertEqual(Set(r.contradictions.map { Self.s($0.resolveEpoch) }), ["r2", "r3"], me)
        }
    }

    func testMalformedTreesAreRefused() {
        let n = { (id: String, parent: String?) in
            ForkNode(epochId: Self.d(id), parent: parent.map(Self.d), author: Self.d("A"), removals: [], list: [Self.d("A")],
                     reason: .remove)
        }
        XCTAssertThrowsError(try EpochForks.resolve([])) { XCTAssertEqual($0 as? ForkError, .noRoot) }
        XCTAssertThrowsError(try EpochForks.resolve([n("1", nil), n("1b", nil)])) { XCTAssertEqual($0 as? ForkError, .noRoot) }
        XCTAssertThrowsError(try EpochForks.resolve([n("1", nil), n("2", "9")])) { XCTAssertEqual($0 as? ForkError, .detached) }
        XCTAssertThrowsError(try EpochForks.resolve([n("1", nil), n("2", "3"), n("3", "2")])) {
            XCTAssertEqual($0 as? ForkError, .detached)
        }
        XCTAssertEqual(try EpochForks.resolve([n("1", nil)]).keptChain, [Self.d("1")])
    }
}
