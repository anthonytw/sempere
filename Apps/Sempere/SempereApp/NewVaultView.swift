import Age
import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Creates a vault in the in-app store (docs/design/device-first-sync.md §2): name, and where the key
/// comes from: a new key
/// (default), a key the user already has (pasted, or a key file, maybe
/// passphrase-wrapped: `ExistingKeyInput`), or only someone's public key.
struct NewVaultView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Environment(\.dismiss) private var dismiss

    enum Source: Hashable { case generate, existing, recipient }

    @State private var name = ""
    @State private var source = Source.generate
    @State private var recipient = ""
    @State private var existingText = ""
    @State private var existingFile: String?
    @State private var existing = ExistingKeyInput.Status.empty
    @State private var pickingKeyFile = false
    @State private var keyFilePassphrase = ""
    @State private var keyFileRevealed = false
    @State private var opening = false
    @State private var wrap = false
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var revealed = false
    @State private var working = false
    @State private var failure: String?
    @State private var created: CreatedVault?
    /// "Keep a copy in": the folder the vault also syncs with (a sync target), if any.
    @State private var copyFolder: URL?
    @State private var pickingCopyFolder = false

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    KeyReceipt(created: created) { dismiss() }
                } else {
                    form
                }
            }
            .navigationTitle(created == nil
                             ? String(localized: "New Vault", comment: "Title of the new-vault form")
                             : String(localized: "Vault Created", comment: "Title after a vault was created"))
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .disabled(!canCreate)
                            .accessibilityIdentifier("newVault.create")
                            .help("Create the vault")
                    }
                }
            }
        }
        .interactiveDismissDisabled(created != nil || working)
        .holdsOnboarding()
    }

    private var form: some View {
        Form {
            Section {
                TextField("Notes", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("newVault.name")
            } header: {
                Text("Name")
            } footer: {
                Text("Sempere keeps the vault on this device, inside the app, so it opens without a connection.")
            }
            keySection
            copySection
            if source != .recipient {
                storeSection
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
                    .accessibilityIdentifier("newVault.failure")
            }
        }
        .disabled(working)
        .overlay { if working { ProgressView() } }
    }

    // MARK: - Keep a copy in

    /// "Keep a copy in: None / A folder…" (docs/design/device-first-sync.md §8.1): a folder in iCloud Drive,
    /// another provider or anywhere becomes a sync target of the new vault.
    private var copySection: some View {
        Section {
            if let copyFolder {
                HStack {
                    Label(copyFolder.lastPathComponent, systemImage: "folder")
                    Spacer()
                    Button("None", systemImage: "xmark.circle") { self.copyFolder = nil }
                        .labelStyle(.iconOnly)
                        .help("Keep no copy outside the app")
                }
            }
            Button(copyFolder == nil ? "Choose Folder…" : "Choose Another Folder…") { pickingCopyFolder = true }
                .accessibilityIdentifier("newVault.copyFolder")
                .fileImporter(isPresented: $pickingCopyFolder, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { copyFolder = url }
                }
        } header: {
            Text("Keep a Copy In")
        } footer: {
            Text(copyFolder == nil
                 ? "None: the vault is only on this device. Choose a folder, for example in iCloud Drive, to sync it with your other devices."
                 : "The vault syncs both ways with a copy in this folder. Add or remove folders later in Sync Targets.")
        }
    }

    // MARK: - Key

    private var keySection: some View {
        Section {
            Picker("Key", selection: $source) {
                Text("Generate a new key").tag(Source.generate)
                Text("Use an existing key").tag(Source.existing)
                Text("Public key only").tag(Source.recipient)
            }
            .accessibilityIdentifier("newVault.keySource")
            switch source {
            case .generate:
                EmptyView()
            case .existing:
                existingKeyRows
            case .recipient:
                TextField("age1pq1…", text: $recipient, axis: .vertical)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("newVault.recipient")
            }
        } header: {
            Text("Key")
        } footer: {
            Text(Self.keyFooter(source))
                .accessibilityIdentifier("newVault.keyFooter")
        }
        .fileImporter(isPresented: $pickingKeyFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { readKeyFile(url) }
        }
    }

    /// What each key choice does, and for an existing key exactly what to give.
    static func keyFooter(_ source: Source) -> String {
        switch source {
        case .generate:
            return String(localized: "Sempere makes a new post-quantum key (AGE-SECRET-KEY-PQ-1…) on this device and shows it once, after the vault is created. Save it: without it, or a passphrase copy, the vault cannot be opened.",
                          comment: "Footer of the key choice: generate a new key")
        case .existing:
            return String(localized: "Paste a secret key that starts with AGE-SECRET-KEY-PQ-1 (the whole output of age-keygen -pq or sempere keys generate works too), or choose a key file: a saved key, or a passphrase-wrapped key file (keys/….key.age) from another vault. A public key (age1pq1…) cannot open a vault, and classic keys (AGE-SECRET-KEY-1…) are not accepted.",
                          comment: "Footer of the key choice: use an existing key")
        case .recipient:
            return String(localized: "Encrypt to someone's public key (age1pq1…). This device gets no key: only the matching secret key opens the vault, and you will be asked for it.",
                          comment: "Footer of the key choice: public key only")
        }
    }

    @ViewBuilder private var existingKeyRows: some View {
        if let existingFile {
            LabeledContent(String(localized: "Key file", comment: "Label of the picked key file"), value: existingFile)
            Button(String(localized: "Paste a Key Instead", comment: "Button: forget the picked key file"),
                   systemImage: "doc.on.clipboard") {
                self.existingFile = nil
                existing = ExistingKeyInput.status(ofText: existingText)
            }
            .help(String(localized: "Forget the key file and paste a key"))
        } else {
            TextField("AGE-SECRET-KEY-PQ-1…", text: $existingText, axis: .vertical)
                .lineLimit(1...6)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .privacySensitive()
                .accessibilityIdentifier("newVault.existingKey")
                .onChange(of: existingText) { _, text in existing = ExistingKeyInput.status(ofText: text) }
        }
        Button(String(localized: "Choose Key File…", comment: "Button: pick a key file for the new vault"),
               systemImage: "key") { pickingKeyFile = true }
            .help(String(localized: "Choose a saved key file or a passphrase-wrapped key file"))
            .accessibilityIdentifier("newVault.chooseKeyFile")
        switch existing {
        case .empty:
            EmptyView()
        case .ready(let identity):
            Label(String(localized: "Ready. The vault will be encrypted to \(ExistingKeyInput.shortRecipient(identity)).",
                         comment: "%@ is the abbreviated public key of the existing key"),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
                .accessibilityIdentifier("newVault.existingStatus")
        case .needsPassphrase(let data):
            PassphraseField(placeholder: String(localized: "Passphrase of the key file", comment: "Placeholder"),
                            text: $keyFilePassphrase, revealed: $keyFileRevealed, contentType: .password,
                            identifier: "newVault.keyFilePassphrase") { openKeyFile(data) }
            Button(String(localized: "Open Key File", comment: "Button: decrypt the passphrase-wrapped key file")) {
                openKeyFile(data)
            }
            .disabled(keyFilePassphrase.isEmpty || opening)
            .accessibilityIdentifier("newVault.openKeyFile")
        case .problem(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.footnote)
                .accessibilityIdentifier("newVault.existingStatus")
        }
    }

    private func readKeyFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        keyFilePassphrase = ""
        do {
            let data = try CloudVault.coordinatedRead(url) {
                try BoundedRead.contents(of: url, maxBytes: KeyText.maximumBytes)
            }
            existing = ExistingKeyInput.status(ofFile: data)
        } catch VaultError.fileTooLarge {
            existing = .problem(ExistingKeyInput.message(.tooLarge(KeyText.maximumBytes + 1)))
        } catch {
            existing = .problem(String(localized: "Sempere could not read that file: \(String(describing: error))"))
        }
        existingFile = url.lastPathComponent
    }

    private func openKeyFile(_ data: Data) {
        guard !keyFilePassphrase.isEmpty, !opening else { return }
        opening = true
        let passphrase = keyFilePassphrase
        Task {
            let status = await Task.detached(priority: .userInitiated) {
                ExistingKeyInput.unwrap(data, passphrase: passphrase)
            }.value
            opening = false
            // A wrong passphrase keeps the file: ask again.
            if case .problem(let message) = status {
                failure = message
            } else {
                failure = nil
                existing = status
            }
        }
    }

    // MARK: - Stored copy

    private var storeSection: some View {
        Section {
            Toggle("Also store the key under a passphrase", isOn: $wrap)
                .accessibilityIdentifier("newVault.storeKey")
            if wrap {
                // One row: AutoFill's Strong Password fills both fields only when they sit together (iPad).
                PassphrasePairField(placeholder: String(localized: "Passphrase", comment: "Placeholder of the new passphrase field"),
                                    confirmationPlaceholder: String(localized: "Repeat passphrase",
                                                                    comment: "Placeholder of the passphrase confirmation"),
                                    passphrase: $passphrase, confirmation: $confirmation, revealed: $revealed,
                                    identifier: "newVault.passphrase", confirmationIdentifier: "newVault.confirmation")
                PassphraseRequirementsView(passphrase: passphrase, confirmation: confirmation)
            }
        } footer: {
            if wrap { Text(StoredKeyPassphrase.footnote) }
        }
    }

    // MARK: - Create

    private var canCreate: Bool {
        guard !working, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let passphraseOK = !wrap || (!passphrase.isEmpty && passphrase == confirmation && StoredKeyPassphrase.accepts(passphrase))
        switch source {
        case .recipient: return !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .generate: return passphraseOK
        case .existing: return existing.identity != nil && passphraseOK
        }
    }

    private func create() {
        failure = nil
        let keySource: NewVaultRequest.KeySource
        switch source {
        case .generate: keySource = .generate
        case .recipient: keySource = .recipient(recipient)
        case .existing:
            guard let identity = existing.identity else { return }
            keySource = .identity(identity)
        }
        // End editing first: a focused multi-line field (the pasted key) under the form that
        // `working` disables, in a sheet going away, kept becoming first responder again in
        // a layout loop that hung the main thread (iPad simulator, iOS 27).
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        working = true
        let request = NewVaultRequest(
            name: name,
            keySource: keySource,
            passphrase: source != .recipient && wrap ? passphrase : nil)
        Task {
            defer { working = false }
            do {
                let result = try await model.createVault(request, library: library)
                if let copyFolder, let vault = model.vault?.vaultId {
                    do { try model.addPickedFolderTarget(copyFolder, to: vault) } catch {
                        model.errorMessage = String(describing: error)
                    }
                }
                if result.secretKey == nil { dismiss() } else { created = result }
            } catch {
                failure = "\(error)"
            }
        }
    }
}

/// Shows the freshly generated secret key once; there is no other copy
/// unless a passphrase wrapped one into `keys/`.
private struct KeyReceipt: View {
    let created: CreatedVault
    let done: () -> Void
    @State private var copied = false
    @State private var sharing = false

    var body: some View {
        Form {
            Section {
                Text("“\(created.url.deletingPathExtension().lastPathComponent)” is ready. Save this secret key now: anyone with it can read the vault, and without it (or a passphrase-wrapped copy) the vault cannot be opened again.")
                // Not selectable, as in the key window: ⌘C would put the secret on the clipboard with no
                // expiry and let Universal Clipboard sync it; Copy Key below does not.
                Text(created.secretKey ?? "")
                    .font(.callout.monospaced())
                Button(copied ? String(localized: "Copied", comment: "Button after the secret key was copied")
                              : String(localized: "Copy Key", comment: "Button: copy the secret key"),
                       systemImage: "doc.on.doc") {
                    // Local only (no Universal Clipboard to other devices) and short-lived.
                    SecretPasteboard.copy(created.secretKey ?? "")
                    copied = true
                }
                    .help("Copy the secret key to the clipboard")
                // The share sheet without its Copy (`SecretSharing`), never a ShareLink.
                Button("Share…", systemImage: "square.and.arrow.up") { sharing = true }
            }
            Section {
                Button("I Saved the Key", action: done)
            }
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [created.secretKey ?? ""], secret: true) { sharing = false }
        }
    }
}
