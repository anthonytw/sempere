import SwiftUI
import UniformTypeIdentifiers
import Sempere
import SempereSync

/// Sync Targets… (docs/design/device-first-sync.md §8.1): the open vault's targets with their status,
/// "Add Folder…" (iCloud Drive, another provider, any folder), Sync Now and Remove (which never deletes
/// anything at the target). WebDAV targets come from connecting to a server.
struct SyncTargetsSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFolder = false
    @State private var addingServer = false
    @State private var removing: SyncTarget?
    /// The folder target whose folder is being chosen again ("Choose Again…").
    @State private var rechoosing: SyncTarget?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if !model.openVaultIsStored {
                    Section {
                        Text("Only a vault kept on this device can have sync targets.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if model.openVaultTargets.isEmpty {
                            Text("This vault is only on this device. Add a folder, for example in iCloud Drive, to keep a copy there and sync it with your other devices.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.openVaultTargets) { target in
                            SyncTargetRow(target: target, session: model.syncSessions.first { $0.locationID == target.id },
                                          rechoose: { rechoosing = target }, remove: { removing = target })
                        }
                    } footer: {
                        Text("Every target gets the same two-way sync. Adding one to a vault with notes copies what either side lacks; nothing is deleted. Removing one never deletes anything there.")
                    }
                    Section {
                        Button("Add Folder…", systemImage: "folder.badge.plus") { pickingFolder = true }
                            .accessibilityIdentifier("syncTargetsAddFolder")
                        Button("Add WebDAV Server…", systemImage: "server.rack") { addingServer = true }
                            .accessibilityIdentifier("syncTargetsAddServer")
                        if !model.syncSessions.isEmpty {
                            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                                Task { await model.syncAllTargetsNow() }
                            }
                        }
                    }
                    if let vault = model.vault?.vaultId {
                        Section {
                            NavigationLink {
                                VaultDetailsView(vaultID: vault)
                            } label: {
                                Label("Details and Repair", systemImage: "info.circle")
                            }
                            .accessibilityIdentifier("syncTargetsDetails")
                        } footer: {
                            Text("Storage on this device, the devices each target holds, and files a sync refused.")
                        }
                    }
                }
            }
            .navigationTitle("Sync Targets")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("syncTargetsDone")
                }
            }
            .sheet(isPresented: $addingServer) {
                if let vault = model.vault?.vaultId { WebDAVConnectSheet(addingTo: vault) }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result, let vault = model.vault?.vaultId else { return }
                do { try model.addPickedFolderTarget(url, to: vault) } catch { problem = String(describing: error) }
            }
            .confirmationDialog("Remove this sync target?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { target in
                Button("Remove", role: .destructive) {
                    guard let vault = model.vault?.vaultId else { return }
                    Task { await model.report { try await model.removeSyncTarget(target.id, of: vault) } }
                }
            } message: { _ in
                Text("Nothing in the folder or on the server is deleted. This device stops syncing with it.")
            }
            .alert("Sync Targets", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") { problem = nil }
            } message: {
                Text(problem ?? "")
            }
        }
        // Its own view: a second picker on the form would take the first one's place.
        .background {
            Color.clear.fileImporter(isPresented: Binding(get: { rechoosing != nil }, set: { if !$0 { rechoosing = nil } }),
                                     allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result, let target = rechoosing, let vault = model.vault?.vaultId else { return }
                rechoosing = nil
                do { try model.rechooseFolderTarget(target.id, of: vault, picked: url) } catch {
                    problem = String(describing: error)
                }
            }
        }
        .accessibilityIdentifier("syncTargetsSheet")
    }
}

/// One target: its kind, place and status line.
private struct SyncTargetRow: View {
    let target: SyncTarget
    let session: SyncSession?
    let rechoose: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: target.kind == .webdav ? "server.rack" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                Text(target.kind == .webdav ? (target.url ?? "") : (target.path ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let session {
                    Text(session.headline).font(.caption)
                        .foregroundStyle(session.needsAttention ? .orange : .secondary)
                    // A folder that went away, or a saved permission that no longer opens it (review of #72, G5).
                    if target.kind == .folder, session.status.kind == .problem(.notFound) {
                        Button("Choose Again…", action: rechoose)
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .help("Choose the folder of this sync target again")
                            .accessibilityIdentifier("syncTargetRechoose")
                    }
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this sync target")
            .accessibilityIdentifier("syncTargetRemove")
        }
    }
}

/// A vault folder picked with "Open Vault…", waiting for the user's choice (`OpenVaultSheet`).
struct PickedVault: Identifiable {
    let id = UUID()
    let url: URL
}

/// "Open Vault…" after the pick (docs/design/device-first-sync.md §8.1): Sempere copies the vault onto
/// this device, and "Keep syncing with this folder" makes the folder a sync target of the copy (on by
/// default for iCloud Drive and other providers' folders, off for a local folder such as an export).
struct OpenVaultSheet: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Environment(\.dismiss) private var dismiss
    let picked: PickedVault
    @State private var keepSyncing: Bool

    init(picked: PickedVault) {
        self.picked = picked
        _keepSyncing = State(initialValue: CopyInFollowUp.suggested(for: picked.url) == .keepSyncing)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sempere will copy “\(picked.url.deletingPathExtension().lastPathComponent)” onto this device. You always work on that copy, online or not.",
                         comment: "%@ is the picked folder's name")
                    Toggle("Keep syncing with this folder", isOn: $keepSyncing)
                        .accessibilityIdentifier("openVaultKeepSyncing")
                } footer: {
                    Text(keepSyncing
                         ? "Changes go both ways between the copy and the folder, so other devices that use the folder stay current."
                         : "A one-time copy: the folder is never written, and the copy on this device is the only one.")
                }
            }
            .navigationTitle("Open Vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        let url = picked.url, followUp: CopyInFollowUp = keepSyncing ? .keepSyncing : .importOnly
                        dismiss()
                        Task { await model.report { try await model.copyIn(picked: url, library: library, followUp: followUp) } }
                    }
                    .help("Copy the vault onto this device")
                    .accessibilityIdentifier("openVaultCopy")
                }
            }
        }
        .accessibilityIdentifier("openVaultSheet")
    }
}
