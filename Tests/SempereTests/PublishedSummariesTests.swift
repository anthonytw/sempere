import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// `sempere-summaries.sealed` (format.md §12): a hint that only a vault's own
/// secret opens, entries keyed by revision names, never created behind the
/// user's back, and bounded and typed on hostile bytes.
final class PublishedSummariesTests: VaultTestCase {
    static let vectorSecret = try! VaultSecret(bytes: Data(0..<32))
    static let vectorVault = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
    static let vectorNonce = Data(0xa0...0xab)

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// The vector in format.md §12.1 (also checked by web/test/summaries.test.ts).
    func testVector() throws {
        let key = PublishedSummaries.key(Self.vectorSecret).withUnsafeBytes { Data($0) }
        let file = try PublishedSummaries.seal(Data("{}".utf8), secret: Self.vectorSecret, vaultId: Self.vectorVault,
                                               nonce: Self.vectorNonce)
        XCTAssertEqual(Self.hex(key), Self.vectorKeyHex)
        XCTAssertEqual(Self.hex(file), Self.vectorFileHex)
        XCTAssertEqual(try PublishedSummaries.open(file, secret: Self.vectorSecret, vaultId: Self.vectorVault),
                       Data("{}".utf8))
    }

    static let vectorKeyHex = "4ffd10840df4dc46092a2c424919f611c1bcc355fe7526a19e25a1489bf5510a"
    static let vectorFileHex = "534d505501a0a1a2a3a4a5a6a7a8a9aaabb466bcf027fe45b94f3fe195f6e0b57d9c6e"

    static let noteA = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000a00a")!
    static let noteB = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000a00b")!
    static let noteC = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000a00c")!

    func rev(_ note: UUID, _ device: DeviceID, _ seq: Int, _ t: Int64, _ ops: [Op]) -> Revision {
        let ms = baseMillis + t
        return Revision(noteId: note, device: device, seq: seq, hlc: HLC(millis: ms, counter: 0)!, wall: wallAt(ms),
                        app: "test/0", body: .delta(ops: ops))
    }

    /// A vault with two clean notes and one with an unreadable revision.
    func makeNotes(_ vault: Vault) throws -> (clean: [Revision], broken: Revision) {
        let page = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000c001")!
        let a = rev(Self.noteA, devA, 1, 0, NoteOps.newNote(title: "Synthetic A", notebook: "School/Math", tags: ["alpha"],
                                                             pageId: page))
        let a2 = rev(Self.noteA, devA, 2, 10, [.setPageRecognition(pageId: page, recognition: Recognition(
            engine: "test", text: "synthetic words", words: [])), .setMeta(.favorite(true))])
        let b = rev(Self.noteB, devB, 1, 5, NoteOps.newNote(title: "Synthetic B", pageId: UUID()))
        let c = rev(Self.noteC, devA, 1, 7, NoteOps.newNote(title: "Synthetic C", pageId: UUID()))
        for r in [a, a2, b, c] { try vault.write(r) }
        try flipByte(fileURL(vault, c.noteId, c.name), at: 40)
        return ([a, a2, b], c)
    }

    func testEntriesRoundTripAndSkipUnreadableNotes() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let (clean, broken) = try makeNotes(vault)
        let (entries, read) = try vault.publishedSummaryEntries()
        XCTAssertEqual(read, 3)
        XCTAssertEqual(Set(entries.keys), Set(clean.map(\.noteId)))
        XCTAssertNil(entries[broken.noteId], "a note with an unreadable revision is never published")
        let a = try XCTUnwrap(entries[clean[0].noteId])
        XCTAssertEqual(a.title, "Synthetic A")
        XCTAssertEqual(a.notebook, "School/Math")
        XCTAssertEqual(a.tags, ["alpha"])
        XCTAssertTrue(a.favorite)
        XCTAssertEqual(a.revisions, [clean[0].name.filename, clean[1].name.filename].sorted())
        XCTAssertEqual(a.pageTexts, [.init(page: 1, text: "synthetic words")])
        XCTAssertEqual(a.modified, clean[1].wall)

        let sealed = try vault.sealPublishedSummaries(entries)
        XCTAssertEqual(try vault.openPublishedSummaries(sealed), entries)
        // Equal entries, equal JSON.
        XCTAssertEqual(try PublishedSummaries.encode(entries, vaultId: vault.vaultId),
                       try PublishedSummaries.encode(try vault.openPublishedSummaries(sealed), vaultId: vault.vaultId))
    }

    func testTamperedForeignAndLockedFilesDoNotOpen() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        _ = try makeNotes(vault)
        let sealed = try vault.sealPublishedSummaries(try vault.publishedSummaryEntries().entries)
        for i in [0, 4, 5, 20, sealed.count - 1] {
            var bad = sealed
            bad[i] ^= 0x01
            XCTAssertThrowsError(try vault.openPublishedSummaries(bad)) { XCTAssert($0 is PublishedSummariesError) }
        }
        XCTAssertThrowsError(try vault.openPublishedSummaries(sealed.prefix(20)))
        XCTAssertThrowsError(try vault.openPublishedSummaries(Data()))

        // Another vault (its own secret) cannot open it.
        let other = try makeVault(id, name: "Other")
        XCTAssertThrowsError(try other.openPublishedSummaries(sealed)) { XCTAssert($0 is PublishedSummariesError) }
        // Same secret, another vault id: the associated data differs.
        let json = try Gzip.compress(try PublishedSummaries.encode([:], vaultId: vault.vaultId))
        let forOther = try PublishedSummaries.seal(json, secret: try vault.requireSecret(), vaultId: other.vaultId)
        XCTAssertThrowsError(try vault.openPublishedSummaries(forOther))
        // Authentic but naming another vault inside.
        let inside = try PublishedSummaries.seal(try Gzip.compress(try PublishedSummaries.encode([:], vaultId: other.vaultId)),
                                                 secret: try vault.requireSecret(), vaultId: vault.vaultId)
        XCTAssertThrowsError(try vault.openPublishedSummaries(inside))
        // A locked vault reads nothing.
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.openPublishedSummaries(sealed)) { XCTAssertEqual($0 as? VaultError, .locked) }
        XCTAssertEqual(locked.readPublishedSummaries(), [:])
    }

    func testMalformedEntriesAreDroppedAlone() throws {
        let vid = UUID()
        let good = #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":1,"pageTexts":[{"page":1,"text":"x"}]"#
        let bad = [
            #""revisions":[],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":0,"pageTexts":[]"#,
            #""revisions":["../x"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":0,"pageTexts":[]"#,
            #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-02-30T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":0,"pageTexts":[]"#,
            #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":1,"pageTexts":[{"page":2,"text":"x"}]"#,
            #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":7,"tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":1,"pageTexts":[]"#,
        ]
        var notes = [#""11111111-1111-4111-8111-111111111111":{\#(good),"unknown":{"x":1}}"#,
                     #""11111111-1111-4111-8111-11111111111A":{\#(good)}"#]
        for (i, b) in bad.enumerated() { notes.append(#""22222222-2222-4222-8222-22222222222\#(i)":{\#(b)}"#) }
        let json = #"{"format":"sempere-summaries/1","vaultId":"\#(vid.uuidString.lowercased())","notes":{\#(notes.joined(separator: ","))}}"#
        let entries = try PublishedSummaries.decode(Data(json.utf8), vaultId: vid)
        XCTAssertEqual(entries.keys.map { $0.uuidString.lowercased() }, ["11111111-1111-4111-8111-111111111111"])
        XCTAssertThrowsError(try PublishedSummaries.decode(Data(json.replacingOccurrences(of: "summaries/1", with: "summaries/2").utf8),
                                                           vaultId: vid))
        XCTAssertThrowsError(try PublishedSummaries.decode(Data(json.utf8), vaultId: UUID()))
    }

    func testStaleEntriesAreReadAgainAndListingFiltersTheServerView() throws {
        let vault = try makeVault(pqIdentity())
        let (clean, _) = try makeNotes(vault)
        let (first, _) = try vault.publishedSummaryEntries()
        // A new revision of note A: its entry is stale, B's is reused.
        let a3 = rev(Self.noteA, devA, 3, 20, [.setMeta(.title("Renamed"))])
        try vault.write(a3)
        let (second, read) = try vault.publishedSummaryEntries(reuse: first)
        XCTAssertEqual(read, 2, "note A again, and the unreadable note C")
        XCTAssertEqual(second[clean[0].noteId]?.title, "Renamed")
        XCTAssertEqual(second[clean[2].noteId], first[clean[2].noteId])
        // For a server that lacks A's newest revision, A has no entry.
        var listing = try vault.webIndexListing()
        listing[clean[0].noteId.uuidString.lowercased()]?.removeAll { $0 == a3.name.filename }
        let (server, _) = try vault.publishedSummaryEntries(for: listing, reuse: second)
        XCTAssertNil(server[clean[0].noteId])
        XCTAssertNotNil(server[clean[2].noteId])
    }

    func testRefreshRewritesOnlyAnExistingStaleFile() throws {
        let vault = try makeVault(pqIdentity())
        _ = try makeNotes(vault)
        XCTAssertFalse(try vault.refreshPublishedSummaries())
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.publishedSummariesURL.path), "never created")
        try Data("junk".utf8).write(to: vault.publishedSummariesURL)
        XCTAssertTrue(try vault.refreshPublishedSummaries(), "a damaged file is replaced")
        XCTAssertEqual(vault.readPublishedSummaries().count, 2)
        XCTAssertFalse(try vault.refreshPublishedSummaries(), "current: not rewritten")
        XCTAssertFalse(try Vault.open(at: vault.url).refreshPublishedSummaries(), "locked: left alone")
    }

    // MARK: - Fuzz

    func testFuzzPublishedSummaries() throws {
        let vault = try makeVault(pqIdentity())
        _ = try makeNotes(vault)
        let entries = try vault.publishedSummaryEntries().entries
        let json = try PublishedSummaries.encode(entries, vaultId: vault.vaultId)
        let vid = vault.vaultId
        let secret = try vault.requireSecret()
        // Plaintext JSON: decode must accept or throw typed errors only.
        let jsonReport = Fuzz.run("published-summaries-json", seeds: [json], quick: 1500, text: true, maxSize: 64 << 10) { input in
            do { _ = try PublishedSummaries.decode(input, vaultId: vid) } catch is PublishedSummariesError {
            } catch { return "untyped error \(type(of: error))" }
            return nil
        }
        XCTAssertGreaterThan(jsonReport.cases, 0)
        for f in jsonReport.failures { XCTFail("\(f)") }
        // Mutated JSON sealed for real, read through the vault.
        let sealedReport = Fuzz.run("published-summaries-sealed", seeds: [json], quick: 200, text: true, maxSize: 64 << 10) { input in
            do {
                let file = try PublishedSummaries.seal(try Gzip.compress(input), secret: secret, vaultId: vid)
                _ = try vault.openPublishedSummaries(file)
            } catch is PublishedSummariesError {
            } catch is GzipError {
            } catch { return "untyped error \(type(of: error))" }
            return nil
        }
        XCTAssertGreaterThan(sealedReport.cases, 0)
        for f in sealedReport.failures { XCTFail("\(f)") }
    }
}
