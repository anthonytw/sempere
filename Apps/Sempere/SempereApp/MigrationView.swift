import Age
import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The only screen of a legacy vault (format.md §3.3.2): it still lists a
/// classic X25519 key, so its notes stay locked until it is moved to a
/// post-quantum key (`AppModel+Migration`).
struct MigrationView: View {
    @AppModelEnvironment private var model
    @State private var saved = false
    @State private var copied = false
    /// The new key while the share sheet is up.
    @State private var sharingKey: String?
    @State private var wrap = false
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var existingKey = ""
    @State private var keyProblem: String?

    var body: some View {
        NavigationStack {
            Form {
                if let migration = model.migration {
                    content(migration)
                }
            }
            .navigationTitle("Upgrade “\(model.vaultName ?? String(localized: "Vault", comment: "Name shown for a vault that has none"))”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close Vault") { model.close() }
                        .disabled(model.migration?.isRunning ?? false)
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: Binding(get: { sharingKey != nil }, set: { if !$0 { sharingKey = nil } })) {
            if let sharingKey { ShareSheet(items: [sharingKey], secret: true) { self.sharingKey = nil } }
        }
    }

    @ViewBuilder
    private func content(_ migration: VaultMigration) -> some View {
        Section {
            if migration.finishingOnly {
                Text("A change of this vault's keys was interrupted. Finish it to open your notes.")
            } else {
                Text("This vault is encrypted to a classic key, which a future quantum computer could break. Its notes stay locked until it is re-encrypted to a post-quantum key. This rewrites every file of the vault; copies made earlier (backups, file version history) are not changed.")
            }
        }
        if let key = migration.key, !migration.finishingOnly {
            if migration.keyIsNew {
                Section {
                    Text("Your new post-quantum secret key. Save it now: after the upgrade only this key (or a passphrase-protected copy) opens the vault. Losing it means losing the vault.")
                    // Not selectable (⌘C would bypass the expiring, local-only Copy Key).
                    Text(key.string)
                        .font(.callout.monospaced())
                    Button(LocalizedStringKey(copied ? "Copied" : "Copy Key"), systemImage: "doc.on.doc") {
                        SecretPasteboard.copy(key.string)
                        copied = true
                    }
                    // The share sheet without its Copy (`SecretSharing`), never a ShareLink.
                    Button("Share…", systemImage: "square.and.arrow.up") { sharingKey = key.string }
                    Toggle("I saved this key", isOn: $saved)
                } header: {
                    Text("New Key")
                }
            } else {
                Section("Key") {
                    Text("The vault will be encrypted to your post-quantum key \(String(key.recipient.string.prefix(16)))…\(String(key.recipient.string.suffix(8))).")
                }
            }
            Section {
                Toggle("Also store the key under a passphrase", isOn: $wrap)
                if wrap {
                    SecureField("Passphrase", text: $passphrase)
                    SecureField("Repeat passphrase", text: $confirmation)
                    if let weak = StoredKeyPassphrase.warning(passphrase) {
                        Text(weak).font(.footnote).foregroundStyle(.red)
                    }
                    Text(StoredKeyPassphrase.footnote).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if migration.keyIsNew {
                Section {
                    TextField("AGE-SECRET-KEY-PQ-1…", text: $existingKey, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Use This Key Instead") {
                        do {
                            try model.useMigrationKey(identityText: existingKey)
                            keyProblem = nil
                            existingKey = ""
                        } catch {
                            keyProblem = "\(error)"
                        }
                    }
                    .disabled(existingKey.isEmpty)
                    if let keyProblem { Text(keyProblem).foregroundStyle(.red) }
                } header: {
                    Text("Or use a post-quantum key you already have")
                }
            }
        }
        Section {
            switch migration.step {
            case .ready:
                EmptyView()
            case .running(let text):
                HStack {
                    ProgressView()
                    Text(text)
                }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red)
            }
            Button(buttonTitle(migration)) { start() }
                .disabled(!canStart(migration))
        }
    }

    private func buttonTitle(_ migration: VaultMigration) -> String {
        if case .failed = migration.step { return String(localized: "Try Again", comment: "Button: retry the vault upgrade") }
        return migration.finishingOnly
            ? String(localized: "Finish", comment: "Button: finish an interrupted change of the vault's keys")
            : String(localized: "Upgrade Vault", comment: "Button: move the vault to a post-quantum key")
    }

    private func canStart(_ migration: VaultMigration) -> Bool {
        if migration.isRunning { return false }
        if migration.finishingOnly { return true }
        guard migration.key != nil else { return false }
        if migration.keyIsNew && !saved { return false }
        return !wrap || (!passphrase.isEmpty && passphrase == confirmation && StoredKeyPassphrase.accepts(passphrase))
    }

    private func start() {
        let pass = wrap ? passphrase : nil
        // A failure is shown on this screen (`step`); starting again resumes.
        Task { try? await model.migrate(passphrase: pass) }
    }
}
