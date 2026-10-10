import Age
import CLITestSupport
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// `sempere export` with PDF page backgrounds (`docs/attachments.md` §10, `docs/cli.md`).
final class CLIPDFBackgroundTests: CLITestCase {
    static let pdfFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SemperePDFTests/Fixtures")

    /// A copy of the fixture vault with one new note: a 400 × 300 page whose
    /// background is `pdf` page 1. Returns the vault path and the note id.
    func vaultWithPDFNote(_ pdf: String = "classic.pdf") throws -> (String, String) {
        let path = try copyFixtureVault()
        let identity = try IdentityFile.parse(String(contentsOfFile: Self.fixtureKey, encoding: .utf8))
        let vault = try Vault.open(at: URL(fileURLWithPath: path), identities: [identity])
        let note = UUID(), pageId = UUID()
        let state = tmp.appendingPathComponent("device.json")
        let ref = try vault.writeBlob(note: note, try Data(contentsOf: Self.pdfFixtures.appendingPathComponent(pdf)),
                                      type: "application/pdf")
        let item = Item.pdfPage(blob: ref, pageIndex: 0, pageSize: Size(w: 400, h: 300),
                                frame: Rect(x: 0, y: 0, w: 400, h: 300), z: "a0")
        try vault.apply(NoteOps.newNote(title: "Annotated", paper: .blank,
                                        pageSize: PageSize(width: 400, height: 300), pageId: pageId)
                        + [.addItem(page: pageId, item: item)], to: note, deviceState: state, app: "test")
        XCTAssertEqual(try vault.reconstruct(noteId: note).pages.first?.items.map(\.id), [item.id])
        return (path, note.uuidString.lowercased())
    }

    func export(_ vault: String, _ note: String, _ format: String, out: String, _ extra: [String] = [],
                env: [String: String] = [:]) throws -> CLIResult {
        try cli(["export", note, "--format", format, "--out", out, "--vault", vault, "--identity", Self.fixtureKey]
                + extra, env: env)
    }

    /// A stand-in `pdftoppm`.
    func fakePoppler(_ body: String) throws -> String {
        let url = tmp.appendingPathComponent("fake-pdftoppm-\(UUID().uuidString.prefix(8))")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    var hasPoppler: Bool { ExternalTool.find("pdftoppm") != nil }

    func testPDFExportKeepsThePageWithoutARenderer() throws {
        let (vault, note) = try vaultWithPDFNote()
        let r = try export(vault, note, "pdf", out: path("out.pdf"), ["--pdf-renderer", "none"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.err, "")
        let pdf = try Data(contentsOf: URL(fileURLWithPath: path("out.pdf")))
        XCTAssertEqual(Array(pdf.prefix(8)), Array("%PDF-1.7".utf8))
        XCTAssertNotNil(pdf.range(of: Data("/Subtype /Form".utf8)))
    }

    func testSVGWithoutRendererWarnsAndDrawsAPlaceholder() throws {
        let (vault, note) = try vaultWithPDFNote()
        let r = try export(vault, note, "svg", out: path("svg"), ["--pdf-renderer", "none", "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("warning: \(note.prefix(8)): 1 PDF background page drawn as placeholder: "
            + "install poppler (pdftoppm) to render them, or export as PDF, which keeps them exactly"), r.err)
        let written = try XCTUnwrap(r.json as? [[String: Any]])
        XCTAssertEqual(written.first?["placeholders"] as? Int, 1)
        let file = try XCTUnwrap((written.first?["files"] as? [String])?.first)
        let svg = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertFalse(svg.contains("<image"))
        XCTAssertTrue(svg.contains("stroke=\"#9aa0a6\""))
    }

    func testPopplerRequestedButMissingFails() throws {
        let r = try export(Self.fixtureVault, Self.lecture, "png", out: path("png"), ["--pdf-renderer", "poppler"],
                           env: ["SEMPERE_PDFTOPPM": tmp.appendingPathComponent("missing").path])
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("pdftoppm not found"), r.err)
    }

    func rasterize(_ pdf: String = "classic.pdf", width: Int = 40, height: Int = 30, timeout: Double = 30,
                   tool: String? = nil, tmpdir: String? = nil) throws -> (CLIResult, String) {
        let out = path("page-\(UUID().uuidString.prefix(6)).ppm")
        var env: [String: String] = [:]
        if let tmpdir { env["TMPDIR"] = tmpdir }
        if let tool { env["SEMPERE_PDFTOPPM"] = tool }
        let r = try cli(["__rasterize-pdf", Self.pdfFixtures.appendingPathComponent(pdf).path, "--width", "\(width)",
                         "--height", "\(height)", "--out", out, "--timeout", "\(timeout)"], env: env)
        return (r, out)
    }

    /// A renderer that never finishes is stopped at the timeout.
    func testHungRendererTimesOut() throws {
        let start = Date()
        let (r, _) = try rasterize(timeout: 1, tool: try fakePoppler("exec sleep 60"))
        XCTAssertEqual(r.status, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        XCTAssertTrue(r.err.contains("pdftoppm timed out after 1 s"), r.err)
        // A busy loop is stopped too (by the timeout or the CPU limit).
        let (busy, _) = try rasterize(timeout: 1, tool: try fakePoppler("while :; do :; done"))
        XCTAssertEqual(busy.status, 1)
    }

    func testCrashingOrFailingRenderer() throws {
        let (crash, _) = try rasterize(tool: try fakePoppler("kill -SEGV $$"))
        XCTAssertTrue(crash.err.contains("pdftoppm was killed by signal 11"), crash.err)
        let (failing, _) = try rasterize(tool: try fakePoppler("exit 3"))
        XCTAssertTrue(failing.err.contains("pdftoppm exited with status 3"), failing.err)
        let (garbage, _) = try rasterize(tool: try fakePoppler("for last; do :; done; printf 'P6\\n3 3\\n255\\nxyz' > \"$last.ppm\""))
        XCTAssertTrue(garbage.err.contains("truncated PPM"), garbage.err)
        let (none, _) = try rasterize(tool: try fakePoppler("exit 0"))
        XCTAssertTrue(none.err.contains("pdftoppm wrote no usable image"), none.err)
    }

    /// Output beyond what the requested pixels need is cut off by the
    /// file-size limit, and the temporary directory is removed.
    func testRunawayOutputIsLimited() throws {
        let scratch = path("tmp")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let (r, _) = try rasterize(tool: try fakePoppler("for last; do :; done; head -c 200000000 /dev/zero > \"$last.ppm\""),
                                   tmpdir: scratch)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("pdftoppm was killed by signal") || r.err.contains("exited with status")
                      || r.err.contains("no usable image"), r.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch), [])
    }

    /// The real Poppler, through the export's rasterizer: rotation handled, size exact.
    func testRealPopplerRasterizer() throws {
        guard hasPoppler else {
            if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_POPPLER"] != nil { XCTFail("pdftoppm missing") }
            throw XCTSkip("pdftoppm (poppler-utils) not installed")
        }
        // rotated.pdf page 1: /Rotate 90, effective page 360 × 500.
        let (r, out) = try rasterize("rotated.pdf", width: 72, height: 100)
        XCTAssertEqual(r.status, 0, r.err)
        let ppm = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertTrue(ppm.starts(with: Data("P6\n72 100\n255\n".utf8)))
        // The orange block (top-left on the turned page).
        let header = "P6\n72 100\n255\n".utf8.count
        let i = header + (15 * 72 + 8) * 3
        let (red, green, blue) = (Int(ppm[i]), Int(ppm[i + 1]), Int(ppm[i + 2]))
        XCTAssertTrue(red > 220 && (100...160).contains(green) && blue < 40, "\(red) \(green) \(blue)")
    }

    func testTrampolineRefusesBadArguments() throws {
        XCTAssertEqual(try cli(["__exec-limited", "--cpu", "x", "--", "/bin/true"]).status, 127)
        XCTAssertEqual(try cli(["__exec-limited", "--", "true"]).status, 127)   // no PATH search
        XCTAssertEqual(try cli(["__exec-limited", "--cpu", "5", "--", "/bin/sh", "-c", "exit 7"]).status, 7)
    }

    func testExportWithRealPoppler() throws {
        guard hasPoppler else {
            if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_POPPLER"] != nil { XCTFail("pdftoppm missing") }
            throw XCTSkip("pdftoppm (poppler-utils) not installed")
        }
        let (vault, note) = try vaultWithPDFNote("rotated.pdf")
        let r = try export(vault, note, "svg", out: path("svg"), ["--json"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.err, "")
        let file = try XCTUnwrap(((r.json as? [[String: Any]])?.first?["files"] as? [String])?.first)
        XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).contains("xlink:href=\"data:image/png;base64,"))
        let png = try export(vault, note, "png", out: path("png"), ["--dpi", "72"])
        XCTAssertEqual(png.status, 0, png.err)
        XCTAssertEqual(png.err, "")
        let none = try export(vault, note, "png", out: path("none"), ["--dpi", "72", "--pdf-renderer", "none"])
        let a = try Data(contentsOf: URL(fileURLWithPath: path("png/Annotated-\(note.prefix(8))-p001.png")))
        let b = try Data(contentsOf: URL(fileURLWithPath: path("none/Annotated-\(note.prefix(8))-p001.png")))
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(none.err.isEmpty)
    }
}
