import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A key file for "Save to Files": the text goes straight to the folder the
/// user picks, with no copy anywhere else.
struct KeyTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum KeyExportText {
    static let warning = String(localized: "This is the secret key in plain text. Anyone who has it can read every note in the vault. Keep it in a password manager or another place only you can open; do not leave it in a shared or synced folder, an email or a chat.")
}

/// Save to Files, Share and the recovery kit for one key. The share sheet's
/// staged file is deleted when it closes and when this view goes away.
struct KeyFileActions: View {
    @AppModelEnvironment private var model
    let key: KeyFile
    @State private var savingFile = false
    @State private var shared: URL?
    @State private var kit: PDFFile?
    @State private var savingKit = false
    @State private var failure: String?

    var body: some View {
        Section {
            Button("Save to Files…", systemImage: "folder") { savingFile = true }
            Button("Share…", systemImage: "square.and.arrow.up") { share() }
        } header: {
            Text("Key file")
        } footer: {
            Text("\(KeyExportText.warning) A password manager that takes files or text (for example from the share sheet) is the best place. The same file from a terminal: sempere keys generate / sempere keys export.")
        }
        // One file exporter per view: SwiftUI presents only one of several on the same view.
        .fileExporter(isPresented: $savingFile, document: KeyTextFile(text: key.text), contentType: .plainText,
                      defaultFilename: (key.fileName as NSString).deletingPathExtension) { result in
            if case .failure(let error) = result { failure = String(localized: "The key was not saved: \(error.localizedDescription)") }
        }
        .sheet(isPresented: Binding(get: { shared != nil }, set: { if !$0 { unshare() } })) {
            if let shared { ShareSheet(items: [shared], secret: true) { unshare() } }
        }
        Section {
            Button("Print Recovery Kit…", systemImage: "printer") { printKit() }
            Button("Save Recovery Kit as PDF…", systemImage: "doc.richtext") { saveKit() }
        } header: {
            Text("Paper recovery kit")
        } footer: {
            Text("A printed page with the key as a QR code and checked text, and how to open the vault with stock tools (sempere keys paper). Print it and keep it somewhere safe; do not keep the PDF.")
        }
        .fileExporter(isPresented: $savingKit, document: kit, contentType: .pdf,
                      defaultFilename: "Sempere recovery kit - \(key.label)") { _ in kit = nil }
        .onDisappear {
            unshare()
            kit = nil
        }
        .alert("Sempere", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func share() {
        do { shared = try KeyShareFile.stage(key) } catch { failure = String(localized: "The key could not be prepared for sharing: \(error)") }
    }

    private func unshare() {
        shared = nil
        KeyShareFile.purge()
    }

    private func kitPDF() -> Data? {
        do { return try model.recoveryKitPDF(for: key) } catch { failure = "\(error)"; return nil }
    }

    private func saveKit() {
        guard let data = kitPDF() else { return }
        kit = PDFFile(data: data)
        savingKit = true
    }

    private func printKit() {
        guard let data = kitPDF() else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "Sempere recovery kit"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        _ = controller.present(animated: true)
    }
}

/// Save Key…: this device's key, after Face ID, to Files or the share sheet,
/// and its recovery kit.
struct SaveKeyView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key: KeyFile?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let key {
                    Section {
                        LabeledContent("Device", value: key.label)
                        LabeledContent("Public key", value: DeviceKey.abbreviated(key.recipient))
                            .font(.caption.monospaced())
                    } footer: {
                        Text("The key this device unlocked “\(model.vaultName ?? String(localized: "Vault", comment: "Name shown for a vault that has none"))” with.")
                    }
                    KeyFileActions(key: key)
                } else if let failure {
                    Section {
                        Label(failure, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                        Button("Try Again") { Task { await reveal() } }
                    }
                } else {
                    Section { ProgressView() }
                }
            }
            .navigationTitle("Save Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await reveal() }
        .onDisappear { key = nil }
    }

    private func reveal() async {
        failure = nil
        do {
            key = try await model.exportThisDeviceKey()
        } catch is CancellationError {
            dismiss()
        } catch {
            failure = "\(error)"
        }
    }
}

/// New Key…: a post-quantum key for another device. The vault is encrypted to
/// it (every note re-encrypted, as when adding a device key), then the secret
/// is shown once to copy, save, share or print.
struct NewKeyView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var key: KeyFile?
    @State private var working = false
    @State private var failure: String?
    /// The vault this sheet was opened for.
    @State private var vaultID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                if let key {
                    Section {
                        // Not selectable, as in the key window: Copy Key expires the clipboard.
                        Text(key.secret).font(.caption.monospaced())
                        Button("Copy Key", systemImage: "doc.on.doc") { SecretPasteboard.copy(key.secret) }
                    } header: {
                        Text("Secret key for “\(key.label)”")
                    } footer: {
                        Text("Shown once: nothing here can show it again. Paste it on the other device when it asks for the key, or save it below. The clipboard is cleared after three minutes.")
                    }
                    KeyFileActions(key: key)
                } else {
                    Section {
                        TextField("Label (for example, Anna's iPad)", text: $label)
                    } footer: {
                        Text("Creates a new key, adds it to this vault's keys and re-encrypts every note to it, which can take a while. Then save or print it for the other device. From a terminal: sempere keys generate, then sempere vault recipients add.")
                    }
                }
            }
            .navigationTitle("New Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(key == nil ? "Cancel" : "Done") { dismiss() }
                }
                if key == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }
                    }
                }
            }
        }
        .onAppear { if vaultID == nil { vaultID = model.vault?.vaultId } }
        .interactiveDismissDisabled(key != nil || working)
        .disabled(working)
        .overlay {
            if working {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Creating the key and re-encrypting every note…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Sempere", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func create() async {
        working = true
        defer { working = false }
        do {
            let generated = try await model.generateDeviceKey(label: label, expectedVault: vaultID)
            key = generated.file
            failure = generated.problem
        } catch is CancellationError {
        } catch {
            failure = "\(error)"
        }
    }
}

/// Puts a secret on this device's clipboard only (no Universal Clipboard),
/// cleared after three minutes.
enum SecretPasteboard {
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(180)])
    }
}
