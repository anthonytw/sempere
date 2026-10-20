import Foundation
import XCTest
@testable import Sempere

/// Fork resolution (docs/design/key-hierarchy.md §5.6) against the fork-tree vectors
/// `Fixtures/epoch-fork-vectors.json` (the §11.1 fork scenarios as trees).
final class EpochForkTests: XCTestCase {
    struct Vectors: Decodable {
        struct Node: Decodable {
            var id: String; var parent: String?; var author: String; var list: [String]; var removes: [String]
            var reason: String; var rejected: String?
        }
        struct Context: Decodable {
            var me: String?; var rejected: [String]; var approverChains: [String: [String]]; var recovery: [String]
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
                     rejected: n.rejected.map(d))
        }
    }

    func testForkTreeVectors() throws {
        let url = try FixtureTests.bundled("epoch-fork-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 15)
        for c in v.cases {
            let ctx = ForkContext(me: c.context.me.map(Self.d), rejectedAuthors: Set(c.context.rejected.map(Self.d)),
                                  approverChains: Dictionary(uniqueKeysWithValues: c.context.approverChains.map {
                                      (Self.d($0.key), $0.value.map(Self.d))
                                  }),
                                  recoveryKeys: Set(c.context.recovery.map(Self.d)))
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
