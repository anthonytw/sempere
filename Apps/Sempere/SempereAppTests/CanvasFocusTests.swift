import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// The canvas never takes the keyboard from a field by itself (TestFlight
/// 1.0.0 on a Mac: "the selected folder constantly steals focus" from the
/// search field and new text boxes). The paged stack lays out on every SwiftUI
/// update (a search result, a sync tick, a list reconcile, a drop, the sidebar
/// collapsing), and each layout gave the current page's canvas the first
/// responder whenever no canvas had it (`PageStackHost.ensureFocus`), taking
/// it from the field being typed in. `CanvasFocus` decides; drawing on a
/// canvas still gives it the focus. `MacFocusUITests` types in the running app.
@MainActor
@Suite(.serialized)
struct CanvasFocusTests {
    /// A key window (in the host app's scene where there is one: on a Mac a
    /// window without a scene never becomes key).
    static func keyWindow(width: CGFloat = 1024, height: CGFloat = 1366) async throws -> UIWindow {
        var scene: UIWindowScene?
        for _ in 0..<50 where scene == nil {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if scene == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.makeKeyAndVisible()
        return window
    }

    /// A key window with a paged stack on its right and `field` on its left, typed in.
    static func stackBesideField(_ editor: NoteEditor, field: UIView & UIKeyInput) async throws -> (UIWindow, PageStackHost) {
        let window = try await keyWindow()
        field.frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        window.addSubview(field)
        let stack = PageStackHost(frame: CGRect(x: 220, y: 0, width: 800, height: 1366))
        window.addSubview(stack)
        stack.update(StackTS.configuration(editor))
        stack.layoutIfNeeded()
        #expect(field.becomeFirstResponder(), "the field takes the keyboard")
        return (window, stack)
    }

    static func canvasHasFocus(_ stack: PageStackHost) -> Bool {
        stack.slots.values.contains { $0.host.canvas.isFirstResponder }
    }

    /// The bug: everything that lays the stack out while the search field is
    /// typed in leaves the keyboard in the field.
    @Test(arguments: ["textField", "searchField", "textView"])
    func aFieldKeepsTheKeyboardWhileTheStackUpdates(kind: String) async throws {
        let editor = try await StackTS.editor(pages: 6)
        let field: UIView & UIKeyInput = switch kind {
        case "searchField": UISearchTextField()
        case "textView": UITextView()
        default: UITextField()
        }
        let (window, stack) = try await Self.stackBesideField(editor, field: field)
        defer { window.isHidden = true }
        func check(_ step: String) {
            #expect(field.isFirstResponder, "\(kind) keeps the keyboard: \(step)")
            #expect(!Self.canvasHasFocus(stack), "no canvas took it: \(step)")
        }
        check("first layout")
        stack.setNeedsLayout()
        stack.layoutIfNeeded()
        check("a layout (a search result, a sync tick, a reconcile)")
        StackTS.refresh(stack, editor)
        check("SwiftUI updated the stack")
        StackTS.scroll(stack, toShowTopOf: 4)
        stack.layoutIfNeeded()
        check("a scroll to a page without a canvas yet")
        stack.frame.size.width -= 200   // the sidebar shown
        stack.layoutIfNeeded()
        stack.frame.size.width += 200   // and hidden
        stack.layoutIfNeeded()
        check("the sidebar collapsed and expanded")
        editor.addPage()
        StackTS.refresh(stack, editor)
        check("a page added (a drop, a remote change)")
        let other = try await StackTS.editor(pages: 2)
        StackTS.refresh(stack, other)
        check("another note opened")
        // The user leaves the field: the canvas takes the focus again (the palette shows).
        field.resignFirstResponder()
        StackTS.refresh(stack, other)
        #expect(Self.canvasHasFocus(stack), "with no field typed in, the current page has the focus")
    }

    /// Drawing on a page is the user leaving the field: that canvas takes the focus.
    @Test func aStrokeTakesTheFocusFromTheField() async throws {
        let editor = try await StackTS.editor(pages: 2)
        let field = UISearchTextField()
        let (window, stack) = try await Self.stackBesideField(editor, field: field)
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 0)
        slot.coordinator.canvasViewDidBeginUsingTool(slot.host.canvas)
        #expect(slot.host.canvas.isFirstResponder)
        #expect(!field.isFirstResponder)
    }

    /// A text box ended while the user is in the search field (the note
    /// changed under it) leaves the keyboard in the search field.
    @Test func anEndedTextBoxDoesNotTakeTheSearchFieldsKeyboard() async throws {
        let editor = try await StackTS.editor(pages: 2)
        let field = UISearchTextField()
        let (window, stack) = try await Self.stackBesideField(editor, field: field)
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 0)
        slot.host.textEditor.beginNew(at: ItemFrames.Point(x: 100, y: 100))
        let typing = try #require(slot.host.textEditor.textView)
        #expect(typing.isFirstResponder, "a new text box has the keyboard")
        StackTS.refresh(stack, editor)
        stack.setNeedsLayout()
        stack.layoutIfNeeded()
        #expect(typing.isFirstResponder, "and keeps it while the stack updates")
        #expect(field.becomeFirstResponder(), "the user clicks the search field")
        slot.host.textEditor.endEditing(commit: false)
        #expect(field.isFirstResponder, "the search field keeps the keyboard when the box ends")
        #expect(!Self.canvasHasFocus(stack))
    }

    /// A text box keeps the keyboard while the editor writes (recognition's
    /// delta, a sync) and the stack is updated for it.
    @Test func aTextBoxKeepsTheKeyboardWhileTheNoteChanges() async throws {
        let editor = try await StackTS.editor(pages: 3)
        let window = try await Self.keyWindow()
        defer { window.isHidden = true }
        let stack = PageStackHost(frame: window.bounds)
        window.addSubview(stack)
        stack.update(StackTS.configuration(editor))
        stack.layoutIfNeeded()
        let slot = try StackTS.slot(stack, editor, page: 1)
        slot.host.textEditor.beginNew(at: ItemFrames.Point(x: 50, y: 50))
        let typing = try #require(slot.host.textEditor.textView)
        typing.insertText("hello")
        for step in 0..<3 {
            // What a written delta does to the stack: SwiftUI updates it and it lays out again
            // (adding a page would jump to it and recycle this one, which writes the box first).
            StackTS.refresh(stack, editor)
            stack.frame.size.height += step == 1 ? -300 : 0   // the keyboard's bar
            stack.setNeedsLayout()
            stack.layoutIfNeeded()
        }
        #expect(typing.isFirstResponder, "the text box keeps the keyboard")
        #expect(slot.host.textEditor.isEditing)
        slot.host.textEditor.endEditing(commit: false)
    }

    /// The one-page canvas (pageless notes) takes the focus when it appears or
    /// its palette changes, but never from a field typed in.
    @Test func thePagelessCanvasLeavesAFieldsKeyboard() async throws {
        let window = try await Self.keyWindow()
        defer { window.isHidden = true }
        let field = UISearchTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        window.addSubview(field)
        #expect(field.becomeFirstResponder())
        let host = PageCanvasHost(frame: CGRect(x: 220, y: 0, width: 800, height: 1000))
        window.addSubview(host)
        #expect(field.isFirstResponder, "appearing")
        host.paletteVisible = false
        host.paletteVisible = true
        host.isReadOnly = true
        host.isReadOnly = false
        #expect(field.isFirstResponder, "palette and read-only changes")
        #expect(!host.canvas.isFirstResponder)
        field.resignFirstResponder()
        host.removeFromSuperview()
        window.addSubview(host)
        #expect(host.canvas.isFirstResponder, "with no field typed in, the canvas has the focus")
    }

    /// Annotate shows Sempere's own palette, which needs no first responder (PencilKit's showed only for
    /// it, so Annotate used to take the focus from a list: TestFlight 1.0.0 (6)). The canvas now leaves a
    /// list's focus alone, as everywhere else (`CanvasFocus`); a touch on it takes the focus.
    @Test func turningThePaletteOnLeavesAListsFocus() async throws {
        let window = try await Self.keyWindow()
        defer { window.isHidden = true }
        let host = PageCanvasHost(frame: CGRect(x: 220, y: 0, width: 800, height: 1000))
        window.addSubview(host)
        let list = FocusableView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        window.addSubview(list)
        #expect(list.becomeFirstResponder())
        host.paletteVisible = false
        host.paletteVisible = true
        #expect(list.isFirstResponder)
        host.reclaimFocus()   // a touch on the canvas
        #expect(host.canvas.isFirstResponder)
        list.removeFromSuperview()
        host.removeFromSuperview()
    }

    /// A responder that takes no typing (a list, the sidebar).
    final class FocusableView: UIView {
        override var canBecomeFirstResponder: Bool { true }
    }

    /// A note window updating in the background never takes the keyboard
    /// from the key window's search field; it gives its canvas the focus once
    /// it becomes key.
    @Test func aBackgroundWindowTakesNothing() async throws {
        let editor = try await StackTS.editor(pages: 2)
        let library = try await Self.keyWindow()
        defer { library.isHidden = true }
        let field = UISearchTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        library.addSubview(field)
        let noteWindow = library.windowScene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        noteWindow.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        noteWindow.isHidden = false
        defer { noteWindow.isHidden = true }
        library.makeKey()
        #expect(field.becomeFirstResponder())
        let stack = PageStackHost(frame: noteWindow.bounds)
        noteWindow.addSubview(stack)
        stack.update(StackTS.configuration(editor))
        stack.layoutIfNeeded()
        StackTS.refresh(stack, editor)
        #expect(library.isKeyWindow, "the library window stays key")
        #expect(field.isFirstResponder, "and its search field keeps the keyboard")
        #expect(!Self.canvasHasFocus(stack))
        noteWindow.makeKey()
        // Note windows are the Mac's (on the iPad the other window's field keeps the one keyboard).
        guard Platform.isMac else { return }
        #expect(await TS.waitUntil(timeout: .seconds(2)) { Self.canvasHasFocus(stack) },
                "the note window's page takes the focus once its window is key")
    }

    /// The rule itself: a typing responder elsewhere holds the keyboard; one inside does not.
    @Test func typingRespondersElsewhereHoldTheKeyboard() async throws {
        let window = try await Self.keyWindow(width: 600, height: 400)
        defer { window.isHidden = true }
        let container = UIView(frame: CGRect(x: 300, y: 0, width: 300, height: 400))
        window.addSubview(container)
        #expect(!CanvasFocus.keyboardIsElsewhere(than: container), "nothing holds it")
        let inside = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        container.addSubview(inside)
        #expect(inside.becomeFirstResponder())
        #expect(CanvasFocus.firstResponder() === inside)
        #expect(!CanvasFocus.keyboardIsElsewhere(than: container), "a field inside (a text box) is the canvas's own")
        let outside = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.addSubview(outside)
        #expect(outside.becomeFirstResponder())
        #expect(CanvasFocus.keyboardIsElsewhere(than: container))
        outside.resignFirstResponder()
        #expect(!CanvasFocus.keyboardIsElsewhere(than: container))
        let detached = UIView()
        #expect(CanvasFocus.keyboardIsElsewhere(than: detached), "a view in no window takes nothing")
    }
}
