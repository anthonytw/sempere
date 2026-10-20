import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Emoji in text boxes, multi-scalar ones included (flags, skin tones, ZWJ sequences, keycaps):
/// they survive the JSON round trip byte for byte, count in scalars for `breaks`, are never cut
/// inside a cluster, and lay out without losing a scalar.
final class EmojiTextTests: XCTestCase {
    static let samples: [(name: String, text: String)] = [
        ("smile", "😀"),
        ("flag", "🇺🇸"),
        ("skin tone", "👍🏽"),
        ("ZWJ family", "👨‍👩‍👧‍👦"),
        ("ZWJ profession", "🧑🏽‍🚀"),
        ("keycap", "1️⃣"),
        ("rainbow flag", "🏳️‍🌈"),
    ]

    static var all: String { samples.map(\.text).joined(separator: " ") }

    func content(_ s: String, breaks: [Int]? = nil) -> TextContent {
        TextContent(size: 12, color: Color(r: 0, g: 0, b: 0, a: 255), runs: [TextRun(s)], breaks: breaks)
    }

    func testEmojiSurviveTheJSONRoundTripUnchanged() throws {
        for (name, text) in Self.samples + [("all", Self.all), ("mixed", "a\(Self.all)\nb é 漢")] {
            let original = content(text)
            XCTAssertNil(original.limitViolation, name)
            let data = try InkJSON.encoder().encode(original)
            let back = try InkJSON.decoder().decode(TextContent.self, from: data)
            XCTAssertEqual(back.string.unicodeScalars.map(\.value), text.unicodeScalars.map(\.value), name)
            XCTAssertEqual(back, original, name)
        }
    }

    func testTheLimitCountsUTF8BytesOfEveryScalar() {
        // A ZWJ family is 7 scalars = 25 bytes; a text just over the limit is reported, one at it is not.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.utf8.count, 25)
        let fits = String(repeating: family, count: TextContent.Limits.utf8Bytes / 25)
        XCTAssertNil(content(fits).limitViolation)
        XCTAssertNotNil(content(fits + family).limitViolation)
    }

    func testBreaksCountScalarsAndNeverSplitACluster() {
        let text = "ab 👨‍👩‍👧‍👦 🇺🇸x"
        let scalars = Array(text.unicodeScalars)
        let familyStart = 3, familyEnd = familyStart + 7
        XCTAssertEqual(scalars[familyStart].value, 0x1F468)
        // A break before and after the family is usable; one inside it (after a ZWJ, or between
        // the regional indicators of the flag) is not.
        XCTAssertEqual(TextLineBreaks.usable(content(text, breaks: [familyStart])), [familyStart])
        XCTAssertEqual(TextLineBreaks.usable(content(text, breaks: [familyEnd])), [familyEnd])
        XCTAssertNil(TextLineBreaks.usable(content(text, breaks: [familyStart + 2])))
        let flag = familyEnd + 1
        XCTAssertEqual(scalars[flag].value, 0x1F1FA)
        XCTAssertNil(TextLineBreaks.usable(content(text, breaks: [flag + 1])))
        XCTAssertEqual(TextLineBreaks.usable(content(text, breaks: [flag])), [flag])
    }

    func testUTF16AndScalarOffsetsAgreeAcrossSurrogatePairs() {
        let text = "a" + Self.all + "z"
        let layout = LayoutText(content(text))
        XCTAssertEqual(layout.scalars.count, text.unicodeScalars.count)
        XCTAssertEqual(layout.layoutString, text)
        XCTAssertEqual(layout.utf16Offsets.last, text.utf16.count)
        for i in 0..<layout.scalars.count {
            XCTAssertEqual(layout.scalarOffset(utf16: layout.utf16Offsets[i]), i)
        }
        // A UTF-16 offset in the middle of a surrogate pair rounds up to the next scalar.
        XCTAssertEqual(layout.scalarOffset(utf16: 2), 2)
        XCTAssertEqual(layout.utf16Range(1..<2).count, 2)
    }

    func testLayingOutEmojiKeepsEveryScalarAndNeverSplitsACluster() throws {
        let text = "ab \(Self.all) z"
        let shaped = try TextLayoutTests.lines(content(text), width: 40)
        let scalarCount = text.unicodeScalars.count
        // Lines cover the text with no gap beyond the spaces a break swallows.
        XCTAssertEqual(shaped.lines.first?.range.lowerBound, 0)
        XCTAssertLessThanOrEqual(shaped.lines.last?.range.upperBound ?? 0, scalarCount)
        let clusters = Set([0] + GraphemeClusters.boundaries(text.unicodeScalars.map(\.value)))
        for line in shaped.lines {
            XCTAssertTrue(clusters.contains(line.range.lowerBound), "line starts inside a cluster at \(line.range)")
        }
        let breaks = TextLineBreaks.breaks(of: shaped, content: content(text))
        XCTAssertTrue(breaks.allSatisfy(clusters.contains), "\(breaks)")
    }
}
