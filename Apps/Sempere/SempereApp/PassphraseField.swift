import SwiftUI
import UIKit

/// A passphrase field with a show/hide (eye) button, for passphrases that
/// protect a key (New Vault's stored copy, a picked key file).
///
/// It is a `UITextField` rather than a `SecureField` because a secure field
/// clears itself when it gets the focus again (or at the next key), which lost
/// a generated password before it could be copied into the second field
/// (c26). Here the focus selects everything instead, so typing still replaces
/// it, and the eye shows the text so it can be read or copied. A new
/// passphrase and its confirmation are one `PassphrasePairField`.
struct PassphraseField: View {
    let placeholder: String
    @Binding var text: String
    /// Shared by the fields of a pair: both show or hide together.
    @Binding var revealed: Bool
    var contentType: UITextContentType = .newPassword
    /// The accessibility identifier of the text field (UI tests).
    var identifier: String
    var onSubmit: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            PassphraseTextField(placeholder: placeholder, text: $text, revealed: revealed, contentType: contentType,
                                identifier: identifier, onSubmit: onSubmit)
            PassphraseRevealButton(revealed: $revealed, identifier: identifier)
        }
    }
}

/// A new passphrase and its confirmation, as AutoFill's Strong Password needs them to fill both:
/// two `.newPassword` fields with the same `passwordRules`, next to each other in one UIKit view
/// (`PassphrasePairTextFields`), the new one first. As two rows of a `Form` (two cells) the iPad
/// filled only the first (TestFlight 1.0.0 (6)); the Mac filled both.
struct PassphrasePairField: View {
    let placeholder: String
    let confirmationPlaceholder: String
    @Binding var passphrase: String
    @Binding var confirmation: String
    @Binding var revealed: Bool
    /// The identifiers of the two fields; the eye is `identifier + ".reveal"`.
    var identifier: String
    var confirmationIdentifier: String
    /// The vault's name: shown above the pair as the AutoFill username, so Passwords saves one entry per vault
    /// (it keys a saved password by app and username; with none, a second Strong Password replaced the first).
    var account: String?

    var body: some View {
        HStack(spacing: 8) {
            PassphrasePairTextFields(placeholders: [placeholder, confirmationPlaceholder],
                                     texts: [$passphrase, $confirmation], revealed: revealed,
                                     identifiers: [identifier, confirmationIdentifier], account: account)
            PassphraseRevealButton(revealed: $revealed, identifier: identifier)
        }
    }
}

/// The eye of a passphrase field: shows or hides the text.
private struct PassphraseRevealButton: View {
    @Binding var revealed: Bool
    let identifier: String

    var body: some View {
        Button {
            revealed.toggle()
        } label: {
            Image(systemName: revealed ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(revealed ? String(localized: "Hide Passphrase", comment: "Tooltip of the eye button of a passphrase field")
                       : String(localized: "Show Passphrase", comment: "Tooltip of the eye button of a passphrase field"))
        .accessibilityLabel(revealed ? String(localized: "Hide Passphrase") : String(localized: "Show Passphrase"))
        .accessibilityIdentifier(identifier + ".reveal")
    }
}

/// How a passphrase `UITextField` is set up (both views use it).
enum PassphraseTextFieldSetup {
    /// The password rules handed to AutoFill, so it offers a Strong Password: Apple's default format
    /// (20 characters with a digit and a capital) meets them.
    static let rules = "minlength: 20; required: lower; required: upper; required: digit;"

    @MainActor
    static func makeField(placeholder: String, text: String, revealed: Bool, contentType: UITextContentType,
                          identifier: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.isSecureTextEntry = !revealed
        field.textContentType = contentType
        if contentType == .newPassword { field.passwordRules = UITextInputPasswordRules(descriptor: rules) }
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = identifier
        field.text = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    @MainActor
    static func update(_ field: UITextField, text: String, revealed: Bool, placeholder: String,
                       coordinator: PassphraseFieldCoordinator? = nil) {
        var text = text
        // Filled behind the app's back (AutoFill puts the Strong Password into the confirmation, which is
        // not being edited, without an editing event): the field's text is the news, never overwritten
        // with the binding's stale value (TestFlight build 8: the iPad's confirmation stayed empty).
        if let coordinator, let filled = coordinator.textChangedUnseen(in: field) {
            text = filled
        }
        if field.isSecureTextEntry == revealed {
            field.isSecureTextEntry = !revealed
            // Switching the mode can drop or garble the text: put it back.
            field.text = nil
            field.text = text
        } else if field.text != text {
            field.text = text
        }
        coordinator?.seen = field.text ?? ""
        if field.placeholder != placeholder { field.placeholder = placeholder }
    }
}

/// The text field of `PassphraseField`.
struct PassphraseTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let revealed: Bool
    let contentType: UITextContentType
    let identifier: String
    var onSubmit: (() -> Void)?

    static var rules: String { PassphraseTextFieldSetup.rules }

    func makeCoordinator() -> PassphraseFieldCoordinator { PassphraseFieldCoordinator(text: $text, onSubmit: onSubmit) }

    func makeUIView(context: Context) -> UITextField {
        let field = PassphraseTextFieldSetup.makeField(placeholder: placeholder, text: text, revealed: revealed,
                                                       contentType: contentType, identifier: identifier)
        context.coordinator.attach(field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        PassphraseTextFieldSetup.update(field, text: text, revealed: revealed, placeholder: placeholder,
                                        coordinator: context.coordinator)
    }
}

/// The two fields of `PassphrasePairField` in one vertical `UIStackView`, with a hairline between.
struct PassphrasePairTextFields: UIViewRepresentable {
    let placeholders: [String]
    let texts: [Binding<String>]
    let revealed: Bool
    let identifiers: [String]
    var account: String?

    func makeCoordinator() -> [PassphraseFieldCoordinator] { texts.map { PassphraseFieldCoordinator(text: $0, onSubmit: nil) } }

    /// The username field `makeStack` puts first when it is given an account: AutoFill saves a Strong Password
    /// under (app, username), so the vault's name there keeps each vault's passphrase as its own entry. It is
    /// shown, not hidden (AutoFill ignores a field the user cannot see), and cannot be edited.
    @MainActor
    static func makeAccountField(_ account: String) -> UITextField {
        let field = UITextField()
        field.textContentType = .username
        field.text = account
        field.isUserInteractionEnabled = false
        field.textColor = .secondaryLabel
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "passphrase.account"
        field.tag = Self.accountTag
        return field
    }

    static let accountTag = 7101

    /// Puts the account field and a hairline at the top of `stack`.
    @MainActor
    static func insertAccount(_ account: String, into stack: UIStackView) {
        let line = UIView()
        line.backgroundColor = .separator
        line.heightAnchor.constraint(equalToConstant: 1 / max(1, UIScreen.main.scale)).isActive = true
        stack.insertArrangedSubview(line, at: 0)
        stack.insertArrangedSubview(makeAccountField(account), at: 0)
    }

    /// The stack: the account (when given), the new passphrase's field, a hairline, the confirmation's field.
    @MainActor
    static func makeStack(placeholders: [String], texts: [String], revealed: Bool, identifiers: [String],
                          account: String? = nil) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        if let account, !account.isEmpty { insertAccount(account, into: stack) }
        for i in placeholders.indices {
            if i > 0 {
                let line = UIView()
                line.backgroundColor = .separator
                line.heightAnchor.constraint(equalToConstant: 1 / max(1, UIScreen.main.scale)).isActive = true
                stack.addArrangedSubview(line)
            }
            stack.addArrangedSubview(PassphraseTextFieldSetup.makeField(
                placeholder: placeholders[i], text: texts[i], revealed: revealed, contentType: .newPassword,
                identifier: identifiers[i]))
        }
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// The passphrase fields (not the account's).
    static func fields(of stack: UIStackView) -> [UITextField] {
        stack.arrangedSubviews.compactMap { $0 as? UITextField }.filter { $0.tag != accountTag }
    }

    func makeUIView(context: Context) -> UIStackView {
        let stack = Self.makeStack(placeholders: placeholders, texts: texts.map(\.wrappedValue), revealed: revealed,
                                   identifiers: identifiers, account: account)
        for (field, coordinator) in zip(Self.fields(of: stack), context.coordinator) { coordinator.attach(field) }
        return stack
    }

    func updateUIView(_ stack: UIStackView, context: Context) {
        if let shown = stack.arrangedSubviews.first(where: { $0.tag == Self.accountTag }) as? UITextField {
            if let account, shown.text != account { shown.text = account }
        } else if let account, !account.isEmpty {
            // The name was empty when the pair was built (New Vault, passphrase switched on before a name): the
            // username shows as soon as there is one.
            Self.insertAccount(account, into: stack)
        }
        for (i, field) in Self.fields(of: stack).enumerated() where i < texts.count {
            context.coordinator[i].text = texts[i]
            PassphraseTextFieldSetup.update(field, text: texts[i].wrappedValue, revealed: revealed, placeholder: placeholders[i],
                                            coordinator: context.coordinator[i])
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIStackView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let size = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                  withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: size.height)
    }
}

/// The delegate and change target of one passphrase `UITextField`.
@MainActor
final class PassphraseFieldCoordinator: NSObject, UITextFieldDelegate {
    var text: Binding<String>
    var onSubmit: (() -> Void)?

    init(text: Binding<String>, onSubmit: (() -> Void)?) {
        self.text = text
        self.onSubmit = onSubmit
    }

    /// The field's text as last written by the app or reported by an editing event.
    var seen = ""

    func attach(_ field: UITextField) {
        field.delegate = self
        field.addTarget(self, action: #selector(changed(_:)), for: .editingChanged)
        seen = field.text ?? ""
        // AutoFill may fill a field that is not being edited with no editing event, only this notification.
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)),
                                               name: UITextField.textDidChangeNotification, object: field)
    }

    /// The field's text when it changed since the app last saw it (filled by the system), which the
    /// binding then takes (on the next turn: this runs inside a view update); nil otherwise.
    func textChangedUnseen(in field: UITextField) -> String? {
        let now = field.text ?? ""
        guard now != seen else { return nil }
        seen = now
        Task { @MainActor [weak self] in
            guard let self, self.text.wrappedValue != now else { return }
            self.text.wrappedValue = now
        }
        return now
    }

    @objc private func textDidChange(_ note: Notification) {
        guard let field = note.object as? UITextField else { return }
        changed(field)
    }

    func textFieldDidBeginEditing(_ field: UITextField) {
        // A secure field may have cleared itself on the focus: never lose what was there.
        if (field.text ?? "").isEmpty, !text.wrappedValue.isEmpty { field.text = text.wrappedValue }
        // Select everything (typing replaces it, as the owner expects), after UIKit placed the caret.
        DispatchQueue.main.async { [weak field] in
            guard let field, field.isFirstResponder else { return }
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        }
    }

    /// Whether the app applies an edit itself instead of UIKit: only a partial edit of a secure field's
    /// text (the case where UIKit would clear the rest). An edit of an empty field or of all its text
    /// is UIKit's: AutoFill's Strong Password fills the confirmation only when UIKit took the fill of
    /// the first field; a rejected one (the app writing it itself) left the second empty on an iPad
    /// (TestFlight build 8: "only fills the first field still").
    nonisolated static func appliesEditItself(secure: Bool, composing: Bool, length: Int, range: NSRange) -> Bool {
        guard secure, !composing, length > 0, range.location != NSNotFound, NSMaxRange(range) <= length else { return false }
        return !(range.location == 0 && range.length == length)
    }

    func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        // A secure field clears everything at the first key after it regains the focus; apply
        // the edit to the range the user had selected instead, so it never does.
        let current = (field.text ?? "") as NSString
        guard Self.appliesEditItself(secure: field.isSecureTextEntry, composing: field.markedTextRange != nil,
                                     length: current.length, range: range) else { return true }
        let updated = current.replacingCharacters(in: range, with: string)
        field.text = updated
        let caret = range.location + (string as NSString).length
        if let position = field.position(from: field.beginningOfDocument, offset: caret) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
        seen = updated
        text.wrappedValue = updated
        return false
    }

    @objc func changed(_ field: UITextField) {
        seen = field.text ?? ""
        if text.wrappedValue != seen { text.wrappedValue = seen }
    }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        onSubmit?()
        return true
    }
}

/// Under a new passphrase pair: says so when the two entries differ.
struct PassphraseMismatchView: View {
    let passphrase: String
    let confirmation: String

    var body: some View {
        if !confirmation.isEmpty, passphrase != confirmation {
            Text("The two entries are not the same.", comment: "Shown under a new passphrase when its repetition differs")
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("passphrase.mismatch")
        }
    }
}

/// What the sheets that offer a passphrase copy say under it.
enum StoredKeyPassphrase {
    static var footnote: String {
        String(localized: "The copy is kept in the vault, on its storage: anyone who can read the storage can try passphrases on it offline, so a long passphrase is worth it. Suggest a Passphrase makes seven random words.",
               comment: "Footnote under the toggle that stores the key in the vault under a passphrase")
    }
}
