import Foundation
import ImportTestSupport
import Sempere
import XCTest

@testable import SempereImport
@testable import SempereNotability

/// Regression tests for hostile `.ntb` indexes and attachment records and the
/// `.note` PDF index (docs/import-notability.md ".ntb attachments", "PDF
/// text"): shared references are charged, never decoded once per reference.
final class UntrustedBundleIndexTests: XCTestCase {
    /// An index laid out like `ios/HandwritingIndex.fb` and `ios/PDFIndex.fb`
    /// (root field 2 → table → field 0: page tables of a 12-byte header whose
    /// third word is the page, and field 1, the text) where every page table
    /// references one shared text. Written by hand: `FBWriter` cannot share.
    static func sharedTextIndex(pages: Int, textBytes: Int) -> Data {
        var b: [UInt8] = [0, 0, 0, 0]
        func put32(_ p: Int, _ v: UInt32) { for i in 0..<4 { b[p + i] = UInt8(v >> (8 * UInt32(i)) & 0xFF) } }
        func app16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func align() { while b.count % 4 != 0 { b.append(0) } }
        /// A vtable and a table of `size` bytes with fields at `offsets`; returns the table's position.
        func table(_ offsets: [Int], size: Int) -> Int {
            align()
            let vt = b.count
            app16(4 + 2 * offsets.count); app16(size)
            for o in offsets { app16(o) }
            align()
            let t = b.count
            b += [UInt8](repeating: 0, count: size)
            put32(t, UInt32(t - vt))
            return t
        }
        func ref(_ at: Int, _ target: Int) { put32(at, UInt32(target - at)) }
        let root = table([0, 0, 4], size: 8)
        put32(0, UInt32(root))
        let list = table([4], size: 8)
        ref(root + 4, list)
        align()
        let vec = b.count
        b += [UInt8](repeating: 0, count: 4 + 4 * pages)
        put32(vec, UInt32(pages))
        ref(list + 4, vec)
        var textRefs: [Int] = []
        for i in 0..<pages {
            let t = table([4, 16], size: 20)   // field 0: 12-byte header at +4; field 1: text reference at +16
            put32(t + 12, UInt32(i))
            ref(vec + 4 + 4 * i, t)
            textRefs.append(t + 16)
        }
        align()
        let s = b.count
        b += [0, 0, 0, 0] + [UInt8](repeating: 0x61, count: textBytes) + [0]
        put32(s, UInt32(textBytes))
        for r in textRefs { ref(r, s) }
        return Data(b)
    }

    /// 20 000 pages naming one 256 KiB text decoded 20 000 copies (5 GB) from
    /// an 800 KB index: the texts are charged to the decode budget.
    func testSharedPDFIndexTextIsCharged() {
        let data = Self.sharedTextIndex(pages: 20_000, textBytes: 256 << 10)
        var notes: [String] = []
        XCTAssertNil(NotabilityPDFIndex.bundleIndex(data, notes: &notes))
        XCTAssertTrue(notes.contains { $0.contains("decode budget") }, "\(notes)")
        // An unshared index still reads.
        let small = Self.sharedTextIndex(pages: 3, textBytes: 10)
        var n2: [String] = []
        XCTAssertEqual(NotabilityPDFIndex.bundleIndex(small, notes: &n2)?.count, 3)
    }

    /// The same sharing in `ios/HandwritingIndex.fb` (the reader the PDF index copies).
    func testSharedHandwritingIndexTextIsCharged() {
        let data = Self.sharedTextIndex(pages: 20_000, textBytes: 256 << 10)
        XCTAssertThrowsError(try NotabilityBundle.parseHandwritingIndex(data, inset: 0)) { e in
            XCTAssertTrue(e is ImportError, "\(e)")
        }
        XCTAssertEqual(try NotabilityBundle.parseHandwritingIndex(Self.sharedTextIndex(pages: 3, textBytes: 10), inset: 0).count, 3)
    }

    /// A PDF or media record's name walk read up to 64 tables of 1 KiB vectors
    /// for a flat 256 bytes of budget, and records can share one payload: the
    /// walk's reads are now charged.
    func testAttachmentRecordWalkIsCharged() throws {
        let vector = [UInt8](repeating: 0x41, count: 1024)
        var fields: [Int: FBValue] = [:]
        for i in 0..<40 { fields[i] = .bytes(vector) }
        let data = FBWriter.buffer(root: fields)
        let fb = FlatBuffer(data)
        let payload = try fb.root()
        var tight = NotabilityBundle.Budget(limit: 8 << 10)
        XCTAssertThrowsError(try NotabilityBundle.attachment(fb, payload, kind: .pdf, index: 0, budget: &tight))
        var ample = NotabilityBundle.Budget(limit: 1 << 20)
        XCTAssertNoThrow(try NotabilityBundle.attachment(fb, payload, kind: .pdf, index: 0, budget: &ample))
        XCTAssertGreaterThan(ample.used, 40 * 1024)
    }

    /// `PDFMetadataIndex.plist` listing one array of a million integers 10 000
    /// times: every visit scanned the whole array (10¹⁰ steps). Only arrays of
    /// the page count's length are scanned now, and scans are charged.
    func testSharedArrayInPDFMetadataIndexIsNotRescanned() {
        let big = PlistValue.array((0..<1_000_000).map { .int(Int64($0)) })
        let plist = PlistValue.array(Array(repeating: big, count: 10_000))
        let start = Date()
        XCTAssertNil(NotabilityPDFIndex.split("abc", offsetsIn: plist, pageCount: 3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // A real offsets array still splits.
        let pages = NotabilityPDFIndex.split("onetwothree", offsetsIn: .dict(["offsets": .array([.int(0), .int(3), .int(6)])]),
                                             pageCount: 3)
        XCTAssertEqual(pages, [0: "one", 1: "two", 2: "three"])
    }

    /// Notability 16's inline hash read (a field of 64 to 71 bytes) copies up
    /// to 64 bytes per candidate field: charged like the name walk, since
    /// records can share one payload.
    func testInlineHashReadIsCharged() throws {
        var fields: [Int: FBValue] = [:]
        for i in 0..<40 { fields[i] = .structBytes((0..<64).map { UInt8(($0 * 7 + i) & 0xFF) } + [0, 0, 0, 0]) }
        let fb = FlatBuffer(FBWriter.buffer(root: fields))
        let payload = try fb.root()
        var tight = NotabilityBundle.Budget(limit: 1024)
        XCTAssertThrowsError(try NotabilityBundle.attachment(fb, payload, kind: .pdf, index: 0, budget: &tight))
        var ample = NotabilityBundle.Budget(limit: 1 << 20)
        let a = try NotabilityBundle.attachment(fb, payload, kind: .pdf, index: 0, budget: &ample)
        XCTAssertGreaterThanOrEqual(ample.used, 40 * 64)
        XCTAssertEqual(a.fileNames.count, 40)
    }
}
