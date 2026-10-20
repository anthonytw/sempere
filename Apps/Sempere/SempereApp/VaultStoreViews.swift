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

    var body: some View {
        let vaults = library.storedVaultsByUse
        if !vaults.isEmpty {
            Section {
                ForEach(vaults, id: \.vaultId) { entry in
                    Button { open(entry) } label: { StoredVaultRow(entry: entry, recent: recent(of: entry)) }
                        .help(String(localized: "Open this vault"))
                        .swipeActions { deleteButton(entry) }
                        .contextMenu { deleteButton(entry) }
                }
            } header: {
                Text("On This Device")
            }
            .alert(Text("Delete “\(deleting?.name ?? "")” from this device?", comment: "%@ is the vault's name"),
                   isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { entry in
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in
                Text("Its notes are deleted from this device. Unless you have a backup or another copy, they cannot be recovered.")
            }
        }
    }

    // help-lint: titled
    private func deleteButton(_ entry: VaultStore.Entry) -> some View {
        Button(String(localized: "Delete from This Device…", comment: "Removes a vault from the in-app store"),
               systemImage: "trash", role: .destructive) { deleting = entry }
    }

    private func recent(of entry: VaultStore.Entry) -> RecentVault? {
        library.recents.first { $0.storeID == entry.vaultId }
    }

    private func delete(_ entry: VaultStore.Entry) {
        deleting = nil
        Task {
            await model.report {
                try await library.removeStored(entry)
                keys.locations.unbind(entry.vaultId, from: entry.url)
            }
        }
    }
}

/// One store vault: its name (and label, when it differs), and when it was last opened here.
private struct StoredVaultRow: View {
    var entry: VaultStore.Entry
    var recent: RecentVault?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            if let label = entry.label, label != entry.name {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if let recent {
                Text(recent.lastOpened, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
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
