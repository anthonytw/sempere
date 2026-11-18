import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere spotlight plan` (docs/design/1.3-spotlight.md §5): what the app's Spotlight switch would donate.
final class CLISpotlightTests: CLITestCase {
    func setUpVault() throws -> [String] {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let v = try makeVault()
        let opened = try Vault.open(at: v.vault.url, identities: [v.identity])
        let state = tmp.appendingPathComponent("lib-device.json")
        for (title, notebook, text) in [("Springs", "Physics", "damping ratio secret"), ("Bread", nil, "sourdough")] {
            let page = UUID()
            var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: notebook, pageId: page)
            ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
            try opened.apply(ops, to: UUID(), deviceState: state, app: "test/1", wall: Date().addingTimeInterval(-3600))
        }
        // A deleted note is never planned.
        let doomed = UUID()
        try opened.apply(NoteOps.newNote(title: "Doomed", paper: .ruled, notebook: nil, pageId: UUID()), to: doomed,
                         deviceState: state, app: "test/1", wall: Date().addingTimeInterval(-3000))
        try opened.apply([.deleteNote], to: doomed, deviceState: state, app: "test/1", wall: Date().addingTimeInterval(-2000))
        return ["--vault", v.vault.url.path, "--identity", v.keyPath]
    }

    func testPlanListsMetadataOnlyByDefault() throws {
        let args = try setUpVault()
        let r = try cli(["spotlight", "plan", "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["includeText"] as? Bool, false)
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        let titles = Set(items.compactMap { $0["title"] as? String })
        XCTAssertTrue(titles.isSuperset(of: ["Springs", "Bread"]), "\(titles)")
        XCTAssertFalse(titles.contains("Doomed"))
        XCTAssertTrue(items.allSatisfy { ($0["textLength"] as? Int) == 0 })
        XCTAssertFalse(r.out.contains("secret"), "no note text without --text")
        let caps = try XCTUnwrap(json["caps"] as? [String: Any])
        XCTAssertEqual(caps["textCharacters"] as? Int, 20_000)
        XCTAssertEqual(caps["notes"] as? Int, 50_000)
    }

    func testPlanWithTextReportsLengthsNotText() throws {
        let args = try setUpVault()
        let r = try cli(["spotlight", "plan", "--text", "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let items = try XCTUnwrap((r.json as? [String: Any])?["items"] as? [[String: Any]])
        let springs = try XCTUnwrap(items.first { ($0["title"] as? String) == "Springs" })
        XCTAssertEqual(springs["textLength"] as? Int, "damping ratio secret".count)
        // The description carries the start of the text, which is what Spotlight would show.
        XCTAssertTrue((springs["description"] as? String ?? "").contains("damping ratio secret"))
    }

    func testPlanTableAndValidation() throws {
        let args = try setUpVault()
        let table = try cli(["spotlight", "plan"] + args)
        XCTAssertEqual(table.status, 0, table.err)
        XCTAssertTrue(table.out.contains("Springs"))
        XCTAssertFalse(table.out.contains("Doomed"))
        let bad = try cli(["spotlight", "plan", "--transcripts"] + args)
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.err.contains("--transcripts needs --text"), bad.err)
    }
}
