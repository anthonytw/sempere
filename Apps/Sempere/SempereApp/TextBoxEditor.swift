import Sempere
import SempereRender
import UIKit

/// Typing in text boxes on the canvas (docs/attachments.md §13 "Text
/// editing on the canvas", task E2). New boxes are Markdown boxes (format.md
/// §8.2.4 "Markdown text"): their source is edited as plain text, with a
/// Markdown bar of helpers that insert syntax (`MarkdownEditing`), and drawn
/// rendered when not edited; closing the edit typesets the formulas and
/// writes their renders before the delta (`NoteEditor.preparedMarkdown`).
/// Styled boxes (imports, older boxes) keep the style bar described here. With the text tool on, the selection
/// controller (`ItemSelectionController`, scope `.textBoxes`) picks boxes: a
/// tap selects one (handles to move it and set its width), a tap on the
/// selected box or a double tap edits it (`begin`), a tap on the empty page
/// starts a new box there (`beginNew`); the menus' "Edit Text" edits too. The box is edited in a `UITextView`
/// (TextKit 1, the layout `TextKitBreaks` uses) laid over the page at the
/// canvas zoom, with a style bar above the keyboard (bold, italic,
/// underline, strikethrough, size, colour, font, alignment, direction);
/// Scribble writes into it like any text field. Ending the edit (Done, a
/// tap outside, another page or note) writes one delta through
/// `ItemActions`: the text with `breaks` from TextKit and the height of its
/// lines (`TextBoxEditing.content`), an empty new box nothing, a box emptied
/// a delete. Nothing is written while typing.
@MainActor
final class TextBoxEditorController: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    private weak var canvas: UIScrollView?
    private weak var itemLayer: ItemLayerView?
    private let tap = UITapGestureRecognizer()

    var editor: NoteEditor?
    var pageID: UUID?
    /// Undoable item edits (the selection controller's, on the canvas's undo manager).
    var actions: () -> ItemActions? = { nil }
    /// Called when editing starts or ends (the host turns drawing and selection off meanwhile).
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// What is being edited.
    struct Session {
        /// The box edited; nil for a new one.
        var itemID: UUID?
        var pageID: UUID
        /// Its frame (page points); the height follows the text.
        var frame: Rect
        var rotation: Double?
        var original: TextContent?
        var style: TextBoxEditing.BoxStyle
        /// A Markdown box: its source is edited, with the Markdown bar.
        var markdown = false
        /// Changed since editing started.
        var dirty = false
    }

    private(set) var session: Session? {
        // The menus read it (`NoteEditor.typingInTextBox`): ⌘⌫ and ⌥⌘⌫ are the text view's then.
        didSet { if (session == nil) != (oldValue == nil) { editor?.typingInTextBox = session != nil } }
    }
    /// The controller editing now, if any: one box is edited at a time, also
    /// across the pages of a paged note (each page has its own controller).
    private static weak var editing: TextBoxEditorController?
    private(set) var textView: UITextView?

    /// The style of the last box edited: the next new box starts with it.
    static var lastStyle = TextBoxEditing.BoxStyle(TextContent(size: 16, color: .black, runs: []))

    var isEditing: Bool { session != nil }

    func attach(to canvas: UIScrollView, itemLayer: ItemLayerView) {
        self.canvas = canvas
        self.itemLayer = itemLayer
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.isEnabled = false
        canvas.addGestureRecognizer(tap)
    }

    /// The text tool on or off. Turning it off ends an edit in progress.
    var toolActive = false {
        didSet {
            guard toolActive != oldValue else { return }
            if !toolActive { endEditing() }
            updateTap()
        }
    }

    /// The tap here only ends an edit; selecting and starting boxes is the selection controller's.
    private func updateTap() { tap.isEnabled = isEditing }

    /// The note or page on the canvas changed: an edit in progress is written first.
    func reset(editor: NoteEditor, pageID: UUID) {
        if self.editor !== editor || self.pageID != pageID {
            endEditing()
            self.editor = editor
            self.pageID = pageID
        }
    }

    private var zoom: CGFloat { max(canvas?.zoomScale ?? 1, 0.01) }

    // MARK: Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Touches in the text view (or its bar) are the text view's.
        if let tv = textView, let view = touch.view, view.isDescendant(of: tv) { return false }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        // A tap outside the box ends the edit; it does not start another box or select one.
        if isEditing { endEditing() }
    }

    // MARK: Editing

    /// Starts editing the text box `item` of the current page.
    func begin(_ item: Item) {
        guard item.kind == .text, let content = item.text, let pageID, editor?.canEditItems == true else { return }
        endEditing()
        let style = TextBoxEditing.BoxStyle(content)
        session = Session(itemID: item.id, pageID: pageID, frame: item.frame, rotation: item.rotation, original: content,
                          style: style, markdown: content.isMarkdown)
        itemLayer?.hiddenItem = item.id
        present(content.isMarkdown ? TextBoxEditing.markdownSource(content.string, style: style) : TextBoxEditing.attributed(content))
    }

    /// Starts a new box with its top-left corner at `p` (page points).
    func beginNew(at p: ItemFrames.Point) {
        guard let editor, let pageID, editor.canEditItems else { return }
        endEditing()
        let style = Self.lastStyle
        let frame = TextBoxPlacement.newFrame(at: p, pageWidth: editor.pageSize.width, size: style.size)
        // New boxes are Markdown boxes (maintainer request 2026-10-09).
        session = Session(itemID: nil, pageID: pageID, frame: frame, rotation: nil, original: nil, style: style, markdown: true)
        present(NSAttributedString())
    }

    private func present(_ text: NSAttributedString) {
        guard let canvas, let session else { return }
        if let other = Self.editing, other !== self { other.endEditing() }
        Self.editing = self
        let tv = UITextView(usingTextLayoutManager: false)
        tv.accessibilityIdentifier = "textBoxEditor"
        tv.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        tv.layer.borderColor = UIColor.tintColor.cgColor
        tv.layer.borderWidth = 1 / zoom
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.allowsEditingTextAttributes = !session.markdown
        tv.overrideUserInterfaceStyle = .light   // text colours are stored as on light paper
        tv.attributedText = text
        if session.markdown {
            tv.typingAttributes = TextBoxEditing.markdownAttributes(session.style)
            tv.autocorrectionType = .no
            tv.smartQuotesType = .no
            tv.smartDashesType = .no
        } else {
            tv.typingAttributes = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil)
                : TextBoxEditing.typingAttributes(session.style)
        }
        tv.delegate = self
        tv.inputAccessoryView = session.markdown ? makeMarkdownBar() : makeStyleBar()
        canvas.addSubview(tv)
        textView = tv
        colourItem?.image = TextColourPalette.swatchImage(currentColour, size: 22)
        layoutTextView()
        updateTap()
        onEditingChanged(true)
        tv.becomeFirstResponder()
    }

    /// Ends the edit, writing it unless `commit` is false.
    func endEditing(commit: Bool = true) {
        guard let session, let tv = textView else { return }
        self.session = nil
        textView = nil
        if Self.editing === self { Self.editing = nil }
        tv.delegate = nil
        let text = tv.attributedText ?? NSAttributedString()
        let language = tv.textInputMode?.primaryLanguage
        tv.resignFirstResponder()
        tv.removeFromSuperview()
        itemLayer?.hiddenItem = nil
        updateTap()
        defer { onEditingChanged(false) }
        Self.lastStyle = session.style
        guard commit, session.dirty, let editor, editor.canEditItems, let actions = actions() else { return }
        if session.markdown {
            commitMarkdown(tv.text ?? "", session: session, keyboardLanguage: language, editor: editor, actions: actions)
            return
        }
        let written = TextBoxEditing.content(from: text, style: session.style, original: session.original,
                                             keyboardLanguage: language, frame: session.frame)
        if let id = session.itemID {
            if written.content.string.isEmpty {
                actions.delete([id], on: session.pageID)
            } else {
                actions.setText(id, to: written.content, frame: written.frame, on: session.pageID)
            }
        } else {
            actions.addText(written.content, frame: written.frame, on: session.pageID)
        }
    }

    /// The last Markdown edit being written (formulas typeset, renders written, then the delta); tests await it.
    private(set) var pendingCommit: Task<Void, Never>?

    /// Writes a Markdown edit: the source in the box's style, then (after
    /// its formulas are typeset and their renders written) one delta.
    private func commitMarkdown(_ source: String, session: Session, keyboardLanguage: String?, editor: NoteEditor,
                                actions: ItemActions) {
        if let id = session.itemID, source.isEmpty {
            actions.delete([id], on: session.pageID)
            return
        }
        guard !source.isEmpty,
              let content = TextBoxEditing.markdownContent(source, style: session.style, original: session.original,
                                                            keyboardLanguage: keyboardLanguage) else { return }
        let frame = session.frame
        let previous = pendingCommit
        pendingCommit = Task { @MainActor in
            await previous?.value
            guard let prepared = try? await editor.preparedMarkdown(content, frame: frame) else { return }
            if let id = session.itemID {
                actions.setText(id, to: prepared.content, frame: prepared.frame, on: session.pageID)
            } else {
                actions.addText(prepared.content, frame: prepared.frame, on: session.pageID)
            }
        }
    }

    /// Places the text view over the box at the canvas zoom (the zoom changed,
    /// or the text grew).
    func layoutTextView() {
        guard let tv = textView, let session else { return }
        let z = zoom
        let w = CGFloat(session.frame.w)
        let fit = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let h = max(CGFloat(session.frame.h), fit, CGFloat(1.2 * session.style.size))
        tv.transform = .identity
        tv.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        tv.center = CGPoint(x: (CGFloat(session.frame.x) + w / 2) * z, y: (CGFloat(session.frame.y) + h / 2) * z)
        tv.transform = CGAffineTransform(rotationAngle: CGFloat(ItemFrames.radians(session.rotation))).scaledBy(x: z, y: z)
        tv.layer.borderWidth = 1 / z
        // Sharp text at any zoom: the text view draws at the zoomed resolution.
        let scale = z * max(tv.traitCollection.displayScale, 1)
        func sharpen(_ v: UIView) {
            v.contentScaleFactor = scale
            v.subviews.forEach(sharpen)
        }
        sharpen(tv)
        canvas?.bringSubviewToFront(tv)
    }

    /// Typing or pasting that would take the box past the format's text
    /// limit (format.md §8.4) is refused as it happens: a box over it could
    /// not be written, and the whole edit would be lost when it closes.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        Self.fits(textView.text ?? "", replacing: range, with: text)
    }

    /// Whether `current` with `range` (UTF-16) replaced by `text` stays
    /// within `TextContent.Limits.utf8Bytes`. A change that shortens the text always fits.
    nonisolated static func fits(_ current: String, replacing range: NSRange, with text: String) -> Bool {
        guard let r = Range(range, in: current) else { return true }
        let removed = current[r].utf8.count, added = text.utf8.count
        return added <= removed || current.utf8.count - removed + added <= TextContent.Limits.utf8Bytes
    }

    func textViewDidChange(_ textView: UITextView) {
        session?.dirty = true
        layoutTextView()
    }

    // MARK: Style bar

    private func makeStyleBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        bar.accessibilityIdentifier = "textStyleBar"
        func toggle(_ name: String, _ title: String, _ change: TextBoxEditing.Change) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: name), primaryAction: UIAction(title: title) { [weak self] _ in
                self?.apply(change)
            })
            item.accessibilityLabel = title
            return item
        }
        let sizes = UIMenu(title: String(localized: "Size", comment: "Text style bar: font size menu"), children: TextBoxPlacement.sizes.map { s in
            UIAction(title: "\(Int(s)) pt") { [weak self] _ in self?.apply(.size(s)) } // l10n:ignore (number and unit)
        })
        let colour = UIBarButtonItem(title: String(localized: "Colour", comment: "Text style bar: text colour menu"), image: TextColourPalette.swatchImage(currentColour, size: 22),
                                     primaryAction: nil, menu: nil)
        colour.primaryAction = UIAction(title: String(localized: "Colour", comment: "Text style bar: text colour menu")) { [weak self, weak colour] _ in
            guard let self, let colour else { return }
            self.showColours(from: colour)
        }
        colour.accessibilityLabel = String(localized: "Colour", comment: "Text style bar: text colour menu")
        colourItem = colour
        let fontChoices: [(String, TextContent.Font)] = [
            (String(localized: "Sans Serif", comment: "Typeface"), .sans),
            (String(localized: "Serif", comment: "Typeface"), .serif),
            (String(localized: "Monospaced", comment: "Typeface"), .mono),
        ]
        let fonts = UIMenu(title: String(localized: "Font", comment: "Text style bar: typeface menu"), children: fontChoices.map { name, f in
            UIAction(title: name) { [weak self] _ in self?.restyle { $0.font = f } }
        })
        let alignChoices: [(String, String, TextContent.Alignment)] = [
            (String(localized: "Start", comment: "Text alignment"), "text.alignleft", .start),
            (String(localized: "Center", comment: "Text alignment"), "text.aligncenter", .center),
            (String(localized: "End", comment: "Text alignment"), "text.alignright", .end),
        ]
        let aligns = UIMenu(title: String(localized: "Alignment", comment: "Text style bar: paragraph alignment menu"), children: alignChoices.map { name, image, a in
            UIAction(title: name, image: UIImage(systemName: image)) { [weak self] _ in self?.restyle { $0.align = a == .start ? nil : a } }
        })
        let directionChoices: [(String, TextContent.Direction)] = [
            (String(localized: "Automatic", comment: "Writing direction"), .auto),
            (String(localized: "Left to Right", comment: "Writing direction"), .ltr),
            (String(localized: "Right to Left", comment: "Writing direction"), .rtl),
        ]
        let directions = UIMenu(title: String(localized: "Direction", comment: "Text style bar: writing direction menu"), children: directionChoices.map { name, d in
            UIAction(title: name) { [weak self] _ in self?.restyle { $0.dir = d == .auto ? nil : d } }
        })
        bar.items = [
            toggle("bold", String(localized: "Bold", comment: "Text style"), .bold),
            toggle("italic", String(localized: "Italic", comment: "Text style"), .italic),
            toggle("underline", String(localized: "Underline", comment: "Text style"), .underline),
            toggle("strikethrough", String(localized: "Strikethrough", comment: "Text style"), .strikethrough),
            UIBarButtonItem(title: sizes.title, image: UIImage(systemName: "textformat.size"), menu: sizes),
            colour,
            UIBarButtonItem(title: fonts.title, image: UIImage(systemName: "textformat"), menu: fonts),
            UIBarButtonItem(title: aligns.title, image: UIImage(systemName: "text.alignleft"), menu: aligns),
            UIBarButtonItem(title: directions.title, image: UIImage(systemName: "arrow.left.arrow.right"), menu: directions),
            .flexibleSpace(),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.endEditing() }),
        ]
        bar.sizeToFit()
        return bar
    }

    /// The style bar's colour button (it shows the colour of the text at the cursor).
    private weak var colourItem: UIBarButtonItem?
    /// The pen's colour now, offered first among the swatches (the host's tool picker).
    var penColour: () -> Sempere.Color? = { nil }

    /// The colour of the selected text, or of what is typed next.
    var currentColour: Sempere.Color {
        guard let tv = textView, let session else { return Self.lastStyle.color }
        let r = tv.selectedRange
        let attributes = r.length > 0 && r.location < tv.attributedText.length
            ? tv.attributedText.attributes(at: r.location, effectiveRange: nil) : tv.typingAttributes
        return (attributes[.foregroundColor] as? UIColor).map { Sempere.Color($0) } ?? session.style.color
    }

    /// Shows the colour swatches (the pen's palette) under the style bar's button.
    private func showColours(from item: UIBarButtonItem) {
        guard let tv = textView, let presenter = Self.presenter(for: tv) else { return }
        let range = tv.selectedRange
        let picker = ColourSwatchesController(swatches: TextColourPalette.swatches(pen: penColour()), current: currentColour) {
            [weak self] colour in
            guard let self, let tv = self.textView else { return }
            if !tv.isFirstResponder { tv.becomeFirstResponder() }
            tv.selectedRange = range
            self.apply(.color(colour))
        }
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceItem = item
        picker.popoverPresentationController?.delegate = picker
        presenter.present(picker, animated: true)
    }

    /// The view controller to present over: the topmost one above `view`'s.
    private static func presenter(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        var top = (responder as? UIViewController) ?? view.window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// Applies a style change to the selection, or to what is typed next.
    /// In a Markdown box a size or colour is the box's (Markdown says the rest).
    func apply(_ change: TextBoxEditing.Change) {
        defer { colourItem?.image = TextColourPalette.swatchImage(currentColour, size: 22) }
        if session?.markdown == true {
            switch change {
            case .size(let s): restyleMarkdown { $0.size = s }
            case .color(let c): restyleMarkdown { $0.color = c }
            default: break
            }
            return
        }
        guard let tv = textView, var session else { return }
        let range = tv.selectedRange
        if range.length > 0 {
            let selected = tv.selectedRange
            tv.attributedText = TextBoxEditing.applying(change, to: tv.attributedText, range: range, style: session.style)
            tv.selectedRange = selected
        } else {
            if tv.attributedText.length == 0 {
                // An empty box: the change is the box's own style.
                if case .size(let s) = change { session.style.size = s }
                if case .color(let c) = change { session.style.color = c }
                self.session = session
            }
            let on = !TextBoxEditing.isOn(change, in: tv.attributedText, range: range, typing: tv.typingAttributes)
            tv.typingAttributes = TextBoxEditing.apply(change, on: on, to: tv.typingAttributes, style: session.style)
        }
        self.session?.dirty = true
        layoutTextView()
    }

    /// Changes the box's own style (font, alignment, direction).
    func restyle(_ change: (inout TextBoxEditing.BoxStyle) -> Void) {
        guard let tv = textView, var session else { return }
        let old = session.style
        change(&session.style)
        guard session.style != old else { return }
        let selected = tv.selectedRange
        tv.attributedText = TextBoxEditing.restyled(tv.attributedText, from: old, to: session.style)
        tv.typingAttributes = TextBoxEditing.typingAttributes(session.style)
        tv.selectedRange = selected
        session.dirty = true
        self.session = session
        layoutTextView()
    }

    // MARK: Markdown bar

    /// Changes a Markdown box's own style (size, colour, font, alignment) and redraws its source.
    func restyleMarkdown(_ change: (inout TextBoxEditing.BoxStyle) -> Void) {
        guard let tv = textView, var session, session.markdown else { return }
        let old = session.style
        change(&session.style)
        guard session.style != old else { return }
        let selected = tv.selectedRange
        tv.attributedText = TextBoxEditing.markdownSource(tv.text ?? "", style: session.style)
        tv.typingAttributes = TextBoxEditing.markdownAttributes(session.style)
        tv.selectedRange = selected
        session.dirty = true
        self.session = session
        layoutTextView()
    }

    /// Inserts or removes Markdown syntax around the selection, as one undoable change of the text.
    func applyMarkdown(_ action: MarkdownEditing.Action) {
        guard let tv = textView, let session else { return }
        let old = tv.text ?? ""
        let before = tv.selectedRange
        let r = MarkdownEditing.apply(action, to: old, selection: before)
        guard r.text != old else { return }
        let change = TextBoxEditing.changedRange(from: old, to: r.text)
        let length = (old as NSString).length
        guard change.range.location >= 0, change.range.location + change.range.length <= length,
              Self.fits(old, replacing: change.range, with: change.replacement) else { return }
        // Only what changed, in the text storage (no UITextInput round trip), as one undo step.
        let removed = (old as NSString).substring(with: change.range)
        tv.textStorage.replaceCharacters(in: change.range, with: NSAttributedString(
            string: change.replacement, attributes: TextBoxEditing.markdownAttributes(session.style)))
        let selection = NSRange(location: min(r.selection.location, tv.textStorage.length),
                                length: min(r.selection.length, max(0, tv.textStorage.length - min(r.selection.location, tv.textStorage.length))))
        tv.selectedRange = selection
        let inserted = NSRange(location: change.range.location, length: (change.replacement as NSString).length)
        tv.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undoMarkdown(inserted, back: removed, selection: before) }
        }
        self.session?.dirty = true
        layoutTextView()
    }

    /// Puts back the text a Markdown helper replaced (its undo).
    private func undoMarkdown(_ inserted: NSRange, back removed: String, selection: NSRange) {
        guard let tv = textView, let session, inserted.location + inserted.length <= tv.textStorage.length else { return }
        tv.textStorage.replaceCharacters(in: inserted, with: NSAttributedString(
            string: removed, attributes: TextBoxEditing.markdownAttributes(session.style)))
        if selection.location + selection.length <= tv.textStorage.length { tv.selectedRange = selection }
        self.session?.dirty = true
        layoutTextView()
    }

    private func makeMarkdownBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        bar.accessibilityIdentifier = "markdownBar"
        func helper(_ name: String, _ title: String, _ action: MarkdownEditing.Action) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: name), primaryAction: UIAction(title: title) { [weak self] _ in
                self?.applyMarkdown(action)
            })
            item.accessibilityLabel = title
            return item
        }
        func entry(_ name: String, _ title: String, _ action: MarkdownEditing.Action) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: name)) { [weak self] _ in self?.applyMarkdown(action) }
        }
        let lists = UIMenu(title: String(localized: "List", comment: "Markdown bar: menu of list and quote helpers"), children: [
            entry("list.bullet", String(localized: "Bulleted List", comment: "Markdown bar: start bulleted list items"), .bulletList),
            entry("list.number", String(localized: "Numbered List", comment: "Markdown bar: start numbered list items"), .numberedList),
            entry("checklist", String(localized: "Task List", comment: "Markdown bar: start task list items (check boxes)"), .taskList),
            entry("text.quote", String(localized: "Quote", comment: "Markdown bar: make the lines a block quote"), .quote),
        ])
        let math = UIMenu(title: String(localized: "Math", comment: "Markdown bar: menu of LaTeX math helpers"), children: [
            entry("x.squareroot", String(localized: "Inline Math", comment: "Markdown bar: insert $…$ (LaTeX math in the line)"), .math),
            entry("function", String(localized: "Display Math", comment: "Markdown bar: insert a $$…$$ block (LaTeX math on its own lines)"),
                  .displayMath),
        ])
        let sizes = UIMenu(title: String(localized: "Size", comment: "Text style bar: font size menu"), children: TextBoxPlacement.sizes.map { s in
            UIAction(title: "\(Int(s)) pt") { [weak self] _ in self?.restyleMarkdown { $0.size = s } } // l10n:ignore (number and unit)
        })
        let colour = UIBarButtonItem(title: String(localized: "Colour", comment: "Text style bar: text colour menu"),
                                     image: TextColourPalette.swatchImage(currentColour, size: 22), primaryAction: nil, menu: nil)
        colour.primaryAction = UIAction(title: String(localized: "Colour", comment: "Text style bar: text colour menu")) { [weak self, weak colour] _ in
            guard let self, let colour else { return }
            self.showColours(from: colour)
        }
        colour.accessibilityLabel = String(localized: "Colour", comment: "Text style bar: text colour menu")
        colourItem = colour
        let fontChoices: [(String, TextContent.Font)] = [
            (String(localized: "Sans Serif", comment: "Typeface"), .sans),
            (String(localized: "Serif", comment: "Typeface"), .serif),
        ]
        let fonts = UIMenu(title: String(localized: "Font", comment: "Text style bar: typeface menu"), children: fontChoices.map { name, f in
            UIAction(title: name) { [weak self] _ in self?.restyleMarkdown { $0.font = f } }
        })
        let alignChoices: [(String, String, TextContent.Alignment)] = [
            (String(localized: "Start", comment: "Text alignment"), "text.alignleft", .start),
            (String(localized: "Center", comment: "Text alignment"), "text.aligncenter", .center),
            (String(localized: "End", comment: "Text alignment"), "text.alignright", .end),
        ]
        let aligns = UIMenu(title: String(localized: "Alignment", comment: "Text style bar: paragraph alignment menu"), children: alignChoices.map { name, image, a in
            UIAction(title: name, image: UIImage(systemName: image)) { [weak self] _ in self?.restyleMarkdown { $0.align = a == .start ? nil : a } }
        })
        bar.items = [
            helper("bold", String(localized: "Bold", comment: "Text style"), .bold),
            helper("italic", String(localized: "Italic", comment: "Text style"), .italic),
            helper("strikethrough", String(localized: "Strikethrough", comment: "Text style"), .strikethrough),
            helper("chevron.left.forwardslash.chevron.right", String(localized: "Code", comment: "Markdown bar: mark the selection as `code`"), .code),
            helper("number", String(localized: "Heading", comment: "Markdown bar: make the line a heading (# Title); again for a smaller one"), .heading),
            UIBarButtonItem(title: lists.title, image: UIImage(systemName: "list.bullet"), menu: lists),
            helper("link", String(localized: "Link", comment: "Markdown bar: insert a [link](https://…)"), .link),
            UIBarButtonItem(title: math.title, image: UIImage(systemName: "x.squareroot"), menu: math),
            UIBarButtonItem(title: sizes.title, image: UIImage(systemName: "textformat.size"), menu: sizes),
            colour,
            UIBarButtonItem(title: fonts.title, image: UIImage(systemName: "textformat"), menu: fonts),
            UIBarButtonItem(title: aligns.title, image: UIImage(systemName: "text.alignleft"), menu: aligns),
            .flexibleSpace(),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.endEditing() }),
        ]
        bar.sizeToFit()
        return bar
    }
}

/// Where text boxes go and what the style bar offers (pure, tested).
enum TextBoxPlacement {
    /// Sizes in the size menu.
    static let sizes: [Double] = [10, 12, 14, 16, 18, 24, 32, 48, 72]
    /// Room kept to the page's right edge.
    static let margin = 16.0
    /// Width of a new box, at most (page points).
    static let newBoxWidth = 320.0
    /// Narrowest new box.
    static let minimumWidth = 60.0

    /// A new box's frame for a tap at `p`: its first line there (the tap is
    /// on the line's middle), as wide as `newBoxWidth` or up to the page's
    /// margin, at least `minimumWidth`, one line tall.
    static func newFrame(at p: ItemFrames.Point, pageWidth: Double, size: Double) -> Rect {
        let lineHeight = 1.2 * size
        let room = pageWidth - margin - p.x
        let w = max(minimumWidth, min(newBoxWidth, room.isFinite ? room : 0))
        let x = min(p.x, max(0, pageWidth - w))
        return Rect(x: InkJSON.round3(max(0, x)), y: InkJSON.round3(max(0, p.y - lineHeight / 2)), w: InkJSON.round3(w),
                    h: InkJSON.round3(lineHeight))
    }

    /// The text box a tap at `p` lands on (topmost, with the selection's slop).
    static func textBox(at p: ItemFrames.Point, in items: [Item], zoom: Double) -> Item? {
        let texts = items.filter { $0.kind == .text && $0.text != nil }
        return ItemFrames.item(at: p, in: texts, slop: ItemSelectionModel.slop / max(zoom, 0.01))
    }
}

/// The text colours the style bar offers: the pen's palette (pure, tested).
/// PencilKit's tool picker offers black, blue, green, yellow and red (the
/// system colours as on light paper) and a colour wheel; the swatches are the
/// same, the pen's current colour first when it is another one, and "More"
/// opens the same system colour picker as the pen's wheel.
enum TextColourPalette {
    /// The pen palette's colours, as drawn on (light) paper, with their names (for VoiceOver).
    @MainActor static var standard: [(name: String, color: Sempere.Color)] {
        let light = UITraitCollection(userInterfaceStyle: .light)
        return [(String(localized: "Black", comment: "Text colour"), UIColor.black),
                (String(localized: "Blue", comment: "Text colour"), .systemBlue),
                (String(localized: "Green", comment: "Text colour"), .systemGreen),
                (String(localized: "Yellow", comment: "Text colour"), .systemYellow),
                (String(localized: "Red", comment: "Text colour"), .systemRed)].map { ($0.0, opaque(Sempere.Color($0.1.resolvedColor(with: light)))) }
    }

    /// The swatches: the pen's colour (opaque) first unless the palette has
    /// it, then the palette.
    static func swatches(pen: Sempere.Color?, standard: [Sempere.Color]) -> [Sempere.Color] {
        var out = standard
        if let pen {
            let p = opaque(pen)
            if !out.contains(p) { out.insert(p, at: 0) }
        }
        return out
    }

    @MainActor static func swatches(pen: Sempere.Color?) -> [Sempere.Color] {
        swatches(pen: pen, standard: standard.map(\.color))
    }

    /// The name VoiceOver reads for a swatch: the palette's, else "Pen Colour"
    /// for the pen's, else the hex value.
    static func name(of colour: Sempere.Color, standard: [(name: String, color: Sempere.Color)], pen: Sempere.Color?) -> String {
        if let named = standard.first(where: { $0.color == opaque(colour) }) { return named.name }
        if let pen, opaque(pen) == opaque(colour) { return String(localized: "Pen Colour", comment: "VoiceOver: the swatch of the pen's current colour") }
        return String(format: "#%02X%02X%02X", colour.r, colour.g, colour.b)
    }

    /// Text is drawn opaque: a marker's translucent colour is taken without its alpha.
    static func opaque(_ c: Sempere.Color) -> Sempere.Color { Sempere.Color(r: c.r, g: c.g, b: c.b) }

    /// A round swatch of `colour`, with a thin ring so white and yellow show on a light bar.
    @MainActor static func swatchImage(_ colour: Sempere.Color, size: CGFloat, selected: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let r = CGRect(x: 0, y: 0, width: size, height: size)
            let inner = selected ? r.insetBy(dx: size * 0.18, dy: size * 0.18) : r.insetBy(dx: 1, dy: 1)
            colour.uiColor.setFill()
            ctx.cgContext.fillEllipse(in: inner)
            UIColor.black.withAlphaComponent(0.2).setStroke()
            ctx.cgContext.setLineWidth(1)
            ctx.cgContext.strokeEllipse(in: inner)
            if selected {
                UIColor.tintColor.setStroke()
                ctx.cgContext.setLineWidth(2)
                ctx.cgContext.strokeEllipse(in: r.insetBy(dx: 1.5, dy: 1.5))
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// The colour popover of the text style bar: a row of round swatches (the
/// current colour ringed) and the system colour picker ("More").
@MainActor
final class ColourSwatchesController: UIViewController, UIPopoverPresentationControllerDelegate,
    UIColorPickerViewControllerDelegate {
    let swatches: [Sempere.Color]
    let current: Sempere.Color
    let choose: (Sempere.Color) -> Void
    static let swatchSize: CGFloat = 36

    init(swatches: [Sempere.Color], current: Sempere.Color, choose: @escaping (Sempere.Color) -> Void) {
        self.swatches = swatches
        self.current = current
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "textColourSwatches"
        let standard = TextColourPalette.standard
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        for c in swatches {
            let button = UIButton(type: .custom)
            button.setImage(TextColourPalette.swatchImage(c, size: Self.swatchSize, selected: TextColourPalette.opaque(c) == TextColourPalette.opaque(current)),
                            for: .normal)
            button.accessibilityLabel = TextColourPalette.name(of: c, standard: standard, pen: swatches.first)
            button.accessibilityTraits.insert(.button)
            button.addAction(UIAction { [weak self] _ in self?.picked(c) }, for: .primaryActionTriggered)
            button.widthAnchor.constraint(equalToConstant: Self.swatchSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.swatchSize).isActive = true
            row.addArrangedSubview(button)
        }
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "paintpalette"), for: .normal)
        more.accessibilityLabel = String(localized: "More Colours", comment: "VoiceOver: opens the system colour picker")
        more.addAction(UIAction { [weak self] _ in self?.showPicker() }, for: .primaryActionTriggered)
        more.widthAnchor.constraint(equalToConstant: Self.swatchSize).isActive = true
        more.heightAnchor.constraint(equalToConstant: Self.swatchSize).isActive = true
        row.addArrangedSubview(more)
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        let n = CGFloat(swatches.count + 1)
        preferredContentSize = CGSize(width: n * Self.swatchSize + (n - 1) * 10 + 28, height: Self.swatchSize + 24)
    }

    private func picked(_ c: Sempere.Color) {
        dismiss(animated: true) { [choose] in choose(c) }
    }

    /// The system colour picker, as the pen's colour wheel opens.
    private func showPicker() {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = current.uiColor
        picker.delegate = self
        present(picker, animated: true)
    }

    func colorPickerViewController(_ controller: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously else { return }
        let c = TextColourPalette.opaque(Sempere.Color(color))
        controller.dismiss(animated: true) { [weak self] in self?.picked(c) }
    }

    /// A popover on an iPhone too (not a sheet).
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
