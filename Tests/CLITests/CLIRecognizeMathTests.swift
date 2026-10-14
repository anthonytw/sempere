import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere recognize-math` (docs/cli.md "Handwritten math"): picking ink,
/// converting it with a given reading (`--latex`, every platform), the one
/// delta it writes, the model image, and Core ML with the tiny fixture model
/// on macOS. End to end through the binary.
final class CLIRecognizeMathTests: CLITestCase {
    static let tinyModel = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereRenderTests/Fixtures/math-tiny")

    let physics = "aaaaaaaa-1111-4111-8111-000000000001"   // page 2 holds two strokes
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"  // one page, one stroke

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }

    func setUpVault() throws -> [String] {
        _ = try makeVault()
        return ["--vault", vaultPath, "--identity", keyPath]
    }

    @discardableResult
    func ok(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let r = try cli(args)
        XCTAssertEqual(r.status, 0, "\(args.prefix(3)): \(r.err)", file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    func vault() throws -> Vault {
        try Vault.open(at: URL(fileURLWithPath: vaultPath),
                       identities: [try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))])
    }

    func state(_ note: String) throws -> NoteState { try vault().reconstruct(noteId: UUID(uuidString: note)!) }

    func revisionCount(_ note: String) throws -> Int { try vault().loadNote(UUID(uuidString: note)!).revisions.count }

    func testReplaceWithAGivenReadingIsOneDelta() throws {
        let args = try setUpVault()
        let before = try state(physics)
        let strokes = before.pages[1].strokes.map(\.id)
        let count = try revisionCount(physics)
        let out = try ok(["recognize-math", physics, "--page", "2", "--all-ink", "--latex", "a+b", "--place", "replace",
                          "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), count + 1, "one delta")
        XCTAssertEqual(out["page"] as? Int, 2)
        XCTAssertEqual(out["strokes"] as? [String], strokes.map { $0.uuidString.lowercased() })
        XCTAssertEqual(out["removed"] as? [String], strokes.map { $0.uuidString.lowercased() })
        XCTAssertEqual((out["candidates"] as? [[String: Any]])?.first?["latex"] as? String, "a+b")
        XCTAssertNotNil(out["file"] as? String)
        let after = try state(physics)
        XCTAssertTrue(after.pages[1].strokes.isEmpty)
        XCTAssertEqual(after.pages[0].strokes.count, 1, "other pages untouched")
        let item = try XCTUnwrap(after.pages[1].items.first)
        XCTAssertEqual(item.kind, .math)
        XCTAssertEqual(item.math?.latex, "a+b")
        XCTAssertNil(item.math?.render, "the CLI has no typesetter")
        // As tall as the ink, starting at its left edge.
        let ink = try XCTUnwrap(InkGeometry.bounds(of: before.pages[1].strokes))
        XCTAssertEqual(item.frame.x, ink.x, accuracy: 0.01)
        XCTAssertEqual(item.frame.h, ink.h, accuracy: 0.01)
    }

    func testBesideKeepsTheInkAndStrokePrefixesPick() throws {
        let args = try setUpVault()
        let stroke = try XCTUnwrap(try state(groceries).pages[0].strokes.first)
        let prefix = String(stroke.id.uuidString.lowercased().prefix(8))
        let out = try ok(["recognize-math", groceries, "--strokes", prefix, "--latex", "x^{2}", "--place", "beside",
                          "--inline", "--size", "14", "--json"] + args)
        XCTAssertEqual(out["removed"] as? [String], [])
        let page = try state(groceries).pages[0]
        XCTAssertEqual(page.strokes.map(\.id), [stroke.id])
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.math?.display, false)
        XCTAssertEqual(item.math?.size, 14)
        let ink = try XCTUnwrap(InkGeometry.bounds(of: [stroke]))
        XCTAssertGreaterThan(item.frame.x, ink.x + ink.w)
    }

    func testRectAndLassoPickTheEnclosedInk() throws {
        let args = try setUpVault()
        let page2 = try state(physics).pages[1].strokes.map(\.id)
        // Each stroke of page 2 runs from x = 40 + 10 n to 88 + 10 n, y 100 to 136: a rectangle around both takes both.
        let both = try ok(["recognize-math", physics, "--page", "2", "--rect", "0,90,200,60", "--latex", "x", "--json"] + args)
        XCTAssertEqual(Set(both["strokes"] as? [String] ?? []), Set(page2.map { $0.uuidString.lowercased() }))
        XCTAssertNil(both["file"] as? String, "nothing written without --place")
        // A loop around only the first stroke's start and middle takes it, not the second (shifted 10 pt right).
        let first = try ok(["recognize-math", physics, "--page", "2", "--lasso", "50,90 85,90 85,130 50,130", "--latex", "x",
                            "--json"] + args)
        XCTAssertEqual(first["strokes"] as? [String], [page2[0].uuidString.lowercased()])
        // Nothing inside: an error, nothing written.
        let count = try revisionCount(physics)
        let none = try cli(["recognize-math", physics, "--rect", "500,500,10,10", "--latex", "x", "--place", "replace"] + args)
        XCTAssertNotEqual(none.status, 0)
        XCTAssertTrue(none.err.contains("no strokes were picked"), none.err)
        XCTAssertEqual(try revisionCount(physics), count)
    }

    func testDryRunAndRefusalsWriteNothing() throws {
        let args = try setUpVault()
        let count = try revisionCount(groceries)
        let dry = try ok(["recognize-math", groceries, "--all-ink", "--latex", "y", "--place", "replace", "--dry-run", "--json"] + args)
        XCTAssertEqual(dry["dryRun"] as? Bool, true)
        XCTAssertNotNil(dry["item"] as? [String: Any])
        let cases: [([String], String)] = [
            (["--latex", "x"], "pick the ink"),
            (["--all-ink", "--rect", "0,0,1,1", "--latex", "x"], "pick the ink"),
            (["--all-ink"], "--model"),
            (["--all-ink", "--latex", "x", "--dry-run"], "--dry-run goes with --place"),
            (["--all-ink", "--latex", "\\frac{a}{b", "--place", "replace"], "never closed"),
            (["--all-ink", "--latex", "x", "--place", "replace", "--candidate", "2"], "1 reading"),
            (["--strokes", "zz", "--latex", "x"], "at least 4 characters"),
            (["--strokes", "ffffffff", "--latex", "x"], "no stroke ffffffff"),
            (["--lasso", "1,2 3,4", "--latex", "x"], "at least three points"),
            (["--all-ink", "--page", "3", "--latex", "x"], "no page 3"),
            (["--all-ink", "--latex", "x", "--model", Self.tinyModel.path], "not both"),
        ]
        for (extra, message) in cases {
            let r = try cli(["recognize-math", groceries] + extra + args)
            XCTAssertNotEqual(r.status, 0, "\(extra)")
            XCTAssertTrue(r.err.contains(message), "\(extra): \(r.err)")
        }
        XCTAssertEqual(try revisionCount(groceries), count)
        XCTAssertTrue(try state(groceries).pages[0].items.isEmpty)
    }

    func testSaveImageWritesTheModelImage() throws {
        let args = try setUpVault()
        let file = path("ink.png")
        let out = try ok(["recognize-math", physics, "--page", "2", "--all-ink", "--save-image", file, "--json"] + args)
        XCTAssertEqual(out["image"] as? String, file)
        let png = try Data(contentsOf: URL(fileURLWithPath: file))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Width and height from the IHDR chunk: the default preview size.
        let width = png[16..<20].reduce(0) { $0 << 8 | Int($1) }, height = png[20..<24].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual([width, height], [512, 128])
    }

    func testModelReadsOnMacOSAndIsRefusedElsewhere() throws {
        let args = try setUpVault()
        let r = try cli(["recognize-math", physics, "--page", "2", "--all-ink", "--model", Self.tinyModel.path, "--json"] + args)
        #if canImport(CoreML)
        XCTAssertEqual(r.status, 0, r.err)
        let out = try XCTUnwrap(r.json as? [String: Any], "standard output is not JSON: \(r.out.prefix(2000))")
        XCTAssertEqual(out["engine"] as? String, "tiny-test")
        XCTAssertNotNil(out["seconds"] as? Double)
        #else
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.err.contains("Core ML"), r.err)
        #endif
        // A model whose files do not match its manifest is refused before anything runs.
        let broken = tmp.appendingPathComponent("broken-model")
        try FileManager.default.copyItem(at: Self.tinyModel, to: broken)
        try Data("{}".utf8).write(to: broken.appendingPathComponent("tokenizer.json"))
        let bad = try cli(["recognize-math", physics, "--all-ink", "--model", broken.path] + args)
        XCTAssertNotEqual(bad.status, 0)
        #if canImport(CoreML)
        XCTAssertTrue(bad.err.contains("does not match its manifest"), bad.err)
        #endif
    }
}
