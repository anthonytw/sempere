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
                                RecentVaultRow(entry: entry, state: library.state(of: entry),
                                               opensWhenReady: library.pendingOpen == entry.id)
                            }
                            .swipeActions { Button("Remove", role: .destructive) { library.forget(entry) } }
                            .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { library.forget(entry) } }
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

/// A recent vault in the welcome list: its name, and when it was opened or why it cannot be opened
/// right now (`RecentVaultState`). A vault iCloud has not delivered yet is listed as waiting, never
/// hidden (docs/io.md "Recent vaults after a restart").
struct RecentVaultRow: View {
    var entry: RecentVault
    var state: RecentVaultState
    /// The launch reopen or a tap is waiting for this vault: it opens by itself when it arrives.
    var opensWhenReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            switch state {
            case .unknown, .available:
                Text(entry.lastOpened, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(waitingText).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if opensWhenReady {
                    Text("Opens as soon as it is available.").font(.caption2).foregroundStyle(.secondary)
                }
            case .missing:
                Label("Not found: it was moved or deleted. Choose it again, or remove it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            case .unreachable:
                Label(unreachableText, systemImage: "icloud.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("recentVault-\(entry.name)")
    }

    private var waitingText: String {
        RecentVaultCheck.mayBeICloud(entry)
            ? String(localized: "Waiting for iCloud…")
            : String(localized: "Waiting for its storage provider…")
    }

    private var unreachableText: String {
        RecentVaultCheck.mayBeICloud(entry)
            ? String(localized: "Can't be reached: iCloud Drive may be off or signed out, or the vault was moved or deleted.")
            : String(localized: "Can't be reached: its storage provider is unavailable, or the vault was moved or deleted.")
    }
}
