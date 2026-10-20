import Age
import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Creates a vault: name, location, and where its recovery key comes from: a
/// new key (default) or a key the user already has (pasted, or a key file,
/// maybe passphrase-wrapped: `ExistingKeyInput`). This device is the vault's
/// home, with a device key made here and remembered in its Keychain.
struct NewVaultView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @Environment(\.dismiss) private var dismiss

    private enum Location: Hashable { case onDevice, folder }
    enum Source: Hashable { case generate, existing }

    @State private var name = ""
    @State private var location = Location.onDevice
    @State private var folder: URL?
    @State private var subfolder: String?
    @State private var pickingFolder = false
    @State private var namingFolder = false
    @State private var newFolderName = ""
    @State private var source = Source.generate
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
        // A folder picker with New Folder (`FolderPicker`).
        .folderPicker(isPresented: $pickingFolder) { result in
            switch result {
            case .success(let url):
                folder = url
                subfolder = nil
            case .failure(let error): failure = "\(error)"
            }
            if folder == nil { location = .onDevice }
        }
        .alert(String(localized: "New Folder", comment: "Title of the alert that names a new folder for the vault"),
               isPresented: $namingFolder) {
            TextField(String(localized: "Folder name", comment: "Placeholder of the new folder name"), text: $newFolderName)
                .autocorrectionDisabled()
                .accessibilityIdentifier("newVault.newFolderName")
            Button("Cancel", role: .cancel) {}
            Button(String(localized: "Create Folder", comment: "Confirms the new folder for the vault")) { nameNewFolder() }
        } message: {
            if let folder {
                Text("The vault goes into a new folder inside “\(folder.lastPathComponent)”. It is made when you create the vault.")
            }
        }
    }

    private var form: some View {
        Form {
            Section("Name") {
                TextField("Notes", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("newVault.name")
            }
            whereSection
            keySection
            storeSection
            if let failure {
                Text(failure).foregroundStyle(.red)
                    .accessibilityIdentifier("newVault.failure")
            }
        }
        .disabled(working)
        .overlay { if working { ProgressView() } }
    }

    // MARK: - Where

    private var whereSection: some View {
        Section {
            Picker("Location", selection: $location) {
                Text("On This Device").tag(Location.onDevice)
                Text("Choose Folder…").tag(Location.folder)
            }
            .accessibilityIdentifier("newVault.location")
            .onChange(of: location) { _, new in
                if new == .folder { pickingFolder = true }
            }
            if location == .folder, let folder {
                LabeledContent("Folder", value: subfolder.map { "\(folder.lastPathComponent) / \($0)" } ?? folder.lastPathComponent)
                    .accessibilityIdentifier("newVault.folder")
                // The folder picker has New Folder too; this names one inside the chosen folder, made with the vault.
                Button(subfolder == nil ? String(localized: "New Folder…", comment: "Button: put the vault into a new folder")
                                        : String(localized: "Rename New Folder…", comment: "Button: rename the new folder for the vault"),
                       systemImage: "folder.badge.plus") {
                    newFolderName = subfolder ?? ""
                    namingFolder = true
                }
                .help(String(localized: "Make a new folder for the vault inside the chosen one"))
                .accessibilityIdentifier("newVault.newFolder")
                if subfolder != nil {
                    Button(String(localized: "No New Folder", comment: "Button: put the vault directly in the chosen folder"),
                           systemImage: "folder") { subfolder = nil }
                        .help(String(localized: "Put the vault directly in the chosen folder"))
                }
            }
            ICloudDriveHelpButton()
        } header: {
            Text("Where")
        } footer: {
            Text("To keep a vault in iCloud Drive, choose a folder inside it. Any Files location works.")
        }
    }

    private func nameNewFolder() {
        do {
            subfolder = try VaultLibrary.subfolderName(newFolderName)
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    // MARK: - Key

    private var keySection: some View {
        Section {
            Picker("Recovery Key", selection: $source) {
                Text("Generate a new key").tag(Source.generate)
                Text("Use an existing key").tag(Source.existing)
            }
            .accessibilityIdentifier("newVault.keySource")
            if source == .existing {
                existingKeyRows
            }
        } header: {
            Text("Recovery Key")
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
            return String(localized: "This device gets its own key, kept in its Keychain, and becomes the vault's home. Sempere also makes the vault's recovery key (AGE-SECRET-KEY-PQ-1…) and shows it once, after the vault is created: save it or print its kit. No device keeps it, and without it nobody can open the vault if this device is lost.",
                          comment: "Footer of the recovery key choice: generate a new key")
        case .existing:
            return String(localized: "This device gets its own key, kept in its Keychain, and becomes the vault's home. Paste a secret key that starts with AGE-SECRET-KEY-PQ-1 to be the vault's recovery key (the whole output of age-keygen -pq works too), or choose a key file. A public key (age1pq1…) cannot open a vault, and classic keys (AGE-SECRET-KEY-1…) are not accepted.",
                          comment: "Footer of the recovery key choice: use an existing key")
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
            Label(String(localized: "Ready. The recovery key is \(ExistingKeyInput.shortRecipient(identity)).",
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
            Toggle("Also store the recovery key under a passphrase", isOn: $wrap)
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

    /// Keeps this device's key of the new vault in the Keychain: it is the
    /// only copy, and without it this device could only read the vault with
    /// the recovery key. A failure says so (the vault stays open until it closes).
    private func rememberDeviceKey(_ created: CreatedVault) async {
        do {
            try await keys.rememberCreatedVaultKey(created.device, vaultID: created.vaultID,
                                                   vaultName: VaultLibrary.displayName(of: created.url),
                                                   folder: model.vault?.vaultId == created.vaultID ? model.vaultURL : nil)
        } catch {
            model.errorMessage = String(localized: "The vault was created, but this device's key could not be saved in the Keychain: \(String(describing: error)). Once the vault is closed, this device can only read it with the recovery key.",
                                        comment: "The error text follows (English)")
        }
    }

    private var canCreate: Bool {
        guard !working, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if location == .folder && folder == nil { return false }
        let passphraseOK = !wrap || (!passphrase.isEmpty && passphrase == confirmation && StoredKeyPassphrase.accepts(passphrase))
        switch source {
        case .generate: return passphraseOK
        case .existing: return existing.identity != nil && passphraseOK
        }
    }

    private func create() {
        failure = nil
        let keySource: NewVaultRequest.KeySource
        switch source {
        case .generate: keySource = .generate
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
            passphrase: wrap ? passphrase : nil,
            subfolder: location == .folder ? subfolder : nil,
            deviceName: ThisDevice.name,
            deviceKind: ThisDevice.kind)
        let parent = location == .folder ? folder : VaultLibrary.onDeviceFolder
        Task {
            defer { working = false }
            do {
                guard let parent else { return }
                let result = try await model.createVault(request, in: parent, library: library)
                await rememberDeviceKey(result)
                if result.secretKey == nil { dismiss() } else { created = result }
            } catch {
                failure = "\(error)"
            }
        }
    }
}

/// Shows the freshly generated recovery key once, with its kit; there is no
/// other copy unless a passphrase wrapped one into `keys/`.
private struct KeyReceipt: View {
    let created: CreatedVault
    let done: () -> Void
    @State private var copied = false
    @State private var sharing = false

    var body: some View {
        Form {
            Section {
                Text("“\(created.url.deletingPathExtension().lastPathComponent)” is ready. Save its recovery key now, or print its kit: anyone with it can read the vault, and without it the vault cannot be opened if this device is lost.")
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
            if let key = created.recoveryKey {
                KeyFileActions(key: key, vault: created.kitVault)
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
