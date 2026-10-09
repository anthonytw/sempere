import Age
import Foundation
import ImportTestSupport
import Sempere
import SempereRender
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Attachments of Notability notes (docs/attachments.md §11, tasks D1 and D2):
/// PDF page backgrounds and images, on synthetic packages only.
final class NotabilityAttachmentTests: NotabilityTestCase {
    static let letter = (612.0, 792.0)
    static let slide = (1024.0, 768.0)
    static let k = 612 / 716.8

    func resolve(_ package: Data) throws -> (NotabilityNote, NotabilityAttachments) {
        let pkg = try NotePackage(data: package)
        let note = try NotabilityNote.parse(package: pkg)
        return (note, NotabilityAttachments.resolve(note, package: pkg))
    }

    // MARK: - PDF pages (D1)

    func testPDFPagesBecomeBackgroundsAtTheirBands() throws {
        let pdf = AttachmentFixtures.pdf(pages: Array(repeating: Self.letter, count: 3))
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 3), pdf: pdf,
                                             thumbnails: [("thumb.png", 48, 62)])
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, into: vault)
        XCTAssertEqual(r.dropped.pdfPages, 0)
        XCTAssertEqual(r.dropped.pdfs, 0)
        XCTAssertEqual(r.attachments.pdfPages, 3)
        XCTAssertEqual(r.attachments.pdfs, 1)
        XCTAssertEqual(r.attachments.blobs, 1)
        XCTAssertEqual(r.attachments.blobBytes, Int64(pdf.count))

        let page = try XCTUnwrap(state.pages.first)
        let items = page.items.filter { $0.kind == .pdfPage }
        XCTAssertEqual(items.count, 3)
        // Letter at 716.8 units: pages every ⌈716.8 × 792/612⌉ = 928 units.
        for (n, item) in items.enumerated() {
            XCTAssertEqual(item.layer, .background)
            XCTAssertEqual(item.pageIndex, n)
            XCTAssertEqual(item.pageSize, Size(w: 612, h: 792))
            XCTAssertEqual(item.frame.x, 0)
            XCTAssertEqual(item.frame.y, Double(n) * 928 * Self.k, accuracy: 1e-3)
            XCTAssertEqual(item.frame.w, 612, accuracy: 1e-9)
            XCTAssertEqual(item.frame.h, 792, accuracy: 1e-3)
            XCTAssertNil(item.crop)
            XCTAssertEqual(item.blob, items[0].blob)
        }
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, 928 * Self.k, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(state.meta.pageSize.height, (2 * 928 + 927.6) * Self.k)
        // Recognition on page 2 sits one stride down.
        XCTAssertEqual(page.recognition?.words.last?.box.y ?? 0, (49 + 928) * Self.k, accuracy: 1e-3)
        // The blob is the PDF, byte for byte, and the vault verifies.
        let blob = try XCTUnwrap(items.first?.blob)
        XCTAssertEqual(try vault.readBlob(note: try XCTUnwrap(r.noteId), blob), pdf)
        XCTAssertEqual(blob.type, "application/pdf")
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    /// A long PDF (a 300-page textbook) stacked on one infinite page would be
    /// about 237 000 pt tall: past the renderer's extent (format.md §8.4,
    /// 200 000 pt), so no export of the note would work. The import stays
    /// within it.
    func testLongPDFNoteStaysWithinTheExtentLimit() throws {
        let pdf = AttachmentFixtures.pdf(pages: Array(repeating: Self.letter, count: 300))
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(pdfPages: 300), pdf: pdf,
                                             thumbnails: [("thumb.png", 48, 62)])
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, into: vault)
        XCTAssertEqual(r.attachments.pdfPages, 300)
        XCTAssertEqual(state.pages.flatMap(\.items).filter { $0.kind == .pdfPage }.count, 300)
        for page in state.pages {
            let bottom = page.items.map { $0.frame.y + $0.frame.h }.max() ?? 0
            XCTAssertLessThanOrEqual(bottom, PageSize.maxSheetHeight)
        }
        XCTAssertLessThanOrEqual(state.meta.pageSize.height, PageSize.maxSheetHeight)
        // Every page renders (the last, lowest one is enough to show the size is accepted).
        var last = state; last.pages = Array(state.pages.suffix(1))
        XCTAssertNoThrow(try PDFWriter.render(note: last))
    }

    /// The PDF's own page boxes give the stride: a thumbnail that is no
    /// standard aspect no longer decides it.
    func testPDFPageBoxReplacesTheThumbnailAspect() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.slide, Self.slide])
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 2), pdf: pdf,
                                             thumbnails: [("thumb.png", 48, 40)])
        let (note, a) = try resolve(pkg)
        XCTAssertEqual(note.paper.pageHeight, 598, accuracy: 1e-9)   // ⌈716.8 × 40/48⌉ from the thumbnail
        XCTAssertEqual(a.pageStride ?? 0, 538, accuracy: 1e-9)       // ⌈716.8 × 0.75⌉ from the PDF
        let state = NotabilityImporter.convert(note, scaleToLetterWidth: false, attachments: a)
        XCTAssertEqual(state.meta.pageSize.breakHeight ?? 0, 538, accuracy: 1e-9)
        XCTAssertEqual(state.pages[0].items.map(\.frame.y), [0, 538])
        XCTAssertEqual(state.pages[0].items[0].frame.h, 537.6, accuracy: 1e-9)
    }

    /// Mixed sizes: each page starts where the heights above it end.
    func testMixedPDFPageSizesStackPerPage() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.slide, Self.letter])
        let (note, a) = try resolve(AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 3), pdf: pdf))
        XCTAssertEqual(a.pageTops, [0, 928, 928 + 538])
        XCTAssertEqual(a.placements.map(\.frame.y), [0, 928, 928 + 538])
        XCTAssertTrue(a.warnings.contains { $0.contains("2 heights") }, "\(a.warnings)")
        // Recognition of page 2 follows the first page's height.
        let state = NotabilityImporter.convert(note, scaleToLetterWidth: false, attachments: a)
        XCTAssertEqual(state.pages[0].recognition?.words.last?.box.y ?? 0, 49 + 928, accuracy: 1e-9)
        XCTAssertEqual(state.meta.pageSize.breakHeight, 928)
        XCTAssertGreaterThanOrEqual(state.meta.pageSize.height, 928 + 538 + 927.6)
    }

    func testRotatedPDFPageUsesItsEffectiveSize() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter], rotate: 90)
        let (_, a) = try resolve(AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 1), pdf: pdf))
        guard case let .pdfPage(_, _, size)? = a.placements.first?.content else { return XCTFail("no page") }
        XCTAssertEqual(size, Size(w: 792, h: 612))
        XCTAssertEqual(a.pageStride ?? 0, (716.8 * 612 / 792).rounded(.up))
    }

    /// An inserted paper page keeps the note's page height and gets no background.
    func testInsertedPaperPageInPDFNote() throws {
        let name = SyntheticNote.pdfName
        let session = SyntheticNote.session(typed: "", layout: [(1, name, 1), (2, nil, 0), (3, name, 2)])
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.letter])
        let (note, a) = try resolve(AttachmentFixtures.package(session: session, pdf: pdf,
                                                               thumbnails: [("thumb.png", 48, 62)]))
        XCTAssertEqual(note.pdfPageCount, 2)
        XCTAssertEqual(a.placements.count, 2)
        XCTAssertEqual(a.pageTops, [0, 928, 928 + note.paper.pageHeight])
        XCTAssertEqual(a.placements.map(\.frame.y), [0, 928 + note.paper.pageHeight])
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).pdfPages, 0)
    }

    /// Entries stored out of order are placed by their document page number.
    func testLayoutOrderFollowsDocumentPageNumbers() throws {
        let name = SyntheticNote.pdfName
        let session = SyntheticNote.session(typed: "", layout: [(2, name, 2), (1, name, 1)])
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter, Self.slide])
        let (_, a) = try resolve(AttachmentFixtures.package(session: session, pdf: pdf))
        let indices = a.placements.compactMap { p -> Int? in
            if case let .pdfPage(_, i, _) = p.content { return i }; return nil
        }
        XCTAssertEqual(indices, [0, 1])
        XCTAssertEqual(a.placements.map(\.frame.y), [0, 928])
    }

    func testZeroBasedPDFPageNumbers() throws {
        let name = SyntheticNote.pdfName
        let session = SyntheticNote.session(typed: "", layout: [(1, name, 0), (2, name, 1)])
        let (_, a) = try resolve(AttachmentFixtures.package(
            session: session, pdf: AttachmentFixtures.pdf(pages: [Self.letter, Self.slide])))
        let sizes = a.placements.compactMap { p -> Size? in
            if case let .pdfPage(_, _, s) = p.content { return s }; return nil
        }
        XCTAssertEqual(sizes, [Size(w: 612, h: 792), Size(w: 1024, h: 768)])
        XCTAssertTrue(a.warnings.contains { $0.contains("0-based") })
    }

    func testPDFPageBeyondTheFileIsDropped() throws {
        let session = SyntheticNote.session(typed: "", pdfPages: 3)
        let (note, a) = try resolve(AttachmentFixtures.package(
            session: session, pdf: AttachmentFixtures.pdf(pages: [Self.letter, Self.letter])))
        XCTAssertEqual(a.placements.count, 2)
        let d = NotabilityImporter.dropped(note, attachments: a)
        XCTAssertEqual(d.pdfPages, 1)
        XCTAssertEqual(d.pdfs, 0)
        XCTAssertTrue(a.warnings.contains { $0.contains("page 3") && $0.contains("2 pages") }, "\(a.warnings)")
    }

    func testEncryptedMissingAndBrokenPDFsAreReported() throws {
        for (pdf, expect) in [(AttachmentFixtures.pdf(pages: [Self.letter], encrypt: true), "encrypted"),
                              (nil, "not in the package"), (Data("%PDF-1.4\n".utf8), "not readable")] as [(Data?, String)] {
            let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 2), pdf: pdf)
            let vault = try makeVault()
            let (r, state) = try importFile(pkg, into: vault)
            XCTAssertEqual(r.dropped.pdfPages, 2, expect)
            XCTAssertEqual(r.dropped.pdfs, 1, expect)
            XCTAssertEqual(r.attachments.pdfPages, 0, expect)
            XCTAssertEqual(r.attachments.blobs, 0, expect)
            XCTAssertTrue(state.pages[0].items.isEmpty, expect)
            XCTAssertTrue(r.warnings.contains { $0.contains(expect) }, "\(expect): \(r.warnings)")
            XCTAssertEqual(state.pages[0].strokes.count, 4, expect)   // the ink still imports
        }
    }

    func testNoAttachmentsKeepsTheOldImport() throws {
        let pdf = AttachmentFixtures.pdf(pages: Array(repeating: Self.letter, count: 2))
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 2), pdf: pdf)
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, into: vault, options: .init(attachments: false))
        XCTAssertEqual(r.dropped.pdfPages, 2)
        XCTAssertEqual(r.dropped.pdfs, 1)
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertTrue(state.pages[0].items.isEmpty)
        XCTAssertTrue(try vault.blobInventory(note: try XCTUnwrap(r.noteId)).files.isEmpty)
    }

    /// An ink-less PDF note is no longer empty: every page has its background.
    func testInklessPDFNoteImportsItsPages() throws {
        let pdf = AttachmentFixtures.pdf(pages: Array(repeating: Self.slide, count: 12))
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", curves: [], pdfPages: 12), pdf: pdf,
                                             handwriting: false)
        let (r, state) = try importFile(pkg, into: try makeVault())
        XCTAssertEqual(r.strokes, 0)
        XCTAssertEqual(r.attachments.pdfPages, 12)
        XCTAssertEqual(r.dropped.pdfPages, 0)
        XCTAssertEqual(state.meta.pageSize.height, (11 * 538 + 537.6) * Self.k, accuracy: 1)
    }

    /// An overwrite writes new item ids (the old ones are tombstoned with
    /// their page) and reuses the blob.
    func testOverwriteReplacesItems() throws {
        let pdf = AttachmentFixtures.pdf(pages: [Self.letter])
        let pkg = AttachmentFixtures.package(session: SyntheticNote.session(typed: "", pdfPages: 1), pdf: pdf)
        let vault = try makeVault()
        let (_, first) = try importFile(pkg, into: vault)
        let (r, second) = try importFile(pkg, into: vault, options: .init(overwrite: true))
        XCTAssertEqual(second.pages.count, 1)
        XCTAssertEqual(second.pages[0].items.count, 1)
        XCTAssertNotEqual(second.pages[0].items[0].id, first.pages[0].items[0].id)
        XCTAssertEqual(second.pages[0].items[0].blob, first.pages[0].items[0].blob)
        XCTAssertEqual(try vault.blobInventory(note: try XCTUnwrap(r.noteId)).files.count, 1)
    }

    func testTemplatePDFPaper() throws {
        let uuid = "11111111-2222-4333-8444-555555555555"
        let session = SyntheticNote.session(typed: "", paperIdentifier: "TemplatePDF:\(uuid):#FFFFFF")
        // Not in the package: reported.
        let (note, missing) = try resolve(AttachmentFixtures.package(session: session))
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: missing).templatePDFs, 1)
        XCTAssertEqual(NotabilityImporter.dropped(note).templatePDFs, 1)
        XCTAssertTrue(missing.placements.isEmpty)
        // A PDF named after the template: one background per page down to the ink (2 pages).
        let found = try resolve(AttachmentFixtures.package(
            session: session, extra: [("PDFs/\(uuid).pdf", AttachmentFixtures.pdf(pages: [Self.letter]))])).1
        XCTAssertEqual(found.dropped.templatePDFs, 0)
        XCTAssertEqual(found.imported.templatePages, 2)
        XCTAssertEqual(found.placements.map(\.frame.y), [0, SyntheticNote.pageHeight])
    }

    // MARK: - Images (D2)

    static let jpegPath = "Images/5B0A-photo.jpg"
    static let pngPath = "Images/5B0B-diagram.png"

    func imagePackage(_ media: @escaping (inout KeyedArchiveBuilder) -> [BValue],
                      files: [(String, Data)]) -> Data {
        AttachmentFixtures.package(session: SyntheticNote.session(typed: "", media: media), extra: files)
    }

    func testImagesBecomeImageItems() throws {
        let jpeg = AttachmentFixtures.jpeg(width: 400, height: 300, orientation: 6)
        let png = AttachmentFixtures.png(width: 8, height: 4)
        let pkg = imagePackage({ a in
            [AttachmentFixtures.imageObject(&a, file: Self.jpegPath, origin: (50, 100), size: (300, 400), scale: 0.5),
             AttachmentFixtures.imageObject(&a, file: Self.pngPath, origin: (10, 600), size: (80, 40))]
        }, files: [(Self.jpegPath, jpeg), (Self.pngPath, png)])
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, into: vault)
        XCTAssertEqual(r.attachments.images, 2)
        XCTAssertEqual(r.attachments.blobs, 2)
        XCTAssertEqual(r.dropped.media, 0)
        let items = state.pages[0].items
        XCTAssertEqual(items.count, 2)
        let photo = try XCTUnwrap(items.first { $0.blob?.type == "image/jpeg" })
        XCTAssertEqual(photo.layer, .content)
        XCTAssertEqual(photo.orientation, 6)
        XCTAssertEqual(photo.pixelSize, Size(w: 300, h: 400))   // after orientation 6
        let inset = 716.8 / 38.4
        XCTAssertEqual(photo.frame.x, (50 + inset) * Self.k, accuracy: 1e-3)
        XCTAssertEqual(photo.frame.y, 100 * Self.k, accuracy: 1e-3)
        XCTAssertEqual(photo.frame.w, 150 * Self.k, accuracy: 1e-3)
        XCTAssertEqual(photo.frame.h, 200 * Self.k, accuracy: 1e-3)
        // Metadata stripped: no EXIF, no comment; the JFIF segment and the image stay.
        let stored = try vault.readBlob(note: try XCTUnwrap(r.noteId), try XCTUnwrap(photo.blob))
        XCTAssertNil(stored.range(of: Data("Exif".utf8)))
        XCTAssertNil(stored.range(of: Data("camera comment".utf8)))
        XCTAssertNotNil(stored.range(of: Data("JFIF".utf8)))
        let diagram = try XCTUnwrap(items.first { $0.blob?.type == "image/png" })
        XCTAssertNil(diagram.orientation)
        XCTAssertEqual(diagram.pixelSize, Size(w: 8, h: 4))
        let storedPNG = try vault.readBlob(note: try XCTUnwrap(r.noteId), try XCTUnwrap(diagram.blob))
        XCTAssertNil(storedPNG.range(of: Data("tEXt".utf8)))
        XCTAssertTrue(r.warnings.allSatisfy { $0.contains("placed from documentContentOrigin") }, "\(r.warnings)")
        // Items count toward the page extent.
        XCTAssertGreaterThanOrEqual(state.meta.pageSize.height, 640 * Self.k)
    }

    /// A hostile package can hold many large, highly compressible entries
    /// (each under the 1 GiB entry cap): what is held for one note is
    /// bounded, the rest left out and reported, never all held at once.
    func testAttachmentBytesHeldPerNoteAreBounded() throws {
        let jpeg = AttachmentFixtures.jpeg(width: 400, height: 300, orientation: 6)
        let png = AttachmentFixtures.png(width: 8, height: 4)
        let pkgData = imagePackage({ a in
            [AttachmentFixtures.imageObject(&a, file: Self.jpegPath, origin: (50, 100), size: (300, 400)),
             AttachmentFixtures.imageObject(&a, file: Self.pngPath, origin: (10, 600), size: (80, 40))]
        }, files: [(Self.jpegPath, jpeg), (Self.pngPath, png)])
        let pkg = try NotePackage(data: pkgData)
        let note = try NotabilityNote.parse(package: pkg)
        // Room for the first (stripped) image only.
        let first = try ImageImport.prepare(jpeg, keepMetadata: false).data.count
        let r = NotabilityAttachments.resolve(note, package: pkg, keepImageMetadata: false, maxHeldBytes: first + 10)
        XCTAssertEqual(r.imported.images, 1)
        XCTAssertEqual(r.dropped.media, 1)
        XCTAssertLessThanOrEqual(r.blobs.values.reduce(0) { $0 + $1.data.count }, first + 10)
        XCTAssertTrue(r.warnings.contains { $0.contains("MiB of attachments read for one note") }, "\(r.warnings)")
        // The same budget for PDFs: none fits in 10 bytes.
        let pkg2 = try NotePackage(data: AttachmentFixtures.package(session: SyntheticNote.session(pdfPages: 1),
                                                                    pdf: AttachmentFixtures.pdf(pages: [Self.letter])))
        let n2 = try NotabilityNote.parse(package: pkg2)
        let r2 = NotabilityAttachments.resolve(n2, package: pkg2, keepImageMetadata: false, maxHeldBytes: 10)
        XCTAssertTrue(r2.blobs.isEmpty)
        XCTAssertEqual(r2.imported.pdfPages, 0)
        XCTAssertEqual(r2.dropped.pdfPages, 1)
    }

    func testKeepImageMetadata() throws {
        let jpeg = AttachmentFixtures.jpeg(width: 40, height: 30, orientation: 3)
        let pkg = imagePackage({ a in [AttachmentFixtures.imageObject(&a, file: Self.jpegPath, origin: (0, 0), size: (40, 30))] },
                               files: [(Self.jpegPath, jpeg)])
        let vault = try makeVault()
        let (r, state) = try importFile(pkg, into: vault, options: .init(keepImageMetadata: true))
        let item = try XCTUnwrap(state.pages[0].items.first)
        XCTAssertEqual(item.orientation, 3)
        XCTAssertEqual(item.pixelSize, Size(w: 40, h: 30))
        XCTAssertEqual(try vault.readBlob(note: try XCTUnwrap(r.noteId), try XCTUnwrap(item.blob)), jpeg)
    }

    /// A frame stored as a rect (`NSValue`), rotation in radians and a unit crop.
    /// Real notes keep a placeholder `{{0, 0}, {0, 0}}` `rect` on the figure's
    /// background object; it must not win over `documentContentOrigin` +
    /// `unscaledContentSize` (25 images of the reference backup were dropped
    /// as "not a finite box" before). A full-image `FigureCropRectKey` is no crop.
    func testPlaceholderRectFallsThroughToOriginAndSize() throws {
        let png = AttachmentFixtures.png(width: 100, height: 50)
        let pkg = imagePackage({ a in
            [AttachmentFixtures.imageObject(&a, file: "Images/Image 1.png", origin: (40, 300), size: (200, 100),
                                            cropPixels: (100, 50))]
        }, files: [("Images/Image 1.png", png)])
        let (note, a) = try resolve(pkg)
        let state = NotabilityImporter.convert(note, scaleToLetterWidth: false, attachments: a)
        let item = try XCTUnwrap(state.pages[0].items.first)
        XCTAssertEqual(item.frame.w, 200)
        XCTAssertEqual(item.frame.h, 100)
        XCTAssertEqual(item.frame.y, 300, accuracy: 1e-9)
        XCTAssertTrue(item.crop == nil || item.crop == Rect(x: 0, y: 0, w: 100, h: 50), "\(String(describing: item.crop))")
        XCTAssertTrue(a.warnings.contains { $0.contains("documentContentOrigin + unscaledContentSize") }, "\(a.warnings)")
    }

    func testFrameRotationAndCropFromOtherFields() throws {
        let png = AttachmentFixtures.png(width: 100, height: 50)
        let pkg = imagePackage({ a in
            let rect = a.object("NSValue", [("NS.special", .int(3)), ("NS.rectval", a.string("{{20, 30}, {200, 100}}"))])
            let file = a.string("Assets/diagram.png")
            return [a.object("ImageMediaObject", [("frame", rect), ("rotation", .real(Double.pi / 2)),
                                                  ("cropRect", a.string("{{0.5, 0}, {0.5, 1}}")), ("fileName", file)])]
        }, files: [("Assets/diagram.png", png)])
        let (note, a) = try resolve(pkg)
        let state = NotabilityImporter.convert(note, scaleToLetterWidth: false, attachments: a)
        let item = try XCTUnwrap(state.pages[0].items.first)
        XCTAssertEqual(item.frame.x, 20 + 716.8 / 38.4, accuracy: 1e-9)
        XCTAssertEqual(item.frame.w, 200)
        XCTAssertEqual(item.rotation ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(item.crop, Rect(x: 50, y: 0, w: 50, h: 50))
        XCTAssertTrue(a.warnings.contains { $0.contains("frame") && $0.contains("rotation") && $0.contains("cropRect (unit)") },
                      "\(a.warnings)")
    }

    func testUnplaceableMediaIsReportedWithItsFieldNames() throws {
        let pkg = imagePackage({ a in
            [AttachmentFixtures.imageObject(&a, file: "Images/anim.webp", origin: (0, 0), size: (10, 10)),
             AttachmentFixtures.imageObject(&a, file: "Images/gone.jpg", origin: (0, 0), size: (10, 10)),
             a.object("ImageMediaObject", [("mysteryKey", a.string(Self.pngPath))]),
             a.object("AudioMediaObject", [("duration", .real(3))])]
        }, files: [("Images/anim.webp", AttachmentFixtures.webp), (Self.pngPath, AttachmentFixtures.png(width: 2, height: 2))])
        let (r, state) = try importFile(pkg, into: try makeVault())
        XCTAssertEqual(r.dropped.media, 4)
        XCTAssertEqual(r.attachments.images, 0)
        XCTAssertTrue(state.pages[0].items.isEmpty)
        XCTAssertTrue(r.warnings.contains { $0.contains("WEBP image") }, "\(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.contains("media object 2") && $0.contains("no file") })
        XCTAssertTrue(r.warnings.contains { $0.contains("media object 3") && $0.contains("no frame") && $0.contains("mysteryKey") })
        XCTAssertTrue(r.warnings.contains { $0.contains("AudioMediaObject") && $0.contains("duration") })
    }

    /// GIF (and TIFF) images are converted to PNG on import; WebP is left out and counted (GA-10).
    func testGIFIsStoredAsPNG() throws {
        let pkg = imagePackage({ a in
            [AttachmentFixtures.imageObject(&a, file: "Images/pic.gif", origin: (0, 0), size: (10, 5))]
        }, files: [("Images/pic.gif", AttachmentFixtures.realGIF)])
        let (note, a) = try resolve(pkg)
        XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).media, 0)
        XCTAssertEqual(a.imported.images, 1)
        let blob = try XCTUnwrap(a.blobs.values.first)
        XCTAssertEqual(blob.ref.type, "image/png")
        XCTAssertEqual(ImageImport.format(of: blob.data), .png)
        let again = try ImageImport.prepare(blob.data)
        XCTAssertEqual([again.width, again.height], [2, 1])
    }

    func testHostileGeometryIsDropped() throws {
        let png = AttachmentFixtures.png(width: 2, height: 2)
        for (origin, size) in [("{1e300, 0}", "{10, 10}"), ("{0, 0}", "{0, 10}"), ("{nan, 0}", "{10, 10}"),
                               ("{0, 0}", "{-5, 10}"), ("{0, 0}", "{1e7, 10}")] {
            let pkg = imagePackage({ a in
                [a.object("ImageMediaObject", [("documentContentOrigin", a.string(origin)),
                                               ("unscaledContentSize", a.string(size)), ("path", a.string(Self.pngPath))])]
            }, files: [(Self.pngPath, png)])
            let (note, a) = try resolve(pkg)
            XCTAssertTrue(a.placements.isEmpty, "\(origin) \(size)")
            XCTAssertEqual(NotabilityImporter.dropped(note, attachments: a).media, 1)
            XCTAssertNoThrow(try JSONEncoder().encode(NotabilityImporter.convert(note, attachments: a)))
        }
    }

    // MARK: - Image preparation (SempereRender.ImageImport)

    func testImagePreparation() throws {
        XCTAssertEqual(ImageImport.format(of: AttachmentFixtures.gif), .gif)
        XCTAssertThrowsError(try ImageImport.prepare(AttachmentFixtures.gif))
        XCTAssertThrowsError(try ImageImport.prepare(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        let p = try ImageImport.prepare(AttachmentFixtures.jpeg(width: 10, height: 20, orientation: nil))
        XCTAssertNil(p.orientation)
        XCTAssertEqual([p.width, p.height], [10, 20])
        // HEIC: sized from its largest `ispe` property, stored as is.
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count + 8
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body
        }
        func ispe(_ w: Int, _ h: Int) -> [UInt8] {
            box("ispe", [0, 0, 0, 0, 0, 0, UInt8(w >> 8), UInt8(w & 0xFF), 0, 0, UInt8(h >> 8), UInt8(h & 0xFF)])
        }
        let heic = Data(box("ftyp", Array("heic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8))
            + box("meta", [0, 0, 0, 0] + box("iprp", box("ipco", ispe(320, 240) + ispe(4032, 3024)))))
        let h = try ImageImport.prepare(heic)
        XCTAssertEqual(h.type, "image/heic")
        XCTAssertEqual([h.width, h.height], [4032, 3024])
        XCTAssertEqual(h.data, heic)
        // Over 100 megapixels (format.md §8.4, writers stay within it): refused, not stored.
        XCTAssertThrowsError(try ImageImport.prepare(AttachmentFixtures.jpeg(width: 60_000, height: 60_000, orientation: nil))) {
            XCTAssertTrue("\($0)".contains("megapixel"), "\($0)")
        }
        let huge = Data(box("ftyp", Array("heic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8))
            + box("meta", [0, 0, 0, 0] + box("iprp", box("ipco", ispe(60_000, 60_000)))))
        XCTAssertThrowsError(try ImageImport.prepare(huge))
    }
}

/// `Tests/SempereNotabilityTests/Fixtures/synthetic-attachments.note`, the CLI tests' note
/// with a two-page PDF and a photo, is generated from these fixtures.
/// `SEMPERE_UPDATE_FIXTURES=1 swift test --filter CLIAttachmentFixtureTests` rewrites it.
final class CLIAttachmentFixtureTests: XCTestCase {
    static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SempereNotabilityTests/Fixtures/synthetic-attachments.note")
    }

    static func package() -> Data {
        let path = "Images/5B0A-photo.jpg"
        let session = SyntheticNote.session(pdfPages: 2, media: { a in
            [AttachmentFixtures.imageObject(&a, file: path, origin: (40, 300), size: (300, 400), scale: 0.5)]
        })
        return AttachmentFixtures.package(session: session,
                                          pdf: AttachmentFixtures.pdf(pages: [(612, 792), (612, 792)]),
                                          extra: [(path, AttachmentFixtures.jpeg(width: 400, height: 300, orientation: 6))],
                                          thumbnails: [("thumb.png", 48, 62)])
    }

    func testFixtureIsCurrent() throws {
        let data = Self.package()
        if ProcessInfo.processInfo.environment["SEMPERE_UPDATE_FIXTURES"] == "1" {
            try data.write(to: Self.url)
        }
        XCTAssertEqual(try Data(contentsOf: Self.url), data, "run with SEMPERE_UPDATE_FIXTURES=1 to regenerate")
    }

    /// `synthetic-text-audio.note`: styled typed text, a recording and strokes linked to it.
    static var textAudioURL: URL { url.deletingLastPathComponent().appendingPathComponent("synthetic-text-audio.note") }

    static func textAudioPackage() -> Data {
        let session = SyntheticNote.session(attributed: { a in
            let ranges = [a.dict([("rangeKey", a.string("{0, 7}")), ("fontName", a.string("Helvetica-Bold")),
                                  ("fontSize", .real(24))])]
            return a.dict([("stringKey", a.string("Heading\nTyped notes about kernels")), ("subRangesKey", a.array(ranges))])
        }, eventTokens: [0, 1500, -1, 3000])
        let entry = """
            <key>name</key><string>Lecture</string><key>fileName</key><string>Recording 1.m4a</string>\
            <key>creationDate</key><date>2026-10-04T16:20:00Z</date>
            """
        return AttachmentFixtures.package(session: session, extra: [
            ("Recordings/library.plist", AttachmentFixtures.library([("rec-0", entry)])),
            ("Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5)),
        ])
    }

    func testTextAudioFixtureIsCurrent() throws {
        let data = Self.textAudioPackage()
        if ProcessInfo.processInfo.environment["SEMPERE_UPDATE_FIXTURES"] == "1" {
            try data.write(to: Self.textAudioURL)
        }
        XCTAssertEqual(try Data(contentsOf: Self.textAudioURL), data, "run with SEMPERE_UPDATE_FIXTURES=1 to regenerate")
    }
}
