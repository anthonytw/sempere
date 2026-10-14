import Foundation
import ImportTestSupport
import XCTest
@testable import SempereImport

final class KeyedArchiveTests: XCTestCase {
    /// A binary archive with real UID objects (marker 0x8n), read as `.uid(n)`.
    func testBinaryArchiveResolvesUIDs() throws {
        var b = KeyedArchiveBuilder()
        let when = Date(timeIntervalSinceReferenceDate: 678_741_683.5)
        let inner = b.object("Thing", [("count", .int(3)), ("label", b.string("hi"))])
        let root = b.dict([
            ("name", b.string("Ünïcode ✓")),
            ("bytesName", b.object("NSMutableString", [("NS.bytes", .data(Data("from bytes".utf8)))])),
            ("when", b.date(when)),
            ("list", b.array([b.string("a"), .int(2), inner])),
            ("blob", b.data(Data([1, 2, 3]))),
            ("flag", .bool(true)),
            ("ratio", .real(0.25)),
            ("nothing", .uid(0)),
        ])
        let archive = try KeyedArchive(data: b.archive(top: [("root", root)]))
        let r = try archive.root("root")
        XCTAssertEqual(try archive.field(r, "name").string, "Ünïcode ✓")
        XCTAssertEqual(try archive.field(r, "bytesName").string, "from bytes")
        XCTAssertEqual(try archive.field(r, "when").date, when)
        XCTAssertEqual(try archive.field(r, "blob").data, Data([1, 2, 3]))
        XCTAssertEqual(try archive.field(r, "flag").int, 1)
        XCTAssertEqual(try archive.field(r, "ratio").double, 0.25)
        XCTAssertTrue(try archive.field(r, "nothing").isNull)
        XCTAssertTrue(try archive.field(r, "absent").isNull)
        let list = try archive.elements(archive.field(r, "list"))
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].string, "a")
        XCTAssertEqual(list[1].int, 2)
        XCTAssertEqual(list[2].className, "Thing")
        XCTAssertEqual(try archive.field(list[2], "count").int, 3)
        XCTAssertEqual(try archive.field(list[2], "label").string, "hi")
    }

    /// XML plists (UIDs spelled `{"CF$UID": n}`) are refused: the importer
    /// reads binary plists only, with its own reader, since Notability writes
    /// nothing else and PropertyListSerialization is not safe on hostile input.
    func testXMLArchiveIsRefused() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>$top</key><dict><key>$0</key><dict><key>CF$UID</key><integer>1</integer></dict></dict>
          <key>$objects</key><array>
            <string>$null</string>
            <dict><key>title</key><dict><key>CF$UID</key><integer>2</integer></dict>
                  <key>$class</key><dict><key>CF$UID</key><integer>3</integer></dict></dict>
            <string>Hello</string>
            <dict><key>$classname</key><string>Session</string></dict>
          </array>
        </dict></plist>
        """
        XCTAssertThrowsError(try KeyedArchive(data: Data(xml.utf8))) { e in
            guard case ImportError.archive? = e as? ImportError else { return XCTFail("\(e)") }
        }
    }

    func testUIDConversionBothShapes() throws {
        XCTAssertEqual(try PlistValue(any: ["CF$UID": 7]), .uid(7))
        XCTAssertEqual(try PlistValue(any: ["CF$UID": NSNumber(value: 9)]), .uid(9))
        // A two-key dictionary is just a dictionary.
        XCTAssertEqual(try PlistValue(any: ["CF$UID": 7, "x": 1]), .dict(["CF$UID": .int(7), "x": .int(1)]))
    }

    func testMalformedArchivesThrow() throws {
        var b = KeyedArchiveBuilder()
        let root = b.object("Thing", [("dangling", .uid(99))])
        let archive = try KeyedArchive(data: b.archive(top: [("root", root)]))
        XCTAssertThrowsError(try archive.field(archive.root("root"), "dangling"))
        XCTAssertThrowsError(try archive.root("missing"))
        XCTAssertThrowsError(try KeyedArchive(data: BPlist.encode(.array([]))))
        XCTAssertThrowsError(try KeyedArchive(data: Data("garbage".utf8)))
        // A self-referencing chain stops instead of recursing forever.
        var c = KeyedArchiveBuilder()
        c.objects.append(.uid(1))
        let loop = try KeyedArchive(data: c.archive(top: [("root", .uid(1))]))
        XCTAssertThrowsError(try loop.root("root"))
    }
}
