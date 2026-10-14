import Darwin
import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// PDFs into notes (docs/attachments.md §14 task E3): a new note with one
/// finite page per PDF page, pages inserted into the open note, encrypted
/// PDFs unlocked and stored without /Encrypt, the shared `NoteOps` and
/// `PDFIngest` paths, and the tiled display (pages drawn by Core Graphics,
/// one open document per PDF, memory bounded over 200 pages).
@MainActor
struct PDFImportTests {
    static let lecture = AppModelTests.lecture

    /// A synthetic PDF of `pages` pages of `size` points, each with a red
    /// square at its top-left and its number written large, in a work folder.
    static func makePDF(pages: Int, size: CGSize = CGSize(width: 612, height: 792), userPassword: String? = nil,
                        ownerPassword: String? = nil) throws -> URL {
        let url = try PDFPreparation.workFolder().appendingPathComponent("synthetic.pdf")
        var info: [CFString: Any] = [:]
        if let userPassword { info[kCGPDFContextUserPassword] = userPassword }
        if let ownerPassword { info[kCGPDFContextOwnerPassword] = ownerPassword }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info.isEmpty ? nil : info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for n in 1...pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: size.height - 100, width: 100, height: 100))   // top-left (PDF space is y up)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(2)
            for k in 0..<(n % 17 + 3) {   // some vector content that differs per page
                ctx.move(to: CGPoint(x: 120 + Double(k) * 20, y: 200))
                ctx.addLine(to: CGPoint(x: 140 + Double(k) * 20, y: size.height - 200))
            }
            ctx.strokePath()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    static func revisions(_ vault: Vault, _ id: UUID) -> [String] {
        let dir = vault.url.appendingPathComponent("notes/\(id.uuidString.lowercased())")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".age") }
    }

    // MARK: Preparing

    @Test func pageSizesComeFromTheSharedReader() throws {
        let url = try Self.makePDF(pages: 3, size: CGSize(width: 400, height: 300))
        defer { PDFPreparation.discard(url) }
        let pdf = try PDFPreparation.prepare(url)
        #expect(pdf.file == url, "an unencrypted PDF is stored as it is")
        #expect(!pdf.decrypted)
        #expect(pdf.pages == (0..<3).map { PDFPageRef(index: $0, size: Size(w: 400, h: 300)) })
        #expect(pdf.name == "synthetic")
    }

    @Test func encryptedPDFsAskForThePasswordAndAreStoredWithoutIt() throws {
        let url = try Self.makePDF(pages: 2, userPassword: "open sesame", ownerPassword: "owner")
        defer { PDFPreparation.discard(url) }
        #expect(try Data(contentsOf: url).range(of: Data("/Encrypt".utf8)) != nil)
        #expect(throws: PDFPreparation.Failure.needsPassword) { try PDFPreparation.prepare(url) }
        #expect(throws: PDFPreparation.Failure.wrongPassword) { try PDFPreparation.prepare(url, password: "nope") }
        let pdf = try PDFPreparation.prepare(url, password: "open sesame")
        #expect(pdf.decrypted)
        #expect(pdf.file != url)
        #expect(try Data(contentsOf: pdf.file).range(of: Data("/Encrypt".utf8)) == nil)
        #expect(pdf.pages.map(\.size) == [Size(w: 612, h: 792), Size(w: 612, h: 792)])
        // The redrawn page still shows the content: red at the top-left.
        let img = try PDFKitRasterizer().rasterize(pdf: pdf.file, pageIndex: 0, pixelWidth: 61, pixelHeight: 79)
        #expect(img.pixels[0] > 200 && img.pixels[1] < 60)
    }

    @Test func ownerPasswordOnlyOpensWithoutAsking() throws {
        let url = try Self.makePDF(pages: 1, userPassword: "", ownerPassword: "owner")
        defer { PDFPreparation.discard(url) }
        let pdf = try PDFPreparation.prepare(url)
        #expect(try Data(contentsOf: pdf.file).range(of: Data("/Encrypt".utf8)) == nil)
    }

    @Test func notAPDFIsRefused() throws {
        let url = try PDFPreparation.workFolder().appendingPathComponent("junk.pdf")
        try Data("hello".utf8).write(to: url)
        defer { PDFPreparation.discard(url) }
        #expect(throws: (any Error).self) { try PDFPreparation.prepare(url) }
    }

    // MARK: Into the vault

    /// A new note: one page per PDF page, the first page's size, blank
    /// paper, a background pdfPage item filling each page; one blob, one delta.
    @Test func importAsANewNote() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let vault = try #require(model.vault)
        let url = try Self.makePDF(pages: 3, size: CGSize(width: 400, height: 500))
        let original = try Data(contentsOf: url)
        guard case .done(let id) = await model.importPDF(copy: url, to: .newNote(notebook: "Imports"), password: nil) else {
            Issue.record("not imported: \(model.errorMessage ?? "")"); return
        }
        #expect(model.selectedNoteID == id)
        #expect(model.notes.contains { $0.id == id && $0.title == "synthetic" && $0.notebook == "Imports" })
        #expect(Self.revisions(vault, id).count == 1, "one delta")
        let state = try vault.reconstruct(noteId: id)
        #expect(state.meta.pageSize.width == 400 && state.meta.pageSize.height == 500 && !state.meta.pageSize.infinite)
        #expect(state.pages.count == 3)
        for (i, page) in state.pages.enumerated() {
            let item = try #require(page.items.first)
            #expect(page.items.count == 1)
            #expect(item.kind == .pdfPage && item.pageIndex == i && item.layer == .background)
            #expect(item.frame == Rect(x: 0, y: 0, w: 400, h: 500))
        }
        let ref = try #require(state.pages[0].items[0].blob)
        #expect(try vault.readBlob(note: id, ref) == original, "the PDF as picked")
        #expect(!FileManager.default.fileExists(atPath: url.path), "the plaintext work copy is gone")
    }

    /// The CLI's `import pdf` writes the same note (shared `NoteOps.newPDFNote`).
    @Test func theNewNoteMatchesTheSharedBuilder() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let vault = try #require(model.vault)
        let url = try Self.makePDF(pages: 2)
        let pdf = try PDFPreparation.prepare(url)
        let id = try await model.importPDF(pdf, title: "Handout")
        let state = try vault.reconstruct(noteId: id)
        let ref = try #require(state.pages[0].items[0].blob)
        var ids = state.pages.map(\.id).makeIterator()
        let expected = try NoteOps.newPDFNote(title: "Handout", blob: ref, pdf.pages, newPageID: { ids.next() ?? UUID() })
        let written = try vault.loadNote(id).revisions.flatMap { rev -> [Op] in
            if case .delta(let ops) = rev.body { return ops }
            return []
        }
        // Item ids are random; everything else is the builder's.
        func normalized(_ ops: [Op]) -> [Op] {
            ops.map { op in
                guard case .addItem(let page, var item) = op else { return op }
                item.id = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
                return .addItem(page: page, item: item)
            }
        }
        #expect(normalized(written) == normalized(expected))
        PDFPreparation.discard(pdf.file)
    }

    /// Pages inserted into the open note after the current one, shown, in one delta.
    @Test func insertPagesIntoTheOpenNote() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        if editor.isPageless { await editor.setLayout(pageless: false) }
        let before = editor.pages.map(\.id)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let url = try Self.makePDF(pages: 2)
        let deltasBefore = try NoteEditorTests.myDeltas(vault, clock).count
        guard case .done = await model.importPDF(copy: url, to: .insert(editor, after: 1), password: nil) else {
            Issue.record("not inserted: \(model.errorMessage ?? "")"); return
        }
        await editor.flush()
        #expect(editor.pages.count == before.count + 2)
        #expect(editor.pages[0].id == before[0])
        #expect(Array(editor.pages.dropFirst(3).map(\.id)) == Array(before.dropFirst()))
        #expect(editor.pageIndex == 1, "the first new page is shown")
        #expect(editor.pages[1].items.first?.kind == .pdfPage)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltasBefore + 1)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.map(\.id) == editor.pages.map(\.id))
        #expect(state.pages[2].items.first?.pageIndex == 1)
    }

    @Test func aPagelessNoteTakesNoPDFPages() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        if !editor.isPageless { await editor.setLayout(pageless: true) }
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let att = vault.url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())/att")
        let blobsBefore = (try? FileManager.default.contentsOfDirectory(atPath: att.path))?.count ?? 0
        let url = try Self.makePDF(pages: 1)
        guard case .failed = await model.importPDF(copy: url, to: .insert(editor, after: 1), password: nil) else {
            Issue.record("inserted into a pageless note"); return
        }
        #expect(model.errorMessage?.contains("pageless") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: att.path))?.count ?? 0) == blobsBefore, "no blob written")
        #expect(!InsertOptions.offersPDFPages(pageless: true))
    }

    @Test func aPasswordProtectedImportWaitsForThePassword() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let url = try Self.makePDF(pages: 1, userPassword: "pw", ownerPassword: "owner")
        guard case .needsPassword(let request) = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil) else {
            Issue.record("did not ask"); return
        }
        #expect(!request.wrongPassword)
        guard case .needsPassword(let again) = await model.continuePDFImport(request, password: "wrong") else {
            Issue.record("took a wrong password"); return
        }
        #expect(again.wrongPassword)
        guard case .done(let id) = await model.continuePDFImport(again, password: "pw") else {
            Issue.record("not imported: \(model.errorMessage ?? "")"); return
        }
        let state = try #require(try model.vault?.reconstruct(noteId: id))
        let ref = try #require(state.pages.first?.items.first?.blob)
        let stored = try #require(try model.vault?.readBlob(note: id, ref))
        #expect(stored.range(of: Data("/Encrypt".utf8)) == nil)
        // Cancelling removes the plaintext copy.
        let other = try Self.makePDF(pages: 1, userPassword: "pw", ownerPassword: "owner")   // Core Graphics encrypts only with an owner password
        guard case .needsPassword(let pending) = await model.importPDF(copy: other, to: .newNote(notebook: nil), password: nil) else {
            Issue.record("did not ask"); return
        }
        model.cancelPDFImport(pending)
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: Display

    /// Core Graphics draws the page into the item's frame, top-left up, the
    /// crop onto the frame: what the tiles show.
    @Test func pdfPagesAreDrawnIntoTheirFrame() throws {
        let url = try Self.makePDF(pages: 1, size: CGSize(width: 200, height: 200))
        defer { PDFPreparation.discard(url) }
        let doc = try #require(PDFDocumentBox(url: url))
        let blob = BlobRef(content: Data("p".utf8), type: "application/pdf")
        func render(_ item: Item) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: item.frame.w, height: item.frame.h), format: format).image { ctx in
                PDFItemDrawing.draw(doc.document, item: item, in: ctx.cgContext)
            }
        }
        let whole = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 200, h: 200), frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a")
        let a = try #require(render(whole).cgImage)
        let topLeft = try #require(ImageInsertTests.pixel(a, x: 10, y: 10)), bottomRight = try #require(ImageInsertTests.pixel(a, x: 90, y: 90))
        #expect(topLeft.r > 200 && topLeft.g < 60, "red square at the top-left: \(topLeft)")
        #expect(bottomRight.r > 200 && bottomRight.g > 200 && bottomRight.b > 200, "white under the page: \(bottomRight)")
        // Cropped to the page's lower-right quarter: no red at all.
        let cropped = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 200, h: 200), crop: Rect(x: 100, y: 100, w: 100, h: 100),
                                   frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a")
        let b = try #require(render(cropped).cgImage)
        let p = try #require(ImageInsertTests.pixel(b, x: 10, y: 10))
        #expect(p.g > 200, "the crop shows the lower right: \(p)")
        let missing = Item.pdfPage(blob: blob, pageIndex: 3, pageSize: Size(w: 200, h: 200), frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a")
        let scratch = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(!PDFItemDrawing.draw(doc.document, item: missing, in: scratch), "no such page")
    }

    /// The task's "done when": a 200-page PDF imports and pages through
    /// without memory warnings. Each page shown is a tile layer over the one
    /// open document (no bitmap per page), and the app's footprint stays bounded.
    @Test func aTwoHundredPagePDFPagesThroughInBoundedMemory() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let vault = try #require(model.vault)
        let url = try Self.makePDF(pages: 200)
        guard case .done(let id) = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil) else {
            Issue.record("not imported: \(model.errorMessage ?? "")"); return
        }
        let state = try vault.reconstruct(noteId: id)
        #expect(state.pages.count == 200)
        let warnings = WarningCounter()
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { warnings.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 820, height: 1061))
        window.addSubview(layer)
        window.isHidden = false
        layer.setZoom(820 / 612)
        let source = model.itemLayerSource
        let start = Self.footprint()
        var peak = start
        for (i, page) in state.pages.enumerated() {
            layer.show(page.items, note: id, paper: .blank, source: source)
            if i == 0 { #expect(await TS.waitUntil(timeout: .seconds(60)) { !layer.tiledItemIDs.isEmpty }) }   // first open: decrypt + parse, slow on CI
            #expect(layer.tiledItemIDs == Set(page.items.map(\.id)), "page \(i + 1) is drawn in tiles")
            if i % 10 == 0 {
                layer.setZoom(i % 20 == 0 ? 4 * 820 / 612 : 820 / 612)   // zoom in and out on the way
                layer.layoutIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(50))
                peak = max(peak, Self.footprint())
            }
        }
        #expect(layer.openDocumentCount == 1, "one open document for the whole PDF")
        let growth = Double(peak > start ? peak - start : 0) / 1_048_576
        print("PERF-REPORT pdf200 footprint growth \(Int(growth)) MB")
        #expect(growth < 300, "memory grew by \(Int(growth)) MB paging through 200 pages")
        #expect(warnings.count == 0)
        window.isHidden = true
    }

    /// The process's physical footprint in bytes (what jetsam counts).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// Memory warnings seen during a test.
@MainActor
final class WarningCounter {
    var count = 0
}
