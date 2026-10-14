import SwiftUI

/// Shown while no vault is open: recents, vaults on this device, and the
/// ways to open or create one.
struct WelcomeView: View {
    @AppEnvironmentObject private var library: VaultLibrary
    var openFolder: () -> Void
    var newVault: () -> Void
    var openRecent: (RecentVault) -> Void
    var openURL: (URL) -> Void

    @State private var onDevice: [URL] = []
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
                    Text("A vault is one .sempere item in Files: on this device, in iCloud Drive, or anywhere else. Choose the .sempere item itself (a plain folder works too).")
                }
                if !library.recents.isEmpty {
                    Section("Recent") {
                        ForEach(library.recents) { entry in
                            Button { openRecent(entry) } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.lastOpened, format: .relative(presentation: .named))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Remove", role: .destructive) { library.forget(entry) } }
                        }
                    }
                }
                WebDAVLocationsSection()
                if !onDevice.isEmpty {
                    Section("On This Device") {
                        ForEach(onDevice, id: \.self) { url in
                            Button(VaultLibrary.displayName(of: url), systemImage: "ipad") { openURL(url) }
                        }
                    }
                }
            }
            .navigationTitle("Sempere")
            .onAppear { onDevice = VaultLibrary.vaults(in: VaultLibrary.onDeviceFolder) }
            .sheet(isPresented: $connectingWebDAV) { WebDAVConnectSheet() }
            .sheet(isPresented: $restoring, onDismiss: { onDevice = VaultLibrary.vaults(in: VaultLibrary.onDeviceFolder) }) {
                RestoreBackupView()
            }
        }
    }
}
