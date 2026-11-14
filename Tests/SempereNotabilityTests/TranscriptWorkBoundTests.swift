import Foundation
import XCTest

@testable import SempereImport
@testable import SempereNotability

/// A library's transcript reading is bounded by one work budget per note.
final class TranscriptWorkBoundTests: XCTestCase {
    /// A binary plist writer whose objects can be shared (referenced by index).
    enum O { case str(String), arr([Int]), dict([(Int, Int)]) }
    static func bplist(_ objs: [O], top: Int) -> Data {
        var out = Data("bplist00".utf8)
        var offsets: [Int] = []
        func hdr(_ m: UInt8, _ n: Int) {
            if n < 15 { out.append(m | UInt8(n)) } else {
                out.append(m | 0x0F)
                if n < 256 { out.append(0x10); out.append(UInt8(n)) }
                else { out.append(0x11); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF)) }
            }
        }
        func ref(_ i: Int) { out.append(UInt8(i >> 8)); out.append(UInt8(i & 0xFF)) }
        for o in objs {
            offsets.append(out.count)
            switch o {
            case .str(let s): hdr(0x50, s.utf8.count); out.append(contentsOf: Array(s.utf8))
            case .arr(let a): hdr(0xA0, a.count); a.forEach(ref)
            case .dict(let kv): hdr(0xD0, kv.count); kv.forEach { ref($0.0) }; kv.forEach { ref($0.1) }
            }
        }
        let table = out.count
        for o in offsets { for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8((o >> s) & 0xFF)) } }
        out.append(contentsOf: [0, 0, 0, 0, 0, 0, 4, 2])
        func be8(_ v: Int) { for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> s) & 0xFF)) } }
        be8(objs.count); be8(top); be8(table)
        return out
    }

    /// A library of `entries` recordings holding nested, shared lists of `n` items per level.
    static func library(n: Int, entries: Int) -> Data {
        var o: [O] = []
        func add(_ x: O) -> Int { o.append(x); return o.count - 1 }
        let kSeg = add(.str("segments")), kTr = add(.str("transcript")), kRec = add(.str("recordings"))
        let empty = add(.dict([]))
        let y = add(.dict([(kSeg, empty)]))
        let yArr = add(.arr(Array(repeating: y, count: n)))
        let x = add(.dict([(kSeg, yArr)]))
        let xArr = add(.arr(Array(repeating: x, count: n)))
        let entry = add(.dict([(kTr, xArr)]))
        let recs = add(.arr(Array(repeating: entry, count: entries)))
        let root = add(.dict([(kRec, recs)]))
        return bplist(o, top: root)
    }


    func testSharedNestingIsReadWithinABudget() throws {
        XCTAssertEqual(try NotabilityNote.parseRecordingEntries(Self.library(n: 2, entries: 1)).count, 1)
        let data = Self.library(n: 2_000, entries: 16)
        XCTAssertLessThan(data.count, 20_000)
        let t0 = Date()
        let entries = try NotabilityNote.parseRecordingEntries(data)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(entries.count, 16)
        XCTAssertNil(entries.first?.transcript)
        XCTAssertTrue(entries.contains { $0.transcriptSkipped })
    }

    func testOrdinaryTranscriptsAreNotSkipped() throws {
        let data = AttachmentFixtures.library([("r", "<key>duration</key><real>5</real><key>transcript</key><array><string>hello</string></array>")])
        let entries = try NotabilityNote.parseRecordingEntries(data)
        XCTAssertEqual(entries.first?.transcript?.segments.count, 1)
        XCTAssertEqual(entries.first?.transcriptSkipped, false)
    }

    func testLongKeysAreReadWithinTheBudget() throws {
        // Y = {<long key>: {}}, shared by every item of every list.
        var o: [O] = []
        func add(_ x: O) -> Int { o.append(x); return o.count - 1 }
        let long = add(.str(String(repeating: "k", count: 60_000)))
        let kSeg = add(.str("segments")), kTr = add(.str("transcript")), kRec = add(.str("recordings"))
        let empty = add(.dict([]))
        let y = add(.dict([(long, empty)]))
        let yArr = add(.arr(Array(repeating: y, count: 600)))
        let x = add(.dict([(kSeg, yArr)]))
        let xArr = add(.arr(Array(repeating: x, count: 600)))
        let entry = add(.dict([(kTr, xArr)]))
        let recs = add(.arr(Array(repeating: entry, count: 4)))
        let root = add(.dict([(kRec, recs)]))
        let t0 = Date()
        _ = try NotabilityNote.parseRecordingEntries(Self.bplist(o, top: root))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }
}
