import Age
import XCTest

@testable import Sempere

/// Transcript search (`TranscriptSearch`), the rules of `sempere search --transcripts`: checked against
/// the CLI's own output for the web viewer's search fixture vault (`web/test/golden/search/search`, written by
/// `web/scripts/golden.sh`), which holds unicode folding cases and two unreadable transcripts on purpose.
final class TranscriptSearchTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let terms = ["café", "CAFE", "  cafe  ", "ss", "STRASSE", "straße", "fi", "e", "the café", "resume", "über",
                        "lait the", "frac", "nothing at all"]

    struct Golden: Hashable, Comparable {
        var note: String, recording: String, start: Double, end: Double, snippet: String, matches: Int, engine: String
        static func < (a: Golden, b: Golden) -> Bool {
            (a.note, a.recording, a.start, a.snippet) < (b.note, b.recording, b.start, b.snippet)
        }
    }

    func openSearchVault() throws -> Vault {
        let id = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
        return try Vault.open(at: Self.repo.appendingPathComponent("web/test/fixtures/search.sempere"), identities: [id])
    }

    /// What the app does: the summaries' `transcribed` list, each blob decoded, the phrase searched.
    func appHits(_ term: String, in vault: Vault) throws -> [Golden] {
        var out: [Golden] = []
        for summary in try vault.summaries() where !summary.deleted {
            for t in summary.transcribed {
                guard let data = try? vault.readBlob(note: summary.id, t.blob, maxBytes: Transcript.maxSize),
                      let transcript = try? Transcript.decode(data) else { continue }
                for h in TranscriptSearch.hits(of: term, in: transcript, recording: t.recording, title: t.title) {
                    out.append(Golden(note: summary.id.uuidString.lowercased(), recording: t.recording.uuidString.lowercased(),
                                      start: h.start, end: h.end, snippet: h.snippet, matches: h.matches, engine: h.engine))
                }
            }
        }
        return out.sorted()
    }

    func goldenHits(_ term: String) throws -> [Golden] {
        let hex = term.utf8.map { String(format: "%02x", $0) }.joined()
        let url = Self.repo.appendingPathComponent("web/test/golden/search/search/\(hex).json")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return rows.filter { $0["source"] as? String == "transcript" }.map {
            Golden(note: $0["noteId"] as! String, recording: $0["recordingId"] as! String,
                   start: ($0["start"] as! NSNumber).doubleValue, end: ($0["end"] as! NSNumber).doubleValue,
                   snippet: $0["snippet"] as! String, matches: ($0["matches"] as! NSNumber).intValue, engine: $0["engine"] as! String)
        }.sorted()
    }

    func testMatchesTheCLIOnTheSharedFixtures() throws {
        let vault = try openSearchVault()
        var total = 0
        for term in Self.terms {
            let expected = try goldenHits(term)
            XCTAssertEqual(try appHits(term, in: vault), expected, "term '\(term)'")
            total += expected.count
        }
        XCTAssertGreaterThan(total, 5, "the fixtures must exercise the search")
    }

    func testSummariesListTranscribedRecordings() throws {
        let vault = try openSearchVault()
        let listed = try vault.summaries().flatMap(\.transcribed)
        XCTAssertFalse(listed.isEmpty)
        XCTAssertTrue(listed.allSatisfy { $0.blob.kind == .transcript })
    }

    func testRulesOnASmallTranscript() throws {
        let rec = UUID()
        let t = Transcript(recording: rec, engine: "e-1", language: "en", created: Date(timeIntervalSince1970: 0), segments: [
            .init(start: 0, end: 2, text: "Eigenvalues of a Matrix"), .init(start: 2, end: 4, text: "Résumé of matrix résumé"),
        ])
        XCTAssertEqual(TranscriptSearch.hits(of: "matrix", in: t, recording: rec).map(\.start), [0, 2])
        XCTAssertEqual(TranscriptSearch.hits(of: "  RESUME ", in: t, recording: rec).map(\.matches), [2])
        XCTAssertEqual(TranscriptSearch.hits(of: "of a", in: t, recording: rec).count, 1, "the whole term is a phrase")
        XCTAssertTrue(TranscriptSearch.hits(of: "matrix eigenvalues", in: t, recording: rec).isEmpty, "not word by word")
        XCTAssertTrue(TranscriptSearch.hits(of: "   ", in: t, recording: rec).isEmpty)
        XCTAssertTrue(TranscriptSearch.hits(of: "matrix", in: t, recording: UUID()).isEmpty, "a transcript of another recording")
    }
}
