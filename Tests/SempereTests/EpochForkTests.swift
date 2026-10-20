import Foundation
import XCTest
@testable import Sempere

/// Fork resolution, the simple rule (docs/design/key-hierarchy.md §5.6), against the vectors
/// `Fixtures/epoch-fork-vectors.json`, and the probes of the earlier review rounds.
final class EpochForkTests: XCTestCase {
    struct Vectors: Decodable {
        struct Node: Decodable {
            var id: String; var parent: String?; var author: String; var list: [String]; var removes: [String]
            var reason: String; var recovery: String?; var rejected: String?
        }
        struct Answer: Decodable { var branch, chosen: String; var confirmed, rejected: [String] }
        struct Context: Decodable { var me: String?; var pinned: [String]; var answers: [Answer]; var rejected: [String] }
        struct Side: Decodable { var child: String; var authors: [String] }
        struct Question: Decodable {
            var branch: String; var sides: [Side]; var suggested: String; var current: String?; var conflicts: [String]
        }
        struct Expect: Decodable {
            var kept: [String]; var questions: [Question]; var resolveFor: [String]; var reapply: [String]; var followed: [String]
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

    static func context(_ c: Vectors.Context) -> ForkContext {
        ForkContext(me: c.me.map(d), pinned: c.pinned.map(d),
                    answers: c.answers.map { ForkAnswer(branch: d($0.branch), chosen: d($0.chosen), confirmed: Set($0.confirmed.map(d)),
                                                        rejected: Set($0.rejected.map(d))) },
                    rejectedAuthors: Set(c.rejected.map(d)))
    }

    func testForkTreeVectors() throws {
        let url = try FixtureTests.bundled("epoch-fork-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 29)
        for c in v.cases {
            let ctx = Self.context(c.context)
            let r = try EpochForks.resolve(try Self.nodes(c), context: ctx)
            XCTAssertEqual(r.keptChain.map(Self.s), c.expect.kept, c.name)
            XCTAssertEqual(r.resolveFor.map(Self.s), c.expect.resolveFor, c.name)
            XCTAssertEqual(Set(r.reapply.map(Self.s)), Set(c.expect.reapply), c.name)
            XCTAssertEqual(r.followed.map(Self.s), c.expect.followed, c.name)
            XCTAssertEqual(r.questions.count, c.expect.questions.count, c.name)
            for (got, want) in zip(r.questions, c.expect.questions) {
                XCTAssertEqual(Self.s(got.branch), want.branch, c.name)
                XCTAssertEqual(got.sides.map { Self.s($0.child) }, want.sides.map(\.child), c.name)
                XCTAssertEqual(got.sides.map { $0.authors.map(Self.s) }, want.sides.map(\.authors), c.name)
                XCTAssertEqual(Self.s(got.suggested), want.suggested, c.name)
                XCTAssertEqual(got.current.map(Self.s), want.current, c.name)
                XCTAssertEqual(got.conflictingResolves.map(Self.s), want.conflicts, c.name)
            }
            // Arrival order never matters.
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

    /// Every probe of the three review rounds, from every viewpoint: a removed device's epochs are
    /// never on a chain without a question, and a device pinned through the removal is asked only
    /// about epochs by devices that were not removed.
    func testEarlierProbesEndInNoEffectOrOneQuestion() throws {
        let trees: [(String, [ForkNode], [String])] = [
            ("C1", [Self.n("e1", nil, "A", list: ["A", "B", "C", "X", "Y", "R"], removes: [], reason: .create),
                    Self.n("2a", "e1", "A", list: ["A", "B", "C", "Y", "R"], removes: ["X"]),
                    Self.n("3a", "2a", "C", list: ["A", "B", "C", "R"], removes: ["Y"]),
                    Self.n("0b", "e1", "B", list: ["A", "B", "C", "X", "R"], removes: ["Y"]),
                    Self.n("1x", "0b", "X", list: ["B", "C", "X", "R"], removes: ["A"])], ["e1", "2a", "3a"]),
            ("deadlock", [Self.n("e1", nil, "A", list: ["A", "A2", "B", "C", "X", "Y", "R"], removes: [], reason: .create),
                          Self.n("m", "e1", "A", list: ["A", "A2", "B", "C", "X", "Y", "R"], removes: []),
                          Self.n("m2", "m", "A2", list: ["A", "A2", "B", "C", "Y", "R"], removes: ["X"]),
                          Self.n("0b", "e1", "B", list: ["A", "A2", "B", "C", "X", "R"], removes: ["Y"]),
                          Self.n("0bx", "0b", "X", list: ["A", "B", "C", "X", "R"], removes: ["A2"])], ["e1", "m", "m2"]),
            ("child", [Self.n("e1", nil, "A", list: ["A", "A2", "B", "C", "X", "R"], removes: [], reason: .create),
                       Self.n("m", "e1", "A", list: ["A", "A2", "B", "C", "X", "R"], removes: []),
                       Self.n("m2", "m", "A2", list: ["A", "A2", "B", "C", "R"], removes: ["X"]),
                       Self.n("zx", "e1", "X", list: ["B", "C", "X", "R"], removes: ["A", "A2"]),
                       Self.n("zx2", "zx", "X", list: ["B", "C", "X", "R"], removes: [])], ["e1", "m", "m2"]),
            ("H2", [Self.n("e1", nil, "A", list: ["A", "B", "C", "D", "X", "Y", "R"], removes: [], reason: .create),
                    Self.n("e2", "e1", "X", list: ["A", "B", "C", "D", "X", "R"], removes: ["Y"]),
                    Self.n("e3", "e2", "A", list: ["A", "B", "C", "D", "R"], removes: ["X"]),
                    Self.n("0x", "e2", "X", list: ["B", "C", "D", "X", "R"], removes: ["A"]),
                    Self.n("0xd", "0x", "D", list: ["B", "C", "D", "R"], removes: ["X"])], ["e1", "e2", "e3"]),
        ]
        for (name, tree, real) in trees {
            for me in ["A", "B", "C", "D"] {
                for pinned in [[], Array(real.prefix(1)), real] {
                    let r = try EpochForks.resolve(tree, context: ForkContext(me: Self.d(me), pinned: pinned.map(Self.d)))
                    let label = "\(name) me \(me) pinned \(pinned)"
                    let xEpochs = tree.filter { Self.s($0.author) == "X" && !real.contains(Self.s($0.epochId)) }.map(\.epochId)
                    if r.questions.isEmpty { XCTAssertFalse(r.keptChain.contains { xEpochs.contains($0) }, label) }
                    if pinned == real {
                        XCTAssertEqual(r.keptChain.map(Self.s), real, label)
                        for q in r.questions { for side in q.sides { XCTAssertFalse(side.authors.contains(Self.d("X")), label) } }
                    }
                }
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
