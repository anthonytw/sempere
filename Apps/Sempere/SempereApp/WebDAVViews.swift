import Sempere
import SempereSync
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
    /// Add WebDAV Server… (P9): the store vault this server folder becomes a target of. The same server check
    /// and certificate trust; the folder must be empty, new or hold this vault.
    var addingTo: UUID?

    @State private var urlText = ""
    @State private var user = ""
    @State private var password = ""
    /// The certificate pin this form will save (`WebDAVLocation.pinnedCertificate`).
    @State private var pin: String?
    @State private var testing = false
    @State private var probe: WebDAVProbe?
    @State private var targetProbe: WebDAVTargetProbe?
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
                    if addingTo != nil {
                        Text("An empty or new WebDAV folder (https://…) for this vault, or one that already holds it. The password is kept only in this device's Keychain. The first sync uploads the vault; after that, changes go both ways.")
                    } else {
                    Text("A WebDAV folder (https://…) that holds a vault, or the folder above your vaults. The password is kept only in this device's Keychain. Sempere keeps a copy of the vault on this device and only uploads to the server: it never takes changes from it.")
                    }
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
                if let targetProbe { targetResults(targetProbe) }
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
                            targetProbe = nil
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
            .navigationTitle(addingTo != nil ? Text("Add WebDAV Server") : editing == nil ? Text("Open from WebDAV") : Text("Server Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: fill)
            // The root view's download overlay is under this sheet: show it here while connecting.
            .overlay {
                if let status = model.webdavDownload {
                    WebDAVDownloadOverlay(status: status) { model.cancelWebDAVDownload() }
                }
            }
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
            failureSection(problem, message: message, certificate: certificate)
        }
    }

    /// Add WebDAV Server…: what the folder holds, and Add when the vault may sync with it.
    @ViewBuilder
    private func targetResults(_ probe: WebDAVTargetProbe) -> some View {
        switch probe {
        case .checked(let found):
            Section {
                switch found {
                case .missing: Text("The folder does not exist yet: the first sync creates it.")
                case .empty: Text("The folder is empty.")
                case .sameVault: Text("The folder already holds this vault: the first sync copies what either side lacks.")
                case .otherVault: Text("The folder holds another vault. Choose an empty or new folder.").foregroundStyle(.red)
                case .notEmpty: Text("The folder holds other files. Choose an empty or new folder.").foregroundStyle(.red)
                }
                if found.acceptable {
                    Button {
                        Task { await addTarget() }
                    } label: {
                        HStack {
                            Text("Add This Server")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("webdavAddTarget")
                }
            }
        case .failed(let problem, let message, let certificate):
            failureSection(problem, message: message, certificate: certificate)
        }
    }

    /// Why the check failed and, for a certificate the system does not trust, the opt-in.
    @ViewBuilder
    private func failureSection(_ problem: WebDAVSyncProblem, message: String, certificate: ServerCertificate?) -> some View {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SyncStatus.text(for: problem))
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
        if let addingTo {
            targetProbe = await model.probeWebDAVTarget(url: url, user: userName, password: testPassword(), pin: pin, vaultID: addingTo)
        } else {
            probe = await model.probeWebDAV(url: url, user: userName, password: testPassword(), pin: pin)
        }
    }

    private func addTarget() async {
        guard let addingTo, let url = parsedURL else { return }
        working = true
        defer { working = false }
        do {
            try await model.addWebDAVTarget(url: url, user: userName, password: password, pin: pin, to: addingTo)
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }

    private func open(_ vault: WebDAVVaultListing) async {
        working = true
        defer { working = false }
        do {
            try await model.connectWebDAV(vault, user: userName, password: password, pin: pin, library: library)
            dismiss()
        } catch is CancellationError {
            // Canceled download (the vault is listed; opening it continues), or another vault opened meanwhile.
            dismiss()
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

/// The note list's bar for a WebDAV vault (`SyncStatus`): syncing, synced, offline, waiting for the
/// unlock, or what went wrong, with Sync Now and Server Settings….
struct WebDAVStatusBar: View {
    @AppModelEnvironment private var model
    let session: SyncSession
    @State private var editing: WebDAVLocation?
    @State private var showingTargets = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                if model.syncSessions.count > 1 {
                    Text(session.targetName).font(.caption2.weight(.semibold))
                }
                Text(session.headline).font(.caption)
                if let last = session.lastSuccess, !session.isSyncing {
                    Text("Last sync \(last, format: .relative(presentation: .named))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if session.isSyncing { ProgressView().controlSize(.small) }
            Menu {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await session.syncNow() }
                }
                .disabled(session.isSyncing)
                Button("Sync Targets…", systemImage: "externaldrive.connected.to.line.below") { showingTargets = true }
                if session.kind == .webdav {
                    Button("Server Settings…", systemImage: "server.rack") {
                        editing = model.webdavLocations.location(session.locationID)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Sync")
            .accessibilityIdentifier("webdavMenu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityIdentifier("webdavStatus")
        .sheet(item: $editing) { location in
            WebDAVConnectSheet(editing: location)
        }
        .sheet(isPresented: $showingTargets) { SyncTargetsSheet() }
    }

    private var icon: String {
        switch session.status.kind {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .problem: return "exclamationmark.triangle.fill"
        case .pending: return "arrow.up.circle"
        case .waitingForUnlock: return "lock"
        case .synced: return "checkmark.circle"
        }
    }

    private var tint: SwiftUI.Color {
        if session.needsAttention { return .orange }
        return .secondary
    }
}

/// WebDAV vaults still joining (no copy on this device yet), as rows of the welcome list's vaults: open
/// (the join continues) or remove.
struct JoiningWebDAVRows: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    let locations: [WebDAVLocation]
    @State private var removing: WebDAVLocation?
    @State private var removingUnconfirmed = 0
    /// What removing it does to this device's key (`KeyRemoval`, the same check as Delete from This Device).
    @State private var removal = KeyRemoval()

    var body: some View {
                ForEach(locations) { location in
                    Button {
                        Task { await model.report { try await model.openWebDAV(location.id, library: library) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: location.name).font(.headline)
                            Text("Joining from \(location.host)", comment: "Welcome list: a WebDAV vault whose first download is not finished")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            Task { await prepareRemoval(location) }
                        }
                    }
                    .contextMenu {
                        Button("Remove from This Device…", systemImage: "trash", role: .destructive) {
                            Task { await prepareRemoval(location) }
                        }
                    }
                    // On this location's row, shown for it only: on the section the dialog was on
                    // each of its rows, and several rows presenting at once can close it again on
                    // Mac Catalyst 27.
                    .confirmationDialog("Remove this vault from this device?",
                                        isPresented: Binding(get: { removing?.id == location.id }, set: { if !$0 { removing = nil } }),
                                        titleVisibility: .visible, presenting: removing) { removed in
                        Button("Remove", role: .destructive) {
                            Task {
                                await model.report {
                                    try await model.removeWebDAVLocation(removed.id, library: library)
                                    // The same rule as Delete from This Device: this device's keys for it go too,
                                    // unless another local copy opens with them.
                                    if removal.deletesKeys, let id = UUID(uuidString: removed.vaultId) {
                                        try? await keys.store.delete(for: id)
                                    }
                                }
                            }
                        }
                        if removal.offersMakeHome {
                            Button("Open to Make Another Device Home") {
                                removing = nil
                                Task { await model.report { try await model.openWebDAV(location.id, library: library) } }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { _ in
                        if removingUnconfirmed > 0 {
                            let fileCount = removingUnconfirmed
                            Text("\(fileCount) changes on this device have not reached the server and will be lost. Open the vault and sync first to keep them.")
                        } else if let warning = removal.removalWarning() {
                            Text("\(warning) The vault on the server is not changed.",
                                 comment: "Remove a WebDAV vault from this device: the warning about this device's key, then this")
                        } else {
                            Text("The copy on this device, this device's key for it and the saved password are deleted. The vault on the server is not changed.")
                        }
                    }
                }
    }

    /// Counts the changes the server has not confirmed and runs the key check (home, other local copies) on the
    /// location's copy, then asks.
    private func prepareRemoval(_ location: WebDAVLocation) async {
        removingUnconfirmed = await model.unconfirmedWebDAVChanges(location.id)
        if let id = UUID(uuidString: location.vaultId) {
            let folder = model.webdavLocations.copy(of: location).folder
            removal = await KeyRemoval.check(vaultID: id, at: folder, store: keys.store, library: library, except: folder)
        } else {
            removal = KeyRemoval()
        }
        removing = location
    }
}

/// Shown over everything while a WebDAV vault downloads (`AppModel.webdavDownload`):
/// a bar and Cancel, with files and bytes.
struct WebDAVDownloadOverlay: View {
    let status: WebDAVDownloadStatus
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Downloading “\(status.name)” from the server…").font(.headline)
            Group {
                if let fraction = status.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(width: 280)
            Text(status.description)
                .font(.callout)
                .monospacedDigit()
                .multilineTextAlignment(.center)
            Text("This can take a while the first time. If it stops, opening the vault again continues it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Cancel", role: .cancel, action: cancel)
                .disabled(status.cancelling)
                .accessibilityIdentifier("webdavDownloadCancel")
        }
        .padding(24)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("webdavDownloading")
    }
}
