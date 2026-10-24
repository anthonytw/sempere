import Sempere
import SwiftUI

/// The welcome list's vaults on this device: the in-app store's (docs/design/device-first-sync.md §2),
/// the most recently opened first. A tap opens one; "Delete from This Device…" removes it, after a
/// confirmation, since with no sync target the in-app copy is the only copy.
struct StoredVaultsSection: View {
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @AppModelEnvironment private var model
    var open: (VaultStore.Entry) -> Void

    @State private var deleting: VaultStore.Entry?
    /// The vault about to be deleted is one this device manages devices of, with other devices listed.
    @State private var deletingHome = false

    var body: some View {
        let vaults = library.storedVaultsByUse
        let joining = model.webdavLocations.locations.filter { l in
            !vaults.contains { $0.vaultId.uuidString.lowercased() == l.vaultId.lowercased() }
        }
        if !vaults.isEmpty || !joining.isEmpty {
            Section {
                ForEach(vaults, id: \.vaultId) { entry in
                    Button { open(entry) } label: {
                        StoredVaultRow(entry: entry, recent: recent(of: entry),
                                       sessions: model.syncCoordinator.sessions(of: entry.vaultId))
                    }
                        .help(String(localized: "Open this vault"))
                        .swipeActions { deleteButton(entry) }
                        .contextMenu { deleteButton(entry) }
                }
                JoiningWebDAVRows(locations: joining)
            } header: {
                Text("On This Device")
            }
            .alert(Text("Delete “\(deleting?.name ?? "")” from this device?", comment: "%@ is the vault's name"),
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { entry in
                if deletingHome {
                    Button("Open to Make Another Device Home") {
                        deleting = nil
                        open(entry)
                    }
                }
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in
                if deletingHome {
                    Text("This device manages the vault's devices, and its key goes with this copy: then only the recovery kit can manage them. Open the vault and make another device home first (Settings ▸ Sync & Devices ▸ Devices ▸ Make Home). Its notes on this device are deleted too.")
                } else {
                    Text("Its notes and this device's key for it are deleted from this device. Unless you have a backup or another copy, the notes cannot be recovered; to use the vault here again, this device joins it again.")
                }
            }
        }
    }

    // help-lint: titled
    private func deleteButton(_ entry: VaultStore.Entry) -> some View {
        Button(String(localized: "Delete from This Device…", comment: "Removes a vault from the in-app store"),
               systemImage: "trash", role: .destructive) {
            Task {
                deletingHome = await Self.isHomeWithOthers(vaultID: entry.vaultId, at: entry.url, store: keys.store)
                deleting = entry
            }
        }
    }

    /// Whether this device manages the devices of the vault at `entry` and other devices are listed (review of #88,
    /// M4: deleting the copy deletes home's keys). Read without the key: the list's home and the fingerprint kept
    /// with this device's signing item.
    static func isHomeWithOthers(vaultID: UUID, at url: URL, store: any DeviceKeyStore) async -> Bool {
        guard let mine = await store.fingerprint(for: vaultID) else { return false }
        return await Task.detached(priority: .userInitiated) {
            guard let m = try? Vault.open(at: url).manifest else { return false }
            return m.home == mine && m.devices.count > 1
        }.value
    }

    private func recent(of entry: VaultStore.Entry) -> RecentVault? {
        library.recents.first { $0.storeID == entry.vaultId }
    }

    private func delete(_ entry: VaultStore.Entry) {
        deleting = nil
        Task {
            await model.report {
                try await library.removeStored(entry)
                // This device's keys for it go with it (key-hierarchy KH5): it would join again.
                try? await keys.store.delete(for: entry.vaultId)
            }
        }
    }
}

/// One store vault: its name (and label, when it differs), and when it was last opened here.
private struct StoredVaultRow: View {
    var entry: VaultStore.Entry
    var recent: RecentVault?
    /// Its targets' sessions, for the status line.
    var sessions: [SyncSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            if let label = entry.label, label != entry.name {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else {
                VaultListStatusLine(sessions: sessions)
                if let recent {
                    Text("Opened \(recent.lastOpened, format: .relative(presentation: .named))",
                         comment: "Welcome list: when the vault was last opened on this device")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storeVault-\(entry.name)")
    }
}

/// "Open Vault…" copying a vault onto this device (`AppModel.vaultCopy`).
struct VaultCopyOverlay: View {
    let progress: VaultCopyProgress

    var body: some View {
        VStack(spacing: 12) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: 240)
            } else {
                ProgressView()
            }
            Text(progress.text)
                .font(.callout)
                .monospacedDigit()
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vaultCopyProgress")
    }
}
