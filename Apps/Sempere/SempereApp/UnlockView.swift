import Sempere
import SwiftUI

/// Opens the open vault on this device (key-hierarchy design §6; KH5): with this device's own key (Face ID first
/// when the vault asks for it), which happens by itself; for a device without one, Join This Device (approved on
/// the device that manages devices, `JoinDeviceView`), Take Over with the Recovery Kit (`TakeoverView`), or a
/// read-only look with the recovery key (pasted, or its passphrase copy in the vault).
struct UnlockView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    @State private var passphrase = ""
    @State private var identityText = ""
    @State private var failure: String?
    @State private var joining = false
    @State private var takingOver = false
    @State private var confirmForget = false
    /// What forgetting the key costs (`KeyRemoval`): warned of when this device is home.
    @State private var forgetRemoval = KeyRemoval()

    var body: some View {
        NavigationStack {
            Group {
                if joining || keys.joinStage != nil {
                    JoinDeviceView { joining = false }
                } else if takingOver {
                    TakeoverView(onDone: { takingOver = false })
                } else {
                    unlockForm
                }
            }
        }
    }

    private var unlockForm: some View {
        Form {
            if let problem = keys.keyProblem {
                Section {
                    Label(problem, systemImage: "key.slash").foregroundStyle(.orange)
                    Button("Forget This Device's Key…", systemImage: "trash", role: .destructive) { Task { await askToForget() } }
                        .accessibilityIdentifier("unlock.forgetKey")
                }
            }
            if keys.hasKeys(for: model), keys.keyProblem == nil {
                Section {
                    Button("Unlock", systemImage: "faceid") { Task { await tryDeviceKey() } }
                        .disabled(keys.isUnlocking)
                        .accessibilityIdentifier("unlock.deviceKey")
                } footer: {
                    Text("This device's key for the vault is in its Keychain.")
                }
            } else if canJoin {
                Section {
                    Button("Join This Device…", systemImage: "person.badge.plus") { joining = true }
                        .accessibilityIdentifier("unlock.join")
                    Button("Take Over with Recovery Kit…", systemImage: "key.viewfinder") { takingOver = true }
                        .accessibilityIdentifier("unlock.takeover")
                } footer: {
                    Text("To write from this device, it joins the vault: the device that manages devices approves it with six words. If that device is lost, take over with the recovery kit.")
                }
            } else {
                // No sync target (a backup, or a one-time copy): a join request has no way to reach the device that
                // manages devices, so Join is not offered (owner's test of build 10: a join from a backup failed).
                Section {
                    Text("This copy does not sync with any folder or server, so it cannot join your other devices. To join, open the vault's sync folder again with Open Vault… and keep “Keep syncing with this folder” on.")
                        .accessibilityIdentifier("unlock.noJoin")
                    Button("Take Over with Recovery Kit…", systemImage: "key.viewfinder") { takingOver = true }
                        .accessibilityIdentifier("unlock.takeover")
                } footer: {
                    Text("Taking over with the recovery kit makes this copy a vault of its own on this device.")
                }
            }
            Section {
                TextField("AGE-SECRET-KEY-PQ-1…", text: $identityText, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
                    .accessibilityIdentifier("unlock.keyText")
                Button("Unlock with Key") {
                    unlock(endingEditing: true) { try await keys.unlock(model, identityText: identityText) }
                }
                    .disabled(identityText.isEmpty)
                    .accessibilityIdentifier("unlock.withKey")
            } header: {
                Text("Or read with the recovery key")
            } footer: {
                Text("The recovery key opens the vault read-only. A device key file made with sempere opens it too; to write, this device then confirms the vault with the root fingerprint from its recovery kit.")
            }
            Section {
                // Unlock shares the field's row: with the keyboard up the form scrolls the focused field just
                // above it, so a button on the next row went under the keyboard on an iPhone once the join
                // and takeover section (KH5) pushed this section down.
                HStack {
                    SecureField("Passphrase", text: $passphrase)
                        .onSubmit { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                    Button("Unlock") { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(passphrase.isEmpty)
                }
            } header: {
                Text("Or the recovery key's passphrase")
            } footer: {
                Text("The vault keeps a copy of its recovery key under a passphrase when one was chosen. It opens the vault read-only.")
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
        .confirmationDialog("Forget this device's key for the vault?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Key", role: .destructive) {
                Task {
                    do { try await keys.forgetKeys(model) } catch { failure = DeviceChangeText.message(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let warning = forgetRemoval.forgetWarning {
                Text("\(warning) Its notes stay in the vault.", comment: "Forget Key: the warning when this device is home, then this")
            } else {
                Text("This device then joins the vault again (approved by the device that manages devices), or takes over with the recovery kit. Its notes stay in the vault.")
            }
        }
        .task(id: model.vault?.vaultId) {
            await keys.refresh(model)
            await tryDeviceKey()
        }
    }

    /// Join This Device needs a sync target the request travels through; a store vault without one (a backup or a
    /// one-time copy) cannot join (`AppModel.canJoinOpenVault`).
    private var canJoin: Bool { model.canJoinOpenVault }

    private var vaultTitle: String {
        model.vaultName ?? String(localized: "Vault", comment: "Fallback name of a vault in “Unlock Vault”")
    }

    /// Forget Key asks after the home check (re-check of #88, R1): forgetting home's key leaves only the kit.
    private func askToForget() async {
        if let id = model.vault?.vaultId {
            forgetRemoval = await KeyRemoval.check(vaultID: id, at: model.vaultURL, store: keys.store, library: nil)
        }
        confirmForget = true
    }

    private func tryDeviceKey() async {
        failure = nil
        switch await keys.unlockWithDeviceKey(model) {
        case .failed(let message): failure = message
        case .unlocked, .noKey, .cancelled, .joining, .keyProblem: break
        }
    }

    private func unlock(endingEditing: Bool = false, _ action: @escaping () async throws -> Void) {
        failure = nil
        // The key path ends editing first, as `NewVaultView.create()` does: the pasted key's multi-line field,
        // still focused when the unlock disabled the form (`model.isBusy`), resigned and became first responder
        // again in a layout loop that hung the main thread on an iPad (iOS 27; the 1.0 release sweep's launch
        // smoke tests). The passphrase path keeps the keyboard: its single-line field never looped, and after a
        // wrong passphrase the field stays in view with the keyboard up (PhoneParityUITests, in landscape too).
        if endingEditing {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        Task {
            do { try await action() } catch { failure = "\(error)" }
        }
    }
}
