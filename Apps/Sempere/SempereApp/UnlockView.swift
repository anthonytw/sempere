import SwiftUI

/// Asks for a key to the open vault: the remembered device key (Face ID
/// first), a pasted device key file, or the recovery key (pasted, or its
/// passphrase copy in the vault), which opens the vault read-only. After a
/// manual unlock with a device key it offers to remember the key
/// (`RememberedKeys`).
struct UnlockView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    @State private var passphrase = ""
    @State private var identityText = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            if let offer = keys.offer, offer.vaultID == model.vault?.vaultId {
                RememberKeyView(offer: offer)
            } else {
                unlockForm
            }
        }
    }

    private var unlockForm: some View {
        Form {
            if keys.storage(for: model) != nil {
                if keys.offersSavedKey(for: model) {
                    Section {
                        Button("Unlock with Saved Key", systemImage: "faceid") { Task { await tryRememberedKey() } }
                            .disabled(keys.isUnlocking)
                    } footer: {
                        Text("The key is saved in the Keychain on \(RememberedKeys.deviceName).")
                    }
                } else {
                    Section {
                        Text("A key for a vault with this id is saved on \(RememberedKeys.deviceName), but it is offered only where it opened this vault before: any folder can claim a vault's id. Unlock this one with this device's key file; Sempere then offers to remember the key here too.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextField("AGE-SECRET-KEY-PQ-1…", text: $identityText, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("unlock.keyText")
                Button("Unlock with Key") { unlock { try await keys.unlock(model, identityText: identityText) } }
                    .disabled(identityText.isEmpty)
                    .accessibilityIdentifier("unlock.withKey")
            } header: {
                Text("Paste a key")
            } footer: {
                Text("This device's key file opens the vault to read and write. The recovery key opens it read-only.")
            }
            Section {
                SecureField("Passphrase", text: $passphrase)
                    .onSubmit { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                Button("Unlock") { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                    .disabled(passphrase.isEmpty)
            } header: {
                Text("Or the recovery key's passphrase")
            } footer: {
                // TODO(KH5): join this device to the vault from here (a join request approved by home).
                Text("The vault keeps a copy of its recovery key under a passphrase when one was chosen at its creation. It opens the vault read-only. To write from this device, it must join the vault; that is not available in the app yet.")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Unlock \(vaultTitle)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close Vault") { model.close() }
                    .help("Close the vault (⇧⌘W)")
            }
        }
        .disabled(model.isBusy || keys.isUnlocking)
        .task(id: model.vault?.vaultId) {
            // A remembered key unlocks at once, after Face ID.
            await tryRememberedKey()
        }
    }

    /// The open vault's name, or a generic word when it has none.
    private var vaultTitle: String {
        model.vaultName ?? String(localized: "Vault", comment: "Fallback name of a vault in “Unlock Vault”")
    }

    private func tryRememberedKey() async {
        failure = nil
        switch await keys.unlockWithRememberedKey(model) {
        case .failed(let message): failure = String(localized: "\(message)\nPaste this device's key file instead, or read the vault with its recovery key.",
                                                    comment: "%@ is why the saved key could not be used")
        case .unlocked, .noKey, .notHere, .cancelled: break
        }
    }

    private func unlock(_ action: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do { try await action() } catch { failure = "\(error)" }
        }
    }
}

/// After a manual unlock: remember the key on this device (default on). A
/// device key never goes to iCloud Keychain (design §6.1), so there is no
/// sync choice. TODO(KH5): shown again once devices join in the app.
private struct RememberKeyView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    let offer: RememberedKeys.Offer
    @State private var remember = true
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Form {
            if offer.replacing != nil {
                Section {
                    Text("A key for a vault with this id is saved on \(RememberedKeys.deviceName), but for another folder (another copy of this vault, or a WebDAV vault added again). Remembering this key replaces it, and it is then offered here too.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Remember on \(RememberedKeys.deviceName)", isOn: $remember)
            } footer: {
                Text(RememberedKeys.deviceOnlyFooter(vaultName: offer.vaultName, biometry: RememberedKeys.biometryName))
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Remember Key?")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Now") { answer(nil) }
                    .help("Do not save the key on this device")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { answer(remember ? .thisDevice : nil) }
            }
        }
        .disabled(saving)
    }

    private func answer(_ storage: KeyStorage?) {
        failure = nil
        saving = true
        Task {
            defer { saving = false }
            do {
                try await keys.answer(offer, storage: storage)
            } catch {
                // Keep the vault unlocked; say why the key was not saved.
                keys.offer = nil
                model.errorMessage = String(localized: "The vault is unlocked, but its key could not be saved: \(String(describing: error))")
            }
        }
    }
}
