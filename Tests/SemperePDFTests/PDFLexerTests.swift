import Foundation
import XCTest

@testable import SemperePDF

final class PDFLexerTests: XCTestCase {
    func parse(_ s: String) throws -> PDFObject {
        var lx = PDFLexer(Array(s.utf8))
        return try lx.parseObject()
    }

    func testScalars() throws {
        XCTAssertEqual(try parse("true"), .bool(true))
        XCTAssertEqual(try parse("null"), .null)
        XCTAssertEqual(try parse("-17"), .int(-17))
        XCTAssertEqual(try parse("+4"), .int(4))
        XCTAssertEqual(try parse(".5"), .real(0.5))
        XCTAssertEqual(try parse("-3."), .real(-3))
        XCTAssertEqual(try parse("123456789012345678901234"), .real(123456789012345678901234))
        XCTAssertEqual(try parse("12 0 R"), .ref(PDFRef(12, 0)))
        XCTAssertEqual(try parse("12 0 Rx"), .int(12))
        XCTAssertThrowsError(try parse("1.2.3"))
        XCTAssertThrowsError(try parse("--1"))
        XCTAssertThrowsError(try parse("1e5"))
    }

    func testStrings() throws {
        XCTAssertEqual(try parse("(a (b) \\(c\\) \\n\\101\\7\\\\)"), .string(Array("a (b) (c) \nA\u{7}\\".utf8)))
        XCTAssertEqual(try parse("(line\\\ncontinued)"), .string(Array("linecontinued".utf8)))
        XCTAssertEqual(try parse("<48 65 6c6C 6>"), .string([0x48, 0x65, 0x6C, 0x6C, 0x60]))
        XCTAssertThrowsError(try parse("(unterminated"))
        XCTAssertThrowsError(try parse("<4G>"))
    }

    func testNamesArraysDicts() throws {
        XCTAssertEqual(try parse("/A#20B"), .name(PDFName(bytes: [0x41, 0x20, 0x42])))
        XCTAssertEqual(try parse("[1 /x [2] (s)]"),
                       .array([.int(1), .name("x"), .array([.int(2)]), .string([0x73])]))
        let d = try parse("<< /Type /Page /K null /N 3 0 R % comment\n /A [1] >>")
        XCTAssertEqual(d.dictValue?["Type"], .name("Page"))
        XCTAssertNil(d.dictValue?["K"])
        XCTAssertEqual(d.dictValue?["N"], .ref(PDFRef(3)))
        XCTAssertThrowsError(try parse("<< 1 2 >>"))
        XCTAssertThrowsError(try parse("<< /A >>"))
        XCTAssertThrowsError(try parse("[1 2"))
    }

    func testSerializerRoundTrip() throws {
        let objects: [PDFObject] = [
            .array([.int(-3), .real(0.125), .real(1e20), .bool(false), .null, .ref(PDFRef(7, 2))]),
            .dict(PDFDict(["Name With Space": .name(PDFName(bytes: [0x23, 0x2F, 0x00, 0xFF])),
                           "S": .string([0, 0x28, 0x29, 0xFF])])),
        ]
        for o in objects {
            var lx = PDFLexer(PDFSerializer.bytes(o))
            XCTAssertEqual(try lx.parseObject(), o)
        }
        XCTAssertEqual(PDFSerializer.real(-0.0000001), "0")
        XCTAssertEqual(PDFSerializer.real(.nan), "0")
    }
}
