import Foundation
import TempDirSupport
import XCTest

/// The `webdav` job (`scripts/test-webdav.sh`) runs the tests whose identifier (`Target.Class/testName`) contains
/// `Wsgidav`, and nothing else, so a test that needs the wsgidav server (or the fault proxy in front of it) must carry
/// the word in its class name or its own name: a test without it skips everywhere, quietly. This reads the test
/// sources of the two targets that have such tests and fails for each one that reaches the server without the name,
/// so a new server test cannot be left out of the job by forgetting a regex. (The tests that also need the seeded
/// vault of `scripts/sync-stress.sh`, `SEMPERE_STRESS_VAULT`, are that script's, which lists them by name.)
final class WebDAVJobSelectionTests: TempDirTestCase {
    /// What reaches the server: the environment variables the job sets, the proxy's constructor, and the transport.
    static let markers = ["SEMPERE_WEBDAV_TEST_URL", "SEMPERE_WEBDAV_PROXY_URL", "FaultProxy.fromEnvironment", ".wsgidav(", "(.wsgidav)"]

    /// `text` with the inside of string literals and comments blanked (same length, so offsets agree), so braces in
    /// them do not count.
    static func masked(_ text: String) -> [Character] {
        var out: [Character] = []
        let c = Array(text)
        var i = 0
        func blank(_ ch: Character) -> Character { ch == "\n" ? "\n" : " " }
        while i < c.count {
            if c[i] == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { out.append(" "); i += 1 }
            } else if c[i] == "\"", i + 2 < c.count, c[i + 1] == "\"", c[i + 2] == "\"" {
                out += ["\"", "\"", "\""]; i += 3
                while i < c.count, !(c[i] == "\"" && i + 2 < c.count && c[i + 1] == "\"" && c[i + 2] == "\"") { out.append(blank(c[i])); i += 1 }
                if i < c.count { out += ["\"", "\"", "\""]; i += 3 }
            } else if c[i] == "\"" {
                out.append("\""); i += 1
                while i < c.count, c[i] != "\"", c[i] != "\n" {
                    if c[i] == "\\", i + 1 < c.count { out += [" ", " "]; i += 2 } else { out.append(" "); i += 1 }
                }
                if i < c.count, c[i] == "\"" { out.append("\""); i += 1 }
            } else {
                out.append(c[i]); i += 1
            }
        }
        return out
    }

    /// The range of the brace-delimited block opened at or after `start` in `code`.
    static func block(in code: [Character], from start: Int) -> Range<Int>? {
        var i = start
        while i < code.count, code[i] != "{" { i += 1 }
        guard i < code.count else { return nil }
        var depth = 0
        for j in i..<code.count {
            if code[j] == "{" { depth += 1 }
            if code[j] == "}" { depth -= 1; if depth == 0 { return start..<(j + 1) } }
        }
        return nil
    }

    static func offenders(inFile url: URL) throws -> [String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let raw = Array(source)
        let code = masked(source)
        let text = String(code)
        var out: [String] = []
        let classes = try NSRegularExpression(pattern: #"(?m)^(?:final )?class (\w+)"#)
        let funcs = try NSRegularExpression(pattern: #"func (test\w+)\s*\("#)
        let setUps = try NSRegularExpression(pattern: #"func setUp\w*\s*\("#)
        func offset(_ r: NSRange) -> Int { text.distance(from: text.startIndex, to: Range(r, in: text)!.lowerBound) }
        func reaches(_ range: Range<Int>) -> Bool {
            let body = String(raw[range])
            // The stress run needs the seeded vault `scripts/sync-stress.sh` builds, which names these tests itself.
            if body.contains("SEMPERE_STRESS_VAULT") { return false }
            return markers.contains { body.contains($0) }
        }
        for m in classes.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(m.range(at: 1), in: text)!])
            guard let body = block(in: code, from: offset(m.range)) else { continue }
            let chunk = String(code[body])
            let inChunk = NSRange(chunk.startIndex..., in: chunk)
            func chunkOffset(_ r: NSRange) -> Int { body.lowerBound + chunk.distance(from: chunk.startIndex, to: Range(r, in: chunk)!.lowerBound) }
            // A setUp that reaches the server makes every test of the class a server test.
            var classWide = false
            for s in setUps.matches(in: chunk, range: inChunk) {
                if let sb = block(in: code, from: chunkOffset(s.range)), reaches(sb) { classWide = true }
            }
            for f in funcs.matches(in: chunk, range: inChunk) {
                let fname = String(chunk[Range(f.range(at: 1), in: chunk)!])
                guard let fb = block(in: code, from: chunkOffset(f.range)) else { continue }
                if (classWide || reaches(fb)), !(name + "/" + fname).contains("Wsgidav") {
                    out.append("\(url.lastPathComponent): \(name)/\(fname)")
                }
            }
        }
        return out
    }

    func testEveryServerTestIsNamedForTheWebDAVJob() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var seen = 0
        for target in ["SempereWebDAVTests", "CLITests"] {
            let dir = tests.appendingPathComponent(target)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where file.hasSuffix(".swift") {
                if file == "WebDAVJobSelectionTests.swift" { continue }
                let found = try Self.offenders(inFile: dir.appendingPathComponent(file))
                offenders += found
                if let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
                   text.contains("Wsgidav") { seen += 1 }
            }
        }
        XCTAssertGreaterThan(seen, 3, "the scan reads the sources (and sees the tests already named for the job)")
        XCTAssertTrue(offenders.isEmpty, """
            these tests reach the wsgidav server but would never run in the `webdav` job (scripts/test-webdav.sh selects \
            identifiers containing "Wsgidav"): put the word in the class or test name\n\(offenders.joined(separator: "\n"))
            """)
    }

    /// The scan finds an unnamed server test, and leaves alone one that carries the word.
    func testTheScanSeesAServerTestWithoutTheName() throws {
        let file = tmp.appendingPathComponent("Sample.swift")
        try """
            final class PlainTests: XCTestCase {
                func testNeedsTheServer() throws { let u = env["SEMPERE_WEBDAV_TEST_URL"]; _ = "{" }
                func testDoesNot() throws { XCTAssertTrue(true) }
            }
            final class OtherTests: XCTestCase {
                override func setUpWithError() throws { _ = try FaultProxy.fromEnvironment() }
                func testAny() throws {}
                func testAgainstWsgidavServer() throws {}
            }
            """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.offenders(inFile: file), ["Sample.swift: PlainTests/testNeedsTheServer", "Sample.swift: OtherTests/testAny"])
    }
}
