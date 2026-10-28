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
    /// What deleting it does to this device's key (`KeyRemoval`: home, other local copies).
    @State private var removal = KeyRemoval()

    var body: some View {
        let vaults = library.storedVaultsByUse
        let joining = model.webdavLocations.locations.filter { l in
            !vaults.contains { $0.vaultId.uuidString.lowercased() == l.vaultId.lowercased() }
        }
        if !vaults.isEmpty || !joining.isEmpty {
            Section {
                ForEach(vaults, id: \.vaultId) { entry in
                    Button { open(entry) } label: {
                        StoredVaultRow(entry: entry, opened: recent(of: entry)?.lastOpened,
                                       status: VaultListStatus(sessions: model.syncCoordinator.sessions(of: entry.vaultId)))
                            .equatable()   // a row whose values are the same is not redrawn (it would drop its swipe)
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
                if removal.offersMakeHome {
                    Button("Open to Make Another Device Home") {
                        deleting = nil
                        open(entry)
                    }
                }
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in
                if let warning = removal.removalWarning() {
                    Text("\(warning) Its notes on this device are deleted too.",
                         comment: "Delete from This Device: the warning about this device's key, then this")
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
                removal = await KeyRemoval.check(vaultID: entry.vaultId, at: entry.url, store: keys.store,
                                                 library: library, except: entry.url)
                deleting = entry
            }
        }
    }

    private func recent(of entry: VaultStore.Entry) -> RecentVault? {
        library.recents.first { $0.storeID == entry.vaultId }
    }

    private func delete(_ entry: VaultStore.Entry) {
        deleting = nil
        Task {
            await model.report {
                try await library.removeStored(entry)
                // This device's keys for it go with it (key-hierarchy KH5): it would join again. Kept while another
                // local copy opens with them (re-check of #88).
                if removal.deletesKeys { try? await keys.store.delete(for: entry.vaultId) }
            }
        }
    }
}

/// One store vault: its name (and label, when it differs), and when it was last opened here.
private struct StoredVaultRow: View, Equatable {
    var entry: VaultStore.Entry
    /// When it was last opened here.
    var opened: Date?
    /// Its targets' standing, for the status line.
    var status: VaultListStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            if let label = entry.label, label != entry.name {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else {
                VaultListStatusLine(status: status)
                if let opened {
                    Text("Opened \(opened, format: .relative(presentation: .named))",
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
