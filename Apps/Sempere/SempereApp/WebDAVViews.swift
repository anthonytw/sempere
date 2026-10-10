import Sempere
import SempereWebDAV
import SwiftUI

/// Open Vault ▸ WebDAV…: URL, user, password, Test Connection, the vaults
/// found, and (only when the system does not trust the server) the
/// certificate opt-in. In edit mode (`editing`) the same form changes a
/// location's password and certificate pin. docs/io.md, "WebDAV vaults in the app".
struct WebDAVConnectSheet: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Environment(\.dismiss) private var dismiss
    var editing: WebDAVLocation?

    @State private var urlText = ""
    @State private var user = ""
    @State private var password = ""
    /// The certificate pin this form will save (`WebDAVLocation.pinnedCertificate`).
    @State private var pin: String?
    @State private var testing = false
    @State private var probe: WebDAVProbe?
    @State private var trusting: ServerCertificate?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server Folder URL", text: $urlText, prompt: Text(verbatim: "https://dav.example.org/notes/"))  // l10n:ignore
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(editing != nil)
                        .accessibilityIdentifier("webdavURL")
                    TextField("User Name", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(editing != nil)
                        .accessibilityIdentifier("webdavUser")
                    SecureField(editing == nil ? LocalizedStringKey("Password") : LocalizedStringKey("New Password (leave empty to keep it)"),
                                text: $password)
                        .accessibilityIdentifier("webdavPassword")
                } footer: {
                    Text("A WebDAV folder (https://…) that holds a vault, or the folder above your vaults. The password is kept only in this device's Keychain. Sempere keeps a copy of the vault on this device and only uploads to the server: it never takes changes from it.")
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || working || parsedURL == nil)
                    .accessibilityIdentifier("webdavTest")
                } footer: {
                    if !urlText.isEmpty, parsedURL == nil {
                        Text("Use an https:// address (plain http only for this device itself), without a user name or password in it.")
                            .foregroundStyle(.red)
                    }
                }
                if let probe { results(probe) }
                if let pin {
                    Section {
                        Label {
                            Text("This server is trusted only with the certificate you chose: \(Self.fingerprint(pin))")
                                .font(.caption.monospaced())
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                        }
                        Button("Stop Trusting This Certificate", role: .destructive) {
                            self.pin = nil
                            probe = nil
                        }
                    } header: {
                        Text("Certificate You Trusted")
                    }
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
                if editing != nil {
                    Section {
                        Button("Save") { Task { await saveEdits() } }
                            .disabled(working)
                    }
                }
            }
            .accessibilityIdentifier("webdavConnectSheet")
            .navigationTitle(editing == nil ? Text("Open from WebDAV") : Text("Server Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: fill)
            .alert("Trust This Certificate?", isPresented: Binding(get: { trusting != nil }, set: { if !$0 { trusting = nil } }),
                   presenting: trusting) { cert in
                Button("Trust It", role: .destructive) {
                    pin = cert.sha256
                    trusting = nil
                    Task { await test() }
                }
                Button("Cancel", role: .cancel) { trusting = nil }
            } message: { cert in
                Text("Trust it only if this fingerprint is exactly the one your server shows. Anyone who can intercept the connection could present a certificate like this one, and would then see your password and encrypted files.\n\n\(cert.subject)\n\(cert.fingerprint)")
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ probe: WebDAVProbe) -> some View {
        switch probe {
        case .reachable(let result):
            Section {
                if result.vaults.isEmpty {
                    Text("Connected, but there is no vault at this address or in the folders directly below it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(result.vaults, id: \.url) { vault in
                    Button {
                        Task { await open(vault) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: vault.name).font(.headline)
                                Text(verbatim: vault.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if working { ProgressView() } else if editing == nil {
                                Text("Download and Open").font(.caption)
                            }
                        }
                    }
                    .disabled(working || editing != nil)
                    .accessibilityIdentifier("webdavVault")
                }
            } header: {
                Text("Vaults")
            } footer: {
                if !result.unreadable.isEmpty || result.foldersSkipped > 0 {
                    Text("Some folders could not be read or were not looked into.")
                }
            }
        case .failed(let problem, let message, let certificate):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WebDAVSession.text(for: problem))
                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let certificate, certificate.sha256 != pin {
                    CertificateWarning(certificate: certificate)
                    Button("Trust This Certificate…", role: .destructive) { trusting = certificate }
                        .accessibilityIdentifier("webdavTrust")
                }
            }
        }
    }

    // MARK: - Actions

    /// The URL typed, as a collection URL (`https://` added when no scheme
    /// was typed); nil when the library would refuse it.
    private var parsedURL: URL? { Self.collectionURL(urlText) }

    static func collectionURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        if !t.hasSuffix("/") { t += "/" }
        guard let url = URL(string: t), (try? WebDAVClient(baseURL: url)) != nil else { return nil }
        return url
    }

    static func fingerprint(_ sha256: String) -> String { ServerCertificate(sha256: sha256, subject: "").fingerprint }

    private var userName: String? {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? nil : u
    }

    private func fill() {
        guard let editing, urlText.isEmpty else { return }
        urlText = editing.url
        user = editing.user ?? ""
        pin = editing.pinnedCertificate
    }

    /// The password to test with: the typed one, else (editing) the stored one.
    private func testPassword() -> String {
        if !password.isEmpty || editing == nil { return password }
        guard let editing else { return password }
        return (try? model.webdavPasswords.password(for: editing.id)) ?? ""
    }

    private func test() async {
        guard let url = parsedURL else { return }
        testing = true
        failure = nil
        defer { testing = false }
        probe = await model.probeWebDAV(url: url, user: userName, password: testPassword(), pin: pin)
    }

    private func open(_ vault: WebDAVVaultListing) async {
        working = true
        defer { working = false }
        do {
            try await model.connectWebDAV(vault, user: userName, password: password, pin: pin, library: library)
            dismiss()
        } catch is CancellationError {
        } catch {
            failure = String(describing: error)
        }
    }

    private func saveEdits() async {
        guard let editing else { return }
        working = true
        defer { working = false }
        do {
            try await model.updateWebDAVLocation(editing.id, password: password.isEmpty ? nil : password, pin: pin)
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }
}

/// The loud part of the self-signed opt-in: what the certificate is and why trusting it matters.
private struct CertificateWarning: View {
    let certificate: ServerCertificate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The system does not trust this server's certificate", systemImage: "lock.trianglebadge.exclamationmark.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text("If your server uses a certificate you made yourself, compare this fingerprint with the one the server shows before trusting it. If you did not expect this, do not continue: someone may be intercepting the connection.")
                .font(.caption)
            Text(verbatim: certificate.subject).font(.caption.weight(.semibold))
            Text(verbatim: certificate.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
        }
        .padding(10)
        .background(SwiftUI.Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// The note list's bar for a WebDAV vault: uploading, up to date, offline,
/// or what went wrong, with Sync Now, Download Again… and Server Settings….
struct WebDAVStatusBar: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    let session: WebDAVSession
    @State private var confirmingDownload = false
    @State private var editing: WebDAVLocation?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.headline).font(.caption)
                if let last = session.lastPush, !session.isPushing {
                    Text("Last upload \(last, format: .relative(presentation: .named))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if session.otherWriterFiles > 0 {
                    Text("The server has notes from another device. Download the vault again to see them.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if session.isPushing { ProgressView().controlSize(.small) }
            Menu {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.webdavSyncNow() }
                }
                .disabled(session.isPushing || model.phase != .unlocked)
                Button("Download Again…", systemImage: "arrow.down.circle") { confirmingDownload = true }
                    .disabled(model.phase != .unlocked)
                Button("Server Settings…", systemImage: "server.rack") {
                    editing = model.webdavLocations.location(session.locationID)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("WebDAV sync")
            .accessibilityIdentifier("webdavMenu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityIdentifier("webdavStatus")
        .confirmationDialog("Download the vault again?", isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Download Again") {
                Task { await model.report { try await model.downloadWebDAVAgain(library: library) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device's changes are uploaded first. Then the vault is downloaded from the server, with the notes other devices uploaded, and replaces this device's copy. Open notes close meanwhile.")
        }
        .sheet(item: $editing) { location in
            WebDAVConnectSheet(editing: location)
        }
    }

    private var icon: String {
        if session.isPushing { return "arrow.up.circle" }
        if session.problems.contains(.offline) { return "wifi.slash" }
        if session.needsAttention { return "exclamationmark.triangle.fill" }
        return session.unconfirmed > 0 ? "arrow.up.circle" : "checkmark.circle"
    }

    private var tint: SwiftUI.Color {
        if session.needsAttention { return .orange }
        return .secondary
    }
}

/// The welcome screen's WebDAV vaults: open (offline too, once downloaded) or remove.
struct WebDAVLocationsSection: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @State private var removing: WebDAVLocation?
    @State private var removingUnconfirmed = 0

    var body: some View {
        if !model.webdavLocations.locations.isEmpty {
            Section("WebDAV") {
                ForEach(model.webdavLocations.locations) { location in
                    Button {
                        Task { await model.report { try await model.openWebDAV(location.id, library: library) } }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: location.name).font(.headline)
                            Text(verbatim: location.host).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            Task {
                                removingUnconfirmed = await model.unconfirmedWebDAVChanges(location.id)
                                removing = location
                            }
                        }
                    }
                    .contextMenu {
                        Button("Remove from This Device…", systemImage: "trash", role: .destructive) {
                            Task {
                                removingUnconfirmed = await model.unconfirmedWebDAVChanges(location.id)
                                removing = location
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Remove this vault from this device?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { location in
                Button("Remove", role: .destructive) {
                    Task { await model.report { try await model.removeWebDAVLocation(location.id, library: library) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                if removingUnconfirmed > 0 {
                    let fileCount = removingUnconfirmed
                    Text("\(fileCount) changes on this device have not reached the server and will be lost. Open the vault and sync first to keep them.")
                } else {
                    Text("The copy on this device and the saved password are deleted. The vault on the server is not changed.")
                }
            }
        }
    }
}

/// Shown over everything while a WebDAV vault downloads.
struct WebDAVDownloadOverlay: View {
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Downloading “\(name)” from the server…").font(.headline)
            Text("This can take a while the first time. If it stops, opening the vault again continues it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("webdavDownloading")
    }
}
