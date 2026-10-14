import Foundation
import FuzzSupport
import ImportTestSupport
import XCTest

@testable import SempereImport

/// Seeded mutation fuzzing of the generic readers every importer builds on: the zip reader (bombs,
/// overlapping entries, bad CRCs, ZIP64 fields), binary plists and keyed archives (cyclic UIDs, deep
/// nesting, huge counts) and XML plists. Each importer fuzzes its own formats too (`SempereNotabilityTests`).
final class ImportFuzzTests: XCTestCase {
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is ImportError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    func testFuzzZip() throws {
        let files: [TestZip.File] = [
            .init(path: "a/", data: Data(), deflate: false),
            .init(path: "a/one.txt", data: Data(repeating: 0x41, count: 5000)),
            .init(path: "a/two.bin", data: Data((0..<300).map { UInt8($0 & 0xFF) }), deflate: false),
            .init(path: "../escape", data: Data("x".utf8)),
        ]
        let seeds = [TestZip.write(files), TestZip.write(files, zip64: true)]
        assertClean(Fuzz.run("zip-generic", seeds: seeds, quick: 2500, maxSize: 512 << 10) { input in
            Self.typed {
                let zip = try ZipArchive(data: input)
                for e in zip.entries.prefix(64) { _ = try? zip.read(e, maxSize: 16 << 20) }
            }
        })
    }

    func testFuzzKeyedArchives() throws {
        var b = KeyedArchiveBuilder()
        let inner = b.object("Thing", [("count", .int(3)), ("label", b.string("hi"))])
        let root = b.dict([("name", b.string("Ünïcode ✓")), ("list", b.array([b.string("a"), .int(2), inner])),
                           ("when", b.date(Date(timeIntervalSinceReferenceDate: 678_741_683.5))), ("blob", b.data(Data([1, 2, 3])))])
        let seeds = [b.archive(top: [("root", root)]), BPlist.encode(.dict([("a", .array([.int(1), .real(2.5), .bool(true)]))]))]
        assertClean(Fuzz.run("bplist-generic", seeds: seeds, quick: 2000, maxSize: 256 << 10) { input in
            Self.typed {
                let a = try KeyedArchive(data: input)
                for key in a.top.keys {
                    func walk(_ n: KeyedArchive.Node, _ depth: Int) throws {
                        guard depth < 6 else { return }
                        switch n {
                        case .object(_, let fields): for k in fields.keys.sorted().prefix(32) { try walk(a.field(n, k), depth + 1) }
                        case .dict(let d): for k in d.keys.sorted().prefix(32) { try walk(a.field(n, k), depth + 1) }
                        case .array: for e in try a.elements(n).prefix(32) { try walk(e, depth + 1) }
                        default: break
                        }
                    }
                    try walk(a.root(key), 0)
                }
            }
        })
    }

    func testFuzzXMLPlists() throws {
        let seeds = [Data(#"<plist><array><integer>-4</integer><real>1.5</real><true/><date>2026-10-05T12:00:00Z</date><data>AAEC</data><string>&lt;&#x41;&amp;</string></array></plist>"#.utf8),
                     Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>k</key><dict/></dict></plist>"#.utf8)]
        assertClean(Fuzz.run("xmlplist-generic", seeds: seeds, quick: 2000, maxSize: 64 << 10) { input in
            Self.typed { _ = try PlistValue.parse(input, allowXML: true) }
        })
    }
}
