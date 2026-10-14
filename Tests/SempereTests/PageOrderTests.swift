import XCTest
@testable import Sempere

final class PageOrderTests: XCTestCase {
    func assertBetween(_ a: String?, _ b: String?, file: StaticString = #filePath, line: UInt = #line) {
        let k = PageOrder.between(a, b)
        if let a { XCTAssertLessThan(a, k, "between(\(a), \(b ?? "nil"))", file: file, line: line) }
        if let b { XCTAssertLessThan(k, b, "between(\(a ?? "nil"), \(b))", file: file, line: line) }
        XCTAssertFalse(k.hasSuffix("0"), k, file: file, line: line)
    }

    func testSimpleCases() {
        XCTAssertEqual(PageOrder.between(nil, nil), "V")
        for (a, b) in [(nil, "1"), (nil, "01"), (nil, "001"), ("z", nil), ("zz", nil), ("a", "b"), ("a", "a1"),
                       ("a0", "a1"), ("a", "a01"), ("a0", nil), (nil, "a0"), ("Az", "B"), ("y", "z"), ("yz", "z")] as [(String?, String?)] {
            assertBetween(a, b)
        }
    }

    func testFallbackWhenNoKeyFits() {
        XCTAssertEqual(PageOrder.between("a", "a"), "aV")
        XCTAssertEqual(PageOrder.between("b", "a"), "bV")
        XCTAssertEqual(PageOrder.between("a", "a0"), "aV")    // nothing lies strictly between
        XCTAssertEqual(PageOrder.between("a-b", nil), "a-bV") // outside the alphabet
    }

    func testTenThousandSequentialInserts() {
        // Front.
        var keys = [PageOrder.between(nil, nil)]
        for _ in 0..<10_000 { keys.insert(PageOrder.between(nil, keys[0]), at: 0) }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertLessThanOrEqual(keys.map(\.count).max() ?? 0, 400, "front")

        // Back.
        keys = [PageOrder.between(nil, nil)]
        for _ in 0..<10_000 { keys.append(PageOrder.between(keys[keys.count - 1], nil)) }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertLessThanOrEqual(keys.map(\.count).max() ?? 0, 400, "back")

        // Middle, sequential: each new page goes right after the previous new
        // one, before a fixed neighbour (typing pages into the middle).
        keys = ["V", "W"]
        var prev = 0
        for _ in 0..<10_000 {
            keys.insert(PageOrder.between(keys[prev], keys[prev + 1]), at: prev + 1)
            prev += 1
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertLessThanOrEqual(keys.map(\.count).max() ?? 0, 400, "middle sequential")

        // Middle, alternating: always insert at count/2, which bisects one gap
        // from alternating sides (worst case; ~log2(62) inserts per character).
        keys = ["V", "W"]
        for _ in 0..<10_000 {
            let i = keys.count / 2
            keys.insert(PageOrder.between(keys[i - 1], keys[i]), at: i)
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertLessThanOrEqual(keys.map(\.count).max() ?? 0, 2_000, "middle alternating")
    }
}
