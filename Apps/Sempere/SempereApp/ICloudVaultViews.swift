import Sempere
import SempereAppCore
import SempereSync
import SwiftUI

/// Open from iCloud… (docs/design/1.4-cloudkit.md §8, §9): the vaults the signed-in Apple Account's iCloud (CloudKit) holds, by
/// name. Choosing one copies it onto this device (`AppModel.openCloudKitVault`) and keeps it syncing with iCloud; the vault
/// opens locked, and Join This Device (the words or the code) takes it from there. The CLI's `sempere cloudkit list` and `open`.
struct OpenFromICloudSheet: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case found([CloudVaultListing])
        case failed(String, signIn: Bool)
    }

    @State private var phase = Phase.loading

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .loading:
                    Section { ProgressView().accessibilityIdentifier("openFromICloudLoading") }
                case .found(let vaults):
                    Section {
                        if vaults.isEmpty {
                            Text("No vaults were found in this Apple Account's iCloud. A vault appears here once a device with Sempere has added iCloud (CloudKit) to it in Sync Targets.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("openFromICloudEmpty")
                        }
                        ForEach(vaults) { vault in
                            Button { open(vault) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: vault.name)
                                    Text(onDevice(vault) ? "On this device" : "Not on this device yet")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("openFromICloud-\(vault.vaultId)")
                        }
                    } footer: {
                        Text("These are the vaults of the Apple Account signed in on this device. Sempere copies the one you choose onto this device and keeps it syncing with iCloud; to read it, join this device with its words or code.")
                    }
                case .failed(let message, let signIn):
                    Section {
                        Text(verbatim: message).foregroundStyle(.secondary)
                            .accessibilityIdentifier("openFromICloudProblem")
                        if signIn { Button("Open Settings") { ICloudSettings.open() } }
                        Button("Try Again") { Task { await load() } }
                    }
                }
            }
            .navigationTitle(Text("Open from iCloud", comment: "Title of the sheet listing the vaults in the user's iCloud"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("openFromICloudCancel") }
            }
            .task { await load() }
        }
        .accessibilityIdentifier("openFromICloudSheet")
    }

    private func onDevice(_ vault: CloudVaultListing) -> Bool {
        UUID(uuidString: vault.vaultId).flatMap { library.vaultStore.entry(id: $0) } != nil
    }

    private func load() async {
        phase = .loading
        do {
            phase = .found(try await model.cloudKitVaults())
        } catch let e as CloudKitTargetProblem {
            if case .account(.noAccount) = e { phase = .failed(e.text, signIn: true) } else { phase = .failed(e.text, signIn: false) }
        } catch {
            phase = .failed(AppModel.describe(error), signIn: false)
        }
    }

    private func open(_ vault: CloudVaultListing) {
        dismiss()
        Task {
            await model.report {
                try await model.openCloudKitVault(vault.vaultId, library: library)
                CloudKitLive.activate()
            }
        }
    }
}
