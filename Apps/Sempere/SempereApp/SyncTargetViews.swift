import SempereAppCore
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
    /// iCloud (CloudKit): no account is signed in (the alert offers Settings), the suggestion for this vault, the backup sheet.
    @State private var needsSignIn = false
    @State private var suggesting = false
    @State private var settingUpBackup = false

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
                                          rechoose: { rechoosing = target; showingRechoose = true }, remove: { removing = target },
                                          remedy: { remedy($0, for: target) })
                        }
                    } footer: {
                        Text("Every target gets the same two-way sync. Adding one to a vault with notes copies what either side lacks; nothing is deleted. Removing one never deletes anything there. Backups are something else: a snapshot for recovery, in Settings ▸ Backups.")
                    }
                    if suggesting {
                        // Another device put this vault in iCloud (CloudKit): suggested once, never added by itself (design §8).
                        Section {
                            Text("This vault is in iCloud. Sync with it here too?",
                                 comment: "Sync Targets: the vault's iCloud zone exists (another device made it) and this device has no target for it")
                            Button("Sync with iCloud", systemImage: "icloud", action: addICloud)
                                .accessibilityIdentifier("syncTargetsSuggestionAccept")
                            Button("Not Now") {
                                suggesting = false
                                if let vault = model.vault?.vaultId { model.cloudKitSuggestionAnswered(for: vault) }
                            }
                            .accessibilityIdentifier("syncTargetsSuggestionDismiss")
                        }
                        .accessibilityIdentifier("syncTargetsSuggestion")
                    }
                    Section {
                        // iCloud (CloudKit) first on Apple devices, then a folder, then a server (design §9).
                        if model.services.cloudKit != nil {
                            AddTargetRow(title: "Add iCloud", systemImage: "icloud",
                                         subtitle: "Syncs this vault through your Apple Account. Apple devices only.",
                                         action: addICloud)
                                .accessibilityIdentifier("syncTargetsAddCloudKit")
                        }
                        AddTargetRow(title: "Add Folder…", systemImage: "folder.badge.plus",
                                     subtitle: "A folder in iCloud Drive, on a drive or a share.") { pickingFolder = true }
                            .accessibilityIdentifier("syncTargetsAddFolder")
                        AddTargetRow(title: "Add WebDAV Server…", systemImage: "server.rack",
                                     subtitle: "A WebDAV server, such as one you run yourself.") { addingServer = true }
                            .accessibilityIdentifier("syncTargetsAddServer")
                        if !model.syncSessions.isEmpty {
                            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                                Task { await model.syncAllTargetsNow() }
                            }
                        }
                    }
                    if onlyICloudCopy {
                        // CloudKit holds records, not files: the stock-CLI recovery path cannot read it (design §7).
                        Section {
                            Text("iCloud keeps your vault on Apple's servers. To open it without Sempere (with the recovery kit and age), keep a backup or a folder copy too.",
                                 comment: "Sync Targets: shown under a vault whose only copy besides this device is iCloud; age is the encryption tool's name")
                                .foregroundStyle(.secondary)
                            Button("Set Up Backup", systemImage: "externaldrive.badge.plus") { settingUpBackup = true }
                                .accessibilityIdentifier("syncTargetsSetUpBackup")
                        }
                        .accessibilityIdentifier("syncTargetsBackupNote")
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
            .task(id: model.openVaultTargets.map(\.id)) {
                guard let vault = model.vault?.vaultId else { return }
                suggesting = await model.cloudKitSuggestion(for: vault)
            }
            .alert("iCloud", isPresented: $needsSignIn) {
                Button("Open Settings") { ICloudSettings.open() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sign in to iCloud in Settings first.")
            }
            .sheet(isPresented: $settingUpBackup) {
                NavigationStack {
                    Form { BackupSettingsSection(restoring: .constant(false)) }
                        .navigationTitle("Backups")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingUpBackup = false } } }
                }
            }
            .sheet(isPresented: $addingServer) {
                if let vault = model.vault?.vaultId { WebDAVConnectSheet(addingTo: vault) }
            }
            // The vault is written into it: a folder picker with New Folder (`FolderPicker`).
            .folderPicker(isPresented: $pickingFolder, purpose: .syncFolder) { result in
                guard case .success(let url) = result, let vault = model.vault?.vaultId else { return }
                do { try model.addPickedFolderTarget(url, to: vault) } catch { problem = AppModel.describe(error) }
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
                    problem = AppModel.describe(error)
                }
            }
        }
        .accessibilityIdentifier("syncTargetsSheet")
    }

    /// The vault's only copy besides this device's is iCloud (CloudKit), and no backup is set (design §7).
    private var onlyICloudCopy: Bool {
        let targets = model.openVaultTargets
        return !targets.isEmpty && targets.allSatisfy { $0.kind == .cloudkit } && model.backupRecord()?.bookmark == nil
    }

    /// Add iCloud (CloudKit), or take the suggestion.
    private func addICloud() {
        guard let vault = model.vault?.vaultId else { return }
        Task {
            do {
                _ = try await model.addCloudKitTarget(to: vault)
                model.cloudKitSuggestionAnswered(for: vault)
                suggesting = false
                CloudKitLive.activate()
            } catch CloudKitTargetProblem.account(.noAccount) {
                needsSignIn = true
            } catch let e as CloudKitTargetProblem {
                problem = e.text
            } catch {
                problem = AppModel.describe(error)
            }
        }
    }

    /// The button a CloudKit problem offers (Upload Again, Use This Account: the target is made again for the account signed
    /// in now, a union that deletes nothing; Open Settings).
    private func remedy(_ remedy: CloudProblem.Remedy, for target: SyncTarget) {
        switch remedy {
        case .openSettings:
            ICloudSettings.open()
        case .uploadAgain, .useThisAccount:
            guard let vault = model.vault?.vaultId else { return }
            Task {
                do {
                    _ = try await model.restartCloudKitTarget(target.id, of: vault)
                    CloudKitLive.activate()
                } catch let e as CloudKitTargetProblem {
                    problem = e.text
                } catch {
                    problem = AppModel.describe(error)
                }
            }
        }
    }
}

/// One way to add a target: a title and a line under it saying what it is.
private struct AddTargetRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let subtitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(subtitle)
    }
}

/// Where the system's iCloud sign-in is.
enum ICloudSettings {
    static func open() {
        #if targetEnvironment(macCatalyst)
        let text = "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"
        #else
        let text = UIApplication.openSettingsURLString
        #endif
        if let url = URL(string: text) { UIApplication.shared.open(url) }
    }
}

/// One target: its kind, place and status line.
private struct SyncTargetRow: View {
    @AppModelEnvironment private var model
    let target: SyncTarget
    let session: SyncSession?
    let rechoose: () -> Void
    let remove: () -> Void
    let remedy: (CloudProblem.Remedy) -> Void
    /// The provider syncs the folder as one item, or it has whole-folder conflict versions (docs/io.md "A vault folder
    /// held as a package"): a warning, never a block.
    @State private var packageWarning: FolderTargetPackageWarning?
    @State private var showingPackageHelp = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: target.kind == .webdav ? "server.rack" : target.kind == .cloudkit ? "icloud" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                Text(verbatim: target.place)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let session {
                    // A problem stays in view while the next run goes (`settledKind`); otherwise syncing, synced, waiting.
                    Text(session.needsAttention ? session.attentionHeadline : session.headline).font(.caption)
                        .foregroundStyle(session.needsAttention ? .orange : .secondary)
                    if case .problem(.cloud(let problem)) = session.status.settledKind, let kind = problem.remedy {
                        Button(kind.title) { remedy(kind) }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("syncTargetRemedy")
                    }
                    // A folder that went away, or a saved permission that no longer opens it (review of #72, G5).
                    if target.kind == .folder, session.status.kind == .problem(.notFound) || session.status.kind == .problem(.writeGrantLapsed) {
                        Button("Choose Again…", action: rechoose)
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .help("Choose the folder of this sync target again")
                            .accessibilityIdentifier("syncTargetRechoose")
                    }
                }
                if let warning = packageWarning {
                    Label(warningText(warning), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("syncTargetPackageWarning")
                    Button("How to Fix…") { showingPackageHelp = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .help("How to move this sync folder to a plain folder")
                        .accessibilityIdentifier("syncTargetPackageHelp")
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
        // Asked again when the row shows and whenever a run starts or ends (a run may merge or clear the flag).
        .task(id: PackageCheck(target: target.id, syncing: session?.isSyncing == true)) {
            packageWarning = await model.folderTargetPackageRecord(target)
        }
        .alert("Sync Folder Kept as a Package", isPresented: $showingPackageHelp) {
            Button("OK") { showingPackageHelp = false }
        } message: {
            // No conflict versions of the folder (a new vault whose sync folder was a package from its first run): nothing
            // to merge back, so the steps start at the new folder. Unknown (nil) gives the full steps.
            let nothingToMerge = packageWarning?.record.hasUnresolvedConflicts == false
            switch (packageWarning?.isICloudDrive ?? true, nothingToMerge) {
            case (true, true):
                Text("Your notes on this device are safe: they live in the app, and this folder has no conflicting versions to merge back. To give the other devices a plain folder: 1. On one device, choose Add Folder… and pick a folder in iCloud Drive that does not hold the old one (a new folder is simplest); Sempere makes a folder for the vault in it, ending in .sempere-vault, and copies the vault into it. 2. On each other device, add the same folder, then remove the old target. 3. Once every device syncs with the new folder, move the old folder to the Trash. Renaming the old folder does not help: iCloud Drive keeps it a package.")
            case (false, true):
                Text("Your notes on this device are safe: they live in the app, and this folder has no conflicting versions to merge back. To give the other devices a plain folder: 1. On one device, choose Add Folder… and pick a folder in the same cloud storage that does not hold the old one (a new folder is simplest); Sempere makes a folder for the vault in it, ending in .sempere-vault, and copies the vault into it. 2. On each other device, add the same folder, then remove the old target. 3. Once every device syncs with the new folder, move the old folder to the Trash. Renaming the old folder does not help: the provider keeps it a package.")
            case (true, false):
                Text("Your notes on this device are safe: they live in the app. To give the other devices a plain folder: 1. Pause Sempere on every device (leave it closed) until step 3. 2. On a Mac, merge back what the conflicting versions hold with the sempere command-line tool (sempere vault conflicts --merge). 3. Open Sempere on that Mac only and let it sync once with the old folder, so the recovered files reach its copy. 4. On one device, choose Add Folder… and pick a folder in iCloud Drive that does not hold the old one (a new folder is simplest); Sempere makes a folder for the vault in it, ending in .sempere-vault, and copies the vault into it. 5. On each other device, add the same folder, then remove the old target. 6. Before moving the old folder to the Trash, check that the files the merge copied back are in the new folder, and keep the merge’s quarantine folder. Renaming the old folder does not help: iCloud Drive keeps it a package.")
            case (false, false):
                Text("Your notes on this device are safe: they live in the app. To give the other devices a plain folder: 1. Pause Sempere on every device (leave it closed) until step 3. 2. On a Mac, merge back what the conflicting versions hold with the sempere command-line tool (sempere vault conflicts --merge). 3. Open Sempere on that Mac only and let it sync once with the old folder, so the recovered files reach its copy. 4. On one device, choose Add Folder… and pick a folder in the same cloud storage that does not hold the old one (a new folder is simplest); Sempere makes a folder for the vault in it, ending in .sempere-vault, and copies the vault into it. 5. On each other device, add the same folder, then remove the old target. 6. Before moving the old folder to the Trash, check that the files the merge copied back are in the new folder, and keep the merge’s quarantine folder. Renaming the old folder does not help: the provider keeps it a package.")
            }
        }
    }

    private func warningText(_ warning: FolderTargetPackageWarning) -> String {
        guard warning.record.heldAsPackage else {
            return String(localized: "This folder has conflicting versions from other devices.")
        }
        return warning.isICloudDrive
            ? String(localized: "iCloud Drive syncs this folder as one package, so changes made on two devices at once can hide each other’s files.")
            : String(localized: "This folder’s provider syncs it as one package, so changes made on two devices at once can hide each other’s files.")
    }
}

/// When a row asks again whether its folder is held as a package.
private struct PackageCheck: Hashable {
    var target: UUID
    var syncing: Bool
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

extension CloudProblem.Remedy {
    var title: String {
        switch self {
        case .openSettings: return String(localized: "Open Settings", comment: "Sync Targets: opens the system's Settings (iCloud sign-in)")
        case .uploadAgain: return String(localized: "Upload Again", comment: "Sync Targets: make the iCloud target again; the vault is uploaded as a union")
        case .useThisAccount: return String(localized: "Use This Account", comment: "Sync Targets: sync with the Apple Account signed in now")
        }
    }
}
