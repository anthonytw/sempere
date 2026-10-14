import Foundation
import ImportTestSupport
import XCTest
@testable import SempereImport

/// The strict XML plist reader (`XMLPlist`).
final class XMLPlistTests: XCTestCase {
    func testEveryValueType() throws {
        let xml = #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- a comment -->
            <plist version="1.0"><dict>
              <key>a</key><array><integer> -4 </integer><real>1.5</real><true/><false/><string/></array>
              <key>d</key><date>2026-10-05T12:00:00Z</date>
              <key>b</key><data>AA EC</data>
              <key>s</key><string>&lt;&gt;&amp;&quot;&apos;&#65;&#x42;é</string>
            </dict></plist>
            """#
        guard case .dict(let d) = try PlistValue.parse(Data(xml.utf8), allowXML: true) else { return XCTFail() }
        XCTAssertEqual(d["a"], .array([.int(-4), .real(1.5), .bool(true), .bool(false), .string("")]))
        XCTAssertEqual(d["d"], .date(Date(timeIntervalSince1970: 1_791_201_600)))
        XCTAssertEqual(d["b"], .data(Data([0, 1, 2])))
        XCTAssertEqual(d["s"], .string("<>&\"'ABé"))
    }

    func testRefusesWhatItShouldNotExpandOrFetch() {
        let hostile = [
            // An internal DTD subset (entity definitions, "billion laughs").
            #"<?xml version="1.0"?><!DOCTYPE plist [<!ENTITY a "aaaa">]><plist><string>&a;</string></plist>"#,
            // An undefined or external entity reference.
            #"<plist><string>&ext;</string></plist>"#,
            #"<plist><string><![CDATA[x]]></string></plist>"#,
            #"<plist><unknown/></plist>"#,
            #"<plist><dict><string>no key</string></dict></plist>"#,
            #"<plist><integer>1e9</integer></plist>"#,
            #"<plist><true>x</true></plist>"#,
            #"<plist><string>a</string></plist><string>b</string>"#,
            #"<plist><array><string>open"#,
            String(repeating: "<array>", count: 100) + String(repeating: "</array>", count: 100),
        ]
        for text in hostile {
            XCTAssertThrowsError(try PlistValue.parse(Data(text.utf8), allowXML: true), text.prefix(60).description)
        }
        XCTAssertThrowsError(try PlistValue.parse(Data(repeating: 0x20, count: XMLPlist.maxBytes + 1), allowXML: true))
        XCTAssertThrowsError(try PlistValue.parse(Data("{ a = 1; }".utf8), allowXML: true))   // OpenStep
    }
}

extension XMLPlistTests {
    /// Keyed archives stay binary-only: XML is accepted only where asked for.
    func testXMLIsOptIn() {
        XCTAssertThrowsError(try PlistValue.parse(Data(#"<?xml version="1.0"?><plist><dict/></plist>"#.utf8)))
    }
}
