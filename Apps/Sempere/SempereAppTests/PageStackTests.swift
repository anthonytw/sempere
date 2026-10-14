import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// Helpers for the paged canvas (`PageStackHost`) suites.
@MainActor
enum StackTS {
    /// The fixture's lecture note, paged, with at least `pages` pages (added
    /// in memory; the long debounce keeps them from being written).
    static func editor(pages: Int = 2) async throws -> NoteEditor {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(600))
        if editor.isPageless { await editor.setLayout(pageless: false) }
        while editor.pages.count < pages { editor.addPage() }
        editor.selectPage(0)   // adding showed the last page
        return editor
    }

    static func configuration(_ editor: NoteEditor, drawingSuspended: Bool = false,
                              selectingItems: Bool = false) -> PageStackHost.Configuration {
        PageStackHost.Configuration(editor: editor, pageIDs: editor.pages.map(\.id), pageSize: editor.pageSize,
                                    pageJump: editor.pageJump, generation: editor.canvasGeneration,
                                    drawingSuspended: drawingSuspended, selectingItems: selectingItems)
    }

    /// A new paged note of `pages` pages written to the vault before it is
    /// opened, so no page counts as edited in this session (`dirtyPages`:
    /// search highlights leave those out; pages `editor(pages:)` adds are).
    static func savedEditor(pages count: Int) async throws -> NoteEditor {
        let (vault, _) = try TS.unlockedFixture()
        let id = UUID()
        var ops = NoteOps.newNote(title: "Stack")
        var order = ops.compactMap { op -> String? in if case .addPage(let p) = op { return p.order }; return nil }.last
        for _ in 1..<max(count, 1) {
            let next = PageOrder.between(order, nil)
            ops.append(.addPage(Page(id: UUID(), order: next)))
            order = next
        }
        try vault.apply(ops, to: id, deviceState: TS.deviceStateURL(), app: "test")
        let (editor, _) = try await NoteEditorTests.open(vault, note: id, debounce: .seconds(600))
        return editor
    }

    /// A stack showing `editor` in a window of `size`.
    static func stack(_ editor: NoteEditor, size: CGSize = CGSize(width: 1024, height: 1366),
                      drawingSuspended: Bool = false) -> (UIWindow, PageStackHost) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let stack = PageStackHost(frame: window.bounds)
        window.addSubview(stack)
        window.isHidden = false
        stack.update(configuration(editor, drawingSuspended: drawingSuspended))
        stack.layoutIfNeeded()
        return (window, stack)
    }

    /// What SwiftUI does after the editor changed: the stack gets the new configuration.
    static func refresh(_ stack: PageStackHost, _ editor: NoteEditor) {
        stack.update(configuration(editor))
        stack.layoutIfNeeded()
    }

    /// Index in `editor.pages` of each page that has a canvas.
    static func shownIndices(_ stack: PageStackHost, _ editor: NoteEditor) -> [Int] {
        stack.slots.keys.compactMap { id in editor.pages.firstIndex { $0.id == id } }.sorted()
    }

    /// Scrolls as the user would (not a jump): the delegate sees it.
    static func scroll(_ stack: PageStackHost, toShowTopOf page: Int, plus extra: CGFloat = 0) {
        let y = stack.layout.offset(toShow: page, scale: Double(stack.scale), viewportHeight: Double(stack.scroller.bounds.height))
        stack.scroller.contentOffset = CGPoint(x: 0, y: CGFloat(y) + extra)
    }

    static func slot(_ stack: PageStackHost, _ editor: NoteEditor, page index: Int) throws -> PageStackHost.Slot {
        try #require(stack.slots[editor.pages[index].id], "page \(index) has no canvas")
    }

    /// Waits until the page's canvas shows its ink (it is prepared off the main actor).
    static func ready(_ slot: PageStackHost.Slot) async -> Bool {
        await TS.waitUntil { !slot.host.isPreparing && !slot.coordinator.isLoading }
    }
}

/// The paged canvas: all pages in one scroll, lazily drawn.
@MainActor
@Suite(.serialized)
struct PageStackTests {
    @Test func onlyPagesNearTheScreenGetACanvas() async throws {
        let editor = try await StackTS.editor(pages: 200)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        // Top of the note: the first page and the next one within a screen.
        #expect(StackTS.shownIndices(stack, editor).first == 0)
        #expect(stack.slots.count <= 3)
        StackTS.scroll(stack, toShowTopOf: 100)
        let shown = StackTS.shownIndices(stack, editor)
        #expect(shown.contains(100))
        #expect(shown.allSatisfy { (98...102).contains($0) }, "\(shown)")
        #expect(stack.slots.count <= 4)
        #expect(stack.spares.count <= PageStackHost.spareLimit)
        // Every canvas in the content belongs to a page on screen.
        #expect(stack.content.subviews.filter { $0 is PageCanvasHost }.count == stack.slots.count)
        // Pages never near the screen were never converted.
        #expect(editor.readyDrawing(for: editor.pages[150].id) == nil)
        #expect(editor.readyDrawing(for: editor.pages[60].id) == nil)
    }

    /// GA-13: the Mac's item commands in a paged note act on the current page's selected
    /// item. Each page's canvas keeps its own selection, and the command went to whichever
    /// canvas a dictionary listed first, so Delete Item (⌥⌘⌫) could remove an item on a page
    /// the user was not looking at.
    @Test func itemCommandsActOnTheCurrentPagesSelection() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let a = try editor.addItems([CanvasSelectionTests.image()], on: editor.pages[0].id)[0]
        let b = try editor.addItems([CanvasSelectionTests.image()], on: editor.pages[1].id)[0]
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        stack.update(StackTS.configuration(editor, selectingItems: true))
        stack.layoutIfNeeded()
        #expect(!stack.perform(itemCommand: .deleteItem), "nothing selected")
        try StackTS.slot(stack, editor, page: 0).host.itemSelection.select(a.id)
        try StackTS.slot(stack, editor, page: 1).host.itemSelection.select(b.id)
        editor.selectPage(1)
        #expect(stack.perform(itemCommand: .deleteItem))
        #expect(!editor.items(on: editor.pages[1].id).map(\.id).contains(b.id), "the current page's item")
        #expect(editor.items(on: editor.pages[0].id).map(\.id).contains(a.id), "the other page's item stays")
        // With none on the current page, the first page in order that has one.
        #expect(stack.perform(itemCommand: .deleteItem))
        #expect(!editor.items(on: editor.pages[0].id).map(\.id).contains(a.id))
        await editor.flush()
    }

    @Test func pagesSitInOneScrollWithAGapBetweenThem() async throws {
        let editor = try await StackTS.editor(pages: 5)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let fit = try #require(stack.fitScale)
        #expect(abs(stack.scale - 1024 / CGFloat(editor.pageSize.width)) < 0.0005)
        #expect(stack.scale == fit)
        for (id, slot) in stack.slots {
            let index = try #require(editor.pages.firstIndex { $0.id == id })
            #expect(PageStackHost.sameFrame(slot.host.frame, stack.layout.pageFrame(index, scale: Double(stack.scale))))
            #expect(slot.host.isEmbedded)
            #expect(!slot.host.canvas.isScrollEnabled)
        }
        let first = try StackTS.slot(stack, editor, page: 0).host.frame
        let second = try StackTS.slot(stack, editor, page: 1).host.frame
        #expect(second.minY - first.maxY >= CGFloat(PageStackLayout.gap) * stack.scale - 0.001, "a visible break")
        #expect(stack.scroller.contentSize.height >= CGFloat(stack.layout.footerTop(scale: Double(stack.scale))))
    }

    @Test func theCurrentPageFollowsTheScroll() async throws {
        let editor = try await StackTS.editor(pages: 20)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let jumps = editor.pageJump
        StackTS.scroll(stack, toShowTopOf: 7, plus: 30)
        #expect(editor.pageIndex == 7)
        StackTS.scroll(stack, toShowTopOf: 3, plus: 30)
        #expect(editor.pageIndex == 3)
        #expect(editor.pageJump == jumps, "scrolling is not a jump")
        StackTS.refresh(stack, editor)
        #expect(editor.pageIndex == 3, "the update after a scroll does not scroll back")
    }

    /// The strip and the toolbar choose a page: the stack scrolls to it, and it
    /// stays the current page (also near the end, where it cannot reach the top).
    @Test func choosingAPageScrollsToIt() async throws {
        let editor = try await StackTS.editor(pages: 60)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        for page in [42, 59, 58, 0] {
            editor.selectPage(page)
            StackTS.refresh(stack, editor)
            let y = stack.layout.offset(toShow: page, scale: Double(stack.scale), viewportHeight: 1366)
            #expect(abs(Double(stack.scroller.contentOffset.y) - y) < 0.5, "page \(page)")
            #expect(stack.slots[editor.pages[page].id] != nil)
            #expect(editor.pageIndex == page)
        }
        // The current page again, scrolled half away: tapping it brings it back.
        StackTS.scroll(stack, toShowTopOf: 0, plus: 200)
        editor.selectPage(0)
        StackTS.refresh(stack, editor)
        #expect(stack.scroller.contentOffset.y == 0)
    }

    @Test func pageActionsFromTheStripKeepWorking() async throws {
        let editor = try await StackTS.editor(pages: 4)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        // Add at the end: the stack shows the new page.
        editor.addPage()
        StackTS.refresh(stack, editor)
        #expect(editor.pageIndex == 4)
        #expect(stack.slots[editor.pages[4].id] != nil)
        // Move: canvases follow their pages to their new places.
        editor.movePage(from: 4, to: 0)
        StackTS.refresh(stack, editor)
        for (id, slot) in stack.slots {
            let index = try #require(editor.pages.firstIndex { $0.id == id })
            #expect(PageStackHost.sameFrame(slot.host.frame, stack.layout.pageFrame(index, scale: Double(stack.scale))))
        }
        // Duplicate, delete, undo: the page count and the layout follow.
        editor.duplicatePage(editor.pages[1].id)
        StackTS.refresh(stack, editor)
        #expect(stack.layout.count == 6)
        #expect(editor.pageIndex == 2)
        #expect(stack.slots[editor.pages[2].id] != nil)
        editor.deletePage(editor.pages[2].id)
        StackTS.refresh(stack, editor)
        #expect(stack.layout.count == 5)
        #expect(stack.slots.keys.allSatisfy { id in editor.pages.contains { $0.id == id } })
        editor.undoDeletePage()
        StackTS.refresh(stack, editor)
        #expect(stack.layout.count == 6)
        #expect(stack.slots[editor.pages[editor.pageIndex].id] != nil)
    }

    @Test func theAddPageButtonEndsTheNote() async throws {
        let editor = try await StackTS.editor(pages: 2)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        #expect(!stack.footerButton.isHidden)
        #expect(stack.footerButton.frame.minY >= CGFloat(stack.layout.footerTop(scale: Double(stack.scale))))
        #expect(stack.content.bounds.height >= stack.footerButton.frame.maxY)
        stack.footerButton.sendActions(for: .primaryActionTriggered)
        #expect(editor.pages.count == 3)
        // No per-page footers inside the stack.
        #expect(stack.slots.values.allSatisfy { $0.host.footer == .none })
    }

    /// Ink drawn on a page is stored in that page's own coordinates, not the stack's.
    @Test func inkStaysInItsPagesCoordinates() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 1)
        #expect(await StackTS.ready(slot))
        let page = editor.pages[1].id
        let before = editor.liveStrokes(of: page).count
        var drawing = slot.host.canvas.drawing
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50, y: 100)))
        slot.host.canvas.drawing = drawing
        #expect(await TS.waitUntil { editor.liveStrokes(of: page).count == before + 1 })
        let stroke = try #require(editor.liveStrokes(of: page).last)
        let start = try #require(stroke.points.first)
        #expect(abs(start.x - 50) < 0.01 && abs(start.y - 100) < 0.01)
        #expect(stroke.transform == nil || stroke.transform == .identity)
        #expect(editor.liveStrokes(of: editor.pages[0].id).count == editor.pages[0].strokes.count, "no ink leaks to page 1")
    }

    /// A canvas taken back when its page leaves the screen never erases the
    /// page, and the page's ink is back when it returns.
    @Test func recyclingACanvasKeepsThePagesInk() async throws {
        let editor = try await StackTS.editor(pages: 40)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 0)
        #expect(await StackTS.ready(slot))
        let page = editor.pages[0].id
        var drawing = slot.host.canvas.drawing
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 200)))
        slot.host.canvas.drawing = drawing
        let count = editor.liveStrokes(of: page).count
        StackTS.scroll(stack, toShowTopOf: 30)
        #expect(stack.slots[page] == nil)
        StackTS.scroll(stack, toShowTopOf: 20)
        StackTS.scroll(stack, toShowTopOf: 0)
        #expect(editor.liveStrokes(of: page).count == count)
        let back = try StackTS.slot(stack, editor, page: 0)
        #expect(await StackTS.ready(back))
        #expect(back.host.canvas.drawing.strokes.count == count)
    }

    @Test func eachPageHasItsOwnUndo() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let a = try StackTS.slot(stack, editor, page: 0), b = try StackTS.slot(stack, editor, page: 1)
        let ua = try #require(a.host.canvas.undoManager), ub = try #require(b.host.canvas.undoManager)
        #expect(ua !== ub)
        #expect(ua === a.host.undoManager)
        // The one-page canvas keeps the window's.
        let single = PageCanvasHost(frame: .zero)
        window.addSubview(single)
        #expect(single.canvas.undoManager !== ua)
        single.removeFromSuperview()
    }

    @Test func zoomAppliesAcrossPages() async throws {
        let editor = try await StackTS.editor(pages: 10)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let fit = try #require(stack.fitScale)
        StackTS.scroll(stack, toShowTopOf: 4)
        // Menu zoom (Mac, keyboard): every page at the new scale.
        stack.zoom(in: true)
        #expect(abs(stack.scale - fit * 1.25) < 0.0005)
        func expectPagesAtScale() throws {
            for (id, slot) in stack.slots {
                let index = try #require(editor.pages.firstIndex { $0.id == id })
                #expect(PageStackHost.sameFrame(slot.host.frame, stack.layout.pageFrame(index, scale: Double(stack.scale))))
                #expect(abs(slot.host.canvas.zoomScale - stack.scale) < 0.0005)
            }
        }
        try expectPagesAtScale()
        #expect((3...5).contains(editor.pageIndex), "zoom keeps the place in the note")
        // A pinch: the scroll view's zoom is baked into the page scale when it ends.
        stack.scroller.setZoomScale(2, animated: false)
        stack.bake()
        #expect(stack.scroller.zoomScale == 1)
        #expect(stack.content.transform == .identity)
        #expect(abs(stack.scale - fit * 2.5) < 0.001)
        try expectPagesAtScale()
        #expect(stack.scroller.contentSize == stack.layout.contentSize(scale: Double(stack.scale)))
        // Never beyond 4x, never below the fit.
        stack.setScale(fit * 10)
        #expect(abs(stack.scale - fit * 4) < 0.001)
        stack.zoomToFit()
        #expect(stack.scale == fit)
        try expectPagesAtScale()
        #expect(abs(stack.scroller.minimumZoomScale - 1) < 0.0001)
        #expect(abs(stack.scroller.maximumZoomScale - 4) < 0.0001)
    }

    /// A wider window (rotation, split view) refits the pages and keeps the place.
    @Test func aNewWidthRefitsThePages() async throws {
        let editor = try await StackTS.editor(pages: 10)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        StackTS.scroll(stack, toShowTopOf: 6, plus: 10)
        #expect(editor.pageIndex == 6)
        window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        stack.frame = window.bounds
        stack.layoutIfNeeded()
        #expect(abs(stack.scale - 1366 / CGFloat(editor.pageSize.width)) < 0.0005)
        #expect(editor.pageIndex == 6)
    }

    /// The Pencil draws and never scrolls; when fingers draw, two scroll.
    @Test func penAndFingers() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        #expect(!PageStackHost.panTouchTypes(drawing: true, isMac: false).contains(pencil))
        #expect(PageStackHost.panTouchTypes(drawing: true, isMac: false).contains(finger))
        #expect(PageStackHost.panTouchTypes(drawing: false, isMac: false).contains(pencil))
        // On a Mac the pointer draws while drawing is on; reading, it drags the pages.
        #expect(!PageStackHost.panTouchTypes(drawing: true, isMac: true).contains(pointer))
        #expect(PageStackHost.panTouchTypes(drawing: false, isMac: true).contains(pointer))
        #expect(PageStackHost.minimumPanTouches(drawing: true, fingersDraw: true) == 2)
        #expect(PageStackHost.minimumPanTouches(drawing: true, fingersDraw: false) == 1)
        #expect(PageStackHost.minimumPanTouches(drawing: false, fingersDraw: true) == 1)
    }

    @Test func selectionModeScrollsWithEverything() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        #expect(stack.scroller.panGestureRecognizer.allowedTouchTypes.contains(pencil) == false)
        stack.update(StackTS.configuration(editor, selectingItems: true))
        #expect(stack.scroller.panGestureRecognizer.allowedTouchTypes.contains(pencil))
        #expect(stack.scroller.panGestureRecognizer.minimumNumberOfTouches == 1)
        #expect(!stack.scroller.delaysContentTouches, "strokes start at once")
    }

    /// Menu commands reach the stack: tools go to the shared palette.
    @Test func menuCommandsReachTheStack() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        #expect(stack.select(tool: .lasso))
        #expect(stack.toolPicker.selectedToolItem is PKToolPickerLassoItem)
        #expect(stack.slots.values.allSatisfy { $0.host.toolPicker === stack.toolPicker })
        stack.toggleRuler()
        #expect(stack.focusedSlot?.host.canvas.isRulerActive == true)
    }

    /// A new note in the same stack: canvases of the old one are dropped and
    /// the new note opens at its current page.
    /// A search hit far down the note (main's highlights, #72): the match's page
    /// gets the highlight on its own canvas and the stack scrolls the word into
    /// view (the embedded canvases never scroll); a recycled canvas drops it.
    @Test func aSearchMatchIsHighlightedAndScrolledIntoView() async throws {
        let editor = try await StackTS.savedEditor(pages: 40)
        #expect(!editor.isPageless && editor.pages.count == 40)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        var pages = editor.pages
        let box = Recognition.Box(x: 300, y: 760, w: 80, h: 20)   // near the page's foot: a page-top jump hides it
        pages[30].recognition = Recognition(engine: "t", text: "wombat", words: [.init(text: "wombat", box: box)])
        editor.searchCursor = try #require(SearchMatchCursor(query: "wombat", pages: pages))
        editor.showPage(id: pages[30].id)
        editor.revealToken &+= 1
        StackTS.refresh(stack, editor)
        #expect(editor.pageIndex == 30)
        let slot = try StackTS.slot(stack, editor, page: 30)
        #expect(slot.host.highlights == [HighlightBox(box: box, isCurrent: true)])
        let page = stack.layout.pageFrame(30, scale: Double(stack.scale))
        let s = Double(stack.scale)
        let word = CGRect(x: Double(page.minX) + box.x * s, y: Double(page.minY) + box.y * s,
                          width: box.w * s, height: box.h * s)
        #expect(stack.visibleContentRect.contains(word), "\(word) in \(stack.visibleContentRect)")
        #expect(slot.host.canvas.contentOffset == .zero, "the page's own canvas does not scroll")
        // Its page stays the current one.
        StackTS.refresh(stack, editor)
        #expect(editor.pageIndex == 30)
        // Scrolled away, the canvas is recycled without its highlights.
        StackTS.scroll(stack, toShowTopOf: 0)
        #expect(stack.slots[pages[30].id] == nil)
        #expect((stack.spares.map(\.host) + stack.slots.values.map(\.host)).allSatisfy { $0.highlights.isEmpty })
    }

    /// Images and PDFs dropped on a page of the stack (#81): every page's
    /// canvas takes drops for its own page, and the stack reports each page's
    /// visible part (where a dropped or added image is fitted).
    @Test func dropsReachThePageTheyLandOn() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let stack = PageStackHost(frame: window.bounds)
        window.addSubview(stack)
        window.isHidden = false
        defer { window.isHidden = true }
        var dropped: [UUID] = []
        var configuration = StackTS.configuration(editor)
        configuration.onDrop = { _, page, _ in dropped.append(page) }
        stack.update(configuration)
        stack.layoutIfNeeded()
        for index in StackTS.shownIndices(stack, editor) {
            let slot = try StackTS.slot(stack, editor, page: index)
            slot.host.dropHandler?([], CGPoint(x: 10, y: 10))
        }
        #expect(dropped == StackTS.shownIndices(stack, editor).map { editor.pages[$0].id })
        let first = try #require(stack.visibleRect(ofPage: editor.pages[0].id))
        #expect(first.minY == 0 && abs(Double(first.width) - editor.pageSize.width) < 0.01)
        #expect(stack.visiblePageRect == first, "the current page is the first")
        // Read-only (no handler): drops are refused.
        configuration.onDrop = nil
        stack.update(configuration)
        #expect(try StackTS.slot(stack, editor, page: 0).host.dropHandler == nil)
    }

    /// A text box being typed in on a page of the stack keeps the keyboard
    /// while the stack lays out again (the keyboard resizing it, a scroll):
    /// the stack never hands the focus back to a page canvas meanwhile.
    @Test func typingInATextBoxKeepsTheFocusWhileTheStackMoves() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let stack = PageStackHost(frame: window.bounds)
        window.addSubview(stack)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        stack.update(StackTS.configuration(editor))
        stack.layoutIfNeeded()
        let slot = try StackTS.slot(stack, editor, page: 0)
        slot.host.textEditor.beginNew(at: ItemFrames.Point(x: 100, y: 100))
        let typing = try #require(slot.host.textEditor.textView)
        #expect(typing.isFirstResponder)
        stack.frame.size.height -= 300   // the keyboard
        StackTS.refresh(stack, editor)
        StackTS.scroll(stack, toShowTopOf: 0, plus: 5)
        #expect(slot.host.textEditor.isEditing)
        #expect(typing.isFirstResponder, "the text view keeps the keyboard")
        #expect(!slot.host.canvas.isFirstResponder)
        slot.host.textEditor.endEditing(commit: false)
    }

    @Test func anotherNoteStartsFresh() async throws {
        let first = try await StackTS.editor(pages: 12)
        let (window, stack) = StackTS.stack(first)
        defer { window.isHidden = true }
        StackTS.scroll(stack, toShowTopOf: 10)
        let second = try await StackTS.editor(pages: 3)
        StackTS.refresh(stack, second)
        #expect(stack.scroller.contentOffset.y == 0)
        #expect(second.pageIndex == 0, "clamping the old offset is not a scroll to another page")
        #expect(stack.slots.keys.allSatisfy { id in second.pages.contains { $0.id == id } })
        #expect(stack.slots.values.allSatisfy { $0.coordinator.editor === second })
    }
}

/// The paged canvas at iPhone sizes (run on an iPhone simulator too).
@MainActor
@Suite(.serialized)
struct PhoneStackTests {
    @Test func pagesFitTheWidthAtEveryPhoneSize() async throws {
        let editor = try await StackTS.editor(pages: 6)
        for size in PhoneCanvasTests.sizes {
            let (window, stack) = StackTS.stack(editor, size: size, drawingSuspended: true)
            #expect(abs(stack.scale - size.width / CGFloat(editor.pageSize.width)) < 0.0005, "\(size)")
            #expect(stack.scroller.contentSize.width <= size.width + 0.5)
            #expect(!stack.slots.isEmpty && stack.slots.count <= 4, "\(size)")
            window.isHidden = true
        }
    }

    /// Reading on a phone: one finger (or a Pencil) scrolls, nothing draws,
    /// and there is no Add Page button to tap by accident.
    @Test func readingModeScrollsWithOneFinger() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let (window, stack) = StackTS.stack(editor, size: PhoneCanvasTests.sizes[0], drawingSuspended: true)
        defer { window.isHidden = true }
        #expect(stack.scroller.panGestureRecognizer.minimumNumberOfTouches == 1)
        #expect(stack.footerButton.isHidden)
        #expect(stack.slots.values.allSatisfy { !$0.host.canvas.drawingGestureRecognizer.isEnabled })
        // Annotating: the pages take one finger, two scroll.
        stack.update(StackTS.configuration(editor, drawingSuspended: false))
        if Platform.isPhone { #expect(stack.scroller.panGestureRecognizer.minimumNumberOfTouches == 2) }
        #expect(!stack.footerButton.isHidden)
    }
}
