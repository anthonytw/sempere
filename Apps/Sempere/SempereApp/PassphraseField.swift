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
/// passphrase declares `.newPassword` with `passwordRules`, so AutoFill's
/// Strong Password fills both fields of the pair.
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
}

/// The text field of `PassphraseField`.
struct PassphraseTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let revealed: Bool
    let contentType: UITextContentType
    let identifier: String
    var onSubmit: (() -> Void)?

    /// What AutoFill generates for a new passphrase: Apple's default format
    /// (20 characters with a digit and a capital) satisfies these rules and
    /// clears the stored-key floor (`PassphraseStrength`).
    static let rules = "minlength: 20; required: lower; required: upper; required: digit;"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.isSecureTextEntry = !revealed
        field.textContentType = contentType
        if contentType == .newPassword { field.passwordRules = UITextInputPasswordRules(descriptor: Self.rules) }
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
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.isSecureTextEntry == revealed {
            field.isSecureTextEntry = !revealed
            // Switching the mode can drop or garble the text: put it back.
            field.text = nil
            field.text = text
        } else if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder { field.placeholder = placeholder }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PassphraseTextField

        init(_ parent: PassphraseTextField) { self.parent = parent }

        func textFieldDidBeginEditing(_ field: UITextField) {
            // A secure field may have cleared itself on the focus: never lose what was there.
            if (field.text ?? "").isEmpty, !parent.text.isEmpty { field.text = parent.text }
            // Select everything (typing replaces it, as the owner expects), after UIKit placed the caret.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder else { return }
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            }
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            // A secure field clears everything at the first key after it regains the focus; apply
            // the edit to the range the user had selected instead, so it never does.
            guard field.isSecureTextEntry, field.markedTextRange == nil else { return true }
            let current = (field.text ?? "") as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= current.length else { return true }
            let updated = current.replacingCharacters(in: range, with: string)
            field.text = updated
            let caret = range.location + (string as NSString).length
            if let position = field.position(from: field.beginningOfDocument, offset: caret) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
            parent.text = updated
            return false
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit?()
            return true
        }
    }
}

/// The live checklist under a new passphrase pair: the strength estimate
/// against the floor with a meter, the two entries matching, and while it is
/// too weak, why (`StoredKeyPassphrase.hints`).
struct PassphraseRequirementsView: View {
    let passphrase: String
    let confirmation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: StoredKeyPassphrase.progress(passphrase))
                .tint(StoredKeyPassphrase.accepts(passphrase) ? .green : .orange)
                .accessibilityHidden(true)
            ForEach(StoredKeyPassphrase.requirements(passphrase, confirmation: confirmation)) { requirement in
                Label {
                    Text(requirement.text)
                } icon: {
                    Image(systemName: requirement.met ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(requirement.met ? Color.green : Color.secondary)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityValue(requirement.met ? String(localized: "Done", comment: "Accessibility value of a met checklist line")
                                                    : String(localized: "Missing", comment: "Accessibility value of an unmet checklist line"))
                .accessibilityIdentifier("passphrase.requirement." + requirement.id)
            }
            ForEach(StoredKeyPassphrase.hints(passphrase), id: \.self) { hint in
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("passphrase.hint")
            }
        }
    }
}
