import Sempere
import SempereSync
import SwiftUI
import UniformTypeIdentifiers

/// Vault Details (docs/design/device-first-sync.md §8.3, §8.4; P9): the copy on this device and, per target,
/// its last sync, the devices it held then, what is staged for the unlock and what is quarantined (Repair).
/// From this device only, like `sempere store info`. Reached from Sync Targets… and Settings ▸ Storage.
struct VaultDetailsView: View {
    @AppModelEnvironment private var model
    let vaultID: UUID
    @State private var details: VaultDetailsSnapshot?
    @State private var failure: String?
    @State private var generation = 0

    var body: some View {
        Form {
            if let details {
                Section {
                    LabeledContent("Notes", value: StorageText.bytes(details.storage.notes))
                    LabeledContent("Attachments", value: StorageText.bytes(details.storage.attachments))
                    LabeledContent("Other Files", value: StorageText.bytes(details.storage.other))
                    LabeledContent("Total", value: StorageText.bytes(details.storage.total))
                } header: {
                    Text("On This Device")
                } footer: {
                    Text("The vault's copy inside the app, which you work on, online or not.")
                }
                if details.targets.isEmpty {
                    Section {
                        Text("No sync targets: this device holds the only copy.").foregroundStyle(.secondary)
                    }
                }
                ForEach(details.targets) { target in
                    TargetDetailsSection(details: target, vaultID: vaultID) { generation += 1 }
                }
            } else if let failure {
                Text(failure).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Vault Details")
        .accessibilityIdentifier("vaultDetails")
        .task(id: generation) {
            do { details = try await model.vaultDetails(vaultID, measureFolders: true) } catch {
                failure = String(describing: error)
            }
        }
    }
}

/// One target in Vault Details.
private struct TargetDetailsSection: View {
    let details: TargetDetails
    let vaultID: UUID
    let changed: () -> Void

    var body: some View {
        let target = details.target
        Section {
            LabeledContent("Place") {
                Text(verbatim: target.kind == .webdav ? (target.url ?? "") : (target.path ?? ""))
                    .lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Last Sync") {
                if let last = target.lastSuccess {
                    Text(last, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }
            LabeledContent("Files in Step", value: "\(details.syncedFiles)")
            if details.staged > 0 {
                LabeledContent("Waiting for Unlock", value: String(localized: "\(details.staged) files", comment: "Files staged by a locked sync"))
            }
            LabeledContent("Sync State", value: StorageText.bytes(details.stateBytes))
            if let bytes = details.folderBytes {
                LabeledContent("Folder Copy", value: StorageText.bytes(bytes))
            }
            NavigationLink {
                RepairView(vaultID: vaultID, targetID: target.id, targetName: target.name, changed: changed)
            } label: {
                LabeledContent("Quarantined Files", value: "\(details.quarantined.count)")
            }
            .accessibilityIdentifier("vaultDetailsRepair")
            if details.devices.isEmpty {
                Text("No devices known yet: this target has not synced.").foregroundStyle(.secondary)
            }
            ForEach(details.devices, id: \.device) { device in
                DeviceOnTargetRow(device: device)
            }
        } header: {
            Text(verbatim: target.name)
        } footer: {
            Text("Devices whose notes or summaries this target held at this device's last sync with it. A device of the vault missing here never syncs with this target: add a target they share.")
        }
    }
}

/// A device as one target held it.
private struct DeviceOnTargetRow: View {
    let device: TargetDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: device.isThisDevice ? "ipad.and.iphone" : "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: device.device).font(.body.monospaced())
                if device.isThisDevice { Text("This Device").font(.caption).foregroundStyle(.secondary) }
            }
            Group {
                if let newest = device.newest {
                    Text("\(device.revisions) changes, the latest \(newest, format: .relative(presentation: .named))",
                         comment: "A device on a sync target: its revisions there and when it wrote the newest")
                } else {
                    Text("Publishes its note summaries here; no changes of it synced yet")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Repair… (design §8.4): a target's quarantined files, each with Adopt (checked again under the vault's
/// keys, placed only if it passes), Export… (a copy elsewhere) and Delete. Nothing else ever removes one.
struct RepairView: View {
    @AppModelEnvironment private var model
    let vaultID: UUID
    let targetID: UUID
    let targetName: String
    let changed: () -> Void

    @State private var files: [QuarantinedFile] = []
    @State private var exporting: QuarantinedFile?
    @State private var deleting: QuarantinedFile?
    @State private var message: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                if files.isEmpty {
                    Text("Nothing is quarantined.").foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    QuarantinedFileRow(file: file, working: working,
                                       adopt: { act { try await model.adoptQuarantined(file.path, target: targetID, of: vaultID) } },
                                       export: { exporting = file },
                                       delete: { deleting = file })
                }
            } footer: {
                Text("A sync never places a file that fails its checks: it keeps it here and never deletes it. Adopt checks it again under the vault's keys and places it only if it passes (a file from before a key change, say). Export copies it elsewhere; Delete removes it for good.")
            }
        }
        .navigationTitle(Text("Repair: \(targetName)", comment: "Repair view title; %@ is the sync target's name"))
        .accessibilityIdentifier("repairView")
        .task { load() }
        .fileImporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result, let file = exporting else { return }
            exporting = nil
            act { _ = try await model.exportQuarantined(file.path, target: targetID, of: vaultID, to: folder) }
        }
        .confirmationDialog("Delete this quarantined file?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { file in
            Button("Delete", role: .destructive) {
                act { try await model.deleteQuarantined(file.path, target: targetID, of: vaultID) }
            }
        } message: { _ in
            Text("It is gone for good. Export it first to keep a copy.")
        }
        .alert("Repair", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func load() {
        files = model.syncStore.quarantine(targetID, of: vaultID).list()
    }

    private func act(_ body: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false; load(); changed() }
            do { try await body() } catch { message = String(describing: error) }
        }
    }
}

/// One quarantined file: where it belongs, its size and age, and its actions.
private struct QuarantinedFileRow: View {
    let file: QuarantinedFile
    let working: Bool
    let adopt: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.vaultPath).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(StorageText.bytes(file.size))
                    if let when = file.quarantined { Text(when, format: .relative(presentation: .named)) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(working)
            .help("Adopt, export or delete this file")
            .accessibilityIdentifier("quarantinedFileMenu")
        }
        .contextMenu { actions }
    }

    // help-lint: titled
    @ViewBuilder private var actions: some View {
        if file.adoptable {
            Button("Adopt", systemImage: "checkmark.shield", action: adopt)
        }
        Button("Export…", systemImage: "square.and.arrow.up", action: export)
        Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
    }
}

/// The welcome list's line for a store vault: how its targets stand (`SyncSession`), or that it has none.
struct VaultListStatusLine: View {
    let sessions: [SyncSession]

    var body: some View {
        if sessions.isEmpty {
            Text("Only on this device").font(.caption).foregroundStyle(.secondary)
        } else if let troubled = sessions.first(where: \.needsAttention) {
            Label(troubled.headline, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if sessions.contains(where: \.isSyncing) {
            Text("Syncing…").font(.caption).foregroundStyle(.secondary)
        } else if let last = sessions.compactMap(\.lastSuccess).max() {
            Text("Synced with \(Self.names(sessions)) \(last, format: .relative(presentation: .named))",
                 comment: "Welcome list: %1$@ is the sync targets' names, then when the last sync ended")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("Not synced yet with \(Self.names(sessions))", comment: "%@ is the sync targets' names")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    static func names(_ sessions: [SyncSession]) -> String {
        ListFormatter.localizedString(byJoining: sessions.map(\.targetName))
    }
}
