import Age
import CLITestSupport
import Foundation
import FuzzSupport
import Sempere
import XCTest

/// The Notability import gaps end to end through the binary: `.ntb`
/// attachments, PDF page text (Notability's index, `attach pdf`, `import
/// pdf`) and `search` over it, the handwriting language with `notes language`
/// and `recognize`, and `notes markers` (docs/cli.md).
final class CLIImportGapsTests: CLITestCase {
    static let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static var gapsNote: String { fixtureDir.appendingPathComponent("synthetic-gaps.note").path }
    static var gapsBundle: String { fixtureDir.appendingPathComponent("synthetic-gaps.ntb").path }

    func vaultArgs(_ vault: String) -> [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    /// A one-page-per-text PDF with Helvetica text, written to the temp dir.
    func textPDF(_ texts: [String]) throws -> String {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\((0..<texts.count).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(texts.count) >>"]
        for (i, t) in texts.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font "
                           + "/Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents \(4 + 2 * i) 0 R >>")
            let c = "BT /F1 12 Tf 72 700 Td (\(t)) Tj ET"
            objects.append("<< /Length \(c.utf8.count) >>\nstream\n\(c)\nendstream")
        }
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(out.utf8.count); out += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let p = path("text-\(UUID().uuidString.prefix(8)).pdf")
        try out.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testImportReportsTheNewCountsAndSearchFindsPDFText() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["import", "notability", Self.gapsNote, Self.gapsBundle, "--pdf-text", "builtin", "--json"] + vaultArgs(vault))
        XCTAssertEqual(r.status, 0, r.err)
        let out = try XCTUnwrap(r.json as? [String: Any])
        let summary = try XCTUnwrap(out["summary"] as? [String: Any])
        XCTAssertEqual(summary["imported"] as? Int, 2)
        XCTAssertEqual(summary["ntbPDFPages"] as? Int, 2)
        XCTAssertEqual(summary["ntbImages"] as? Int, 1)
        XCTAssertEqual(summary["ntbDroppedPDFs"] as? Int, 0)
        XCTAssertEqual(summary["pdfTextPages"] as? Int, 4)
        XCTAssertEqual(summary["pdfTextFromIndex"] as? Int, 2)
        XCTAssertEqual(summary["pdfTextExtracted"] as? Int, 2)
        XCTAssertEqual(summary["pdfPagesWithoutText"] as? Int, 0)
        XCTAssertEqual(summary["languages"] as? [String: Int], ["es-ES": 1])
        XCTAssertEqual(summary["markersBehindText"] as? Int, 1)
        XCTAssertEqual(summary["paperColors"] as? Int, 1)
        let notes = try XCTUnwrap(out["notes"] as? [[String: Any]])
        let note = try XCTUnwrap(notes.first { $0["format"] as? String == "note" })
        XCTAssertEqual(note["lang"] as? String, "es-ES")
        XCTAssertEqual(note["markersBehindText"] as? Bool, true)
        XCTAssertEqual(note["paperColor"] as? String, "#FFF7E0FF")
        let bundle = try XCTUnwrap(notes.first { $0["format"] as? String == "ntb" })
        let a = try XCTUnwrap(bundle["attachments"] as? [String: Any])
        XCTAssertEqual(a["bundlePDFRecords"] as? Int, 1)
        XCTAssertEqual(a["bundleMediaRecords"] as? Int, 1)
        XCTAssertEqual(a["bundleFiles"] as? Int, 2)
        XCTAssertEqual(a["bundleFilesImported"] as? Int, 2)
        XCTAssertEqual((bundle["dropped"] as? [String: Any])?["bundleFilesUnreferenced"] as? Int, 0)

        // `search` reports the PDF page and item; `notes search` ranks the note.
        let hits = try XCTUnwrap(try cli(["search", "propios", "--json"] + vaultArgs(vault)).json as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0]["source"] as? String, "pdf")
        XCTAssertEqual(hits[0]["page"] as? Int, 1)
        XCTAssertEqual(hits[0]["pdfPage"] as? Int, 2)
        XCTAssertNotNil(hits[0]["itemId"] as? String)
        XCTAssertEqual((hits[0]["engine"] as? String)?.hasPrefix("notability"), true)
        let table = try cli(["search", "nullity"] + vaultArgs(vault))
        XCTAssertTrue(table.out.contains("p1 pdf p2"), table.out)
        let ranked = try XCTUnwrap(try cli(["notes", "search", "kernel", "--json"] + vaultArgs(vault)).json as? [[String: Any]])
        XCTAssertEqual(ranked.first?["title"] as? String, "Synthetic PDF bundle")

        // notes language / markers, and what `notes list --json` says.
        let id = try XCTUnwrap(note["id"] as? String)
        XCTAssertEqual(try cli(["notes", "language", id] + vaultArgs(vault)).out.trimmingCharacters(in: .whitespacesAndNewlines), "es-ES")
        XCTAssertEqual(try cli(["notes", "language", id, "pt_BR"] + vaultArgs(vault)).status, 0)
        XCTAssertEqual(try cli(["notes", "language", id, "not a tag"] + vaultArgs(vault)).status, 2)
        XCTAssertEqual(try cli(["notes", "markers", id, "above"] + vaultArgs(vault)).status, 0)
        let list = try XCTUnwrap(try cli(["notes", "list", "--json"] + vaultArgs(vault)).json as? [[String: Any]])
        let listed = try XCTUnwrap(list.first { $0["id"] as? String == id })
        XCTAssertEqual(listed["lang"] as? String, "pt-BR")
        XCTAssertEqual(listed["markersBehindText"] as? Bool, false)
        XCTAssertEqual(try cli(["notes", "language", id, "--none", "--json"] + vaultArgs(vault)).status, 0)
        let cleared = try XCTUnwrap(try cli(["notes", "language", id, "--json"] + vaultArgs(vault)).json as? [String: Any])
        XCTAssertNil(cleared["lang"] as? String)

        // recognize --dry-run says which language Vision is asked for (works without Vision).
        _ = try cli(["notes", "language", id, "es"] + vaultArgs(vault))
        let dry = try cli(["recognize", id, "--force", "--dry-run", "--json"] + vaultArgs(vault))
        XCTAssertEqual(dry.status, 0, dry.err)
        let rec = try XCTUnwrap(((dry.json as? [String: Any])?["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(rec["language"] as? String, "es")
        XCTAssertEqual(try cli(["vault", "verify"] + vaultArgs(vault)).status, 0)
    }

    func testAttachAndImportPDFStoreTheText() throws {
        let vault = try copyFixtureVault()
        let pdf = try textPDF(["Hamiltonian mechanics", "Lagrangian"])
        let imported = try XCTUnwrap(try cli(["import", "pdf", pdf, "--pdf-text", "builtin", "--json"] + vaultArgs(vault)).json as? [String: Any])
        let result = try XCTUnwrap((imported["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["pagesWithText"] as? Int, 2)
        XCTAssertEqual(result["textEngine"] as? String, "semperepdf-1")
        let hits = try XCTUnwrap(try cli(["search", "lagrangian", "--json"] + vaultArgs(vault)).json as? [[String: Any]])
        XCTAssertEqual(hits.map { $0["page"] as? Int }, [2])

        let attached = try XCTUnwrap(try cli(["attach", "pdf", "11111111-1111-4111-8111-111111111111", pdf, "--pages", "1",
                                              "--pdf-text", "builtin", "--json"] + vaultArgs(vault)).json as? [String: Any])
        XCTAssertEqual(attached["pagesWithText"] as? Int, 1)
        // --pdf-text none stores nothing.
        let none = try XCTUnwrap(try cli(["attach", "pdf", "11111111-1111-4111-8111-111111111111", pdf, "--pdf-text", "none",
                                          "--json"] + vaultArgs(vault)).json as? [String: Any])
        XCTAssertEqual(none["pagesWithText"] as? Int, 0)
        XCTAssertEqual(try XCTUnwrap(try cli(["search", "hamiltonian", "--json"] + vaultArgs(vault)).json as? [Any]).count, 2)
    }

    func testPopplerIsUsedWhenInstalledOrAsked() throws {
        let vault = try copyFixtureVault()
        let pdf = try textPDF(["Poppler words"])
        let missing = try cli(["import", "pdf", pdf, "--pdf-text", "poppler"] + vaultArgs(vault),
                              env: ["SEMPERE_PDFTOTEXT": path("no-such-pdftotext")])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.err.contains("pdftotext"), missing.err)
        guard let p = ExternalTool.find("pdftotext")?.path else {
            // CI names pdftotext in SEMPERE_REQUIRE_TOOLS (or sets SEMPERE_REQUIRE_POPPLER on a Mac): a missing install fails.
            let env = ProcessInfo.processInfo.environment
            let names = (env["SEMPERE_REQUIRE_TOOLS"] ?? "").split(separator: ",").map(String.init)
            if names.contains("pdftotext") || names.contains("all") || env["SEMPERE_REQUIRE_POPPLER"] != nil {
                XCTFail("pdftotext is not installed but CI requires it")
            }
            throw XCTSkip("pdftotext is not installed")
        }
        let r = try cli(["import", "pdf", pdf, "--pdf-text", "poppler", "--json"] + vaultArgs(vault), env: ["SEMPERE_PDFTOTEXT": p])
        XCTAssertEqual(r.status, 0, r.err)
        let result = try XCTUnwrap(((r.json as? [String: Any])?["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["pagesWithText"] as? Int, 1)
        XCTAssertEqual((result["textEngine"] as? String)?.hasPrefix("pdftotext"), true)
        let hits = try XCTUnwrap(try cli(["search", "poppler", "--json"] + vaultArgs(vault)).json as? [[String: Any]])
        XCTAssertEqual(hits.first?["source"] as? String, "pdf")
    }

    /// `pdftotext -v` (the engine name) runs once per run, not once per page.
    func testPdftotextVersionIsAskedOnce() throws {
        let vault = try copyFixtureVault()
        let pdf = try textPDF((1...6).map { "Page \($0)" })
        let log = path("pdftotext-calls.log")
        let tool = path("fake-pdftotext")
        // -v: log it and print a version. Else: one form-feed-terminated page per page asked (-f, -l), into the last argument.
        let script = """
            #!/bin/sh
            if [ "$1" = "-v" ]; then echo v >> '\(log)'; echo 'pdftotext version 99.1.0' >&2; exit 0; fi
            f=1; l=1
            while [ $# -gt 2 ]; do case "$1" in -f) f=$2; shift;; -l) l=$2; shift;; esac; shift; done
            out=$2; : > "$out"; i=$f
            while [ $i -le $l ]; do printf 'text %s\\f' $i >> "$out"; i=$((i+1)); done

            """
        try script.write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        let r = try cli(["import", "pdf", pdf, "--pdf-text", "poppler", "--json"] + vaultArgs(vault), env: ["SEMPERE_PDFTOTEXT": tool])
        XCTAssertEqual(r.status, 0, r.err)
        let result = try XCTUnwrap(((r.json as? [String: Any])?["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["pagesWithText"] as? Int, 6)
        XCTAssertEqual(result["textEngine"] as? String, "pdftotext-99.1.0")
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "v\n", "was once per page")
    }
}
