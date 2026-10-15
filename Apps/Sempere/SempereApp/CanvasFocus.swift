import UIKit

/// When a canvas may take the first responder by itself (to show the palette
/// and get the menus' undo), as opposed to because the user drew on it.
///
/// The paged stack lays out on every SwiftUI update (a search result, a sync
/// tick, a list reconcile, a drop, the sidebar collapsing) and used to hand
/// the first responder to the current page's canvas whenever no canvas had
/// it (`PageStackHost.ensureFocus`). That took the keyboard from the search
/// field, a rename or tag field, or a sheet's text field after every key, and
/// on a Mac the window's keyboard focus then fell back to the sidebar's
/// selected row (TestFlight 1.0.0: "the selected folder constantly steals
/// focus"). So a canvas takes the focus by itself only when nothing outside
/// it holds the keyboard: no text input elsewhere is the first responder and
/// the window's keyboard focus (a list row moved through with the arrow keys)
/// is not elsewhere either. Drawing on a canvas still makes it the first
/// responder (`PageCanvasHost.focus`, called when a stroke begins).
@MainActor
enum CanvasFocus {
    /// The first responder of the key window, nil when there is none.
    static func firstResponder() -> UIResponder? {
        Probe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.sempereReportFirstResponder(_:)), to: nil, from: nil, for: nil)
        defer { Probe.found = nil }
        return Probe.found
    }

    /// Whether something outside `view` holds the keyboard of `view`'s window.
    static func keyboardIsElsewhere(than view: UIView) -> Bool {
        // A window in the background takes nothing: `becomeFirstResponder` there could take
        // the keyboard from the key window (a note window updating while the library is typed in).
        guard let window = view.window, window.isKeyWindow else { return true }
        if let responder = firstResponder(),
           holdsTyping(responder), !isInside(responder, view) {
            return true
        }
        if let focused = window.windowScene?.focusSystem?.focusedItem, !isInside(focused, view) {
            return true
        }
        return false
    }

    /// A responder that takes typed text: a text field, a text view, a search field.
    static func holdsTyping(_ responder: UIResponder) -> Bool {
        responder is UIKeyInput
    }

    /// Whether `item` is `view` or inside it (a focus item that is not a view
    /// counts by its focus environment's chain).
    static func isInside(_ item: AnyObject, _ view: UIView) -> Bool {
        if let v = item as? UIView { return v.isDescendant(of: view) }
        var environment = (item as? UIFocusEnvironment)?.parentFocusEnvironment
        while let current = environment {
            if let v = current as? UIView { return v.isDescendant(of: view) }
            environment = current.parentFocusEnvironment
        }
        return false
    }

    fileprivate enum Probe {
        nonisolated(unsafe) static weak var found: UIResponder?
    }
}

extension UIResponder {
    /// `CanvasFocus.firstResponder`: the action reaches the first responder.
    @objc fileprivate func sempereReportFirstResponder(_ sender: Any?) {
        CanvasFocus.Probe.found = self
    }
}
