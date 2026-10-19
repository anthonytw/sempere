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

    var body: some View {
        HStack(spacing: 8) {
            PassphrasePairTextFields(placeholders: [placeholder, confirmationPlaceholder],
                                     texts: [$passphrase, $confirmation], revealed: revealed,
                                     identifiers: [identifier, confirmationIdentifier])
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
    /// What AutoFill generates for a new passphrase: Apple's default format
    /// (20 characters with a digit and a capital) satisfies these rules and
    /// clears the stored-key floor (`PassphraseStrength`).
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
    static func update(_ field: UITextField, text: String, revealed: Bool, placeholder: String) {
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
        PassphraseTextFieldSetup.update(field, text: text, revealed: revealed, placeholder: placeholder)
    }
}

/// The two fields of `PassphrasePairField` in one vertical `UIStackView`, with a hairline between.
struct PassphrasePairTextFields: UIViewRepresentable {
    let placeholders: [String]
    let texts: [Binding<String>]
    let revealed: Bool
    let identifiers: [String]

    func makeCoordinator() -> [PassphraseFieldCoordinator] { texts.map { PassphraseFieldCoordinator(text: $0, onSubmit: nil) } }

    /// The stack: the new passphrase's field, a hairline, the confirmation's field.
    @MainActor
    static func makeStack(placeholders: [String], texts: [String], revealed: Bool, identifiers: [String]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
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

    static func fields(of stack: UIStackView) -> [UITextField] { stack.arrangedSubviews.compactMap { $0 as? UITextField } }

    func makeUIView(context: Context) -> UIStackView {
        let stack = Self.makeStack(placeholders: placeholders, texts: texts.map(\.wrappedValue), revealed: revealed,
                                   identifiers: identifiers)
        for (field, coordinator) in zip(Self.fields(of: stack), context.coordinator) { coordinator.attach(field) }
        return stack
    }

    func updateUIView(_ stack: UIStackView, context: Context) {
        for (i, field) in Self.fields(of: stack).enumerated() where i < texts.count {
            context.coordinator[i].text = texts[i]
            PassphraseTextFieldSetup.update(field, text: texts[i].wrappedValue, revealed: revealed, placeholder: placeholders[i])
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

    func attach(_ field: UITextField) {
        field.delegate = self
        field.addTarget(self, action: #selector(changed(_:)), for: .editingChanged)
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
        text.wrappedValue = updated
        return false
    }

    @objc func changed(_ field: UITextField) {
        text.wrappedValue = field.text ?? ""
    }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        onSubmit?()
        return true
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
