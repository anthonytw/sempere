import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere attach video`, `items poster`, `items list` and the exports of a
/// video item, end to end through the binary (format.md §8.2.7, docs/cli.md
/// "Video").
final class CLIVideoTests: CLITestCase {
    static let video = fixtures.appendingPathComponent("video")

    let physics = "aaaaaaaa-1111-4111-8111-000000000001"   // two pages
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"  // one page

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }

    func setUpVault() throws -> [String] {
        _ = try makeVault()
        return ["--vault", vaultPath, "--identity", keyPath]
    }

    func clip(_ name: String) -> String { Self.video.appendingPathComponent(name).path }

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

    func blobFiles(_ note: String) -> [String] {
        let dir = URL(fileURLWithPath: vaultPath).appendingPathComponent("notes/\(note)/att")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: attach video

    func testAttachVideoWithAPosterWritesBlobsThenOneDelta() throws {
        let args = try setUpVault()
        let before = try revisionCount(physics)
        let out = try ok(["attach", "video", physics, clip("clip-h264.mp4"), "--poster", clip("poster.jpg"), "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1, "one delta")
        XCTAssertEqual(out["metadataRemoved"] as? Int, 1)
        let item = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "video")
        XCTAssertEqual(item["codec"] as? String, "h264")
        XCTAssertEqual(item["pixelSize"] as? [Double], [160, 90])
        XCTAssertEqual(item["frame"] as? [Double], [66, 36, 480, 270], "fitted at 480 pt wide, centred, a margin from the top")
        XCTAssertNotNil(item["poster"])
        XCTAssertNil(item["videoRotation"])

        let files = blobFiles(physics)
        XCTAssertEqual(files.filter { $0.hasSuffix(".video.age") }.count, 1, "\(files)")
        XCTAssertEqual(files.filter { $0.hasSuffix(".image.age") }.count, 1, "\(files)")
        XCTAssertEqual(try cli(["blobs", "verify", physics] + args).status, 0)

        // The stored clip is the file with its location blanked, the same length.
        let ref = try XCTUnwrap(try state(physics).pages[0].items.first?.blob)
        let extracted = try cli(["blobs", "extract", physics, ref.sha256] + args)
        XCTAssertEqual(extracted.status, 0, extracted.err)
        let original = try Data(contentsOf: URL(fileURLWithPath: clip("clip-h264.mp4")))
        XCTAssertEqual(extracted.outData.count, original.count)
        XCTAssertNil(extracted.outData.range(of: Data("48.8584".utf8)))
        XCTAssertNotNil(original.range(of: Data("48.8584".utf8)))

        // Listed by items list (human and JSON) and notes show.
        let list = try cli(["items", "list", physics] + args)
        XCTAssertTrue(list.out.contains("video") && list.out.contains("+poster"), list.out)
        let rows = try XCTUnwrap(try cli(["items", "list", physics, "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(rows.first?["kind"] as? String, "video")
        XCTAssertEqual(rows.first?["duration"] as? Double ?? 0, 1, accuracy: 0.1)
        let show = try cli(["notes", "show", physics] + args)
        XCTAssertTrue(show.out.contains("video/mp4"), show.out)
    }

    func testKeepMetadataRotationAndPlacement() throws {
        let args = try setUpVault()
        let kept = try ok(["attach", "video", groceries, clip("clip-hevc.mov"), "--keep-metadata", "--no-poster",
                           "--at", "10,20", "--width", "128", "--json"] + args)
        XCTAssertNil(kept["metadataRemoved"])
        let item = try XCTUnwrap(try state(groceries).pages[0].items.first)
        XCTAssertEqual(item.blob?.type, "video/quicktime")
        XCTAssertEqual(item.codec, "hevc")
        XCTAssertEqual(item.frame, Rect(x: 10, y: 20, w: 128, h: 72))
        XCTAssertNil(item.poster)
        let extracted = try cli(["blobs", "extract", groceries, try XCTUnwrap(item.blob).sha256] + args)
        XCTAssertEqual(extracted.outData, try Data(contentsOf: URL(fileURLWithPath: clip("clip-hevc.mov"))))

        _ = try ok(["attach", "video", groceries, clip("clip-h264-rotated.mp4"), "--no-poster", "--frame", "0,0,90,160",
                    "--rotation", "15", "--json"] + args)
        let rotated = try XCTUnwrap(try state(groceries).pages[0].items.first { $0.videoRotation != nil })
        XCTAssertEqual(rotated.videoRotation, 270)
        XCTAssertEqual(rotated.pixelSize, Size(w: 90, h: 160))
        XCTAssertEqual(rotated.rotation, 15)
    }

    func testRefusalsWriteNothing() throws {
        let args = try setUpVault()
        let revisions = try revisionCount(physics)
        func fails(_ extra: [String], _ message: String, status: Int32 = 1, file: StaticString = #filePath, line: UInt = #line) throws {
            let r = try cli(["attach", "video"] + extra + args)
            XCTAssertEqual(r.status, status, r.out, file: file, line: line)
            XCTAssertTrue(r.err.contains(message), "expected '\(message)' in: \(r.err)", file: file, line: line)
        }
        try fails([physics, clip("clip-mpeg4.mp4")], "not H.264 or HEVC")
        try fails([physics, clip("clip-fragmented.mp4")], "fragmented")
        try fails([physics, clip("poster.jpg")], "not an MP4 or QuickTime")
        try fails([physics, path("missing.mp4")], "cannot read")
        try fails([physics, clip("clip-h264.mp4"), "--poster", clip("clip-h264.mp4")], "JPEG")
        try fails([physics, clip("clip-h264.mp4"), "--page", "3"], "no page 3")
        try fails([physics, clip("clip-h264.mp4"), "--no-poster", "--poster", clip("poster.jpg")], "--no-poster", status: 2)
        XCTAssertEqual(try revisionCount(physics), revisions)
        XCTAssertTrue(blobFiles(physics).isEmpty, "\(blobFiles(physics))")
        #if !canImport(AVFoundation)
        try fails([physics, clip("clip-h264.mp4"), "--poster-time", "0.2"], "needs macOS")
        #endif
    }

    func testDryRunWritesNothing() throws {
        let args = try setUpVault()
        let revisions = try revisionCount(physics)
        let out = try ok(["attach", "video", physics, clip("clip-h264-faststart.mp4"), "--poster", clip("poster.jpg"),
                          "--dry-run", "--json"] + args)
        XCTAssertEqual(out["dryRun"] as? Bool, true)
        XCTAssertNotNil(out["blob"])
        XCTAssertEqual(try revisionCount(physics), revisions)
        XCTAssertTrue(blobFiles(physics).isEmpty)
    }

    #if !canImport(AVFoundation)
    func testWithoutADecoderThereIsNoPoster() throws {
        let args = try setUpVault()
        _ = try ok(["attach", "video", physics, clip("clip-h264.mp4"), "--json"] + args)
        XCTAssertNil(try state(physics).pages[0].items.first?.poster)
    }
    #else
    func testOnMacOSThePosterIsTakenFromTheClip() throws {
        let args = try setUpVault()
        _ = try ok(["attach", "video", physics, clip("clip-h264.mp4"), "--poster-time", "0.2", "--json"] + args)
        let poster = try XCTUnwrap(try state(physics).pages[0].items.first?.poster)
        XCTAssertEqual(poster.type, "image/jpeg")
    }
    #endif

    // MARK: items poster

    func testItemsPosterSetsAndRemovesTheRegister() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "video", physics, clip("clip-h264.mp4"), "--no-poster", "--json"] + args)
        let id = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let before = try revisionCount(physics)
        let set = try ok(["items", "poster", physics, String(id.prefix(8)), clip("poster.jpg"), "--json"] + args)
        XCTAssertEqual(set["changed"] as? Bool, true)
        XCTAssertEqual(try revisionCount(physics), before + 1)
        XCTAssertEqual(try state(physics).pages[0].items[0].poster?.type, "image/jpeg")
        // The same poster again changes nothing.
        let again = try ok(["items", "poster", physics, id, clip("poster.jpg"), "--json"] + args)
        XCTAssertEqual(again["changed"] as? Bool, false)
        XCTAssertEqual(try revisionCount(physics), before + 1)
        _ = try ok(["items", "poster", physics, id, "--remove", "--json"] + args)
        XCTAssertNil(try state(physics).pages[0].items[0].poster)
        XCTAssertEqual(try revisionCount(physics), before + 2)
        // Not a video; no image given.
        _ = try ok(["attach", "text", physics, "hello", "--json"] + args)
        let text = try XCTUnwrap(try state(physics).pages[0].items.first { $0.kind == .text })
        let r = try cli(["items", "poster", physics, text.id.uuidString, clip("poster.jpg")] + args)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("not a video"), r.err)
        XCTAssertEqual(try cli(["items", "poster", physics, id] + args).status, 2)
    }

    #if !canImport(AVFoundation)
    /// Gap audit GA-53: without AVFoundation `--from-clip` is refused (exit 1) and nothing is written.
    func testItemsPosterFromClipIsRefusedWithoutAVFoundation() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "video", physics, clip("clip-h264.mp4"), "--no-poster", "--json"] + args)
        let id = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let before = try revisionCount(physics)
        let blobs = blobFiles(physics)
        let r = try cli(["items", "poster", physics, id, "--from-clip"] + args)
        XCTAssertEqual(r.status, 1, r.err)
        XCTAssertTrue(r.err.contains("--from-clip needs macOS"), r.err)
        XCTAssertEqual(try revisionCount(physics), before)
        XCTAssertEqual(blobFiles(physics), blobs)
        XCTAssertNil(try state(physics).pages[0].items.first?.poster)
    }
    #endif

    func testCopyingAVideoCopiesItsClipAndPoster() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "video", physics, clip("clip-h264.mp4"), "--poster", clip("poster.jpg"), "--json"] + args)
        let id = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let copy = try cli(["items", "copy", physics, id, "--to", groceries, "--json"] + args)
        XCTAssertEqual(copy.status, 0, copy.err)
        XCTAssertEqual(blobFiles(groceries).count, 2, "clip and poster are copied: \(blobFiles(groceries))")
        XCTAssertEqual(try cli(["blobs", "verify", groceries] + args).status, 0)
    }

    // MARK: export

    func testExportsDrawThePosterAndAttachOrLinkTheClip() throws {
        let args = try setUpVault()
        _ = try ok(["attach", "video", groceries, clip("clip-h264.mp4"), "--poster", clip("poster.jpg"), "--json"] + args)
        _ = try ok(["attach", "video", groceries, clip("clip-hevc.mov"), "--no-poster", "--at", "40,400", "--json"] + args)

        // Plain PDF: the poster as an image, the clip left out (said so), the poster-less one a placeholder.
        let plain = try cli(["export", groceries, "--format", "pdf", "--out", path("plain.pdf")] + args)
        XCTAssertEqual(plain.status, 0, plain.err)
        XCTAssertTrue(plain.err.contains("2 video clips shown as poster only"), plain.err)
        XCTAssertTrue(plain.err.contains("video without a poster frame"), plain.err)
        let plainBytes = try Data(contentsOf: URL(fileURLWithPath: path("plain.pdf")))
        XCTAssertNotNil(plainBytes.range(of: Data("/Subtype /Image".utf8)))
        XCTAssertNil(plainBytes.range(of: Data("/EmbeddedFile".utf8)))

        // PDF + attachments: both clips embedded byte for byte as stored (location already removed).
        let attached = try cli(["export", groceries, "--format", "pdf", "--attachments", "--out", path("att.pdf"), "--json"] + args)
        XCTAssertEqual(attached.status, 0, attached.err)
        XCTAssertEqual(((attached.json as? [[String: Any]])?.first)?["videos"] as? Int, 2)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path("att.pdf")))
        XCTAssertNotNil(bytes.range(of: Data("/Subtype /video#2Fmp4".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("/Subtype /video#2Fquicktime".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("/PageMode /UseAttachments".utf8)))
        XCTAssertNil(bytes.range(of: Data("48.8584".utf8)))
        let state = try state(groceries)
        let stored = try vault().readBlob(note: UUID(uuidString: groceries)!, try XCTUnwrap(state.pages[0].items.first?.blob))
        XCTAssertNotNil(bytes.range(of: stored), "the clip is embedded unchanged")
        XCTAssertEqual(try cli(["export", groceries, "--format", "pdf", "--videos", "attach", "--out", path("v.pdf")] + args).status, 0)
        XCTAssertEqual(try cli(["export", groceries, "--format", "svg", "--videos", "attach", "--out", path("x")] + args).status, 2)

        // SVG and PNG draw the poster and the play mark.
        XCTAssertEqual(try cli(["export", groceries, "--format", "svg", "--out", path("svg")] + args).status, 0)
        let svgName = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path("svg")).first { $0.hasSuffix(".svg") })
        let svg = try String(contentsOfFile: path("svg/" + svgName), encoding: .utf8)
        XCTAssertTrue(svg.contains("<image"), "the poster")
        XCTAssertTrue(svg.contains("<circle"), "the play mark")
        XCTAssertEqual(try cli(["export", groceries, "--format", "png", "--out", path("png")] + args).status, 0)

        // Markdown and HTML: each clip written once next to the note, its location removed, and linked.
        for format in ["markdown", "html"] {
            let tree = try cli(["export", "--all", "--format", format, "--out", path(format)] + args)
            XCTAssertEqual(tree.status, 0, "\(format): \(tree.err)")
            let dir = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path(format)).first { $0.hasPrefix("Groceries") && $0.hasSuffix("-assets") })
            let assets = try FileManager.default.contentsOfDirectory(atPath: path("\(format)/\(dir)")).sorted()
            XCTAssertEqual(assets, ["video-1.mp4", "video-2.mov"], format)
            let mov = try Data(contentsOf: URL(fileURLWithPath: path("\(format)/\(dir)/video-2.mov")))
            XCTAssertNil(mov.range(of: Data("48.8584".utf8)), "\(format): metadata removed on export")
            let page = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: path(format))
                .first { $0.hasPrefix("Groceries") && $0.hasSuffix(format == "html" ? ".html" : ".md") })
            let text = try String(contentsOfFile: path("\(format)/\(page)"), encoding: .utf8)
            XCTAssertTrue(text.contains("\(dir)/video-1.mp4"), "\(format) links the clip")
            if format == "html" { XCTAssertTrue(text.contains("<video controls")) }
            // A second run changes nothing.
            let again = try cli(["export", "--all", "--format", format, "--out", path(format), "--json"] + args)
            XCTAssertEqual(again.status, 0)
            let rows = try XCTUnwrap(again.json as? [[String: Any]])
            XCTAssertEqual(rows.flatMap { ($0["changed"] as? [String]) ?? [] }, [], "\(format): nothing rewritten")
        }
    }
}
