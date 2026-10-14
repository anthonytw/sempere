import CLITestSupport
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Sempere
import XCTest

final class CLIExportTreeTests: CLITestCase {
    var keyPath = ""
    var vaultPath = ""
    var vault: Vault!
    var seq = 10
    let device = DeviceID("abcdef02")!

    func add(_ id: String, _ ops: [Op]) throws {
        seq += 1
        let hlc = HLC(millis: 1_760_000_100_000 + Int64(seq) * 1000, counter: 0)!
        try vault.write(Revision(noteId: UUID(uuidString: id)!, device: device, seq: seq, hlc: hlc,
                                 wall: Date(timeIntervalSince1970: Double(hlc.millis) / 1000), app: "t/1",
                                 body: .delta(ops: ops)))
    }

    /// Notes: two titled "Same" (one in A/B, one in a/b with different case), an awkward title in "School/Math",
    /// one with recognition in no notebook, and one deleted.
    override func setUpWithError() throws {
        try super.setUpWithError()
        let (v, _, key) = try makeVault()
        vault = v
        keyPath = key
        vaultPath = path("mine.sempere")
        func page(_ text: String?) -> (UUID, [Op]) {
            let p = UUID()
            var ops: [Op] = [.addPage(Page(id: p, order: "a0")),
                             .addStroke(page: p, stroke: Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                                                                points: [StrokePoint(x: 10, y: 10, w: 2, h: 2),
                                                                         StrokePoint(x: 80, y: 60, w: 2, h: 2)]))]
            if let text {
                ops.append(.setPageRecognition(pageId: p, recognition: Recognition(
                    engine: "test-1", text: text, words: [.init(text: "kangaroo", box: .init(x: 10, y: 10, w: 60, h: 14))])))
            }
            return (p, ops)
        }
        try add("cccccccc-3333-4333-8333-000000000003",
                page("kangaroo jumps").1 + [.setMeta(.title("Same")), .setMeta(.notebook("A/B")), .addTag("x")])
        try add("dddddddd-4444-4444-8444-000000000004",
                page(nil).1 + [.setMeta(.title("Same")), .setMeta(.notebook("a / b"))])
        try add("eeeeeeee-5555-4555-8555-000000000005",
                page("wombat").1 + [.setMeta(.title("Plan: \"Q3\"\nnotes ☃")), .setMeta(.notebook("School/Math")),
                                    .addTag("has space"), .addTag("ünï")])
        try add("ffffffff-6666-4666-8666-000000000006", page(nil).1 + [.setMeta(.title("Gone"))])
        try add("ffffffff-6666-4666-8666-000000000006", [.deleteNote])
    }

    func export(_ extra: [String], out: String) throws -> CLIResult {
        try cli(["export"] + extra + ["--out", out, "--vault", vaultPath, "--identity", keyPath])
    }

    func read(_ rel: String, in dir: String) throws -> String {
        try String(contentsOfFile: dir + "/" + rel, encoding: .utf8)
    }

    func files(_ dir: String) -> [String] {
        let all = FileManager.default.enumerator(atPath: dir)?.allObjects as? [String] ?? []
        return all.filter { !$0.hasPrefix(".") && !$0.hasSuffix("/.") }.sorted()
    }

    func testMarkdownHierarchyFrontMatterAndRecognition() throws {
        let out = path("md")
        let r = try export(["--all", "--format", "markdown", "--images", "png", "--dpi", "36"], out: out)
        XCTAssertEqual(r.status, 0, r.err)
        let f = files(out)
        // Hierarchy: case variants of A/B share one folder; the two "Same" notes cannot collide.
        XCTAssertTrue(f.contains("A/B/Same-cccccccc.md") && f.contains("A/B/Same-dddddddd.md"), "\(f)")
        XCTAssertTrue(f.contains("A/B/Same-cccccccc.pdf") && f.contains("A/B/Same-cccccccc-assets/p001.png"), "\(f)")
        XCTAssertTrue(f.contains("A/README.md") && f.contains("A/B/README.md") && f.contains("README.md"), "\(f)")
        XCTAssertTrue(f.contains("School/Math/Plan-Q3-notes-☃-eeeeeeee.md"), "\(f)")
        XCTAssertTrue(f.contains("Groceries-bbbbbbbb.md") && f.contains("Physics-Week-3-aaaaaaaa.md"), "\(f)")
        XCTAssertFalse(f.contains { $0.contains("Gone") }, "deleted notes are skipped: \(f)")
        XCTAssertFalse(f.contains("a"), "no case-variant folder: \(f)")

        let md = try read("School/Math/Plan-Q3-notes-☃-eeeeeeee.md", in: out)
        XCTAssertTrue(md.contains("title: \"Plan: \\\"Q3\\\"\\nnotes ☃\"\n"), md)
        XCTAssertTrue(md.contains("notebook: \"School/Math\"\n") && md.contains("  - \"has-space\"\n  - \"ünï\"\n"), md)
        XCTAssertTrue(md.contains("![[Plan-Q3-notes-☃-eeeeeeee.pdf]]"), md)
        XCTAssertTrue(md.contains("![Page 1](Plan-Q3-notes-%E2%98%83-eeeeeeee-assets/p001.png)"), md)
        XCTAssertTrue(md.contains("Machine-recognized text") && md.contains("wombat"), md)
        let pdf = try Data(contentsOf: URL(fileURLWithPath: out + "/School/Math/Plan-Q3-notes-☃-eeeeeeee.pdf"))
        XCTAssertEqual(String(decoding: pdf.prefix(5), as: UTF8.self), "%PDF-")
        let png = try Data(contentsOf: URL(fileURLWithPath: out + "/A/B/Same-cccccccc-assets/p001.png"))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        let readme = try read("A/B/README.md", in: out)
        XCTAssertTrue(readme.contains("Same-cccccccc.md") && readme.contains("Same-dddddddd.md"), readme)
        let root = try read("README.md", in: out)
        XCTAssertTrue(root.contains("[A](A/README.md)") && root.contains("[School](School/README.md)")
                      && root.contains("Groceries-bbbbbbbb.md"), root)
        XCTAssertTrue(try read("A/README.md", in: out).contains("[B](B/README.md)"))
    }

    func testMarkdownWithoutImagesAndNotebookFilter() throws {
        let out = path("md")
        let r = try export(["--all", "--format", "markdown", "--notebook", "A"], out: out)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(files(out), ["A", "A/B", "A/B/README.md", "A/B/Same-cccccccc.md", "A/B/Same-cccccccc.pdf",
                                    "A/README.md", "README.md"])
        // Notebook names are case-sensitive: "a / b" is a different notebook, so the filter skips it.
        let md = try read("A/B/Same-cccccccc.md", in: out)
        XCTAssertFalse(md.contains(".png"), md)
        XCTAssertTrue(md.contains("kangaroo jumps"), md)
        // Single note.
        let one = path("one")
        XCTAssertEqual(try export(["Groceries", "--format", "markdown"], out: one).status, 0)
        XCTAssertEqual(files(one), ["Groceries-bbbbbbbb.md", "Groceries-bbbbbbbb.pdf", "README.md"])
    }

    func testIdempotentAndClean() throws {
        let out = path("md")
        let args = ["--all", "--format", "markdown"]
        XCTAssertEqual(try export(args, out: out).status, 0)
        func stamps() throws -> [String: Date] {
            Dictionary(uniqueKeysWithValues: try files(out).compactMap { rel -> (String, Date)? in
                let a = try FileManager.default.attributesOfItem(atPath: out + "/" + rel)
                guard a[.type] as? FileAttributeType == .typeRegular, let d = a[.modificationDate] as? Date else { return nil }
                return (rel, d)
            })
        }
        let before = try stamps()
        Thread.sleep(forTimeInterval: 1.1)
        let again = try export(args, out: out)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertEqual(try stamps(), before, "an unchanged re-export rewrites nothing")
        XCTAssertFalse(again.out.contains("Wrote "), again.out)
        XCTAssertTrue(again.out.contains("0 file(s) written"), again.out)

        // Rename a note: the new stem appears, the old files stay until --clean.
        try add("bbbbbbbb-2222-4222-8222-000000000002", [.setMeta(.title("Shopping"))])
        XCTAssertEqual(try export(args, out: out).status, 0)
        XCTAssertTrue(files(out).contains("Shopping-bbbbbbbb.md") && files(out).contains("Groceries-bbbbbbbb.md"))
        XCTAssertEqual(try export(args + ["--clean"], out: out).status, 0)
        XCTAssertFalse(files(out).contains("Groceries-bbbbbbbb.md") || files(out).contains("Groceries-bbbbbbbb.pdf"), "\(files(out))")
        XCTAssertTrue(files(out).contains("Shopping-bbbbbbbb.md"))
        XCTAssertTrue(try read("README.md", in: out).contains("Shopping-bbbbbbbb.md"))
        XCTAssertFalse(try read("README.md", in: out).contains("Groceries-bbbbbbbb.md"))
    }

    /// A re-run reads and renders only what changed: a new revision rewrites that note's files,
    /// other options rewrite all, and `--clean` keeps the files of notes it did not render.
    func testReRunRendersOnlyChangedNotes() throws {
        for format in ["markdown", "html"] {
            let out = path("rerun-" + format)
            let args = ["--all", "--format", format, "--clean"]
            let first = try export(args, out: out)
            XCTAssertEqual(first.status, 0, first.err)
            let total = try XCTUnwrap(first.out.components(separatedBy: " file(s) written").first?.split(separator: " ").last.flatMap { Int($0) })
            XCTAssertGreaterThan(total, 0)
            let none = try export(args, out: out)
            XCTAssertTrue(none.out.contains("0 file(s) written"), none.out)
            let filesBefore = files(out)

            let p = UUID()
            try add("bbbbbbbb-2222-4222-8222-000000000002",
                    [.addPage(Page(id: p, order: "a1")),
                     .addStroke(page: p, stroke: Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                                                        points: [StrokePoint(x: 1, y: 1, w: 2, h: 2), StrokePoint(x: 40, y: 30, w: 2, h: 2)]))])
            let changed = try export(args + ["--json"], out: out)
            XCTAssertEqual(changed.status, 0, changed.err)
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(changed.out.utf8)) as? [[String: Any]])
            let rewritten = rows.filter { !(($0["changed"] as? [String]) ?? []).isEmpty }.compactMap { $0["note"] as? String }
            XCTAssertEqual(rewritten, ["bbbbbbbb-2222-4222-8222-000000000002"], "only the edited note's files changed")
            XCTAssertEqual(rows.count, 5, "skipped notes are still listed")
            XCTAssertEqual(files(out), filesBefore, "--clean kept every skipped note's files")

            let paper = try export(args + ["--no-paper"], out: out)
            XCTAssertFalse(paper.out.contains("0 file(s) written"), "other options render again: \(paper.out)")
        }
    }

    func testCleanRemovesEmptiedFoldersAndKeepsForeignFiles() throws {
        let out = path("md")
        XCTAssertEqual(try export(["--all", "--format", "markdown"], out: out).status, 0)
        try "mine".write(toFile: out + "/School/keep.txt", atomically: true, encoding: .utf8)
        // Exporting only notebook A with --clean leaves School alone (out of scope).
        XCTAssertEqual(try export(["--all", "--format", "markdown", "--notebook", "A", "--clean"], out: out).status, 0)
        XCTAssertTrue(files(out).contains("School/Math/Plan-Q3-notes-☃-eeeeeeee.md"))
        // Delete the note: clean removes it and the emptied Math folder, not the foreign file.
        try add("eeeeeeee-5555-4555-8555-000000000005", [.deleteNote])
        let r = try export(["--all", "--format", "markdown", "--clean"], out: out)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertFalse(files(out).contains("School/Math/Plan-Q3-notes-☃-eeeeeeee.md"))
        XCTAssertFalse(files(out).contains("School/Math"), "\(files(out))")
        XCTAssertTrue(files(out).contains("School/keep.txt"))
    }

    func testHTMLExport() throws {
        let out = path("html")
        let r = try export(["--all", "--format", "html"], out: out)
        XCTAssertEqual(r.status, 0, r.err)
        let f = files(out)
        XCTAssertTrue(f.contains("index.html") && f.contains("A/B/Same-cccccccc.html")
                      && f.contains("School/Math/Plan-Q3-notes-☃-eeeeeeee.html"), "\(f)")
        for rel in f where rel.hasSuffix(".html") {
            let html = try read(rel, in: out)
            let d = TextExportParse.parse(html, rel)
            TextExportParse.assertSelfContained(html, d, rel)
        }
        let note = try read("A/B/Same-cccccccc.html", in: out)
        XCTAssertTrue(note.contains("kangaroo") && note.contains("href=\"../../index.html\""), note)
        let index = try read("index.html", in: out)
        XCTAssertTrue(index.contains("kangaroo jumps") && index.contains("wombat"), "search text is in the index")
        XCTAssertTrue(index.contains("href=\"School/Math/Plan-Q3-notes-%E2%98%83-eeeeeeee.html\""), index)
        XCTAssertFalse(index.contains("Gone"))
        // Idempotent.
        let again = try export(["--all", "--format", "html"], out: out)
        XCTAssertTrue(again.out.contains("0 file(s) written"), again.out)
    }

    // MARK: - Review regressions

    /// Every file a tree export wrote, as absolute paths (the manifest included).
    func allFiles(under dir: String) -> [String] {
        (FileManager.default.enumerator(atPath: dir)?.allObjects as? [String] ?? []).map { dir + "/" + $0 }
    }

    /// Hostile titles and notebooks never leave the output folder, never make a
    /// name the file system refuses, and never collide with the index files.
    func testHostileNamesStayInsideTheOutputFolderAndExportCleanly() throws {
        let zalgo = "e" + String(repeating: "\u{0301}", count: 300)    // one Character, 600+ bytes
        let hostile: [(String, String)] = [
            ("../../escape", "../../etc"), ("..", ".."), (".", "."), ("/abs/olute", "/abs//x"),
            ("CON", "NUL/aux"), (String(repeating: "🙂", count: 60), "Folder"), (zalgo, zalgo),
            ("README.md", "README.md"), ("index.html", "index.html"), ("a\u{0}b\u{202E}c", "d\\e:f"),
        ]
        for (i, (title, notebook)) in hostile.enumerated() {
            let id = String(format: "a%07x-%04d-4000-8000-0000000000%02d", i, 7000 + i, i)
            try add(id, [.setMeta(.title(title)), .setMeta(.notebook(notebook))])
        }
        for format in ["markdown", "html"] {
            let parent = path("parent-" + format)
            let out = parent + "/out"
            let r = try export(["--all", "--format", format] + (format == "markdown" ? ["--images", "png", "--dpi", "20"] : []),
                               out: out)
            XCTAssertEqual(r.status, 0, "\(format): \(r.err)")
            XCTAssertFalse(r.err.contains("error"), r.err)
            // Nothing outside `out`, nothing hidden but the manifest.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent), ["out"])
            for f in allFiles(under: out) {
                let rel = String(f.dropFirst(out.count + 1))
                XCTAssertFalse(rel.split(separator: "/").contains { $0 == ".." || $0 == "." }, rel)
                XCTAssertTrue(rel.split(separator: "/").allSatisfy { $0.utf8.count <= 200 }, rel)
                let name = rel.split(separator: "/").last.map(String.init) ?? ""
                XCTAssertTrue(!name.hasPrefix(".") || name == ".sempere-export-\(format).json", rel)
            }
            // The index files are files, and every notebook named like one is a folder with a different name.
            var isDir: ObjCBool = false
            let index = format == "markdown" ? "README.md" : "index.html"
            XCTAssertTrue(FileManager.default.fileExists(atPath: out + "/" + index, isDirectory: &isDir) && !isDir.boolValue)
            // And a second run changes nothing.
            let again = try export(["--all", "--format", format] + (format == "markdown" ? ["--images", "png", "--dpi", "20"] : []), out: out)
            XCTAssertEqual(again.status, 0, again.err)
            XCTAssertTrue(again.out.contains("0 file(s) written"), again.out)
        }
    }

    /// `--clean` and the folder indexes trust `.sempere-export-*.json`, a file in a
    /// folder that may be shared: a doctored one cannot write or delete outside it.
    func testDoctoredExportManifestCannotEscapeTheOutputFolder() throws {
        let parent = path("parent")
        let out = parent + "/out"
        XCTAssertEqual(try export(["--all", "--format", "markdown"], out: out).status, 0)
        let manifestPath = out + "/.sempere-export-markdown.json"
        func doctor(files extra: [String], note: Bool) throws {
            var m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath))) as? [String: Any])
            var files = m["files"] as? [String: Any] ?? [:]
            for f in extra { files[f] = ["note": NSNull()] }
            m["files"] = files
            if note {
                var notes = m["notes"] as? [String: Any] ?? [:]
                notes["99999999-0000-4000-8000-000000000000"] = ["title": "x", "stem": "../../stem", "folder": ["..", "evil"],
                                                                 "tags": [], "pages": 1]
                m["notes"] = notes
            }
            try JSONSerialization.data(withJSONObject: m).write(to: URL(fileURLWithPath: manifestPath))
        }
        // The folder indexes write where a doctored note says it lives.
        try doctor(files: [], note: true)
        var r = try export(["--all", "--format", "markdown"], out: out)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent).sorted(), ["out"], "nothing written outside out")
        XCTAssertFalse(try read("README.md", in: out).contains("stem"), "the doctored note is dropped")
        // --clean deletes what the manifest lists.
        let victim = parent + "/victim.txt"
        try "keep".write(toFile: victim, atomically: true, encoding: .utf8)
        try doctor(files: ["../victim.txt", "a/../../victim.txt", "x/./../../victim.txt", victim], note: false)
        r = try export(["--all", "--format", "markdown", "--clean"], out: out)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent).sorted(), ["out", "victim.txt"])
    }

    /// The export folder may be synced or shared (format.md §9): a manifest
    /// with a hostile date or one that is a FIFO is ignored, never read with
    /// Foundation's ISO 8601 parser (which dies in ICU on a long fraction on
    /// Linux) or blocked on.
    func testHostileExportManifestIsIgnored() throws {
        let out = path("md")
        let args = ["--all", "--format", "markdown"]
        XCTAssertEqual(try export(args, out: out).status, 0)
        let manifestPath = out + "/.sempere-export-markdown.json"
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
                              as? [String: Any])
        var notes = m["notes"] as? [String: Any] ?? [:]
        notes["99999999-0000-4000-8000-000000000000"] = [
            "title": "x", "stem": "x", "folder": [], "tags": [], "pages": 1,
            "modified": "2025-10-09T14:03:20." + String(repeating: "1", count: 100_000) + "Z"]
        m["notes"] = notes
        try JSONSerialization.data(withJSONObject: m).write(to: URL(fileURLWithPath: manifestPath))
        var r = try export(args, out: out)
        XCTAssertEqual(r.status, 0, r.err)

        try FileManager.default.removeItem(atPath: manifestPath)
        XCTAssertEqual(mkfifo(manifestPath, 0o600), 0)
        let t0 = Date()
        r = try export(args, out: out)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 60)
    }

    func testOptionValidation() throws {
        let out = path("x")
        XCTAssertEqual(try export(["--all", "--format", "pdf", "--clean"], out: out).status, 2)
        XCTAssertEqual(try export(["Groceries", "--format", "markdown", "--clean"], out: out).status, 2)
        XCTAssertEqual(try export(["--all", "--format", "html", "--images", "png"], out: out).status, 2)
        XCTAssertEqual(try export(["Groceries", "--format", "html", "--notebook", "A"], out: out).status, 2)
        XCTAssertEqual(try export(["--all", "--format", "markdown", "--notebook", "Nope"], out: out).status, 1)
    }
}

/// XML parse helpers shared by the HTML tests.
enum TextExportParse {
    final class Delegate: NSObject, XMLParserDelegate {
        var attrs: [(String, String)] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            for (k, v) in a { attrs.append((k, v)) }
        }
    }

    static func parse(_ html: String, _ name: String) -> Delegate {
        let p = XMLParser(data: Data(html.utf8))
        let d = Delegate()
        p.delegate = d
        XCTAssertTrue(p.parse(), "\(name) is not well-formed: \(String(describing: p.parserError))")
        return d
    }

    static func assertSelfContained(_ html: String, _ d: Delegate, _ name: String) {
        XCTAssertFalse(html.contains("http://") || html.contains("https://"), "\(name): external URL")
        XCTAssertFalse(html.contains("<link") || html.contains("<img") || html.contains("url("), name)
        for (k, v) in d.attrs where ["src", "href", "xlink:href"].contains(k) {
            XCTAssertFalse(v.contains("://") || v.hasPrefix("//"), "\(name): \(k)=\(v)")
        }
    }
}
