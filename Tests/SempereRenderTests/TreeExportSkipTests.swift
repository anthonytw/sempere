import FuzzSupport
import TempDirSupport
import XCTest
import Foundation
import Sempere
@testable import SempereRender

/// `TreeExporter.run` decides "up to date" from a key before it reads or renders a note.
final class TreeExportSkipTests: XCTestCase {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    struct Blobs: BlobSource {
        var token: String?
        func data(for ref: BlobRef, maxBytes: Int) throws -> Data { throw BlobError.missing("x") }
        func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T { throw BlobError.missing("x") }
        var contentToken: String? { token }
    }

    static let when = Date(timeIntervalSince1970: 1_760_000_000)

    func summary(_ n: Int, _ title: String, notebook: String? = nil) -> NoteSummary {
        NoteSummary(id: UUID(uuidString: String(format: "0d1c6a1e-0000-4000-8000-%012d", n))!, title: title, tags: [],
                    notebook: notebook, deleted: false, pages: 1, strokes: 1, modified: Self.when, problem: nil)
    }

    func notes(_ count: Int, version: String = "v1", loads: Counter, titlePrefix: String = "Note") -> [TreeNote] {
        (1...count).map { n in
            let title = "\(titlePrefix) \(n)"
            return TreeNote(summary: summary(n, title, notebook: n % 2 == 0 ? "A/B" : nil), version: version, load: {
                loads.bump()
                return T.note(pages: [[T.stroke([T.pt(10, 10), T.pt(80, 50), T.pt(120, 20)])]], meta: T.meta(title: title))
            })
        }
    }

    func exporter(_ root: URL, format: TreeFormat, configure: (inout TreeExporter) -> Void = { _ in }) -> TreeExporter {
        var t = TreeExporter(root: root, format: format, source: "test", clean: true)
        t.environment = "env-1"
        configure(&t)
        return t
    }

    func run(_ t: TreeExporter, _ notes: [TreeNote], files: Counter? = nil) throws -> (TreeResult, [TreeResult]) {
        let r = try t.run(notes, protected: [], vaultSource: "test:1", onFile: { _, changed in if changed { files?.bump() } })
        XCTAssertEqual(r.failures, 0, "\(r.errors)")
        return (r.results[0], r.results)
    }

    func listing(_ root: URL) -> [String] { FileTree.regularFiles(under: root, skipHidden: true) }

    func testUnchangedNotesAreNeitherLoadedNorRendered() throws {
        for format in TreeFormat.allCases {
            let root = try makeScratch("treeskip-\(format)").appendingPathComponent("out")
            let loads = Counter()
            let t = exporter(root, format: format)
            _ = try run(t, notes(4, loads: loads))
            XCTAssertEqual(loads.value, 4)
            let before = listing(root)
            let written = Counter()
            let again = Counter()
            let (_, results) = try run(t, notes(4, loads: again), files: written)
            XCTAssertEqual(again.value, 0, "an up-to-date note is not read")
            XCTAssertEqual(written.value, 0)
            XCTAssertEqual(results.count, 4)
            XCTAssertTrue(results.allSatisfy { $0.changed.isEmpty && !$0.files.isEmpty })
            // --clean keeps the skipped notes' files.
            XCTAssertEqual(listing(root), before)
        }
    }

    func testEachInputRendersTheNoteAgain() throws {
        let root = try makeScratch("treeskip-inputs").appendingPathComponent("out")
        let base = exporter(root, format: .html)
        _ = try run(base, notes(2, loads: Counter()))

        func loadsWith(_ t: TreeExporter, version: String = "v1", titlePrefix: String = "Note",
                       blobs: Blobs? = nil, source: String = "test:1") throws -> Int {
            let c = Counter()
            var t = t
            if let blobs { t.blobs = { _ in blobs } }
            _ = try t.run(notes(2, version: version, loads: c, titlePrefix: titlePrefix), protected: [], vaultSource: source)
            return c.value
        }
        XCTAssertEqual(try loadsWith(base), 0)
        XCTAssertEqual(try loadsWith(base, version: "v2"), 2, "a new revision")
        XCTAssertEqual(try loadsWith(base, version: "v2"), 0, "and then it is current again")
        XCTAssertEqual(try loadsWith(base, version: "v2", titlePrefix: "Renamed"), 2, "title (file name)")
        XCTAssertEqual(try loadsWith(base, version: "v2", titlePrefix: "Renamed", source: "test:2"), 2, "vault source")
        let env = exporter(root, format: .html) { $0.environment = "env-2" }
        XCTAssertEqual(try loadsWith(env, version: "v2", titlePrefix: "Renamed", source: "test:2"), 2, "fonts or program changed")
        let noPaper = exporter(root, format: .html) { $0.environment = "env-2"; $0.options.paper = false }
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", source: "test:2"), 2, "options")
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", source: "test:2"), 0)
        // Blobs: a source that can describe itself keys the note; one that cannot is never skipped.
        let a = Blobs(token: "a")
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", blobs: a, source: "test:2"), 2)
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", blobs: a, source: "test:2"), 0)
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", blobs: Blobs(token: "b"), source: "test:2"), 2,
                       "a blob arrived")
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", blobs: Blobs(token: nil), source: "test:2"), 2)
        XCTAssertEqual(try loadsWith(noPaper, version: "v2", titlePrefix: "Renamed", blobs: Blobs(token: nil), source: "test:2"), 2)
    }

    func testMissingOrResizedOutputRendersAgainAndNoEnvironmentNeverSkips() throws {
        let root = try makeScratch("treeskip-files").appendingPathComponent("out")
        let t = exporter(root, format: .markdown)
        _ = try run(t, notes(2, loads: Counter()))
        let victim = listing(root).first { $0.hasSuffix(".pdf") }!
        try FileManager.default.removeItem(at: root.appendingPathComponent(victim))
        let c = Counter()
        _ = try run(t, notes(2, loads: c))
        XCTAssertEqual(c.value, 1, "only the note whose file is gone")
        XCTAssertTrue(listing(root).contains(victim))
        try Data("x".utf8).write(to: root.appendingPathComponent(victim))
        let d = Counter()
        _ = try run(t, notes(2, loads: d))
        XCTAssertEqual(d.value, 1, "a file of another size")

        // A same-length edit of an output file is noticed (its time changed, its content did not match).
        let md = listing(root).first { $0.hasSuffix(".md") }!
        let before = try Data(contentsOf: root.appendingPathComponent(md))
        var edited = before
        edited[edited.startIndex] ^= 0x01
        try edited.write(to: root.appendingPathComponent(md))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: root.appendingPathComponent(md).path)
        let f = Counter()
        _ = try run(t, notes(2, loads: f))
        XCTAssertEqual(f.value, 1, "same size, other content")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(md)), before, "and put back")

        var blind = t
        blind.environment = nil
        let e = Counter()
        _ = try run(blind, notes(2, loads: e))
        _ = try run(blind, notes(2, loads: e))
        XCTAssertEqual(e.value, 4)
    }

    func testLoadFailureIsThatNotesFailureOnly() throws {
        let root = try makeScratch("treeskip-fail").appendingPathComponent("out")
        let loads = Counter()
        var list = notes(3, loads: loads)
        list[1].load = { throw VaultError.io("boom") }
        let r = try exporter(root, format: .html).run(list, protected: [], vaultSource: "test:1")
        XCTAssertEqual(r.failures, 1)
        XCTAssertEqual(r.results.count, 2)
    }
}
