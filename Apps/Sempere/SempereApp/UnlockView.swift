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
                    Button("Forget This Device's Key…", systemImage: "trash", role: .destructive) { confirmForget = true }
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
            } else {
                Section {
                    Button("Join This Device…", systemImage: "person.badge.plus") { joining = true }
                        .accessibilityIdentifier("unlock.join")
                    Button("Take Over with Recovery Kit…", systemImage: "key.viewfinder") { takingOver = true }
                        .accessibilityIdentifier("unlock.takeover")
                } footer: {
                    Text("To write from this device, it joins the vault: the device that manages devices approves it with six words. If that device is lost, take over with the recovery kit.")
                }
            }
            Section {
                TextField("AGE-SECRET-KEY-PQ-1…", text: $identityText, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
                    .accessibilityIdentifier("unlock.keyText")
                Button("Unlock with Key") { unlock { try await keys.unlock(model, identityText: identityText) } }
                    .disabled(identityText.isEmpty)
                    .accessibilityIdentifier("unlock.withKey")
            } header: {
                Text("Or read with the recovery key")
            } footer: {
                Text("The recovery key opens the vault read-only. A device key file made with sempere opens it to write.")
            }
            Section {
                SecureField("Passphrase", text: $passphrase)
                    .onSubmit { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                Button("Unlock") { unlock { try await keys.unlock(model, passphrase: passphrase) } }
                    .disabled(passphrase.isEmpty)
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
            Text("This device then joins the vault again (approved by the device that manages devices), or takes over with the recovery kit. Its notes stay in the vault.")
        }
        .task(id: model.vault?.vaultId) {
            await keys.refresh(model)
            await tryDeviceKey()
        }
    }

    private var vaultTitle: String {
        model.vaultName ?? String(localized: "Vault", comment: "Fallback name of a vault in “Unlock Vault”")
    }

    private func tryDeviceKey() async {
        failure = nil
        switch await keys.unlockWithDeviceKey(model) {
        case .failed(let message): failure = message
        case .unlocked, .noKey, .cancelled, .joining, .keyProblem: break
        }
    }

    private func unlock(_ action: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do { try await action() } catch { failure = "\(error)" }
        }
    }
}
