import Sempere
import SwiftUI

/// Add Passphrase Copy (key-hierarchy design §8.2): the recovery key under a passphrase, kept in the vault, for a
/// vault made without one. Add-only: sync never replaces a copy, so changing its passphrase is Replace Recovery Kit. No device keeps the recovery key, so it is given from the
/// printed kit; the other way to get a copy is Replace Recovery Kit, which makes a new key and can add its copy.
/// Device-owner authentication first (`AppModel.addPassphraseCopy`).
struct AddPassphraseCopySheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    /// Told what the change did (the list's alert).
    let done: (String) -> Void

    @State private var keyText = ""
    @State private var key = ExistingKeyInput.Status.empty
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var revealed = false
    @State private var working = false
    @State private var failure: String?

    private var canAdd: Bool {
        !working && key.identity != nil && !passphrase.isEmpty && passphrase == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A secure field, as the takeover's: the key is not shown on screen, in screen sharing or in the
                    // app switcher.
                    SecureField("AGE-SECRET-KEY-PQ-1…", text: $keyText)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("addCopy.key")
                        .onChange(of: keyText) { _, text in key = ExistingKeyInput.status(ofText: text) }
                    switch key {
                    case .ready(let identity):
                        Label(String(localized: "Ready. The recovery key is \(ExistingKeyInput.shortRecipient(identity)).",
                                     comment: "%@ is the abbreviated public key of the recovery key"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.footnote)
                    case .problem(let message):
                        Text(message).font(.footnote).foregroundStyle(.red)
                    case .needsPassphrase:
                        Text("That key file is protected by a passphrase. Paste the plain recovery key from the printed kit instead.")
                            .font(.footnote).foregroundStyle(.red)
                    case .empty:
                        EmptyView()
                    }
                } header: {
                    Text("Recovery key")
                } footer: {
                    Text("No device keeps the recovery key, so type or paste it from the printed kit. It must be the current kit: after Replace Recovery Kit, the new one. If the kit is lost, replace it instead and add the passphrase copy there.")
                }
                Section {
                    PassphrasePairField(placeholder: String(localized: "Passphrase", comment: "Placeholder of the new passphrase field"),
                                        confirmationPlaceholder: String(localized: "Repeat passphrase",
                                                                        comment: "Placeholder of the passphrase confirmation"),
                                        passphrase: $passphrase, confirmation: $confirmation, revealed: $revealed,
                                        identifier: "addCopy.passphrase", confirmationIdentifier: "addCopy.confirmation",
                                        account: model.vaultName)
                    PassphraseMismatchView(passphrase: passphrase, confirmation: confirmation)
                    Button(String(localized: "Suggest a Passphrase", comment: "New Vault: fill in seven random words"),   // help-lint: ignore (a titled button in a form row: its title says what it does)
                           systemImage: "dice") {
                        let suggested = GeneratedPassphrase.make()
                        passphrase = suggested
                        confirmation = suggested
                        revealed = true
                    }
                } header: {
                    Text("Passphrase")
                } footer: {
                    Text(StoredKeyPassphrase.footnote)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "Add Passphrase Copy"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add", comment: "Button: write the passphrase copy"), action: add)   // help-lint: ignore (the sheet's titled confirm button)
                        .disabled(!canAdd)
                        .accessibilityIdentifier("addCopy.confirm")
                }
            }
            .disabled(working)
            .interactiveDismissDisabled(working)
        }
        .accessibilityIdentifier("addPassphraseCopySheet")
    }

    private func add() {
        failure = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await model.addPassphraseCopy(recoveryKey: key, passphrase: passphrase)
                passphrase = ""; confirmation = ""; keyText = ""
                done(String(localized: "The recovery key's passphrase copy is in the vault. The passphrase alone can now open the vault read-only or take it over: keep it as safe as the kit."))
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }
}
