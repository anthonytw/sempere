import Foundation
import PencilKit
import Sempere
import SwiftUI
import Testing
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import SempereApp

/// A pan the test moves: what `ItemSelectionController.panned` reads from a real one.
final class FakePan: UIPanGestureRecognizer {
    var fakeState: UIGestureRecognizer.State = .began
    /// Where the finger went down, in the canvas's coordinates, and how far it moved since.
    var start: CGPoint = .zero
    var moved: CGPoint = .zero
    override var state: UIGestureRecognizer.State { get { fakeState } set { fakeState = newValue } }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: start.x + moved.x, y: start.y + moved.y) }
    override func translation(in view: UIView?) -> CGPoint { moved }
}

/// A two-finger turn the test moves (`ItemSelectionController.rotated`).
final class FakeRotation: UIRotationGestureRecognizer {
    var fakeState: UIGestureRecognizer.State = .began
    var fakeRotation: CGFloat = 0
    var touches: [CGPoint] = []
    override var state: UIGestureRecognizer.State { get { fakeState } set { fakeState = newValue } }
    override var rotation: CGFloat { get { fakeRotation } set { fakeRotation = newValue } }
    override var numberOfTouches: Int { touches.count }
    override func location(ofTouch touchIndex: Int, in view: UIView?) -> CGPoint { touches[touchIndex] }
    override func location(in view: UIView?) -> CGPoint { touches.first ?? .zero }
}

/// Device checks on what the canvas and the page strip show, automated in process: c13 the page
/// strip's thumbnails, c16 many items on a page, c40 and c41 pages loading while another device
/// writes. Gestures on items go through the selection controller's own handlers (`panned:`,
/// `rotated:`) with recognizers whose movement the test sets; `MacItemUITests` drags for real.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct ViewDeviceCheckTests {
    // MARK: - c13

    /// The thumbnail key of page `index` as the strip's row builds it, at each likely screen scale.
    static func thumbnailKeys(_ editor: NoteEditor, page index: Int) -> [NSString] {
        let page = editor.pages[index]
        let width: CGFloat = 120
        let height = CGFloat(PageStrip.thumbnailHeight(width: Double(width), pageSize: editor.pageSize))
        return [1.0, 2.0, 3.0].map { scale in
            PageThumbnail.key("\(editor.sessionID)-\(page.id)-\(editor.inkRevisions[page.id] ?? 0)-\(page.strokes.count)",
                              paper: editor.displayedPaper(of: page), pageSize: editor.pageSize,
                              size: CGSize(width: width, height: height), scale: scale)
        }
    }

    static func cachedThumbnail(_ editor: NoteEditor, page index: Int) -> UIImage? {
        thumbnailKeys(editor, page: index).lazy.compactMap { PageThumbnail.cached($0) }.first
    }

    /// The gray level (0 black, 255 white) of `image` around the page point `p`.
    static func level(_ image: UIImage, at p: CGPoint, pageWidth: CGFloat) throws -> Int {
        let cg = try #require(image.cgImage)
        let s = CGFloat(cg.width) / pageWidth
        let ctx = try #require(CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(cg, in: CGRect(x: -(p.x * s - 1), y: -(CGFloat(cg.height) - p.y * s - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        var darkest = 255
        for i in 0..<9 { darkest = min(darkest, (Int(bytes[i * 4]) + Int(bytes[i * 4 + 1]) + Int(bytes[i * 4 + 2])) / 3) }
        return darkest
    }

    /// c13: the page strip redraws a page's thumbnail about 0.4 s after the pen rests (not after
    /// every stroke), and a pixel-erased stroke is drawn as its pieces, the same as the stored note.
    @Test func c13ThePageStripRedrawsAfterThePenRestsAndDrawsErasedInkRight() async throws {
        let editor = try await StackTS.savedEditor(pages: 3)
        let window = try await CanvasFocusTests.keyWindow(width: 900, height: 1000)
        defer { window.isHidden = true }
        let strip = UIHostingController(rootView: PageStripView(editor: editor))
        strip.view.frame = CGRect(x: 0, y: 0, width: 200, height: 1000)
        window.addSubview(strip.view)
        let i = try InkInjector(editor: editor, page: editor.pages[0].id, size: CGSize(width: 700, height: 1000))
        defer { i.close() }
        #expect(await i.ready())
        #expect(await TS.waitUntil(timeout: .seconds(10)) { Self.cachedThumbnail(editor, page: 0) != nil }, "first thumbnail")

        // A thick stroke across the page: the thumbnail follows once the pen rests.
        // Pen size 12 draws 20 points wide (`NibSize`): 8 pixels in a 120-point thumbnail at 2x.
        let thick = Stroke(ink: Ink(tool: .pen, color: .black, width: 12),
                           points: (0..<40).map { k in StrokePoint(x: 100 + Double(k) * 10, y: 300, t: Double(k) * 0.01, w: 12, h: 12) })
        i.draw([thick])
        let drawn = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.cachedThumbnail(editor, page: 0) == nil, "not redrawn while the pen may still be writing")
        #expect(await TS.waitUntil(timeout: .seconds(3)) { Self.cachedThumbnail(editor, page: 0) != nil })
        let after = (ContinuousClock.now - drawn) / .milliseconds(1)
        print("PERF-REPORT c13 thumbnail redrawn \(String(format: "%.0f", after)) ms after the pen rested")
        #expect(after >= 350 && after < 2_000)
        let width = CGFloat(editor.pageSize.width)
        let inked = try #require(Self.cachedThumbnail(editor, page: 0))
        #expect(try Self.level(inked, at: CGPoint(x: 300, y: 300), pageWidth: width) < 120, "the stroke is in the thumbnail")

        // A pixel erase across its middle (a 120-point gap): the gap shows paper, the pieces ink.
        let cut = try #require(i.strokes.last).renderBounds.midX
        i.pixelErase(across: try #require(i.strokes.last).id, gap: 60)
        #expect(await TS.waitUntil(timeout: .seconds(3)) { Self.cachedThumbnail(editor, page: 0) != nil })
        let erased = try #require(Self.cachedThumbnail(editor, page: 0))
        let gapLevel = try Self.level(erased, at: CGPoint(x: cut, y: 300), pageWidth: width)
        let pieceLevel = try Self.level(erased, at: CGPoint(x: 160, y: 300), pageWidth: width)
        #expect(gapLevel > 200, "the erased part is paper (\(gapLevel))")
        #expect(pieceLevel < 120, "the pieces stay (\(pieceLevel))")
        // The stored strokes draw the same thumbnail (what a reopen shows). Stored pieces end in
        // round caps half a stroke width into the erased part (StrokeConversion: a masked range
        // becomes a trimmed stroke), so the comparison leaves 15 points around each cut out.
        await editor.flush()
        let page = editor.pages[0]
        let stored = await PageThumbnail.render(.strokes(editor.liveStrokes(of: page.id)), paper: editor.displayedPaper(of: page),
                                                pageSize: editor.pageSize, size: erased.size, scale: erased.scale)
        for x in stride(from: 100.0, through: 480, by: 20) where abs(x - Double(cut)) < 45 || abs(x - Double(cut)) > 75 {
            let a = try Self.level(erased, at: CGPoint(x: x, y: 300), pageWidth: width)
            let b = try Self.level(stored, at: CGPoint(x: x, y: 300), pageWidth: width)
            #expect(abs(a - b) < 60, "x \(x): canvas \(a), stored \(b)")
        }
        await editor.close()
    }

    // MARK: - c16

    /// A note whose first page holds 60 text boxes, 20 equations, 20 images and two audio cards.
    static func busyPage() async throws -> (Vault, NoteEditor, page: UUID, text: UUID, image: UUID, card: UUID) {
        let (vault, _) = try TS.unlockedFixture()
        let note = UUID(), page = Page(order: "a0"), rec = UUID()
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }.pngData())
        let imageRef = try vault.writeBlob(note: note, png, type: "image/png")
        let audioRef = try vault.writeBlob(note: note, Data("audio".utf8), type: "audio/mp4")
        var items: [Item] = []
        for k in 0..<60 {
            items.append(.text(TextContent(size: 12, color: .black, runs: [TextRun("Box \(k): a few words to lay out")]),
                               frame: Rect(x: 20 + Double(k % 6) * 95, y: 20 + Double(k / 6) * 50, w: 90, h: 44), z: "b\(1000 + k)"))
        }
        for k in 0..<20 {
            items.append(.math(try NoteOps.math("x^{\(k)} + \\frac{1}{\(k + 2)}"),
                               frame: Rect(x: 20 + Double(k % 5) * 110, y: 540 + Double(k / 5) * 40, w: 100, h: 34), z: "c\(1000 + k)"))
        }
        for k in 0..<20 {
            items.append(.image(blob: imageRef, pixelSize: Size(w: 8, h: 6),
                                frame: Rect(x: 20 + Double(k % 10) * 58, y: 720 + Double(k / 10) * 46, w: 52, h: 39), z: "d\(1000 + k)"))
        }
        let card = Item.audio(recording: rec, frame: Rect(x: 40, y: 840, w: 260, h: 80), z: "e1")
        let card2 = Item.audio(recording: rec, frame: Rect(x: 320, y: 840, w: 260, h: 80), z: "e2")
        items += [card, card2]
        let ops: [Op] = [.setMeta(.title("Busy")), .setMeta(.pageSize(PageSize(width: 612, height: 1000, infinite: false, breakHeight: nil))),
                         .addPage(page), .addRecording(Recording(id: rec, blob: audioRef, started: Date(), duration: 30, title: "Talk"))]
            + items.map { .addItem(page: page.id, item: $0) }
        _ = try vault.apply(ops, to: note, deviceState: TS.deviceStateURL(), app: "fixture/1")
        let (editor, _) = try await NoteEditorTests.open(vault, note: note, debounce: .seconds(60))
        return (vault, editor, page.id, items[7].id, items[85].id, card.id)
    }

    /// The selection outline's bounds on screen.
    static func outline(_ host: PageCanvasHost) -> CGRect? {
        let view = host.itemSelection.overlay
        guard !view.isHidden else { return nil }
        return (view.layer.sublayers?.first as? CAShapeLayer)?.path?.boundingBox
    }

    static func expectedOutline(_ frame: Rect, rotation: Double?, zoom: CGFloat) -> CGRect {
        let b = ItemFrames.bounds(frame, rotation: rotation)
        return CGRect(x: b.x * zoom, y: b.y * zoom, width: b.w * zoom, height: b.h * zoom)
    }

    static func close(_ a: CGRect?, _ b: CGRect, _ tol: CGFloat = 1.5) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    /// Drags `id` by `total` page points in `steps`, from `grab` (page points; the item's middle by
    /// default): each step the outline is on the item's previewed frame. Returns the frames shown.
    static func drag(_ i: InkInjector, _ id: UUID, by total: CGPoint, grab: CGPoint? = nil, steps: Int = 6,
                     sourceLocation: SourceLocation = #_sourceLocation) throws {
        let host = i.host, z = host.canvas.zoomScale
        let item = try #require(i.editor.item(id, on: i.pageID))
        let start = grab ?? CGPoint(x: item.frame.x + item.frame.w / 2, y: item.frame.y + item.frame.h / 2)
        let pan = FakePan()
        pan.start = CGPoint(x: start.x * z, y: start.y * z)
        for k in 0...steps {
            pan.fakeState = k == 0 ? .began : (k == steps ? .ended : .changed)
            pan.moved = CGPoint(x: total.x * z * CGFloat(k) / CGFloat(steps), y: total.y * z * CGFloat(k) / CGFloat(steps))
            if k == steps {
                i.grouped { _ = host.itemSelection.perform(NSSelectorFromString("panned:"), with: pan) }
            } else {
                host.itemSelection.perform(NSSelectorFromString("panned:"), with: pan)
            }
            if k < steps {
                let shown = host.itemLayer.shownFrame(of: id) ?? item.frame
                #expect(close(outline(host), expectedOutline(shown, rotation: item.rotation, zoom: z)),
                        "step \(k): outline \(String(describing: outline(host))) for \(shown)", sourceLocation: sourceLocation)
            }
        }
    }

    /// c16: on a page of 102 items, moving and resizing a text box and an image and turning an
    /// image keep the selection outline on the item through every step of the gesture, each
    /// gesture writes one delta, and the audio cards' play buttons stay on their cards (also after
    /// a card is moved).
    @Test func c16ItemsMoveResizeAndTurnWithTheirOutlineAndAudioControls() async throws {
        let (_, editor, page, text, image, card) = try await Self.busyPage()
        let i = try InkInjector(editor: editor, page: page, size: CGSize(width: 900, height: 1200))
        defer { i.close() }
        #expect(await i.ready())
        var commands = ItemCommands()
        commands.toggleRecording = { _ in }
        i.show(selecting: true, itemCommands: commands)
        #expect(editor.items(on: page).count == 102)
        let z = i.host.canvas.zoomScale
        var deltas = editor.deltasWritten
        /// After a gesture: its delta is written, and SwiftUI's update shows the page again (`show`).
        func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
            #expect(await TS.waitUntil { editor.deltasWritten >= deltas + 1 }, "one delta per gesture", sourceLocation: sourceLocation)
            #expect(editor.deltasWritten == deltas + 1, "one delta per gesture", sourceLocation: sourceLocation)
            deltas = editor.deltasWritten
            i.show(selecting: true, itemCommands: commands)
        }

        // Move a text box, then an image.
        for (id, by) in [(text, CGPoint(x: 37, y: 61)), (image, CGPoint(x: -25, y: 48))] {
            let before = try #require(editor.item(id, on: page)).frame
            i.host.itemSelection.select(id)
            #expect(Self.close(Self.outline(i.host), Self.expectedOutline(before, rotation: nil, zoom: z)))
            try Self.drag(i, id, by: by)
            await settle()
            let after = try #require(editor.item(id, on: page)).frame
            #expect(abs(after.x - before.x - by.x) < 0.01 && abs(after.y - before.y - by.y) < 0.01)
            #expect(Self.close(Self.outline(i.host), Self.expectedOutline(after, rotation: nil, zoom: z)))
        }

        // Resize the image from its bottom-right corner.
        let frame = try #require(editor.item(image, on: page)).frame
        try Self.drag(i, image, by: CGPoint(x: 30, y: 22), grab: CGPoint(x: frame.x + frame.w, y: frame.y + frame.h))
        await settle()
        let resized = try #require(editor.item(image, on: page)).frame
        #expect(resized.w > frame.w + 10 && resized.h > frame.h + 10, "\(frame) -> \(resized)")
        #expect(Self.close(Self.outline(i.host), Self.expectedOutline(resized, rotation: nil, zoom: z)))

        // Turn the image with two fingers.
        let turn = FakeRotation()
        let mid = CGPoint(x: (resized.x + resized.w / 2) * z, y: (resized.y + resized.h / 2) * z)
        turn.touches = [CGPoint(x: mid.x - 5, y: mid.y), CGPoint(x: mid.x + 5, y: mid.y)]
        for (k, degrees) in [0.0, 10, 20, 31].enumerated() {
            turn.fakeState = k == 0 ? .began : (k == 3 ? .ended : .changed)
            turn.fakeRotation = CGFloat(degrees * .pi / 180)
            if k == 3 {
                i.grouped { _ = i.host.itemSelection.perform(NSSelectorFromString("rotated:"), with: turn) }
            } else {
                i.host.itemSelection.perform(NSSelectorFromString("rotated:"), with: turn)
            }
            if k < 3 {
                #expect(Self.close(Self.outline(i.host), Self.expectedOutline(resized, rotation: degrees == 0 ? nil : degrees, zoom: z), 2),
                        "turned \(degrees)°")
            }
        }
        await settle()
        let turned = try #require(editor.item(image, on: page))
        #expect(turned.rotation != nil)
        #expect(Self.close(Self.outline(i.host), Self.expectedOutline(turned.frame, rotation: turned.rotation, zoom: z), 2))

        // Move an audio card, then leave selection mode: each card's button is on its card.
        i.host.itemSelection.select(card)
        try Self.drag(i, card, by: CGPoint(x: 20, y: -30))
        await settle()
        i.host.itemSelection.select(nil)
        i.show(selecting: false, itemCommands: commands)
        let buttons = i.host.canvas.subviews.compactMap { $0 as? AudioCardButton }
        let cards = editor.items(on: page).filter { $0.kind == .audio }
        #expect(buttons.count == cards.count)
        for c in cards {
            let badge = AudioCard(frame: c.frame).badge(rotation: c.rotation)
            let expected = CGPoint(x: CGFloat(badge.center.x) * z, y: CGFloat(badge.center.y) * z)
            #expect(buttons.contains { abs($0.center.x - expected.x) < 1 && abs($0.center.y - expected.y) < 1 },
                    "a button on the card at \(c.frame)")
        }
        await editor.close()
    }

    // MARK: - c40, c41

    /// A paged note of `pages` letter pages, each with `strokes` strokes, written by another device.
    static func densePagedNote(pages count: Int, strokes: Int) throws -> (url: URL, key: URL, vault: Vault, note: UUID, pages: [UUID]) {
        let (url, key) = try AppModelTests.fixtureVault()
        let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))])
        let note = UUID()
        var ops: [Op] = [.setMeta(.title("Paged")), .setMeta(.pageSize(.letter))]
        var order: String?
        var pages: [UUID] = []
        for k in 0..<count {
            order = PageOrder.between(order, nil)
            let page = Page(order: order ?? "a0")
            pages.append(page.id)
            ops.append(.addPage(page))
            var ink = SyntheticInk(seed: UInt64(k + 1), options: .init(pointsPerStroke: 16, rowHeight: 9, top: 30))
            ops += ink.strokes(strokes).map { .addStroke(page: page.id, stroke: $0) }
        }
        _ = try vault.apply(ops, to: note, deviceState: TS.deviceStateURL(), app: "fixture/1")
        return (url, key, vault, note, pages)
    }

    /// Every page with a canvas shows exactly the editor's strokes of that page.
    static func everyShownPageIsReal(_ stack: PageStackHost, _ editor: NoteEditor,
                                     sourceLocation: SourceLocation = #_sourceLocation) async {
        for (id, slot) in stack.slots {
            #expect(await StackTS.ready(slot), sourceLocation: sourceLocation)
            #expect(DrawingPreparation.matches(slot.host.canvas.drawing, editor.liveStrokes(of: id)),
                    "page \(editor.pages.firstIndex { $0.id == id } ?? -1) shows \(slot.host.canvas.drawing.strokes.count) strokes",
                    sourceLocation: sourceLocation)
        }
    }

    /// c40: a paged note of dense pages; page 3 is scrolled to and, while its ink is still being
    /// prepared, another device draws on it and erases a stroke there, the merge arrives, and the
    /// page is scrolled away and back. Once loaded it shows the merged ink exactly; a stroke drawn
    /// on it then saves alone (nothing lost, nothing echoed or doubled).
    @Test func c40ScrollingAPageOutAndBackWhileItLoadsWithASecondWriterLosesNothing() async throws {
        let perPage = InkFixture.scaled(3_000)
        let n = try Self.densePagedNote(pages: 6, strokes: perPage)
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: n.vault, noteID: n.note, clock: clock, debounce: .seconds(60))
        let (window, stack) = StackTS.stack(editor, size: CGSize(width: 800, height: 1000))
        defer { window.isHidden = true }
        let first = try StackTS.slot(stack, editor, page: 0)
        #expect(await StackTS.ready(first))

        StackTS.scroll(stack, toShowTopOf: 3)
        stack.layoutIfNeeded()
        let third = try StackTS.slot(stack, editor, page: 3)
        let wasLoading = third.host.isPreparing
        let remote = TS.stroke(x: 300, y: 700, n: 30)
        let gone = try #require(n.vault.reconstruct(noteId: n.note).pages[3].strokes.first).id
        try TS.writeAsAnotherDevice([.addStroke(page: n.pages[3], stroke: remote), .removeStroke(page: n.pages[3], strokeId: gone)],
                                    to: n.note, vault: n.url, key: n.key)
        _ = try await editor.mergeRevisions(vault: n.vault, clock: clock, coordinated: false, verify: nil)
        StackTS.refresh(stack, editor)
        StackTS.scroll(stack, toShowTopOf: 0)
        stack.layoutIfNeeded()
        StackTS.scroll(stack, toShowTopOf: 3)
        StackTS.refresh(stack, editor)
        print("c40: page 3 was \(wasLoading ? "still loading" : "already loaded") when the merge arrived")
        await Self.everyShownPageIsReal(stack, editor)
        let shown = try StackTS.slot(stack, editor, page: 3)
        #expect(shown.host.canvas.drawing.strokes.count == perPage)
        #expect(editor.liveStrokes(of: n.pages[3]).contains { $0.id == remote.id })
        #expect(!editor.liveStrokes(of: n.pages[3]).contains { $0.id == gone })

        // Drawing on the page now saves exactly that stroke.
        var drawing = shown.host.canvas.drawing
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 100, y: 740, n: 20)))
        shown.host.canvas.drawing = drawing
        await editor.flush()
        let mine = try NoteEditorTests.myDeltas(n.vault, clock, note: n.note)
        #expect(mine.count == 1 && mine.first?.count == 1, "only the new stroke is written: \(mine.map(\.count))")
        let disk = try n.vault.reconstruct(noteId: n.note).pages[3].strokes
        #expect(disk.count == perPage + 1 && Set(disk.map(\.id)).count == perPage + 1)
        #expect(try n.vault.strokeConflicts(of: n.note).duplicates.isEmpty)
        await editor.close()
    }

    /// c41: a note opened from the drawing cache while another device edits it (before its
    /// revisions are read, and right after): once read, every page with a canvas shows the real
    /// ink, the other device's strokes included, and nothing is written for it.
    @Test func c41OpeningFromTheDrawingCacheWhileAnotherCopyEditsShowsTheRealInk() async throws {
        let n = try Self.densePagedNote(pages: 3, strokes: InkFixture.scaled(1_500))
        let root = DrawingCacheTests.tempDir()
        let identity = try IdentityFile.parse(try String(contentsOf: n.key, encoding: .utf8))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), drawingCacheRoot: root)
        defer { model.close() }
        try await model.openVault(at: n.url, identities: [identity])
        let first = try await DrawingCacheTests.open(model, n.note)
        for p in n.pages { _ = await first.prepareDrawing(for: p) }
        let cache = try #require(model.drawingCache)
        let key = try DrawingCacheTests.key(n.url, n.note)
        #expect(await TS.waitUntil(timeout: .seconds(20)) { cache.layout(key) != nil && n.pages.allSatisfy { cache.drawing(key, page: $0) != nil } })
        try await model.openEditor(for: nil)

        // The other device writes after the listing, while this one opens from the cache.
        let gate = Gate()
        await gate.close()
        model.editorLoadHook = { await gate.pass() }
        model.selectedNoteID = n.note
        try await model.openEditor(for: n.note)
        let editor = try #require(model.editor)
        #expect(editor.openedFromCache && editor.isPreparing)
        let (window, stack) = StackTS.stack(editor, size: CGSize(width: 800, height: 2400))
        defer { window.isHidden = true }
        let a = TS.stroke(x: 200, y: 300, n: 30), b = TS.stroke(x: 260, y: 500, n: 30)
        let gone = try #require(n.vault.reconstruct(noteId: n.note).pages[1].strokes.last).id
        try TS.writeAsAnotherDevice([.addStroke(page: n.pages[0], stroke: a), .addStroke(page: n.pages[1], stroke: b),
                                     .removeStroke(page: n.pages[1], strokeId: gone)], to: n.note, vault: n.url, key: n.key)
        await gate.open()
        await editor.loaded()
        StackTS.refresh(stack, editor)
        #expect(!editor.isReadOnly)
        #expect(stack.slots.count >= 2)
        await Self.everyShownPageIsReal(stack, editor)
        #expect(editor.liveStrokes(of: n.pages[0]).contains { $0.id == a.id })
        #expect(editor.liveStrokes(of: n.pages[1]).contains { $0.id == b.id })
        #expect(!editor.liveStrokes(of: n.pages[1]).contains { $0.id == gone })
        await editor.flush()
        let mine = try n.vault.loadNote(n.note).revisions.filter { !["fixture/1", "other-device/1"].contains($0.app) }
        #expect(mine.isEmpty, "nothing written for what was shown")
    }
}

extension AttachmentPersistenceTests {
    /// c16: text boxes and equations drawn by CoreText are cached on disk under the system and
    /// fonts they were drawn with. A reopen after an OS update or a font install (a cache with
    /// another salt) draws every one again instead of showing the old pictures; the same system
    /// reopens from the cache.
    @Test func c16TextAndEquationsAreDrawnAgainAfterAFontOrSystemChange() async throws {
        let (vault, _) = try TS.unlockedFixture()
        var items = (0..<40).map { k -> Item in
            var t = AttachmentEditorTests.textItem("Text box \(k), several words long")
            t.frame = Rect(x: Double(k % 5) * 110, y: Double(k / 5) * 60, w: 100, h: 50)
            return t
        }
        for k in 0..<10 {
            items.append(.math(try NoteOps.math("a_{\(k)} = \\sqrt{\(k + 1)}"), frame: Rect(x: Double(k) * 55, y: 520, w: 50, h: 30),
                               z: "m\(k)"))
        }
        let renders = Self.root()
        func show(_ salt: String) async throws -> RenderCache {
            let cache = RenderCache(root: renders, vault: vault, salt: salt)
            let view = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            view.show(items, note: Self.lecture, paper: .blank, source: ItemLayerSource(cache: nil, renders: cache))
            #expect(await TS.waitUntil(timeout: .seconds(60)) { view.isSettled })
            #expect(items.allSatisfy { if case .image? = view.picture(of: $0.id) { true } else { false } })
            await cache.waitForWrites()
            return cache
        }
        let first = try await show("os-1|fonts-a")
        #expect(first.diskHits == 0)
        #expect(try await show("os-1|fonts-a").diskHits == items.count, "the same system reopens from the cache")
        #expect(try await show("os-1|fonts-b").diskHits == 0, "a font install draws every box again")
        #expect(try await show("os-2|fonts-a").diskHits == 0, "so does an OS update")
    }
}
