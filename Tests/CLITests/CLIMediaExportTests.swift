import CLITestSupport
import Foundation
import FuzzSupport
import Sempere
import XCTest

/// Task C4: `export --format media` (a note's recordings, transcripts, clips,
/// images and PDFs as files with `media.json`, single note and bulk) and the
/// attachment list page of "PDF + attachments" (`--attachments`,
/// `--recordings attach|list`).
final class CLIMediaExportTests: CLITestCase {
    static let renderImages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereRenderTests/Fixtures/images")
    static let pdfFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SemperePDFTests/Fixtures")

    let physics = "aaaaaaaa-1111-4111-8111-000000000001"   // two pages
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"  // one page, nothing attached

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }
    var tone: String { Self.fixtures.appendingPathComponent("audio/tone-aac.m4a").path }
    var clip: String { Self.fixtures.appendingPathComponent("video/clip-h264.mp4").path }
    var poster: String { Self.fixtures.appendingPathComponent("video/poster.jpg").path }
    var jpeg: String { Self.renderImages.appendingPathComponent("metadata.jpg").path }
    var pdf: String { Self.pdfFixtures.appendingPathComponent("rotated.pdf").path }

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

    /// The vault with, on Physics: a placed recording "Lecture" (card on page
    /// 2) with a transcript, an image, a two-page PDF and a video clip.
    func setUpMedia() throws -> [String] {
        _ = try makeVault()
        let args = ["--vault", vaultPath, "--identity", keyPath]
        try ok(["attach", "recording", physics, tone, "--title", "Lecture", "--place", "--page", "2"] + args)
        let rid = try XCTUnwrap(try vault().reconstruct(noteId: UUID(uuidString: physics)!).recordings.first?.id)
        let t = Transcript(recording: rid, engine: "test-1", language: "en-US", created: Date(timeIntervalSince1970: 0),
                           segments: [.init(start: 0, end: 2, text: "Linear maps and kernels.")])
        try t.encoded().write(to: URL(fileURLWithPath: path("t.json")))
        try ok(["attach", "transcript", physics, rid.uuidString.lowercased(), path("t.json")] + args)
        try ok(["attach", "image", physics, jpeg] + args)
        try ok(["attach", "pdf", physics, pdf, "--after", "2"] + args)
        try ok(["attach", "video", physics, clip, "--poster", poster] + args)
        return args
    }

    func manifest(_ folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("media.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func onlyFolder(_ dir: String) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 1, "\(names)")
        return URL(fileURLWithPath: dir).appendingPathComponent(try XCTUnwrap(names.first))
    }

    // MARK: --format media

    func testMediaWritesEveryKindWithAManifest() throws {
        let args = try setUpMedia()
        let r = try cli(["export", physics, "--format", "media", "--out", path("media"), "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.err, "", "nothing left out")
        let folder = try onlyFolder(path("media"))
        XCTAssertTrue(folder.lastPathComponent.hasSuffix("-aaaaaaaa"), folder.lastPathComponent)
        let written = try XCTUnwrap(((r.json as? [[String: Any]])?.first)?["files"] as? [String])
        XCTAssertEqual(written.count, 6, "audio, transcript, video, image, PDF, media.json: \(written)")
        XCTAssertTrue(written.last?.hasSuffix("/media.json") ?? false)

        let m = try manifest(folder)
        XCTAssertEqual(m["format"] as? String, "sempere-media/1")
        XCTAssertEqual(m["note"] as? String, physics)
        let files = try XCTUnwrap(m["files"] as? [[String: Any]])
        XCTAssertEqual(files.compactMap { $0["kind"] as? String }, ["recording", "video", "image", "pdf"])
        let rec = files[0]
        let audioName = try XCTUnwrap(rec["file"] as? String)
        XCTAssertTrue(audioName.hasSuffix("-Recording-1-Lecture.m4a"), audioName)
        XCTAssertEqual(rec["title"] as? String, "Lecture")
        XCTAssertEqual(rec["pages"] as? [Int], [2])
        XCTAssertNotNil(rec["duration"] as? Double)
        XCTAssertNotNil(rec["started"] as? String)
        XCTAssertEqual(rec["transcript"] as? String, audioName.replacingOccurrences(of: ".m4a", with: ".txt"))
        // The audio byte for byte; the transcript as text.
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(audioName)),
                       try Data(contentsOf: URL(fileURLWithPath: tone)))
        let text = try String(contentsOf: folder.appendingPathComponent(try XCTUnwrap(rec["transcript"] as? String)), encoding: .utf8)
        XCTAssertTrue(text.contains("Linear maps and kernels."), text)

        XCTAssertTrue((files[1]["file"] as? String)?.hasSuffix("-Video-1.mp4") ?? false)
        XCTAssertEqual(files[1]["type"] as? String, "video/mp4")
        XCTAssertTrue((files[2]["file"] as? String)?.hasSuffix("-Image-1.jpg") ?? false)
        XCTAssertEqual(files[2]["pages"] as? [Int], [1])
        XCTAssertTrue((files[3]["file"] as? String)?.hasSuffix("-PDF-1.pdf") ?? false)
        XCTAssertEqual(files[3]["pages"] as? [Int], [3, 4], "the PDF's two pages were inserted after page 2")
        for f in files {
            let name = try XCTUnwrap(f["file"] as? String)
            let size = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))[.size]
                                     as? NSNumber)
            XCTAssertEqual(f["size"] as? Int, size.intValue, name)
        }
        // The PDF as stored, a JPEG without its EXIF block.
        let pdfOut = try Data(contentsOf: folder.appendingPathComponent(try XCTUnwrap(files[3]["file"] as? String)))
        XCTAssertTrue(pdfOut.starts(with: Data("%PDF".utf8)))
        let jpegOut = try Data(contentsOf: folder.appendingPathComponent(try XCTUnwrap(files[2]["file"] as? String)))
        XCTAssertTrue(jpegOut.starts(with: [0xFF, 0xD8]))
        XCTAssertNil(jpegOut.range(of: Data("Exif".utf8)), "metadata removed by default")

        // Plain text names every file.
        let plain = try cli(["export", physics, "--format", "media", "--out", path("media2")] + args)
        XCTAssertEqual(plain.status, 0, plain.err)
        XCTAssertEqual(plain.out.split(separator: "\n").filter { $0.hasPrefix("Wrote ") }.count, 6, plain.out)
    }

    func testMediaOfANoteWithoutMediaWritesNothing() throws {
        _ = try makeVault()
        let args = ["--vault", vaultPath, "--identity", keyPath]
        let r = try cli(["export", groceries, "--format", "media", "--out", path("media"), "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("no recordings, videos, images or PDFs to export"), r.err)
        XCTAssertEqual(((r.json as? [[String: Any]])?.first)?["files"] as? [String], [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("media")), [])
    }

    func testMediaOptionsAreValidated() throws {
        _ = try makeVault()
        let args = ["--vault", vaultPath, "--identity", keyPath]
        for bad in [["--no-paper"], ["--merge"], ["--recordings", "attach"], ["--images", "png"], ["--breaks", "fixed"]] {
            let r = try cli(["export", physics, "--format", "media", "--out", path("m")] + bad + args)
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        XCTAssertEqual(try cli(["export", physics, "--format", "svg", "--recordings", "list", "--out", path("s")] + args).status, 2)
        XCTAssertEqual(try cli(["export", physics, "--format", "pdf", "--videos", "list", "--out", path("s.pdf")] + args).status, 2)
    }

    func testBulkMediaSkipsNotesWithoutMediaAndResumes() throws {
        let args = try setUpMedia()
        let r = try cli(["export", "--all", "--format", "media", "--layout", "notebooks", "--out", path("bulk"), "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let notes = try XCTUnwrap(r.json as? [[String: Any]])
        XCTAssertEqual(notes.compactMap { $0["note"] as? String }, [physics], "only the note with media")
        let files = try XCTUnwrap(notes.first?["files"] as? [String])
        XCTAssertEqual(files.count, 6)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        XCTAssertTrue(files.contains { $0.hasSuffix("/media.json") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("bulk/.sempere-export-bulk.json")))

        // A re-run skips the unchanged note; a change exports it again.
        let again = try cli(["export", "--all", "--format", "media", "--layout", "notebooks", "--out", path("bulk")] + args)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("Unchanged "), again.out)
        XCTAssertTrue(again.out.contains("0 note(s) exported, 1 unchanged"), again.out)
        let rid = try XCTUnwrap(try vault().reconstruct(noteId: UUID(uuidString: physics)!).recordings.first?.id)
        try ok(["recordings", "rename", physics, rid.uuidString.lowercased(), "Lecture two"] + args)
        let third = try cli(["export", "--all", "--format", "media", "--layout", "notebooks", "--out", path("bulk"), "--json"] + args)
        XCTAssertEqual(third.status, 0, third.err)
        let renamed = try XCTUnwrap(((third.json as? [[String: Any]])?.first)?["files"] as? [String])
        XCTAssertTrue(renamed.contains { $0.hasSuffix("-Recording-1-Lecture-two.m4a") }, "\(renamed)")
        XCTAssertFalse(renamed.contains { $0.hasSuffix("-Recording-1-Lecture.m4a") })
        let leftover = files.first { $0.hasSuffix("-Recording-1-Lecture.m4a") }!
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover), "the earlier name is removed")

        // A zip holds the same tree.
        let zip = try cli(["export", "--all", "--format", "media", "--zip", "--out", path("media.zip")] + args)
        XCTAssertEqual(zip.status, 0, zip.err)
        let archive = try Data(contentsOf: URL(fileURLWithPath: path("media.zip")))
        XCTAssertNotNil(archive.range(of: Data("/media.json".utf8)))
        XCTAssertNotNil(archive.range(of: try Data(contentsOf: URL(fileURLWithPath: tone))), "stored entries")
    }

    // MARK: The attachment list page

    func pdfText(_ file: String) throws -> String? {
        guard let tool = ExternalTool.find("pdftotext") else { return nil }
        return String(decoding: try ExternalTool.run(tool, ["-layout", file, "-"]).out, as: UTF8.self)
    }

    func count(_ needle: String, in data: Data) -> Int {
        var n = 0
        var range = data.startIndex..<data.endIndex
        while let r = data.range(of: Data(needle.utf8), in: range) {
            n += 1
            range = r.upperBound..<data.endIndex
        }
        return n
    }

    func testAttachmentsEndWithALinkedListPage() throws {
        let args = try setUpMedia()
        let out = path("attached.pdf")
        let r = try cli(["export", physics, "--format", "pdf", "--attachments", "--out", out, "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.err, "", "no warning")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        // Three embedded files (audio, transcript, clip): each linked once from the list.
        XCTAssertEqual(count("/Type /Filespec", in: bytes), 3)
        XCTAssertEqual(count("/Subtype /FileAttachment", in: bytes), 3)
        // Links to the pages: the recording's card (2), and the clip's (1).
        XCTAssertEqual(count("/Subtype /Link", in: bytes), 3, "recording, transcript and clip rows")
        let plain = try Data(contentsOf: URL(fileURLWithPath: try {
            let p = path("plain.pdf")
            try ok(["export", physics, "--format", "pdf", "--out", p] + args)
            return p
        }()))
        XCTAssertEqual(count("/Type /Page ", in: bytes), count("/Type /Page ", in: plain) + 1, "one list page")
        XCTAssertEqual(count("/Subtype /Link", in: plain), 0)
        if let text = try pdfText(out) {
            let list = text.components(separatedBy: "\u{0C}").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.last ?? ""
            XCTAssertTrue(list.contains("Attachments"), list)
            XCTAssertTrue(list.contains("Recording") && list.contains("Lecture"), list)
            XCTAssertTrue(list.contains("Transcript of Lecture"), list)
            XCTAssertTrue(list.contains("Video 1"), list)
            XCTAssertTrue(list.contains("Duration") && list.contains("Size"), list)
            XCTAssertTrue(list.contains(" kB"), list)
        }
    }

    func testRecordingsListAddsThePageWithoutEmbedding() throws {
        let args = try setUpMedia()
        let out = path("listed.pdf")
        let r = try cli(["export", physics, "--format", "pdf", "--recordings", "list", "--out", out] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertEqual(count("/EmbeddedFiles", in: bytes), 0)
        XCTAssertEqual(count("/Subtype /FileAttachment", in: bytes), 0)
        XCTAssertGreaterThan(count("/Subtype /Link", in: bytes), 0)
        if let text = try pdfText(out) {
            XCTAssertTrue(text.contains("Attachments") && text.contains("Lecture"), text)
            XCTAssertFalse(text.contains("not embedded"), "nothing was asked to be embedded")
        }
        // `list,attach` is `attach`.
        let both = try cli(["export", physics, "--format", "pdf", "--recordings", "list,attach", "--out", path("both.pdf")] + args)
        XCTAssertEqual(both.status, 0, both.err)
        XCTAssertEqual(count("/Subtype /FileAttachment", in: try Data(contentsOf: URL(fileURLWithPath: path("both.pdf")))), 2,
                       "the audio and the transcript; the clip is listed, not embedded")
    }

    func testBulkPDFWithAttachmentsHasTheListPage() throws {
        let args = try setUpMedia()
        let r = try cli(["export", "--all", "--format", "pdf", "--attachments", "--out", path("bulk"), "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let notes = try XCTUnwrap(r.json as? [[String: Any]])
        let file = try XCTUnwrap(notes.first { $0["note"] as? String == physics }?["files"] as? [String]).first
        let bytes = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(file)))
        XCTAssertEqual(count("/Subtype /FileAttachment", in: bytes), 3)
        // A note without recordings or clips gets no list page.
        let other = try XCTUnwrap(notes.first { $0["note"] as? String == groceries }?["files"] as? [String]).first
        XCTAssertEqual(count("/Subtype /Link", in: try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(other)))), 0)
    }
}
