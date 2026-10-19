import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The iPad canvas after the owner's TestFlight 1.0.0 feedback: a tap selects
/// and never shows the menu (a held finger, a secondary click or the
/// selection bar's menu button does), clips and cards play only from their
/// buttons, Delete is on the selection, the text tool is one-shot, new items
/// land below the page's items, the fitted width is a zoom detent, and a
/// touch on the canvas brings the palette back. The interactions themselves
/// are in `IPadCanvasUITests` (iPad simulator).
@MainActor
struct IPadCanvasTests {
    // MARK: One-shot text tool

    @Test func theTextToolIsOneShotAndGoesBackToDrawing() {
        var modes = CanvasModes()
        modes.addingText = true
        #expect(modes.addingText && !modes.selectingItems)
        modes.textToolEnded(.placed)
        #expect(modes.mode == .drawing, "one box, then the palette's tool again")
        // Picking a tool ends it too; so does turning the toggle off.
        modes.addingText = true
        modes.textToolEnded(.toolPicked)
        #expect(modes.mode == .drawing)
        modes.addingText = true
        modes.addingText = false
        #expect(modes.mode == .drawing)
    }

    @Test func theTextToolGoesBackToSelectionModeWhenItCameFromThere() {
        var modes = CanvasModes()
        modes.selectingItems = true
        modes.addingText = true
        #expect(modes.addingText && !modes.selectingItems, "one mode at a time")
        modes.textToolEnded(.placed)
        #expect(modes.selectingItems)
        // A second placement from there does not remember the first.
        modes.addingText = true
        modes.selectingItems = false
        #expect(modes.addingText, "turning off a mode that is not on changes nothing")
        modes.selectingItems = true
        #expect(modes.selectingItems && !modes.addingText)
        modes.reset()
        #expect(modes.mode == .drawing && modes.returnTo == .drawing)
        modes.textToolEnded(.placed)
        #expect(modes.mode == .drawing, "nothing to end")
    }

    /// The canvas reports the one placement: a box started on the empty page ends the tool when
    /// its edit ends; editing an existing box does not.
    @Test func theHostEndsTheTextToolAfterItsBox() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let text = try editor.addItems([AttachmentEditorTests.textItem()], on: page)[0]
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        host.textEditor.reset(editor: editor, pageID: page)
        var ends: [CanvasModes.TextToolEnd] = []
        host.onTextToolEnded = { ends.append($0) }
        host.textToolActive = true
        // Editing an existing box: the tool stays.
        host.textEditor.begin(text)
        #expect(host.textEditor.isEditing)
        host.textEditor.endEditing()
        #expect(ends.isEmpty)
        // A new box on the empty page: its end ends the tool.
        let empty = try #require(host.itemSelection.onEmptyTap)
        empty(ItemFrames.Point(x: 100, y: 400))
        #expect(host.textEditor.isEditing)
        host.textEditor.endEditing()
        #expect(ends == [.placed])
        await editor.flush()
    }

    // MARK: Zoom detent

    @Test func aPinchNearTheFitSettlesOnIt() {
        let fit = 1.2
        #expect(ZoomDetent.settle(fit * 1.1, fit: fit, paged: true) == fit)
        #expect(ZoomDetent.settle(fit * 0.9, fit: fit, paged: true) == fit)
        #expect(ZoomDetent.settle(fit * 1.11, fit: fit, paged: false) == fit)
        #expect(abs(ZoomDetent.settle(fit * 1.5, fit: fit, paged: true) - fit * 1.5) < 1e-9, "beyond the band it stays")
        #expect(abs(ZoomDetent.settle(fit * 0.7, fit: fit, paged: true) - fit * 0.7) < 1e-9, "a paged note zooms out")
        #expect(abs(ZoomDetent.settle(fit * 0.7, fit: fit, paged: false) - fit * 0.7) < 1e-9, "a pageless note zooms out too")
        #expect(ZoomDetent.settle(fit * 0.2, fit: fit, paged: false) == fit * 0.5)
        #expect(ZoomDetent.settle(fit * 0.7, fit: fit, paged: false, isPhone: true) == fit, "an iPhone's pageless note stops at the fit")
        #expect(abs(ZoomDetent.settle(fit * 0.7, fit: fit, paged: true, isPhone: true) - fit * 0.7) < 1e-9)
        #expect(ZoomDetent.settle(fit * 0.2, fit: fit, paged: true) == fit * 0.5)
        #expect(ZoomDetent.settle(fit * 9, fit: fit, paged: true) == fit * ZoomSteps.maxFactor)
        #expect(ZoomDetent.settle(.nan, fit: fit, paged: true) == fit)
        #expect(ZoomDetent.settle(2, fit: .infinity, paged: true) == 1)
        #expect(ZoomDetent.isFit(fit, fit: fit) && !ZoomDetent.isFit(fit * 1.01, fit: fit))
    }

    /// The page stack bakes a pinch through the detent: near the fit it lands on the fit, below
    /// it the pages zoom out to half the fit, centered; a big pinch stays.
    @Test func aPinchOnThePagesSettlesOnTheFit() async throws {
        let editor = try await StackTS.editor(pages: 4)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let fit = try #require(stack.fitScale)
        stack.scroller.setZoomScale(1.08, animated: false)
        stack.bake()
        #expect(abs(stack.scale - fit) < 0.0005, "near the fit: the fit")
        stack.scroller.setZoomScale(2, animated: false)
        stack.bake()
        #expect(abs(stack.scale - fit * 2) < 0.001, "a big pinch stays")
        stack.scroller.setZoomScale(0.53, animated: false)
        stack.bake()
        #expect(abs(stack.scale - fit) < 0.0005, "back near the fit: the fit again")
        stack.scroller.setZoomScale(0.6, animated: false)
        stack.bake()
        #expect(abs(stack.scale - fit * 0.6) < 0.001, "below the fit: an overview of the pages")
        #expect(abs(stack.content.frame.midX - stack.scroller.bounds.width / 2) < 1, "centered")
        #expect(stack.scroller.minimumZoomScale <= 0.5 / 0.6 + 0.001)
        stack.scroller.setZoomScale(0.5, animated: false)
        stack.bake()
        #expect(abs(stack.scale - fit * 0.5) < 0.001, "never below half the fit")
    }

    @Test func pagesZoomedOutStandInTheMiddle() {
        #expect(PageStackHost.sideMargin(contentWidth: 400, viewWidth: 1000) == 300)
        #expect(PageStackHost.sideMargin(contentWidth: 1200, viewWidth: 1000) == 0)
        #expect(PageStackHost.sideMargin(contentWidth: .nan, viewWidth: 1000) == 0)
    }

    // MARK: Selection bar

    @Test func theBarSitsAboveTheItemClearOfItsHandles() {
        let content = CGSize(width: 800, height: 2000)
        let above = ItemSelectionBar.frame(around: CGRect(x: 100, y: 300, width: 200, height: 100), width: 84, in: content)
        #expect(above.maxY <= 300 - ItemSelectionBar.gap + 0.001)
        #expect(abs(above.midX - 200) < 0.001)
        let below = ItemSelectionBar.frame(around: CGRect(x: 100, y: 10, width: 200, height: 100), width: 84, in: content)
        #expect(below.minY >= 110 + ItemSelectionBar.gap - 0.001, "no room above: below")
        let inside = ItemSelectionBar.frame(around: CGRect(x: 0, y: 0, width: 800, height: 2000), width: 84, in: content)
        #expect(inside.minY >= 0 && inside.maxY <= 2000, "a page-sized item: inside its top")
        let edge = ItemSelectionBar.frame(around: CGRect(x: 760, y: 500, width: 40, height: 40), width: 84, in: content)
        #expect(edge.maxX <= 800, "within the page's width")
    }

    /// A selected item shows the bar (iPad); its Delete deletes the item (one delta, undoable)
    /// and the Delete key does the same.
    @Test func theSelectionHasDelete() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let image = try editor.addItems([CanvasSelectionTests.image()], on: page)[0]
        let second = try editor.addItems([CanvasSelectionTests.image(frame: Rect(x: 100, y: 400, w: 200, h: 100))], on: page)[0]
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        #expect(host.itemSelection.bar.isHidden)
        host.itemSelection.pick(image.id, menu: false)
        #expect(host.itemSelection.bar.isHidden == Platform.isMac, "the bar on the iPad; a Mac has its menus")
        #expect(!host.itemSelection.bar.deleteButton.isHidden)
        #expect(!host.itemSelection.menuElements().isEmpty, "the menu button offers the item's menu")
        host.itemSelection.bar.onDelete()
        #expect(editor.items(on: page).map(\.id) == [second.id])
        #expect(host.itemSelection.selectedID == nil && host.itemSelection.bar.isHidden)
        // The Delete key, while an item is selected.
        #expect(!(host.keyCommands ?? []).contains { $0.input == UIKeyCommand.inputDelete }, "nothing selected: the key is not ours")
        host.itemSelection.pick(second.id, menu: false)
        let delete = try #require(host.keyCommands?.first { $0.input == UIKeyCommand.inputDelete })
        #expect(delete.modifierFlags.isEmpty)
        #expect(host.itemSelection.perform(.deleteItem))
        #expect(editor.items(on: page).isEmpty)
        await editor.flush()
    }

    // MARK: Play only from the buttons

    /// A clip's play button is in the canvas outside selection mode (a tap elsewhere on the clip
    /// selects it); in selection mode it goes, as the cards' buttons do.
    @Test func clipsPlayFromTheirButtonOnly() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let clip = Item.video(blob: BlobRef(content: Data("v".utf8), type: "video/mp4"), pixelSize: Size(w: 1920, h: 1080),
                              duration: 3, frame: Rect(x: 100, y: 100, w: 320, h: 180), z: "b")
        let video = try editor.addItems([clip], on: page)[0]
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 612, height: 800))
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: nil)
        var played: [UUID] = []
        var commands = ItemCommands()
        commands.play = { item, _ in played.append(item.id) }
        host.itemSelection.commands = commands
        host.itemSelection.refresh()
        let button = try #require(host.canvas.subviews.compactMap { $0 as? VideoPlayButton }.first)
        #expect(button.item?.id == video.id)
        #expect(button.bounds.width >= 44)
        #expect(abs(button.center.x - 260 * host.canvas.zoomScale) < 0.5)
        button.sendActions(for: .primaryActionTriggered)
        #expect(played == [video.id])
        host.itemSelectionActive = true
        host.itemSelection.refresh()
        #expect(!host.canvas.subviews.contains { $0 is VideoPlayButton }, "selection mode: the clip is moved, not played")
        await editor.flush()
    }

    // MARK: Placement

    /// A second recording's card, placed on the same view, goes below the first.
    @Test func aSecondCardGoesBelowTheFirst() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .milliseconds(50))
        let page = try #require(editor.currentPage).id
        let r = try await editor.addRecording(file: RecordingTests.tone, started: Date(timeIntervalSince1970: 1_800_000_000),
                                              place: true)
        let second = try #require(editor.placeRecording(r.id))
        let cards = editor.items(on: page).filter { $0.kind == .audio }
        #expect(cards.count == 2)
        let first = try #require(cards.first { $0.id != second.id })
        #expect(second.frame.y >= first.frame.y + first.frame.h, "below, not on top")
        await editor.flush()
    }

    // MARK: The palette comes back

    /// Something else took the first responder: a touch on the canvas takes it back with the palette.
    @Test func aTouchOnTheCanvasBringsThePaletteBack() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let host = PageCanvasHost(frame: window.bounds)
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.addSubview(host)
        window.addSubview(field)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        _ = field.becomeFirstResponder()
        #expect(!host.canvas.isFirstResponder)
        host.reclaimFocus()
        #expect(host.canvas.isFirstResponder, "the touch's canvas has the focus again (the palette follows it; shown in IPadCanvasUITests)")
    }
}
