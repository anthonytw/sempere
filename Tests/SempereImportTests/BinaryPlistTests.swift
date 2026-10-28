import Foundation
import ImportTestSupport
import XCTest

@testable import SempereImport

/// `BinaryPlist`, the importer's own `bplist00` reader.
final class BinaryPlistTests: XCTestCase {
    /// Builds a `bplist00` from raw object encodings with 2-byte offsets and
    /// 1-byte references (or the given sizes).
    static func bplist(_ objects: [[UInt8]], top: UInt64 = 0, refSize: UInt8 = 1, count: UInt64? = nil) -> Data {
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for o in objects { offsets.append(out.count); out += o }
        let table = out.count
        for o in offsets { out += [UInt8(o >> 8), UInt8(o & 0xFF)] }
        out += [0, 0, 0, 0, 0, 0, 2, refSize]
        for v in [count ?? UInt64(objects.count), top, UInt64(table)] { out += (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }
        return Data(out)
    }

    /// `n` objects; object k (k < n - 1) is an array of `width` references to
    /// object k + 1, and the last is an empty array.
    static func chain(_ n: Int, width: Int) -> [[UInt8]] {
        var objects: [[UInt8]] = []
        for k in 0..<n {
            if k == n - 1 {
                objects.append([0xA0])
            } else {
                let next = UInt8(k + 1)
                objects.append([0xA0 | UInt8(width)] + [UInt8](repeating: next, count: width))
            }
        }
        return objects
    }

    func assertBad(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PlistValue.parse(data), file: file, line: line) { e in
            guard case ImportError.archive? = e as? ImportError else { return XCTFail("\(e)", file: file, line: line) }
        }
    }

    /// 48 bytes: a set holding one integer. PropertyListSerialization on Linux
    /// segfaults on any binary plist with a set (found by the long fuzz run),
    /// so a hostile `.note` crashed the importer.
    func testSetThatCrashedFoundationParses() throws {
        let data = Self.bplist([[0xC1, 0x01], [0x10, 0x05]])
        XCTAssertEqual(data.count, 48)
        XCTAssertEqual(try PlistValue.parse(data), .array([.int(5)]))
        XCTAssertThrowsError(try KeyedArchive(data: data))
    }

    func testRoundTripOfEveryType() throws {
        let when = Date(timeIntervalSinceReferenceDate: 700_000_000.25)
        let value = BValue.dict([("s", .string("plain")), ("u", .string("Ünïcode ✓")), ("i", .int(-7)),
                                 ("big", .int(.max)), ("r", .real(0.5)), ("b", .bool(true)), ("d", .date(when)),
                                 ("data", .data(Data(repeating: 9, count: 40))), ("uid", .uid(70_000)),
                                 ("list", .array((0..<20).map { .int(Int64($0)) }))])
        let parsed = try PlistValue.parse(BPlist.encode(value))
        guard case .dict(let d) = parsed else { return XCTFail("\(parsed)") }
        XCTAssertEqual(d["s"], .string("plain"))
        XCTAssertEqual(d["u"], .string("Ünïcode ✓"))
        XCTAssertEqual(d["i"], .int(-7))
        XCTAssertEqual(d["big"], .int(.max))
        XCTAssertEqual(d["r"], .real(0.5))
        XCTAssertEqual(d["b"], .bool(true))
        XCTAssertEqual(d["d"], .date(when))
        XCTAssertEqual(d["data"], .data(Data(repeating: 9, count: 40)))
        XCTAssertEqual(d["uid"], .uid(70_000))
        XCTAssertEqual(d["list"], .array((0..<20).map { .int(Int64($0)) }))
        // Small widths: 1-byte unsigned int, float32, 128-bit int that fits.
        XCTAssertEqual(try PlistValue.parse(Self.bplist([[0x10, 0xFF]])), .int(255))
        XCTAssertEqual(try PlistValue.parse(Self.bplist([[0x22, 0x3F, 0x80, 0, 0]])), .real(1))
        XCTAssertEqual(try PlistValue.parse(Self.bplist([[0x14] + [UInt8](repeating: 0xFF, count: 16)])), .int(-1))
        assertBad(Self.bplist([[0x14, 1] + [UInt8](repeating: 0, count: 15)]))   // needs more than 64 bits
    }

    func testCyclesAndDepthAreRejected() {
        assertBad(Self.bplist([[0xA1, 0x00]]))                       // array containing itself
        assertBad(Self.bplist([[0xA1, 0x01], [0xD1, 0x02, 0x00], [0x51, 0x6B]]))   // via a dictionary value
        // A chain of 100 nested arrays.
        assertBad(Self.bplist(Self.chain(100, width: 1)))
        XCTAssertNoThrow(try PlistValue.parse(Self.bplist(Self.chain(40, width: 1))))
    }

    /// Object k is `[k + 1, k + 1]`: 2^60 elements if expanded, but each object
    /// is parsed once and shared.
    func testSharedReferencesAreParsedOnce() throws {
        let objects = Self.chain(61, width: 2)
        let t0 = Date()
        guard case .array(let top) = try PlistValue.parse(Self.bplist(objects)) else { return XCTFail() }
        XCTAssertEqual(top.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testCountsOffsetsAndReferencesAreBounded() {
        // Array claiming 2^60 elements (length in a following 8-byte int).
        assertBad(Self.bplist([[0xAF, 0x13, 0x10, 0, 0, 0, 0, 0, 0, 0, 0x00]]))
        // Data and UTF-16 strings running past the object area.
        assertBad(Self.bplist([[0x4F, 0x10, 0x7F]]))
        assertBad(Self.bplist([[0x6F, 0x11, 0x7F, 0xFF]]))
        // Reference out of range, and an 8-byte reference beyond Int.max.
        assertBad(Self.bplist([[0xA1, 0x09]]))
        assertBad(Self.bplist([[0xA1] + [UInt8](repeating: 0xFF, count: 8)], refSize: 8))
        // Trailer: no objects, top beyond count, count larger than the file.
        assertBad(Self.bplist([[0x08]], count: 0))
        assertBad(Self.bplist([[0x08]], top: 1))
        assertBad(Self.bplist([[0x08]], count: .max))
        // UID wider than Int, non-string dictionary key, unknown markers.
        assertBad(Self.bplist([[0x87] + [UInt8](repeating: 0xFF, count: 8)]))
        assertBad(Self.bplist([[0xD1, 0x01, 0x01], [0x10, 0x01]]))
        assertBad(Self.bplist([[0x00]]))
        assertBad(Self.bplist([[0xF0]]))
        assertBad(Data("bplist00".utf8))
        assertBad(Data("<?xml version=\"1.0\"?><plist/>".utf8))
    }

    /// Every truncation of a real archive parses or throws `ImportError`.
    func testEveryTruncationFailsCleanly() {
        var b = KeyedArchiveBuilder()
        let root = b.dict([("name", b.string("Ünïcode ✓")), ("list", b.array([b.string("a"), .int(2), b.data(Data([1, 2, 3]))])),
                           ("when", b.date(Date(timeIntervalSinceReferenceDate: 1)))])
        let full = b.archive(top: [("root", root)])
        for n in stride(from: 0, to: full.count, by: 7) {
            do { _ = try PlistValue.parse(full.prefix(n)) } catch is ImportError {} catch { XCTFail("\(n): \(error)") }
        }
    }
}
