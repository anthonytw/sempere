import Sempere
import SempereAppCore
import SwiftUI

/// The welcome list's vaults on this device: the in-app store's (docs/design/device-first-sync.md §2),
/// the most recently opened first. A tap opens one; "Delete from This Device…" removes it, after a
/// confirmation, since with no sync target the in-app copy is the only copy.
///
/// Nothing here may change while the device is idle, or a revealed swipe button and the confirmation close by
/// themselves (owner, TestFlight 1.3.0 build 111: "you have to swipe or click the button multiple times and be
/// quick"). Every vault's targets sync while it is closed, and each run changes its status: the status line observes
/// its sessions itself (`StoredVaultStatus`), so a run redraws that line only, never the section or the row. The
/// confirmations are the welcome list's (`WelcomeRemovalDialogs`), never a row's or this section's: SwiftUI took an
/// alert hanging off the section for a new one whenever the list re-hosted the section's cells (the swipe closing
/// after its button was tapped, a row redrawn by a run) and dismissed it (`UIKitDialogBridge.updateExistingAlert`).
struct StoredVaultsSection: View {
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @AppModelEnvironment private var model
    var open: (VaultStore.Entry) -> Void
    /// The welcome list's confirmations; this section only asks for one.
    let removals: WelcomeRemovals

    var body: some View {
        let vaults = library.storedVaultsByUse
        let joining = model.webdavLocations.locations.filter { l in
            !vaults.contains { $0.vaultId.uuidString.lowercased() == l.vaultId.lowercased() }
        }
        if !vaults.isEmpty || !joining.isEmpty {
            Section {
                ForEach(vaults, id: \.vaultId) { entry in
                    Button { open(entry) } label: {
                        StoredVaultRow(entry: entry, opened: recent(of: entry)?.lastOpened)
                            .equatable()   // a row whose values are the same is not redrawn (it would drop its swipe)
                    }
                        .help(String(localized: "Open this vault"))
                        .swipeActions { deleteButton(entry) }
                        .contextMenu { deleteButton(entry) }
                }
                JoiningWebDAVRows(locations: joining, removals: removals)
            } header: {
                Text("On This Device")
            }
        }
    }

    // help-lint: titled
    private func deleteButton(_ entry: VaultStore.Entry) -> some View {
        Button(String(localized: "Delete from This Device…", comment: "Removes a vault from the in-app store"),
               systemImage: "trash", role: .destructive) {
            let store = keys.store
            Task {
                let removal = await KeyRemoval.check(vaultID: entry.vaultId, at: entry.url, store: store)
                removals.askToDelete(entry, removal: removal)
            }
        }
    }

    private func recent(of entry: VaultStore.Entry) -> RecentVault? {
        library.recents.first { $0.storeID == entry.vaultId }
    }
}

/// The removal the welcome list is asking about, if any: a store vault's Delete from This Device… or a joining WebDAV
/// vault's Remove. `WelcomeView` holds it and `WelcomeRemovalDialogs` shows it on the list, so nothing the rows do (a
/// sync run redrawing one, a swipe closing) closes the question.
@MainActor
@Observable
final class WelcomeRemovals {
    /// The store vault to delete, and what that does to this device's key.
    private(set) var vault: VaultStore.Entry?
    private(set) var vaultRemoval = KeyRemoval()
    /// The joining WebDAV vault to remove, its changes the server has not confirmed, and the key check.
    private(set) var webdav: WebDAVLocation?
    private(set) var webdavUnconfirmed = 0
    private(set) var webdavRemoval = KeyRemoval()

    func askToDelete(_ entry: VaultStore.Entry, removal: KeyRemoval) {
        vaultRemoval = removal
        vault = entry
    }

    func askToRemove(_ location: WebDAVLocation, unconfirmed: Int, removal: KeyRemoval) {
        webdavUnconfirmed = unconfirmed
        webdavRemoval = removal
        webdav = location
    }

    func doneWithVault() { vault = nil }
    func doneWithWebDAV() { webdav = nil }
}

/// The welcome list's two removal confirmations (`WelcomeRemovals`), on the list itself.
struct WelcomeRemovalDialogs: ViewModifier {
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @AppModelEnvironment private var model
    let removals: WelcomeRemovals
    var open: (VaultStore.Entry) -> Void

    func body(content: Content) -> some View {
        content
            .alert(Text("Delete “\(removals.vault?.name ?? "")” from this device?", comment: "%@ is the vault's name"),
                   isPresented: Binding(get: { removals.vault != nil }, set: { if !$0 { removals.doneWithVault() } }),
                   presenting: removals.vault) { entry in
                if removals.vaultRemoval.offersMakeHome {
                    Button("Open to Make Another Device Home") {
                        removals.doneWithVault()
                        open(entry)
                    }
                }
                Button("Delete", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) { removals.doneWithVault() }
            } message: { _ in
                if let warning = removals.vaultRemoval.removalWarning() {
                    Text("\(warning) Its notes on this device are deleted too.",
                         comment: "Delete from This Device: the warning about this device's key, then this")
                } else {
                    Text("Its notes and this device's key for it are deleted from this device. Unless you have a backup or another copy, the notes cannot be recovered; to use the vault here again, this device joins it again.")
                }
            }
            .confirmationDialog("Remove this vault from this device?",
                                isPresented: Binding(get: { removals.webdav != nil }, set: { if !$0 { removals.doneWithWebDAV() } }),
                                titleVisibility: .visible, presenting: removals.webdav) { removed in
                Button("Remove", role: .destructive) { remove(removed) }
                if removals.webdavRemoval.offersMakeHome {
                    Button("Open to Make Another Device Home") {
                        removals.doneWithWebDAV()
                        Task { await model.report { try await model.openWebDAV(removed.id, library: library) } }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                if removals.webdavUnconfirmed > 0 {
                    let fileCount = removals.webdavUnconfirmed
                    Text("\(fileCount) changes on this device have not reached the server and will be lost. Open the vault and sync first to keep them.")
                } else if let warning = removals.webdavRemoval.removalWarning() {
                    Text("\(warning) The vault on the server is not changed.",
                         comment: "Remove a WebDAV vault from this device: the warning about this device's key, then this")
                } else {
                    Text("The copy on this device, this device's key for it and the saved password are deleted. The vault on the server is not changed.")
                }
            }
    }

    private func delete(_ entry: VaultStore.Entry) {
        removals.doneWithVault()
        Task {
            await model.report {
                try await model.removeStoredVault(entry, library: library)
                // This device's keys for it go with it (key-hierarchy KH5): it would join again. Kept while another
                // local copy opens with them (re-check of #88).
                try? await keys.store.delete(for: entry.vaultId)
            }
        }
    }

    private func remove(_ removed: WebDAVLocation) {
        Task {
            await model.report {
                try await model.removeWebDAVLocation(removed.id, library: library)
                // The same rule as Delete from This Device: this device's keys for it go too, unless another local
                // copy opens with them.
                if let id = UUID(uuidString: removed.vaultId) {
                    try? await keys.store.delete(for: id)
                }
            }
        }
    }
}

/// One store vault: its name (and label, when it differs), how its targets stand, and when it was last opened here.
/// Its values change only when the vault's entry or its last opening does; the status line follows the runs itself.
private struct StoredVaultRow: View, Equatable {
    var entry: VaultStore.Entry
    /// When it was last opened here.
    var opened: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            if let label = entry.label, label != entry.name {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else {
                StoredVaultStatus(vaultID: entry.vaultId)
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

/// A store vault's status line (`VaultListStatus`): the one view that reads its sessions, so their runs redraw it alone.
private struct StoredVaultStatus: View {
    @AppModelEnvironment private var model
    let vaultID: UUID

    var body: some View {
        VaultListStatusLine(status: VaultListStatus(sessions: model.syncCoordinator.sessions(of: vaultID)))
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
