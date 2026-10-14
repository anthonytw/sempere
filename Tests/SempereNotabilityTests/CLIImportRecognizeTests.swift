import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `import notability --recognize missing` (the CLI's host-side recognition of the notes an importer wrote).
/// Reading handwriting needs Vision: on Linux the import must be refused before it imports anything; on macOS it
/// runs for real. Neither asserts what Vision reads from synthetic strokes, only what is stored.
final class CLIImportRecognizeTests: CLITestCase {
    func args(_ vault: Vault, _ keyPath: String) -> [String] { ["--vault", vault.url.path, "--identity", keyPath] }

    #if canImport(Vision)
    func testImportRecognizesOnlyPagesNotabilityNeverIndexed() throws {
        let (vault, _, key) = try makeVault()
        let r = try cli(["import", "notability", CLIImportSearchTests.zipNote, "--recognize", "missing", "--json"]
                        + args(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let out = try XCTUnwrap(r.json as? [String: Any])
        let recognized = try XCTUnwrap(out["recognized"] as? [[String: Any]])
        XCTAssertEqual(recognized.count, (out["summary"] as? [String: Any])?["imported"] as? Int)
        XCTAssertTrue(recognized.allSatisfy { $0["error"] == nil }, "\(recognized)")
        for entry in recognized {
            let state = try vault.reconstruct(noteId: try XCTUnwrap(UUID(uuidString: entry["note"] as! String)))
            for (i, page) in state.pages.enumerated() where (entry["read"] as? [Int])?.contains(i + 1) == true {
                XCTAssertEqual(page.recognition?.basis, RecognitionBasis.digest(of: page.strokes.map(\.id)))
            }
            // Pages Notability indexed keep its recognition (no basis).
            for page in state.pages where page.recognition != nil && page.recognition?.basis == nil {
                XCTAssertFalse(page.recognition?.engine.hasPrefix("vision-") ?? true)
            }
        }
    }
    #else
    func testImportRecognizeIsRefusedWithoutVision() throws {
        let (vault, _, key) = try makeVault()
        // The import is refused before anything is imported.
        let notes = try vault.noteIDs()
        let i = try cli(["import", "notability", CLIImportSearchTests.zipNote, "--recognize", "missing"] + args(vault, key))
        XCTAssertEqual(i.status, 1)
        XCTAssertTrue(i.err.contains("Vision"), i.err)
        XCTAssertEqual(try vault.noteIDs(), notes)
        // Without --recognize, or as a dry run, the import works.
        let dry = try cli(["import", "notability", CLIImportSearchTests.zipNote, "--recognize", "missing", "--dry-run",
                           "--json"] + args(vault, key))
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertNotNil((dry.json as? [String: Any])?["recognized"] as? [[String: Any]])
        XCTAssertEqual(try vault.noteIDs(), notes)
    }
    #endif
}
