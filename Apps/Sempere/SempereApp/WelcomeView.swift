import Sempere
import SempereAppCore
import SwiftUI

/// Shown while no vault is open: the vaults on this device (the in-app store, with WebDAV vaults still
/// joining, one list with each vault's sync status), recent WebDAV vaults, and the ways to open or create one.
struct WelcomeView: View {
    @AppEnvironmentObject private var library: VaultLibrary
    @AppModelEnvironment private var model
    var openFolder: () -> Void
    var newVault: () -> Void
    var openRecent: (RecentVault) -> Void
    var openStored: (VaultStore.Entry) -> Void

    @State private var restoring = false
    @State private var connectingWebDAV = false
    @State private var openingICloud = false
    /// The removal being confirmed: the list's own, never a row's (`WelcomeRemovals`).
    @State private var removals = WelcomeRemovals()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New Vault…", systemImage: "plus.circle", action: newVault)
                    Button("Open Vault…", systemImage: "folder", action: openFolder)
                    if model.services.cloudKit != nil {
                        Button("Open from iCloud…", systemImage: "icloud") { openingICloud = true }
                            .accessibilityIdentifier("openICloud")
                    }
                    Button("Open from WebDAV…", systemImage: "server.rack") { connectingWebDAV = true }
                        .accessibilityIdentifier("openWebDAV")
                    Button("Restore from Backup…", systemImage: "clock.arrow.circlepath") { restoring = true }
                    ICloudDriveHelpButton()
                } footer: {
                    Text("Sempere keeps your vaults on this device, inside the app, so they open without a connection. Open Vault… copies a vault (a .sempere item in Files, iCloud Drive, a backup or an export) onto this device; the original is not changed.")
                }
                StoredVaultsSection(open: openStored, removals: removals)
                let others = library.recents.filter { $0.storeID == nil }
                if !others.isEmpty {
                    Section("Recent") {
                        ForEach(others) { entry in
                            Button { openRecent(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.lastOpened, format: .relative(presentation: .named))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .accessibilityIdentifier("recentVault-\(entry.name)")
                            }
                            .swipeActions { Button("Remove", role: .destructive) { library.forget(entry) } }
                            .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { library.forget(entry) } }
                        }
                    }
                }
            }
            .modifier(WelcomeRemovalDialogs(removals: removals, open: openStored))
            #if DEBUG
            .overlay(alignment: .bottomTrailing) { DebugSyncRuns() }
            #endif
            .navigationTitle("Sempere")
            .task { await library.refreshStoredVaults() }
            .sheet(isPresented: $connectingWebDAV) { WebDAVConnectSheet() }
            .sheet(isPresented: $openingICloud) { OpenFromICloudSheet() }
            .sheet(isPresented: $restoring) {
                RestoreBackupView()
            }
        }
    }
}

#if DEBUG
/// UI tests only (`SEMPERE_DEBUG_SYNC_RUNS`, `VaultListSwipeUITests`): an all but invisible element whose label is
/// when a sync run last started (any session), so a test can tell that runs happened while it watched the list. A view
/// of its own over the list, reading the sessions itself: a run redraws it alone, never the list or its rows.
private struct DebugSyncRuns: View {
    @AppModelEnvironment private var model
    static let enabled = ProcessInfo.processInfo.environment["SEMPERE_DEBUG_SYNC_RUNS"] != nil

    var body: some View {
        if Self.enabled {
            let last = model.syncCoordinator.sessions.values.compactMap(\.schedule.lastAttempt).max()
            Color.clear
                .frame(width: 2, height: 2)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: last.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "none"))
                .accessibilityIdentifier("debugSyncRuns")
                .allowsHitTesting(false)
        }
    }
}
#endif
