import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Creates a vault: name, location, and where the key comes from.
struct NewVaultView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Environment(\.dismiss) private var dismiss

    private enum Location: Hashable { case onDevice, folder }
    private enum Source: Hashable { case generate, recipient }

    @State private var name = ""
    @State private var location = Location.onDevice
    @State private var folder: URL?
    @State private var pickingFolder = false
    @State private var source = Source.generate
    @State private var recipient = ""
    @State private var wrap = false
    @State private var passphrase = ""
    @State private var confirmation = ""
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
                        Button("Create") { create() }.disabled(!canCreate)
                    }
                }
            }
        }
        .interactiveDismissDisabled(created != nil || working)
        .holdsOnboarding()
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): folder = url
            case .failure(let error): failure = "\(error)"
            }
            if folder == nil { location = .onDevice }
        }
    }

    private var form: some View {
        Form {
            Section("Name") {
                TextField("Notes", text: $name)
                    .autocorrectionDisabled()
            }
            Section {
                Picker("Location", selection: $location) {
                    Text("On This Device").tag(Location.onDevice)
                    Text("Choose Folder…").tag(Location.folder)
                }
                .onChange(of: location) { _, new in
                    if new == .folder { pickingFolder = true }
                }
                if location == .folder, let folder {
                    LabeledContent("Folder", value: folder.lastPathComponent)
                }
                ICloudDriveHelpButton()
            } header: {
                Text("Where")
            } footer: {
                Text("To keep a vault in iCloud Drive, choose a folder inside it. Any Files location works.")
            }
            Section("Key") {
                Picker("Key", selection: $source) {
                    Text("Generate on this device").tag(Source.generate)
                    Text("Use an existing recipient").tag(Source.recipient)
                }
                if source == .recipient {
                    TextField("age1pq1…", text: $recipient, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Only the matching secret key can open the vault; you will be asked for it.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Toggle("Also store the key under a passphrase", isOn: $wrap)
                    if wrap {
                        SecureField("Passphrase", text: $passphrase)
                        SecureField("Repeat passphrase", text: $confirmation)
                    }
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .disabled(working)
        .overlay { if working { ProgressView() } }
    }

    private var canCreate: Bool {
        guard !working, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if location == .folder && folder == nil { return false }
        switch source {
        case .recipient: return !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .generate: return !wrap || (!passphrase.isEmpty && passphrase == confirmation)
        }
    }

    private func create() {
        failure = nil
        working = true
        let request = NewVaultRequest(
            name: name,
            keySource: source == .generate ? .generate : .recipient(recipient),
            passphrase: source == .generate && wrap ? passphrase : nil)
        let parent = location == .folder ? folder : VaultLibrary.onDeviceFolder
        Task {
            defer { working = false }
            do {
                guard let parent else { return }
                let result = try await model.createVault(request, in: parent, library: library)
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
