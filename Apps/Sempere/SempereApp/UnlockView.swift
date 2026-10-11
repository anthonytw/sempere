import SwiftUI

/// Asks for a key to the open vault: the remembered key (Face ID first), a
/// stored key file's passphrase, or a pasted `AGE-SECRET-KEY-PQ-1…` (or legacy
/// `AGE-SECRET-KEY-1…`) identity. After a manual unlock it offers to remember
/// the key (`RememberedKeys`).
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
                        Text("A key for a vault with this id is saved on \(RememberedKeys.deviceName), but it is offered only where it opened this vault before: any folder can claim a vault's id. Unlock this one with the passphrase or the key.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Passphrase of a stored key") {
                SecureField("Passphrase", text: $passphrase)
                    .onSubmit { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                Button("Unlock") { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                    .disabled(passphrase.isEmpty)
            }
            Section("Or paste a secret key") {
                TextField("AGE-SECRET-KEY-PQ-1…", text: $identityText, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Unlock with Key") { unlock { try await keys.unlock(model, identityText: identityText) } }
                    .disabled(identityText.isEmpty)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Unlock \(vaultTitle)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close Vault") { model.close() }
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
        case .failed(let message): failure = String(localized: "\(message)\nUse the passphrase or paste the key instead.",
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

/// After a manual unlock: remember the key on this device (default on) and,
/// optionally, in iCloud Keychain (default off).
private struct RememberKeyView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    let offer: RememberedKeys.Offer
    @State private var remember = true
    @State private var sync = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Toggle("Remember on \(RememberedKeys.deviceName)", isOn: $remember)
            } footer: {
                Text(RememberedKeys.deviceOnlyFooter(vaultName: offer.vaultName, biometry: RememberedKeys.biometryName))
            }
            Section {
                Toggle("Also sync via iCloud Keychain", isOn: $sync)
                    .disabled(!remember)
            } footer: {
                let biometry = RememberedKeys.biometryPhrase
                Text("Your other devices signed in to the same Apple Account get the key too. The Keychain cannot require \(biometry) for synced items, so Sempere asks for \(biometry) or your passcode itself before using it; the key is otherwise protected by iCloud Keychain's end-to-end encryption and your device passcode. Synced keys may not be listed in the Passwords app.")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Remember Key?")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Now") { answer(nil) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { answer(remember ? (sync ? .iCloudKeychain : .thisDevice) : nil) }
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
