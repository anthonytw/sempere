import Sempere
import SempereAppCore
import SwiftUI

/// Shown while no vault is open: the vaults on this device (the in-app store, with WebDAV vaults still
/// joining, one list with each vault's sync status), recent WebDAV vaults, and the ways to open or create one.
struct WelcomeView: View {
    @AppEnvironmentObject private var library: VaultLibrary
    var openFolder: () -> Void
    var newVault: () -> Void
    var openRecent: (RecentVault) -> Void
    var openStored: (VaultStore.Entry) -> Void

    @State private var restoring = false
    @State private var connectingWebDAV = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New Vault…", systemImage: "plus.circle", action: newVault)
                    Button("Open Vault…", systemImage: "folder", action: openFolder)
                    Button("Open from WebDAV…", systemImage: "server.rack") { connectingWebDAV = true }
                        .accessibilityIdentifier("openWebDAV")
                    Button("Restore from Backup…", systemImage: "clock.arrow.circlepath") { restoring = true }
                    ICloudDriveHelpButton()
                } footer: {
                    Text("Sempere keeps your vaults on this device, inside the app, so they open without a connection. Open Vault… copies a vault (a .sempere item in Files, iCloud Drive, a backup or an export) onto this device; the original is not changed.")
                }
                StoredVaultsSection(open: openStored)
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
            .navigationTitle("Sempere")
            .task { await library.refreshStoredVaults() }
            .sheet(isPresented: $connectingWebDAV) { WebDAVConnectSheet() }
            .sheet(isPresented: $restoring) {
                RestoreBackupView()
            }
        }
    }
}
