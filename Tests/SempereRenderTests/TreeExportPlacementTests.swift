import FuzzSupport
import TempDirSupport
import XCTest
import Foundation
import Sempere
@testable import SempereRender

/// An export folder may be shared: `TreeExporter` works relative to the folder, never through a link
/// below it, and keeps what it writes private.
final class TreeExportPlacementTests: XCTestCase {
    func note(_ title: String, n: Int = 1) -> (NoteSummary, NoteState) {
        let s = NoteSummary(id: UUID(uuidString: String(format: "0d1c6a1e-0000-4000-8000-%012d", n))!, title: title, tags: [],
                            notebook: nil, deleted: false, pages: 1, strokes: 1, modified: Date(timeIntervalSince1970: 1_760_000_000), problem: nil)
        let st = T.note(pages: [[T.stroke([T.pt(10, 10), T.pt(80, 50)])]], meta: T.meta(title: title))
        return (s, st)
    }

    func folders() throws -> (out: URL, outside: URL) {
        let base = try makeScratch("treeplace")
        let out = base.appendingPathComponent("out"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (out, outside)
    }

    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    func testCleanLeavesFilesBehindALinkedFolder() throws {
        let (out, outside) = try folders()
        let kept = outside.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: kept)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("link"), withDestinationURL: outside)
        let entry = #"{"size":4,"sha256":"\#(FileDigest.sha256(Data("mine".utf8)))"}"#
        try Data(#"{"version":1,"files":{"link/keep.txt":\#(entry)},"notes":{}}"#.utf8)
            .write(to: out.appendingPathComponent(".sempere-export-markdown.json"))
        let t = TreeExporter(root: out, format: .markdown, source: "test", clean: true)
        let r = try t.run([note("A")], protected: [], vaultSource: "test:1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(r.errors.contains { $0.contains("link/keep.txt") }, "\(r.errors)")
    }

    func testIndexIsNotWrittenThroughALinkedFolder() throws {
        let (out, outside) = try folders()
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("link"), withDestinationURL: outside)
        let n = #""0d1c6a1e-0000-4000-8000-0000000000ff":{"title":"x","stem":"x","folder":["link"],"tags":[],"pages":1,"modified":"2025-10-09T00:00:00Z"}"#
        try Data(#"{"version":1,"files":{},"notes":{\#(n)}}"#.utf8).write(to: out.appendingPathComponent(".sempere-export-markdown.json"))
        let t = TreeExporter(root: out, format: .markdown, source: "test", clean: false)
        let r = try t.run([note("A")], protected: [], vaultSource: "test:1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertFalse(r.errors.isEmpty)
    }

    func testNoteFolderThatIsALinkIsSkippedAndReported() throws {
        let (out, outside) = try folders()
        let (s, st) = note("A")
        let t = TreeExporter(root: out, format: .markdown, source: "test")
        let first = try t.run([(s, st)], protected: [], vaultSource: "test:1")
        XCTAssertEqual(first.failures, 0)
        // The note's PDF name becomes a link to a file outside.
        let pdf = try XCTUnwrap(first.results.first?.files.first { $0.hasSuffix(".pdf") })
        try FileManager.default.removeItem(atPath: pdf)
        let target = outside.appendingPathComponent("target.pdf")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: pdf, withDestinationPath: target.path)
        let second = try t.run([(s, st)], protected: [], vaultSource: "test:1")
        XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
        XCTAssertEqual(second.failures, 1)
    }

    func testCleanRemovesOnlyWhatWasExported() throws {
        let (out, _) = try folders()
        let t1 = TreeExporter(root: out, format: .markdown, source: "test", clean: true)
        let first = try t1.run([note("A", n: 1), note("B", n: 2)], protected: [], vaultSource: "test:1")
        let files = Dictionary(uniqueKeysWithValues: first.results.map { ($0.noteId, $0.files) })
        let bFiles = try XCTUnwrap(files["0d1c6a1e-0000-4000-8000-000000000002"])
        let bMd = try XCTUnwrap(bFiles.first { $0.hasSuffix(".md") })
        // The user edited B's .md after the export: --clean keeps it.
        try Data("my edits".utf8).write(to: URL(fileURLWithPath: bMd))
        let second = try t1.run([note("A", n: 1)], protected: [], vaultSource: "test:1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bMd))
        XCTAssertTrue(second.errors.contains { $0.contains("not removed") }, "\(second.errors)")
        for f in bFiles where f != bMd { XCTAssertFalse(FileManager.default.fileExists(atPath: f), f) }
        // Not removed stays reported by the next run.
        let third = try t1.run([note("A", n: 1)], protected: [], vaultSource: "test:1")
        XCTAssertTrue(third.errors.contains { $0.contains("not removed") }, "\(third.errors)")
    }

    /// Manifests written before files carried a digest: the note's recorded size and hash decide.
    func testCleanUsesTheRecordedStampsOfAnOlderManifest() throws {
        let (out, _) = try folders()
        var t = TreeExporter(root: out, format: .markdown, source: "test", clean: true)
        t.environment = "env"
        func versioned(_ n: Int) -> TreeNote {
            let (s, st) = note(n == 1 ? "A" : "B", n: n)
            return TreeNote(summary: s, version: "v1", load: { st })
        }
        let first = try t.run([versioned(1), versioned(2)], protected: [], vaultSource: "test:1")
        let bFiles = try XCTUnwrap(first.results.first { $0.noteId.hasSuffix("2") }?.files)
        let manifestURL = out.appendingPathComponent(".sempere-export-markdown.json")
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try XCTUnwrap(m["files"] as? [String: [String: Any]])
        for k in files.keys { files[k]?["size"] = nil; files[k]?["sha256"] = nil }
        m["files"] = files
        try JSONSerialization.data(withJSONObject: m).write(to: manifestURL)
        let second = try t.run([versioned(1)], protected: [], vaultSource: "test:1")
        for f in bFiles.filter({ !$0.hasSuffix("README.md") }) { XCTAssertFalse(FileManager.default.fileExists(atPath: f), f) }
        XCTAssertTrue(second.errors.isEmpty, "\(second.errors)")
    }

    func testIndexInALinkedFolderCountsAsAFailure() throws {
        let (out, outside) = try folders()
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("link"), withDestinationURL: outside)
        let n = #""0d1c6a1e-0000-4000-8000-0000000000ff":{"title":"x","stem":"x","folder":["link"],"tags":[],"pages":1,"modified":"2025-10-09T00:00:00Z"}"#
        try Data(#"{"version":1,"files":{},"notes":{\#(n)}}"#.utf8).write(to: out.appendingPathComponent(".sempere-export-markdown.json"))
        let r = try TreeExporter(root: out, format: .markdown, source: "test").run([note("A")], protected: [], vaultSource: "test:1")
        XCTAssertGreaterThan(r.failures, 0)
    }

    func testReplacedExportsAreOwnerOnly() throws {
        let (out, _) = try folders()
        let t = TreeExporter(root: out, format: .markdown, source: "test")
        let r = try t.run([note("A")], protected: [], vaultSource: "test:1")
        let pdf = URL(fileURLWithPath: try XCTUnwrap(r.results.first?.files.first { $0.hasSuffix(".pdf") }))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pdf.path)
        try Data("stale".utf8).write(to: pdf)
        _ = try t.run([note("A")], protected: [], vaultSource: "test:1")
        XCTAssertEqual(try mode(pdf), 0o600)

        let single = out.appendingPathComponent("single.pdf")
        try Data("old".utf8).write(to: single)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: single.path)
        var report = RenderReport()
        try PDFWriter.write(note: note("A").1, report: &report, to: single)
        XCTAssertEqual(try mode(single), 0o600)
    }
}
