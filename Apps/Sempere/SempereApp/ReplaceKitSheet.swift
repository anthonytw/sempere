import Age
import Sempere
import SempereRender
import SwiftUI

/// Replace Recovery Kit (on home: key-hierarchy design §6.5): device-owner authentication, then every device is
/// kept or removed (takeovers since the current kit marked), then the new kit is printed and one of its lines
/// typed back, and an optional passphrase copy. The old kit is useless for every later change; it still opens
/// what was written before, unless everything is re-encrypted.
struct ReplaceKitSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    /// Told what the change did (the list's alert).
    let done: (String) -> Void

    private enum Stage { case review, kit }
    @State private var stage = Stage.review
    @State private var review: [Vault.KitReviewItem]?
    /// Device id → keep (true) or remove (false); every device must be answered.
    @State private var answers: [String: Bool] = [:]
    @State private var newKit: MLKEM768X25519Identity?
    @State private var lineNumber = 1
    @State private var typedLine = ""
    @State private var oldKitText = ""
    @State private var passphrase = ""
    @State private var passphraseAgain = ""
    @State private var revealed = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                switch stage {
                case .review: reviewForm
                case .kit: kitForm
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Replace Recovery Kit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch stage {
                    case .review:
                        Button("Continue") { continueToKit() }.disabled(!reviewAnswered)
                            .help("Make the new kit")
                    case .kit:
                        Button("Replace") { replace() }.disabled(!lineMatches || !passphraseOK)
                            .help("Replace the recovery kit")
                            .accessibilityIdentifier("replaceKit.confirm")
                    }
                }
            }
            .disabled(working)
            .interactiveDismissDisabled(working)
            .overlay { DeviceChangeSyncOverlay() }
            .task {
                do { review = try await model.kitReview() } catch { failure = DeviceChangeText.message(error) }
            }
        }
        .accessibilityIdentifier("replaceKitSheet")
    }

    // MARK: - Review (design §6.5 step 1)

    @ViewBuilder private var reviewForm: some View {
        Section {
            Text("A new kit makes the current one useless for every later change: from then on, no device that sees the change accepts a takeover with the old kit.")
        }
        if let review {
            Section {
                if review.isEmpty {
                    Text("This is the vault's only device.").foregroundStyle(.secondary)
                }
                ForEach(review, id: \.device.fingerprint) { item in
                    let id = item.device.id ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: DeviceName.display(item.device.name)).font(.headline)
                            Text(verbatim: id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if item.takeoverSinceKit {
                            Label("Took over or was added with the recovery kit since the current kit was made",
                                  systemImage: "exclamationmark.shield")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Picker("Keep or remove", selection: Binding(get: { answers[id] }, set: { answers[id] = $0 })) {
                            Text("Keep").tag(Bool?.some(true))
                            Text("Remove").tag(Bool?.some(false))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Confirm every device")
            } footer: {
                Text("Remove any device you no longer have or do not recognize.")
            }
        } else if failure == nil {
            ProgressView()
        }
    }

    private var reviewAnswered: Bool {
        guard let review else { return false }
        return review.allSatisfy { answers[$0.device.id ?? ""] != nil }
    }

    private func continueToKit() {
        failure = nil
        working = true
        Task {
            defer { working = false }
            do {
                // The one list change that needs the owner at the device (design §6.5 step 0).
                try await model.ownerAuthenticator.authenticate(reason: String(localized: "Replace the recovery kit"))
                let kit = try MLKEM768X25519Identity()
                newKit = kit
                lineNumber = Self.checkLine(of: kit.string)
                stage = .kit
            } catch is CancellationError {
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }

    // MARK: - The new kit (design §6.5 steps 2 and 3)

    @ViewBuilder private var kitForm: some View {
        if let newKit, let vault = model.vault {
            let key = KeyFile(identity: .mlkem768x25519(newKit),
                              label: String(localized: "Recovery key of \(model.vaultName ?? "")", comment: "Label of a vault's recovery key; the value is the vault's name"))
            KeyFileActions(key: key, vault: RecoveryKit.VaultInfo(vault: vault, name: model.vaultName ?? ""))
            Section {
                TextField("Line \(lineNumber)", text: $typedLine)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .privacySensitive()
                    .accessibilityIdentifier("replaceKit.line")
                if !typedLine.isEmpty, !lineMatches {
                    Text("That is not line \(lineNumber) of the new key.").font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Type line \(lineNumber) of the printed key", comment: "Replace Kit: the value is a line number")
            } footer: {
                Text("This checks that the new kit was printed or saved before the old one stops working.")
            }
            Section {
                PassphrasePairField(placeholder: String(localized: "New passphrase"), confirmationPlaceholder: String(localized: "Again"),
                                    passphrase: $passphrase, confirmation: $passphraseAgain, revealed: $revealed,
                                    identifier: "replaceKit.passphrase", confirmationIdentifier: "replaceKit.passphraseAgain")
                if let problem = passphraseProblem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Passphrase copy (optional)")
            } footer: {
                Text("A copy of the new recovery key in the vault under a passphrase, so the passphrase alone can take over. Leave it empty for none; any old copy is deleted.")
            }
            Section {
                SecureField("AGE-SECRET-KEY-PQ-1…", text: $oldKitText)
                    .font(.body.monospaced())
            } header: {
                Text("Old recovery key (optional)")
            } footer: {
                Text("If you still have the current kit, its key adds a record that its holder agreed. It changes nothing else.")
            }
        }
    }

    private var lineMatches: Bool {
        guard let newKit else { return false }
        return Self.lineMatches(typedLine, line: lineNumber, of: newKit.string)
    }

    /// The line (1-based) of the printed key `identity` the user types back: one of the lines after the fixed
    /// `AGE-SECRET-KEY-PQ-1` prefix, at random (review of #87, M2: the prefix line proves nothing was printed).
    nonisolated static func checkLine(of identity: String, random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Int {
        let lines = PaperKey.identityLines(identity)
        let candidates = lines.indices.filter { i in
            !PaperKey.identityPrefixes.contains(lines[i].text) && !PaperKey.identityPrefixes.contains { lines[i].text.hasPrefix($0) }
        }
        guard let first = candidates.first, let last = candidates.last else { return lines.count }
        // The candidates are the lines after the prefix: contiguous.
        return random(first...last) + 1
    }

    /// True when `typed` is line `line` (1-based) of the printed key `identity`, ignoring case and spaces (the
    /// kit prints it in groups).
    nonisolated static func lineMatches(_ typed: String, line: Int, of identity: String) -> Bool {
        let lines = PaperKey.identityLines(identity)
        guard lines.indices.contains(line - 1) else { return false }
        func clean(_ s: String) -> String { s.uppercased().filter { !$0.isWhitespace } }
        return !typed.isEmpty && clean(typed) == clean(lines[line - 1].text)
    }

    private var passphraseProblem: String? {
        guard !passphrase.isEmpty else { return nil }
        if passphrase != passphraseAgain { return String(localized: "The passphrases do not match.") }
        return PassphraseStrength.storedKeyProblem(passphrase)
    }

    private var passphraseOK: Bool { passphrase.isEmpty || passphraseProblem == nil }

    private func replace() {
        guard let newKit else { return }
        failure = nil
        let old: MLKEM768X25519Identity?
        let text = oldKitText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            old = nil
        } else {
            guard case .mlkem768x25519(let pq)? = try? IdentityFile.parse(text) else {
                failure = String(localized: "The old recovery key does not read as a post-quantum key.")
                return
            }
            old = pq
        }
        let keep = Set(answers.filter(\.value).map(\.key)), remove = Set(answers.filter { !$0.value }.map(\.key))
        let phrase = passphrase.isEmpty ? nil : passphrase
        working = true
        Task {
            defer { working = false }
            do {
                let outcome = try await model.replaceRecoveryKit(newKit, keep: keep, remove: remove, oldKit: old, passphrase: phrase)
                passphrase = ""; passphraseAgain = ""; oldKitText = ""; typedLine = ""
                done(DeviceChangeText.done(outcome, action: String(localized: "The recovery kit was replaced. Keep the new kit somewhere safe and destroy the old one.")))
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }
}
