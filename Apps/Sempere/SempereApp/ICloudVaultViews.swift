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
    /// The row whose Delete from iCloud is being confirmed.
    @State private var deleting: CloudVaultListing?
    @State private var deleteFailure: String?

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
                                    Text(detail(vault)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!vault.hasVault)
                            // Delete from iCloud: for any listed vault, including one no device here has (a vault another
                            // device removed, a half-made one); the confirmation says what is left.
                            .swipeActions(edge: .trailing) {
                                Button("Delete…", role: .destructive) { deleting = vault }
                                    .accessibilityIdentifier("openFromICloudDelete-\(vault.vaultId)")
                            }
                            .contextMenu {
                                Button("Delete from iCloud…", role: .destructive) { deleting = vault }
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
            .confirmationDialog(deleting.map { Text("Delete “\($0.name)” from iCloud?", comment: "Open from iCloud: asks before deleting a vault's iCloud data; %@ is its name") } ?? Text(verbatim: ""),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { vault in
                Button("Delete from iCloud", role: .destructive) { delete(vault) }
                    .accessibilityIdentifier("openFromICloudConfirmDelete")
            } message: { vault in
                Text(deletionWarning(vault))
            }
            .alert("Open from iCloud", isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })) {
                Button("OK") { deleteFailure = nil }
            } message: {
                Text(deleteFailure ?? "")
            }
        }
        .accessibilityIdentifier("openFromICloudSheet")
    }

    private func onDevice(_ vault: CloudVaultListing) -> Bool {
        UUID(uuidString: vault.vaultId).flatMap { library.vaultStore.entry(id: $0) } != nil
    }

    /// The row's second line: whether it is here, and when the vault last changed in iCloud (what tells two vaults apart).
    private func detail(_ vault: CloudVaultListing) -> String {
        guard vault.hasVault else {
            return String(localized: "Nothing to open: this iCloud space holds no vault. Delete it to clear it away.",
                          comment: "Open from iCloud: a row whose zone has no readable vault in it")
        }
        let here = onDevice(vault) ? String(localized: "On this device") : String(localized: "Not on this device yet")
        guard let modified = vault.modified else { return here }
        let when = modified.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "\(here) · changed \(when)", comment: "Open from iCloud: %1$@ is whether it is on this device, %2$@ when it last changed")
    }

    /// What the confirmation says deleting leaves: the three cases of `ICloudDeletionImpact`.
    private func deletionWarning(_ vault: CloudVaultListing) -> String {
        let impact = model.iCloudDeletionImpact(vault.vaultId, library: library)
        let base = String(localized: "This deletes the vault and every note in it from your iCloud. Other devices that sync it with iCloud stop syncing.",
                          comment: "Open from iCloud: delete confirmation")
        if !vault.hasVault { return base }
        if impact.onlyICloud {
            return base + " " + String(localized: "No copy of this vault is on this device, and it has no other sync target here. If no other device holds it, it is gone for good.",
                                       comment: "Open from iCloud: delete confirmation when iCloud holds the only copy this device knows of")
        }
        return base + " " + String(localized: "The copy on this device stays.", comment: "Open from iCloud: delete confirmation when a copy is on this device")
    }

    private func delete(_ vault: CloudVaultListing) {
        Task {
            do {
                try await model.deleteICloudVault(vault.vaultId, library: library, acknowledgingNoOtherCopy: true)
                await load()
            } catch {
                deleteFailure = AppModel.describe(error)
            }
        }
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
