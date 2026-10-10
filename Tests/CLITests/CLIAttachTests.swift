import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere attach …`, `import pdf`, `search` over typed text and transcripts,
/// and `export` of every item kind, end to end through the binary
/// (docs/attachments.md §14 task F, docs/cli.md "Attachments").
final class CLIAttachTests: CLITestCase {
    static let renderImages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereRenderTests/Fixtures/images")
    static let pdfFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SemperePDFTests/Fixtures")
    static let audio = fixtures.appendingPathComponent("audio")

    let physics = "aaaaaaaa-1111-4111-8111-000000000001"   // two pages
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"  // one page

    var vaultPath: String { path("mine.sempere") }
    var keyPath: String { path("mine.sempere.key") }

    /// Creates the test vault and returns the arguments every command takes.
    func setUpVault() throws -> [String] {
        _ = try makeVault()
        return ["--vault", vaultPath, "--identity", keyPath]
    }

    func image(_ name: String) -> String { Self.renderImages.appendingPathComponent(name).path }
    func pdf(_ name: String) -> String { Self.pdfFixtures.appendingPathComponent(name).path }
    func audio(_ name: String) -> String { Self.audio.appendingPathComponent(name).path }

    /// Runs a command that must succeed and returns its JSON object.
    @discardableResult
    func ok(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let r = try cli(args)
        XCTAssertEqual(r.status, 0, "\(args.prefix(3)): \(r.err)", file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    func state(_ note: String) throws -> NoteState {
        let vault = try Vault.open(at: URL(fileURLWithPath: vaultPath), identities: [try readIdentityFor(keyPath)])
        return try vault.reconstruct(noteId: UUID(uuidString: note)!)
    }

    func readIdentityFor(_ path: String) throws -> NativeIdentity {
        try IdentityFile.parse(String(contentsOfFile: path, encoding: .utf8))
    }

    func revisionCount(_ note: String) throws -> Int {
        let vault = try Vault.open(at: URL(fileURLWithPath: vaultPath), identities: [try readIdentityFor(keyPath)])
        return try vault.loadNote(UUID(uuidString: note)!).revisions.count
    }

    func blobFiles(_ note: String) -> [String] {
        let dir = URL(fileURLWithPath: vaultPath).appendingPathComponent("notes/\(note)/att")
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: attach image

    func testAttachImageWritesOneDeltaAndTheStrippedBlob() throws {
        let args = try setUpVault()
        let before = try revisionCount(physics)
        let out = try ok(["attach", "image", "Physics / Week 3", image("metadata.jpg"), "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1, "one delta")
        XCTAssertNotNil(out["file"] as? String)
        XCTAssertEqual(out["dryRun"] as? Bool, false)
        let placed = try XCTUnwrap((out["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(placed["page"] as? Int, 1)
        let item = try XCTUnwrap(placed["item"] as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "image")
        XCTAssertEqual(item["orientation"] as? Int, 6)
        XCTAssertEqual(item["pixelSize"] as? [Double], [45, 61])
        // 1 pixel per point, centred across the 612 pt page, a 36 pt margin from the top.
        XCTAssertEqual(item["frame"] as? [Double], [283.5, 36, 45, 61])
        let blob = try XCTUnwrap(out["blob"] as? [String: Any])
        XCTAssertEqual(blob["type"] as? String, "image/jpeg")

        // The note has the item, the blob verifies, and its bytes are the original without metadata.
        let note = try state(physics)
        XCTAssertEqual(note.pages[0].items.map(\.kind), [.image])
        XCTAssertEqual(try cli(["blobs", "verify", physics] + args).status, 0)
        let sha = try XCTUnwrap(blob["sha256"] as? String)
        let extracted = try cli(["blobs", "extract", physics, sha] + args)
        XCTAssertEqual(extracted.status, 0, extracted.err)
        XCTAssertNil(extracted.outData.range(of: Data("synthetic comment".utf8)))
        XCTAssertNil(extracted.outData.range(of: Data("Exif".utf8)))

        // Listed by notes show, human and JSON.
        let show = try cli(["notes", "show", physics] + args)
        XCTAssertTrue(show.out.contains("Items (1):") && show.out.contains("image/jpeg"), show.out)
    }

    /// `items replace`: the app's Replace Image. The new picture is stored
    /// (stripped), then one delta removes the old image and adds the new one
    /// with `parent`, fitted into the old frame; text boxes are refused.
    func testItemsReplaceSwapsThePictureInOneDelta() throws {
        let args = try setUpVault()
        let placed = try ok(["attach", "image", physics, image("rgb8.png"), "--frame", "10,20,230,170", "--rotation", "90",
                             "--json"] + args)
        let old = try XCTUnwrap(((placed["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let before = try revisionCount(physics)
        let out = try ok(["items", "replace", physics, String(old.prefix(13)), image("metadata.jpg"), "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1, "one delta")
        XCTAssertEqual(out["changed"] as? Bool, true)
        XCTAssertEqual(out["replaced"] as? String, old)
        let newID = try XCTUnwrap(out["item"] as? String)
        let items = try state(physics).pages[0].items
        XCTAssertFalse(items.contains { $0.id.uuidString.lowercased() == old })
        let new = try XCTUnwrap(items.first { $0.id.uuidString.lowercased() == newID })
        XCTAssertEqual(new.parent?.uuidString.lowercased(), old)
        XCTAssertEqual(new.blob?.type, "image/jpeg")
        XCTAssertEqual(new.orientation, 6)
        XCTAssertEqual(new.rotation, 90)
        XCTAssertNil(new.crop)
        // 45 × 61 (upright) fitted into 230 × 170, centred.
        XCTAssertEqual(new.frame.h, 170, accuracy: 0.001)
        XCTAssertEqual(new.frame.w, 170 * 45 / 61, accuracy: 0.001)
        XCTAssertEqual(new.frame.x + new.frame.w / 2, 125, accuracy: 0.001)
        XCTAssertEqual(try cli(["blobs", "verify", physics] + args).status, 0)
        let sha = try XCTUnwrap(new.blob?.sha256)
        XCTAssertNil(try cli(["blobs", "extract", physics, sha] + args).outData.range(of: Data("Exif".utf8)), "stripped")

        // Plain output: the new id on stdout.
        let again = try cli(["items", "replace", physics, newID, image("rgb8.png")] + args)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertEqual(UUID(uuidString: again.out.trimmingCharacters(in: .whitespacesAndNewlines)) != nil, true, again.out)

        let text = try ok(["attach", "text", physics, "Not a picture", "--json"] + args)
        let textID = try XCTUnwrap(((text["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["id"] as? String)
        let count = try revisionCount(physics), blobs = blobFiles(physics).count
        let refused = try cli(["items", "replace", physics, textID, image("rgb8.png")] + args)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("no image"), refused.err)
        XCTAssertEqual(try revisionCount(physics), count, "nothing written")
        XCTAssertEqual(blobFiles(physics).count, blobs, "no blob stored for a refused replace")
    }

    func testKeepMetadataStoresTheOriginalBytes() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "image", physics, image("metadata.jpg"), "--keep-metadata", "--json"] + args)
        let sha = try XCTUnwrap((out["blob"] as? [String: Any])?["sha256"] as? String)
        let extracted = try cli(["blobs", "extract", physics, sha] + args)
        XCTAssertEqual(extracted.outData, try Data(contentsOf: URL(fileURLWithPath: image("metadata.jpg"))))
    }

    func testPlacementOptionsStackingAndPages() throws {
        let args = try setUpVault()
        _ = try ok(["attach", "image", physics, image("rgb8.png"), "--page", "2", "--frame", "10,20,100,50", "--rotation", "90",
                    "--json"] + args)
        _ = try ok(["attach", "image", physics, image("rgb8.png"), "--page", "2", "--at", "5,6", "--width", "40", "--layer", "background", "--json"] + args)
        _ = try ok(["attach", "image", physics, image("baseline-444.jpg"), "--page", "2", "--crop", "0,0,10,10", "--width", "50", "--json"] + args)
        let items = try state(physics).pages[1].items
        XCTAssertEqual(items.count, 3)
        let first = try XCTUnwrap(items.first { $0.rotation == 90 })
        XCTAssertEqual(first.frame, Rect(x: 10, y: 20, w: 100, h: 50))
        XCTAssertEqual(first.layer, .content)
        let background = try XCTUnwrap(items.first { $0.layer == .background })
        XCTAssertEqual(background.frame.x, 5); XCTAssertEqual(background.frame.w, 40)
        let cropped = try XCTUnwrap(items.first { $0.crop != nil })
        XCTAssertEqual(cropped.frame.h, 50, "the crop's aspect, not the image's")
        // Drawing order: background layer first, then by z.
        let order = items.sorted(by: Item.drawsBefore)
        XCTAssertEqual(order.first?.layer, .background)
        XCTAssertTrue(Item.drawsBefore(first, cropped), "the later content item is on top")
        XCTAssertTrue(try state(physics).pages[0].items.isEmpty)
    }

    func testImageFailuresWriteNothing() throws {
        let args = try setUpVault()
        let revisions = try revisionCount(physics)
        func fails(_ extra: [String], _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let r = try cli(["attach", "image"] + extra + args)
            XCTAssertEqual(r.status, 1, r.out, file: file, line: line)
            XCTAssertTrue(r.err.contains(message), "expected '\(message)' in: \(r.err)", file: file, line: line)
        }
        let heic = tmp.appendingPathComponent("photo.heic")
        try (Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 16)).write(to: heic)
        let gif = tmp.appendingPathComponent("a.gif")
        try Data("GIF89a-not-really".utf8).write(to: gif)
        try fails([physics, heic.path], "HEIC")
        try fails([physics, gif.path], "only JPEG and PNG")
        try fails([physics, image("cmyk.jpg")], "CMYK")
        try fails([physics, path("missing.jpg")], "cannot read")
        try fails([physics, image("rgb8.png"), "--page", "3"], "no page 3")
        try fails([physics, image("rgb8.png"), "--frame", "0,0,0,5"], "invalid frame")
        try fails([groceries, image("rgb8.png"), "--rec", "nothing"], "no recording")
        XCTAssertEqual(try cli(["attach", "image", physics, image("rgb8.png"), "--frame", "1,2,3"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "image", physics, image("rgb8.png"), "--frame", "1,2,3,4", "--width", "5"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "image", physics, image("rgb8.png"), "--page", "0"] + args).status, 2)
        // A deleted note is refused, with the way out.
        _ = try ok(["notes", "delete", groceries] + args)
        try fails([groceries, image("rgb8.png")], "undelete")
        XCTAssertEqual(try revisionCount(physics), revisions, "nothing was written")
        XCTAssertEqual(blobFiles(physics), [], "no blob was stored for a placement that failed")
    }

    func testDryRunWritesNothing() throws {
        let args = try setUpVault()
        let revisions = try revisionCount(physics)
        let out = try ok(["attach", "image", physics, image("rgb8.png"), "--dry-run", "--json"] + args)
        XCTAssertEqual(out["dryRun"] as? Bool, true)
        XCTAssertNil(out["file"])
        XCTAssertEqual(((out["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["kind"] as? String, "image")
        XCTAssertEqual(try revisionCount(physics), revisions)
        XCTAssertEqual(blobFiles(physics), [])
        let pdf = try ok(["attach", "pdf", physics, pdf("rotated.pdf"), "--dry-run", "--json"] + args)
        XCTAssertEqual(pdf["pagesAdded"] as? Int, 2)
        XCTAssertEqual(try revisionCount(physics), revisions)
        let text = try ok(["attach", "text", physics, "hello", "--dry-run", "--json"] + args)
        XCTAssertEqual(text["dryRun"] as? Bool, true)
        XCTAssertEqual(try revisionCount(physics), revisions)
    }

    func testHumanOutputPrintsTheItemIdOnStdout() throws {
        let args = try setUpVault()
        let r = try cli(["attach", "image", physics, image("rgb8.png")] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let id = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(UUID(uuidString: id), r.out)
        XCTAssertTrue(r.err.contains("Added image"), r.err)
        XCTAssertEqual(try state(physics).pages[0].items.map { $0.id.uuidString.lowercased() }, [id])
        let q = try cli(["attach", "image", physics, image("rgb8.png"), "-q"] + args)
        XCTAssertEqual(q.err, "")
    }

    // MARK: attach pdf, import pdf

    func testAttachPDFInsertsBackgroundPages() throws {
        let args = try setUpVault()
        let before = try revisionCount(physics)
        let out = try ok(["attach", "pdf", physics, pdf("rotated.pdf"), "--after", "1", "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1, "one delta for the whole PDF")
        XCTAssertEqual(out["pagesAdded"] as? Int, 2)
        let note = try state(physics)
        XCTAssertEqual(note.pages.count, 4)
        XCTAssertTrue(note.pages[0].items.isEmpty && note.pages[3].items.isEmpty)
        let items = note.pages[1...2].compactMap(\.items.first)
        XCTAssertEqual(items.map(\.pageIndex), [0, 1])
        XCTAssertEqual(items.map(\.layer), [.background, .background])
        XCTAssertEqual(items.map(\.blob?.type), ["application/pdf", "application/pdf"])
        XCTAssertEqual(Set(items.compactMap(\.blob?.sha256)).count, 1, "one blob serves both pages")
        XCTAssertEqual(blobFiles(physics).count, 1)
        // 360 × 500 filling a 612 × 792 page: fitted and centred, scaled up.
        XCTAssertEqual(items[0].frame.h, 792, accuracy: 0.01)
        XCTAssertEqual(items[0].frame.w, 570.24, accuracy: 0.01)
        let json = out["items"] as? [[String: Any]]
        XCTAssertEqual(json?.map { $0["page"] as? Int }, [2, 3])
        // The page selection, in the order given, and at the end by default.
        let more = try ok(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "2,1", "--json"] + args)
        XCTAssertEqual(more["pagesAdded"] as? Int, 2)
        let last = try state(physics).pages.suffix(2).compactMap(\.items.first)
        XCTAssertEqual(last.map(\.pageIndex), [1, 0])
        XCTAssertEqual(blobFiles(physics).count, 1, "the same PDF is stored once")
        // Before the first page.
        _ = try ok(["attach", "pdf", groceries, pdf("classic.pdf"), "--pages", "1", "--after", "0"] + args)
        XCTAssertEqual(try state(groceries).pages.first?.items.first?.kind, .pdfPage)
    }

    func testAttachPDFAsAFigure() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "1", "--page", "2", "--frame", "10,10,180,250", "--crop", "0,0,180,250", "--json"] + args)
        XCTAssertNil(out["pagesAdded"])
        let note = try state(physics)
        XCTAssertEqual(note.pages.count, 2, "no page was added")
        let figure = try XCTUnwrap(note.pages[1].items.first)
        XCTAssertEqual(figure.layer, .content)
        XCTAssertEqual(figure.frame, Rect(x: 10, y: 10, w: 180, h: 250))
        XCTAssertEqual(figure.crop, Rect(x: 0, y: 0, w: 180, h: 250))
        XCTAssertEqual(figure.pageSize, Size(w: 360, h: 500))
        // Several pages as one figure, or a figure together with --after, are usage errors.
        XCTAssertEqual(try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--page", "1"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "1", "--page", "1", "--after", "1"] + args).status, 2)
    }

    func testPDFRefusals() throws {
        let args = try setUpVault()
        let revisions = try revisionCount(physics)
        let encrypted = try cli(["attach", "pdf", physics, pdf("encrypted.pdf")] + args)
        XCTAssertEqual(encrypted.status, 1)
        XCTAssertTrue(encrypted.err.contains("encrypted"), encrypted.err)
        let notPDF = try cli(["attach", "pdf", physics, image("rgb8.png")] + args)
        XCTAssertEqual(notPDF.status, 1)
        let missing = try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "3"] + args)
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.err.contains("no page 3"), missing.err)
        XCTAssertEqual(try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "2-1"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "0"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "1-99999999999"] + args).status, 1)
        XCTAssertEqual(try revisionCount(physics), revisions)
        XCTAssertEqual(blobFiles(physics), [])
        // Pages cannot be inserted into a pageless note, only placed as figures.
        _ = try ok(["notes", "layout", physics, "pageless"] + args)
        let pageless = try cli(["attach", "pdf", physics, pdf("rotated.pdf")] + args)
        XCTAssertEqual(pageless.status, 1)
        XCTAssertTrue(pageless.err.contains("pageless"), pageless.err)
        XCTAssertEqual(try cli(["attach", "pdf", physics, pdf("rotated.pdf"), "--pages", "1", "--page", "1", "--frame", "0,0,100,100"] + args).status, 0)
    }

    func testImportPDFMakesANoteWithOnePagePerPDFPage() throws {
        let args = try setUpVault()
        let out = try ok(["import", "pdf", pdf("rotated.pdf"), "--notebook", "School/Math", "--tag", "Slides", "--json"] + args)
        XCTAssertEqual(out["imported"] as? Int, 1)
        let result = try XCTUnwrap((out["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["status"] as? String, "imported")
        XCTAssertEqual(result["pages"] as? Int, 2)
        XCTAssertEqual(result["title"] as? String, "rotated")
        let id = try XCTUnwrap(result["id"] as? String)
        let note = try state(id)
        XCTAssertEqual(note.meta.title, "rotated")
        XCTAssertEqual(note.meta.notebook, "School/Math")
        XCTAssertEqual(note.meta.tags, ["Slides"])
        XCTAssertEqual(note.meta.pageSize, PageSize(width: 360, height: 500))
        XCTAssertEqual(note.meta.paper.kind, .blank)
        XCTAssertEqual(note.pages.count, 2)
        XCTAssertEqual(try revisionCount(id), 1, "the whole note is one delta")
        XCTAssertEqual(note.pages[0].items.first?.frame, Rect(x: 0, y: 0, w: 360, h: 500))
        XCTAssertEqual(note.pages.compactMap { $0.items.first?.pageIndex }, [0, 1])
        XCTAssertEqual(try cli(["blobs", "verify", id] + args).status, 0)
        // The PDF export draws the original pages as backgrounds.
        let exported = try cli(["export", id, "--format", "pdf", "--out", path("slides.pdf")] + args)
        XCTAssertEqual(exported.status, 0, exported.err)
        XCTAssertNotNil(try Data(contentsOf: URL(fileURLWithPath: path("slides.pdf"))).range(of: Data("/Subtype /Form".utf8)))
        // notes list sees it, with its items.
        let list = try XCTUnwrap(try cli(["notes", "list", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(list.first { $0["id"] as? String == id }?["items"] as? Int, 2)
    }

    func testImportPDFOptionsAndPartialFailure() throws {
        let args = try setUpVault()
        let subset = try ok(["import", "pdf", pdf("rotated.pdf"), "--title", "  Two  ", "--pages", "2", "--json"] + args)
        let id = try XCTUnwrap(((subset["notes"] as? [[String: Any]])?.first)?["id"] as? String)
        XCTAssertEqual(try state(id).pages.map { $0.items.first?.pageIndex }, [1])
        XCTAssertEqual(try state(id).meta.title, "Two")
        XCTAssertEqual(try state(id).meta.pageSize, PageSize(width: 180, height: 250))
        // Dry run: nothing is written.
        let notes = try XCTUnwrap(try cli(["notes", "list", "--json"] + args).json as? [Any]).count
        let dry = try ok(["import", "pdf", pdf("classic.pdf"), "--dry-run", "--json"] + args)
        XCTAssertEqual(dry["dryRun"] as? Bool, true)
        XCTAssertEqual((try cli(["notes", "list", "--json"] + args).json as? [Any])?.count, notes)
        // One bad file does not stop the others; exit 1, the good one is imported.
        let mixed = try cli(["import", "pdf", pdf("encrypted.pdf"), pdf("classic.pdf"), "--json"] + args)
        XCTAssertEqual(mixed.status, 1)
        let results = try XCTUnwrap((mixed.json as? [String: Any])?["notes"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["status"] as? String }, ["failed", "imported"])
        XCTAssertTrue((results[0]["reason"] as? String ?? "").contains("encrypted"))
        XCTAssertEqual((mixed.json as? [String: Any])?["failed"] as? Int, 1)
        // --title names one note.
        XCTAssertEqual(try cli(["import", "pdf", pdf("classic.pdf"), pdf("rotated.pdf"), "--title", "x"] + args).status, 2)
        // Quiet prints just the id.
        let quiet = try cli(["import", "pdf", pdf("classic.pdf"), "-q"] + args)
        XCTAssertNotNil(UUID(uuidString: quiet.out.trimmingCharacters(in: .whitespacesAndNewlines)), quiet.out)
    }

    // MARK: attach text and search

    func testAttachTextAndSearchIt() throws {
        let args = try setUpVault()
        let textFile = tmp.appendingPathComponent("note.txt")
        try "Ünïcode héading\nsecond line with kangaroo\n".write(to: textFile, atomically: true, encoding: .utf8)
        let out = try ok(["attach", "text", physics, "--file", textFile.path, "--size", "18", "--bold", "--font", "serif",
                          "--color", "#FF0000", "--align", "center", "--lang", "de", "--page", "2", "--json"] + args)
        let item = try XCTUnwrap(((out["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "text")
        XCTAssertEqual(item["frame"] as? [Double], [36, 36, 540, 43.2])
        let content = try XCTUnwrap(item["text"] as? [String: Any])
        XCTAssertEqual(content["font"] as? String, "serif")
        XCTAssertEqual(content["size"] as? Double, 18)
        XCTAssertEqual(content["color"] as? String, "#FF0000FF")
        XCTAssertEqual(content["align"] as? String, "center")
        XCTAssertEqual(content["lang"] as? String, "de")
        let note = try state(physics)
        XCTAssertEqual(note.pages[1].items.first?.text?.string, "Ünïcode héading\nsecond line with kangaroo", "one trailing newline is the file's")
        XCTAssertEqual(note.pages[1].items.first?.text?.runs.first?.b, true)
        XCTAssertEqual(blobFiles(physics), [], "text is not a blob")

        // Search finds typed text, case and accent insensitive; the table says where.
        let found = try cli(["search", "KANGAROO"] + args)
        XCTAssertEqual(found.status, 0, found.err)
        XCTAssertTrue(found.out.contains("Physics / Week 3") && found.out.contains("p2 text") && found.out.contains("kangaroo"), found.out)
        let json = try XCTUnwrap(try cli(["search", "heading", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["source"] as? String, "text")
        XCTAssertEqual(json[0]["page"] as? Int, 2)
        XCTAssertEqual(json[0]["itemId"] as? String, item["id"] as? String)
        XCTAssertEqual(json[0]["box"] as? [Double], [36, 36, 540, 43.2])
        XCTAssertEqual((json[0]["words"] as? [Any])?.count, 0)
        XCTAssertEqual((try cli(["search", "unicode", "--json"] + args).json as? [[String: Any]])?.count, 1, "accents are ignored")
        // --show-boxes: where the words are inside the text box (GA-07), in the box's frame.
        let boxed = try XCTUnwrap(try cli(["search", "kangaroo", "--show-boxes", "--json"] + args).json as? [[String: Any]])
        let locations = try XCTUnwrap(boxed.first?["locations"] as? [[String: Any]])
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0]["text"] as? String, "kangaroo")
        XCTAssertEqual(locations[0]["itemId"] as? String, item["id"] as? String)
        XCTAssertEqual(locations[0]["n"] as? Int, 1)
        let box = try XCTUnwrap(locations[0]["box"] as? [Double])
        XCTAssertTrue(box[0] >= 36 && box[0] + box[2] <= 36 + 540 && box[1] > 36 + 10, "second line, inside the frame: \(box)")
        let table = try cli(["search", "kangaroo", "--show-boxes"] + args)
        XCTAssertEqual(table.status, 0, table.err)
        // A deleted note is not searched.
        _ = try ok(["notes", "delete", physics] + args)
        XCTAssertEqual((try cli(["search", "kangaroo", "--json"] + args).json as? [Any])?.count, 0)
    }

    func testTextInputRules() throws {
        let args = try setUpVault()
        XCTAssertEqual(try cli(["attach", "text", physics] + args).status, 2, "no text")
        XCTAssertEqual(try cli(["attach", "text", physics, "x", "--file", "y"] + args).status, 2, "both")
        XCTAssertEqual(try cli(["attach", "text", physics, "x", "--size", "0"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "text", physics, "x", "--color", "red"] + args).status, 2)
        let big = tmp.appendingPathComponent("big.txt")
        try String(repeating: "x", count: 70_000).write(to: big, atomically: true, encoding: .utf8)
        let tooLong = try cli(["attach", "text", physics, "--file", big.path] + args)
        XCTAssertEqual(tooLong.status, 1)
        XCTAssertTrue(tooLong.err.contains("65536") || tooLong.err.contains("limit"), tooLong.err)
        let bad = tmp.appendingPathComponent("bad.txt")
        try Data([0x66, 0xFF, 0xFE]).write(to: bad)
        XCTAssertTrue(try cli(["attach", "text", physics, "--file", bad.path] + args).err.contains("UTF-8"))
        let control = try cli(["attach", "text", physics, "a\u{7}b"] + args)
        XCTAssertEqual(control.status, 1)
        XCTAssertEqual(try revisionCount(physics), 2, "nothing was written")
    }

    // MARK: recordings, transcripts

    func testAttachRecordingReadsTheHeader() throws {
        let args = try setUpVault()
        let before = try revisionCount(physics)
        let out = try ok(["attach", "recording", physics, audio("tone-aac.m4a"), "--title", "Lecture 3",
                          "--started", "2026-10-04T16:20:00Z", "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1)
        let recording = try XCTUnwrap(out["recording"] as? [String: Any])
        XCTAssertEqual(recording["codec"] as? String, "aac")
        XCTAssertEqual(recording["sampleRate"] as? Int, 48000)
        XCTAssertEqual(recording["channels"] as? Int, 1)
        XCTAssertEqual(try XCTUnwrap(recording["duration"] as? Double), 2.5, accuracy: 0.05)
        XCTAssertEqual(recording["title"] as? String, "Lecture 3")
        XCTAssertEqual(recording["started"] as? String, "2026-10-04T16:20:00Z")
        XCTAssertEqual((recording["blob"] as? [String: Any])?["type"] as? String, "audio/mp4")
        let note = try state(physics)
        XCTAssertEqual(note.recordings.map(\.title), ["Lecture 3"])
        XCTAssertEqual(try cli(["blobs", "verify", physics] + args).status, 0)
        let show = try cli(["notes", "show", physics] + args)
        XCTAssertTrue(show.out.contains("Recordings (1):") && show.out.contains("\"Lecture 3\"") && show.out.contains("audio/mp4"), show.out)
        // ALAC; overrides win over the header; without --started the file's time minus its length.
        // A fresh copy: the committed file's modification time is the checkout's,
        // which is only "now" on a fresh clone (the test failed on older checkouts).
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("tone-alac-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: audio("tone-alac.m4a")), to: fresh)
        defer { try? FileManager.default.removeItem(at: fresh) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fresh.path)
        let alac = try ok(["attach", "recording", physics, fresh.path, "--codec", "alac-test", "--bit-rate", "123456", "--json"] + args)
        let r2 = try XCTUnwrap(alac["recording"] as? [String: Any])
        XCTAssertEqual(r2["codec"] as? String, "alac-test")
        XCTAssertEqual(r2["bitRate"] as? Int, 123456)
        XCTAssertEqual(r2["channels"] as? Int, 2)
        XCTAssertNil(r2["title"])
        let started = try XCTUnwrap(RFC3339.parse(try XCTUnwrap(r2["started"] as? String)))
        XCTAssertLessThan(abs(started.timeIntervalSinceNow), 3600 + 5, "derived from the file's modification time")
    }

    func testAttachRecordingRefusals() throws {
        let args = try setUpVault()
        let wav = tmp.appendingPathComponent("a.wav")
        try Data("RIFF\0\0\0\0WAVEfmt ".utf8).write(to: wav)
        let notMP4 = try cli(["attach", "recording", physics, wav.path] + args)
        XCTAssertEqual(notMP4.status, 1)
        XCTAssertTrue(notMP4.err.contains("MPEG-4") && notMP4.err.contains("--type"), notMP4.err)
        // With --type it is stored as it is.
        let stored = try ok(["attach", "recording", physics, wav.path, "--type", "audio/wav", "--duration", "3", "--started", "2026-01-01T00:00:00Z", "--json"] + args)
        XCTAssertEqual(((stored["recording"] as? [String: Any])?["blob"] as? [String: Any])?["type"] as? String, "audio/wav")
        XCTAssertEqual(try state(physics).recordings.first?.duration, 3)
        XCTAssertEqual(try cli(["attach", "recording", physics, audio("tone-aac.m4a"), "--type", "video/mp4"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "recording", physics, audio("tone-aac.m4a"), "--started", "yesterday"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "recording", physics, audio("tone-aac.m4a"), "--duration", "-1"] + args).status, 2)
        XCTAssertEqual(try cli(["attach", "recording", physics, path("nope.m4a")] + args).status, 1)
    }

    func transcriptFile(for recording: String, text: String = "Today we look at linear maps and kernels.") throws -> String {
        let t = Transcript(recording: UUID(uuidString: recording)!, engine: "test-engine/1", language: "en",
                           created: Date(timeIntervalSince1970: 1_760_000_000),
                           segments: [.init(start: 1.5, end: 3.0, text: "Welcome back."),
                                      .init(start: 63.2, end: 70, text: text, confidence: 0.9)])
        let url = tmp.appendingPathComponent("t-\(UUID().uuidString.prefix(6)).json")
        try t.encoded().write(to: url)
        return url.path
    }

    /// A transcript whose segment starts at 1e300 seconds is valid (start ≥ 0 and
    /// ordered): `search --transcripts` used to trap converting it to minutes
    /// for the table.
    func testSearchSurvivesAHugeTranscriptTime() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "recording", physics, audio("tone-aac.m4a"), "--started", "2026-10-04T16:20:00Z", "--json"] + args)
        let rid = try XCTUnwrap((out["recording"] as? [String: Any])?["id"] as? String)
        let t = Transcript(recording: UUID(uuidString: rid)!, engine: "test-engine/1", language: "en",
                           created: Date(timeIntervalSince1970: 1_760_000_000),
                           segments: [.init(start: 1e300, end: 1e300, text: "synthetic far future")])
        let url = tmp.appendingPathComponent("huge.json")
        try t.encoded().write(to: url)
        _ = try ok(["attach", "transcript", physics, String(rid.prefix(8)), url.path, "--json"] + args)
        let table = try cli(["search", "future", "--transcripts"] + args)
        XCTAssertEqual(table.status, 0, table.err)
        XCTAssertTrue(table.out.contains("far future"), table.out)
    }

    func testTranscriptAndSearch() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "recording", physics, audio("tone-aac.m4a"), "--title", "Lecture 3", "--started", "2026-10-04T16:20:00Z", "--json"] + args)
        let rid = try XCTUnwrap((out["recording"] as? [String: Any])?["id"] as? String)
        let file = try transcriptFile(for: rid)
        let before = try revisionCount(physics)
        let set = try ok(["attach", "transcript", physics, "Lecture 3", file, "--json"] + args)
        XCTAssertEqual(try revisionCount(physics), before + 1)
        XCTAssertEqual((set["blob"] as? [String: Any])?["type"] as? String, "application/vnd.sempere.transcript+json")
        XCTAssertNotNil(try state(physics).recordings.first?.transcript)
        XCTAssertTrue(try cli(["notes", "show", physics] + args).out.contains("+transcript"))
        XCTAssertEqual(try cli(["blobs", "verify", physics] + args).status, 0)

        // Transcripts are searched only on request; a prefix of the id names the recording too.
        XCTAssertEqual((try cli(["search", "kernels", "--json"] + args).json as? [Any])?.count, 0)
        let hits = try XCTUnwrap(try cli(["search", "KERNELS", "--transcripts", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0]["source"] as? String, "transcript")
        XCTAssertEqual(hits[0]["recordingId"] as? String, rid)
        XCTAssertEqual(hits[0]["recordingTitle"] as? String, "Lecture 3")
        XCTAssertEqual(hits[0]["start"] as? Double, 63.2)
        XCTAssertEqual(hits[0]["engine"] as? String, "test-engine/1")
        XCTAssertNil(hits[0]["page"])
        let table = try cli(["search", "kernels", "--transcripts"] + args)
        XCTAssertTrue(table.out.contains("rec 1:03 Lecture 3") && table.out.contains("linear maps and kernels"), table.out)
        // Replacing it: the new transcript is the one searched.
        _ = try ok(["attach", "transcript", physics, String(rid.prefix(8)), try transcriptFile(for: rid, text: "Replaced wording only."), "--json"] + args)
        XCTAssertEqual((try cli(["search", "kernels", "--transcripts", "--json"] + args).json as? [Any])?.count, 0)
        XCTAssertEqual((try cli(["search", "wording", "--transcripts", "--json"] + args).json as? [Any])?.count, 1)
        // One search covers handwriting, text boxes and transcripts.
        _ = try ok(["attach", "text", physics, "wording in a text box", "--json"] + args)
        let all = try XCTUnwrap(try cli(["search", "wording", "--transcripts", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(Set(all.compactMap { $0["source"] as? String }), ["text", "transcript"])
    }

    func testTranscriptRefusals() throws {
        let args = try setUpVault()
        let out = try ok(["attach", "recording", physics, audio("tone-aac.m4a"), "--started", "2026-10-04T16:20:00Z", "--json"] + args)
        let rid = try XCTUnwrap((out["recording"] as? [String: Any])?["id"] as? String)
        let before = try revisionCount(physics)
        func fails(_ recording: String, _ file: String, _ message: String, line: UInt = #line) throws {
            let r = try cli(["attach", "transcript", physics, recording, file] + args)
            XCTAssertEqual(r.status, 1, r.out, line: line)
            XCTAssertTrue(r.err.contains(message), "expected '\(message)' in: \(r.err)", line: line)
        }
        try fails(rid, try transcriptFile(for: UUID().uuidString.lowercased()), "names recording")
        let junk = tmp.appendingPathComponent("junk.json")
        try Data("{\"format\": \"other\"}".utf8).write(to: junk)
        try fails(rid, junk.path, "invalid transcript")
        try fails("00000000-0000-4000-8000-000000000000", try transcriptFile(for: rid), "no recording")
        try fails(String(rid.prefix(2)), try transcriptFile(for: rid), "give a whole id or at least 4 characters")
        try fails(rid, path("missing.json"), "cannot read")
        XCTAssertEqual(try revisionCount(physics), before)
        XCTAssertEqual(blobFiles(physics).count, 1, "only the audio is stored")
        // A recording link on an item needs a recording that exists.
        let linked = try ok(["attach", "text", physics, "linked", "--rec", String(rid.prefix(8)), "--rec-at", "4.5", "--json"] + args)
        let rec = try XCTUnwrap(((linked["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["rec"] as? [String: Any])
        XCTAssertEqual(rec["id"] as? String, rid)
        XCTAssertEqual(rec["at"] as? Double, 4.5)
    }

    // MARK: export of every item kind

    func testExportCoversEveryItemKind() throws {
        let args = try setUpVault()
        let note = groceries
        _ = try ok(["attach", "pdf", note, pdf("classic.pdf"), "--pages", "1", "--after", "0", "--json"] + args)
        _ = try ok(["attach", "image", note, image("rgb8.png"), "--page", "1", "--frame", "20,20,80,80", "--json"] + args)
        _ = try ok(["attach", "image", note, image("metadata.jpg"), "--page", "1", "--frame", "120,20,60,80", "--json"] + args)
        _ = try ok(["attach", "text", note, "Typed heading: Ünïcode", "--page", "1", "--at", "20,120", "--size", "20", "--bold", "--json"] + args)
        _ = try ok(["attach", "recording", note, audio("tone-aac.m4a"), "--title", "Lecture", "--started", "2026-10-04T16:20:00Z", "--json"] + args)

        // PDF: the original PDF page as a form, the images as image objects, the text drawn, no warnings.
        let pdfOut = try cli(["export", note, "--format", "pdf", "--out", path("o.pdf")] + args)
        XCTAssertEqual(pdfOut.status, 0, pdfOut.err)
        // No placeholders; the one warning says the recording was left out (`--recordings attach` embeds it).
        XCTAssertEqual(pdfOut.err.split(separator: "\n"),
                       ["sempere: warning: bbbbbbbb: 1 recording not exported (--recordings attach embeds them)"])
        let pdfBytes = try Data(contentsOf: URL(fileURLWithPath: path("o.pdf")))
        XCTAssertNotNil(pdfBytes.range(of: Data("/Subtype /Form".utf8)))
        XCTAssertNotNil(pdfBytes.range(of: Data("/Subtype /Image".utf8)))
        XCTAssertNotNil(pdfBytes.range(of: Data("/Type0".utf8)), "text uses an embedded font subset")
        // The merged PDF of all notes works too.
        XCTAssertEqual(try cli(["export", "--all", "--format", "pdf", "--merge", "--out", path("all.pdf")] + args).status, 0)

        // SVG (images as data URIs and as linked assets, text as <text>) and PNG.
        let svg = try cli(["export", note, "--format", "svg", "--pdf-renderer", "none", "--out", path("svg"), "--json"] + args)
        XCTAssertEqual(svg.status, 0, svg.err)
        let svgText = try String(contentsOf: URL(fileURLWithPath: path("svg/\(try exportStem(note))-p001.svg")), encoding: .utf8)
        XCTAssertTrue(svgText.contains("<image"), "images are drawn")
        XCTAssertTrue(svgText.contains("<text"), "text is drawn")
        XCTAssertTrue(svg.err.contains("PDF background page drawn as placeholder"), "no Poppler requested: said so\n\(svg.err)")
        XCTAssertEqual(try cli(["export", note, "--format", "svg", "--assets", path("assets"), "--pdf-renderer", "none", "--out", path("svg2")] + args).status, 0)
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: path("assets"))).isEmpty)
        XCTAssertEqual(try cli(["export", note, "--format", "png", "--pdf-renderer", "none", "--out", path("png")] + args).status, 0)

        // JSON carries the items and the recording; Markdown and HTML trees export without failing.
        let json = try cli(["export", note, "--format", "json", "--out", path("o.json")] + args)
        XCTAssertEqual(json.status, 0, json.err)
        let exported = try String(contentsOf: URL(fileURLWithPath: path("o.json")), encoding: .utf8)
        let compact = exported.replacingOccurrences(of: " ", with: "")
        for needle in ["\"kind\":\"image\"", "\"kind\":\"pdfPage\"", "\"kind\":\"text\"", "\"recordings\""] {
            XCTAssertTrue(compact.contains(needle), "json has \(needle)")
        }
        XCTAssertTrue(exported.contains("Typed heading"))
        for format in ["markdown", "html"] {
            let tree = try cli(["export", "--all", "--format", format, "--pdf-renderer", "none", "--out", path(format)] + args)
            XCTAssertEqual(tree.status, 0, "\(format): \(tree.err)")
        }
        let html = try String(contentsOf: URL(fileURLWithPath: path("html")).appendingPathComponent(try htmlFile()), encoding: .utf8)
        XCTAssertTrue(html.contains("<summary>Typed text</summary>") && html.contains("Typed heading: Ünïcode"), "typed text is in the HTML export")
        let index = try String(contentsOf: URL(fileURLWithPath: path("html/index.html")), encoding: .utf8)
        XCTAssertTrue(index.lowercased().contains("typed heading"), "and in the HTML search index")
        let md = try FileManager.default.contentsOfDirectory(atPath: path("markdown")).first { $0.hasPrefix("Groceries") && $0.hasSuffix(".md") }
        let markdown = try String(contentsOf: URL(fileURLWithPath: path("markdown")).appendingPathComponent(try XCTUnwrap(md)), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Typed text:") && markdown.contains("Typed heading: Ünïcode"), "and in the Markdown")
    }

    func exportStem(_ note: String) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(atPath: path("svg"))
        return String(try XCTUnwrap(files.first { $0.hasPrefix("Groceries") }).dropLast("-p001.svg".count))
    }

    func htmlFile() throws -> String {
        let files = try FileManager.default.contentsOfDirectory(atPath: path("html"))
        return try XCTUnwrap(files.first { $0.hasPrefix("Groceries") && $0.hasSuffix(".html") })
    }
}
