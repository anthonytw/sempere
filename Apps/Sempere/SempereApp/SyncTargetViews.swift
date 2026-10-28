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
    /// The folder target whose folder is being chosen again ("Choose Again…"). Kept apart from `showingRechoose`: the
    /// Mac's panel sets its binding to false BEFORE it delivers the pick (`FolderPicker`).
    @State private var rechoosing: SyncTarget?
    @State private var showingRechoose = false
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
                            Text("This vault is only on this device. Add a folder, for example in iCloud Drive, or a WebDAV server: your other devices open it to join, and every change syncs both ways.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.openVaultTargets) { target in
                            SyncTargetRow(target: target, session: model.syncSessions.first { $0.locationID == target.id },
                                          rechoose: { rechoosing = target; showingRechoose = true }, remove: { removing = target })
                        }
                    } footer: {
                        Text("Every target gets the same two-way sync. Adding one to a vault with notes copies what either side lacks; nothing is deleted. Removing one never deletes anything there. Backups are something else: a snapshot for recovery, in Settings ▸ Backups.")
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
            // The vault is written into it: a folder picker with New Folder (`FolderPicker`).
            .folderPicker(isPresented: $pickingFolder, purpose: .syncFolder) { result in
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
            Color.clear.folderPicker(isPresented: $showingRechoose, purpose: .syncFolder) { result in
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
    /// A held target's folders: the one build 10 synced bare (`junk`) and the copy's own name (`Wompa.sempere`).
    static func oldFolderName(_ target: SyncTarget) -> String {
        target.bookmarkedPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    }

    static func newFolderName(_ target: SyncTarget) -> String {
        target.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? target.name
    }

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
                if FolderTargetAccess.isMisrecorded(target) {
                    // Set up wrong by build 10 (its copy went into the picked folder itself): held, never synced.
                    Text("Set up wrong by an earlier build. Remove it and add the folder again.")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("syncTargetMisrecorded")
                    Text("The vault's files left directly in “\(Self.oldFolderName(target))” are a copy an earlier build made there. Delete them once every device syncs the new “\(Self.newFolderName(target))”.",
                         comment: "Held sync target; first %@ is the old folder's name (junk), the second the vault's folder name (Wompa.sempere)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose Again…", action: rechoose)
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .help("Choose the folder of this sync target again")
                        .accessibilityIdentifier("syncTargetRechoose")
                } else if let session {
                    Text(session.headline).font(.caption)
                        .foregroundStyle(session.needsAttention ? .orange : .secondary)
                    // A folder that went away, or a saved permission that no longer opens it (review of #72, G5).
                    if target.kind == .folder, session.status.kind == .problem(.notFound) || session.status.kind == .problem(.writeGrantLapsed) {
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
    /// A backup is copied in once: no "Keep syncing" (a sync would write into the backup).
    private let isBackup: Bool
    /// This account may write to the folder: else no "Keep syncing" (build 12: every run failed with "errno 13").
    private let writable: Bool
    /// The vault is on this device already: Copy opens that copy, nothing is copied (`copyIn`, `openExistingCopy`).
    @State private var alreadyHere = false

    init(picked: PickedVault) {
        self.picked = picked
        isBackup = CopyInFollowUp.isBackup(picked.url)
        writable = CopyInFollowUp.isWritable(picked.url)
        _keepSyncing = State(initialValue: CopyInFollowUp.suggested(for: picked.url) == .keepSyncing)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if alreadyHere {
                        Text("“\(picked.url.deletingPathExtension().lastPathComponent)” is already on this device: Sempere opens that copy, and nothing is copied from the folder.",
                             comment: "Open Vault: the picked vault is already on the device; %@ is the picked folder's name")
                    } else {
                        Text("Sempere will copy “\(picked.url.deletingPathExtension().lastPathComponent)” onto this device. You always work on that copy, online or not.",
                             comment: "%@ is the picked folder's name")
                    }
                    if !isBackup, writable {
                        Toggle("Keep syncing with this folder", isOn: $keepSyncing)
                            .accessibilityIdentifier("openVaultKeepSyncing")
                    }
                } footer: {
                    if isBackup, alreadyHere {
                        Text("This is a backup of a vault already on this device. To get the backup's notes back as a separate vault, use Settings ▸ Backups ▸ Restore from Backup… instead.")
                    } else if !isBackup, !writable {
                        Text("This account cannot write to this folder (it belongs to another user, or is read-only), so the vault is copied onto this device once and the folder is never written.")
                    } else if isBackup {
                        Text("This is a backup, a snapshot of the vault: it is copied onto this device once, as a vault of its own, and Sempere never syncs with it, so the backup stays as it was. A backup cannot join your other devices: for that, open the vault's sync folder instead (the .sempere folder they sync with) and choose Join This Device there.")
                    } else {
                        Text(keepSyncing
                             ? "Changes go both ways between the copy and the folder, so other devices that use the folder stay current."
                             : "A one-time copy: the folder is never written, and the copy on this device is the only one.")
                    }
                }
            }
            .navigationTitle(isBackup ? String(localized: "Open Vault Backup", comment: "Title of the Open Vault sheet for a backup")
                                      : String(localized: "Open Vault", comment: "Title of the Open Vault sheet"))
            .task {
                let url = picked.url, store = library.vaultStore
                alreadyHere = await Task.detached(priority: .userInitiated) { CopyInFollowUp.isOnDevice(url, store: store) }.value
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(alreadyHere ? String(localized: "Open", comment: "Open Vault sheet: the vault is on the device already")
                                       : String(localized: "Copy", comment: "Open Vault sheet: copy the vault onto the device")) {
                        let url = picked.url, followUp: CopyInFollowUp = keepSyncing && writable ? .keepSyncing : .importOnly
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
