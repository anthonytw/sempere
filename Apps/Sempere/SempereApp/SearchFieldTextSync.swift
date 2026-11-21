import SwiftUI
import UIKit

/// Puts the list's search text back into its search field when the field starts editing with other text in it.
///
/// The note list's field holds one of two texts, the search (Search) or the question (Ask, `AskTargetPicker`), and
/// SwiftUI pushes the binding's value into the field only when that value changes. On a Mac a click on a segment while
/// the field is empty in Search cancels the search (UIKit's click outside an empty search field), and the search
/// controller's dismissal, still running when Ask comes in, empties the field when it ends: after SwiftUI put the
/// question there, and without telling SwiftUI. The binding still says the question, so SwiftUI never puts it back and
/// the question vanished from the field about a second after the click (2 runs in 3), while the model kept it. The
/// field starts editing again right after (the segment gives it the focus back), so that is where this repairs it.
///
/// Only the search field of the navigation item that holds this view is touched, never another text field.
struct SearchFieldTextSync: UIViewRepresentable {
    /// What the field should hold: the binding's current value.
    var text: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        context.coordinator.marker = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.text = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text) }

    @MainActor
    final class Coordinator: NSObject {
        var text: String
        weak var marker: UIView?

        init(text: String) {
            self.text = text
            super.init()
            // Selector-based: the center lets go of it by itself. Text fields post this on the main thread.
            NotificationCenter.default.addObserver(self, selector: #selector(textDidBeginEditing(_:)),
                                                   name: UITextField.textDidBeginEditingNotification, object: nil)
        }

        @objc private func textDidBeginEditing(_ note: Notification) {
            if let field = note.object as? UISearchTextField { beganEditing(field) }
        }

        private func beganEditing(_ field: UISearchTextField) {
            guard let marker, marker.window != nil, marker.window === field.window, ownsField(field) else { return }
            if (field.text ?? "") != text { field.text = text }
        }

        /// Whether `field` is the search field of a navigation item on the marker's way up (its view controllers and
        /// their parents): the field `.searchable` made for this list.
        private func ownsField(_ field: UISearchTextField) -> Bool {
            var responder: UIResponder? = marker
            while let next = responder {
                var controller = next as? UIViewController
                while let c = controller {
                    if c.navigationItem.searchController?.searchBar.searchTextField === field { return true }
                    controller = c.parent
                }
                responder = next.next
            }
            return false
        }
    }
}

