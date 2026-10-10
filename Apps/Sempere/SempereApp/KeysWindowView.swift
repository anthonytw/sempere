import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The key window (Mac): the keys the open vault is encrypted to, adding and
/// removing a device key, and the paper recovery kit. The work is
/// `AppModel+Keys`; adding or removing a key re-encrypts every note in the vault.
struct KeysWindowView: View {
    @AppModelEnvironment private var model
    @State private var adding = false
    @State private var removing: DeviceKey?
    @State private var replacing: DeviceKey?
    @State private var working: String?
    @State private var failure: String?
    @State private var confirmingKit = false
    @State private var kitDocument: PDFFile?
    @State private var exportingKit = false

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .unlocked {
                    keys
                } else {
                    ContentUnavailableView("No Vault Unlocked", systemImage: "key.slash",
                                           description: Text("Open and unlock a vault in the library window to manage its keys."))
                }
            }
            .accessibilityIdentifier("keysWindow")
            .navigationTitle(model.vaultName.map { String(localized: "Keys of “\($0)”", comment: "Key window title; the value is the vault name") }
                             ?? String(localized: "Vault Keys", comment: "Key window title when the vault has no name"))
        }
        .disabled(working != nil)
        .overlay {
            if let working {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(working).font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $adding) {
            AddDeviceKeyView()
        }
        .sheet(item: $replacing) { key in
            AddDeviceKeyView(replacing: key)
        }
        .confirmationDialog("Remove this key?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { key in
            Button("Remove “\(key.label)”", role: .destructive) {
                Task { await run(String(localized: "Removing the key and re-encrypting every note…")) { try await model.removeDeviceKey(key.recipient, expectedVault: key.vault) } }
            }
        } message: { _ in
            Text("Every note is re-encrypted without it. That device can no longer open new or changed files; it keeps what it already copied.")
        }
        .confirmationDialog("Print the recovery kit?", isPresented: $confirmingKit, titleVisibility: .visible) {
            Button("Print…") { Task { await printKit() } }
            Button("Save as PDF…") { Task { await prepareKit() } }
        } message: {
            Text("The kit contains this vault's secret key. Print it and keep it somewhere safe; do not leave the PDF in cloud storage.")
        }
        .fileExporter(isPresented: $exportingKit, document: kitDocument, contentType: .pdf,
                      defaultFilename: String(localized: "Sempere recovery kit", comment: "Default file name of the saved recovery kit PDF")) { _ in kitDocument = nil }
        .alert("Sempere", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var keys: some View {
        List {
            Section {
                ForEach(model.deviceKeys) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(key.label).font(.headline)
                            if key.isInUse { Text("This key unlocked the vault").font(.caption).foregroundStyle(.green) }
                            if !key.isPostQuantum { Text("Classic").font(.caption).foregroundStyle(.orange) }
                            Spacer()
                            Button("Replace Key…") { replacing = key }
                                .disabled(key.isInUse)
                            Button("Remove Key…", role: .destructive) { removing = key }
                                .disabled(key.isInUse || model.deviceKeys.count < 2)
                        }
                        Text(key.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Added \(key.added.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Replace Key…", systemImage: "arrow.triangle.2.circlepath") { replacing = key }
                            .disabled(key.isInUse)
                        Button("Remove Key…", systemImage: "trash", role: .destructive) { removing = key }
                            .disabled(key.isInUse || model.deviceKeys.count < 2)
                        Button("Copy Public Key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key.recipient }
                    }
                }
            } header: {
                Text("Keys this vault is encrypted to")
            } footer: {
                Text("Add a device by pasting its public key (age1pq1…) or by generating one for it. Replace swaps a device's key for a new one in a single re-encryption (for a lost or exposed key). A key that opened the vault here cannot be removed or replaced here.")
            }
            Section {
                Button("Add Device Key…", systemImage: "plus") { adding = true }
            }
            Section {
                Button("Recovery Kit…", systemImage: "printer") { confirmingKit = true }
            } header: {
                Text("Paper recovery kit")
            } footer: {
                Text("A printed page with your key as a QR code and checked text, and how to open the vault with stock tools. The same kit from a terminal: sempere keys paper.")
            }
        }
    }

    private func run(_ message: String, _ work: () async throws -> Void) async {
        working = message
        defer { working = nil }
        do { try await work() } catch is CancellationError {} catch { failure = "\(error)" }
    }

    /// The kit holds the secret key: the owner authenticates first (P1).
    private func kitPDF() async -> Data? {
        do { return try await model.recoveryKitPDF() } catch is CancellationError { return nil } catch {
            failure = "\(error)"
            return nil
        }
    }

    private func prepareKit() async {
        guard let data = await kitPDF() else { return }
        kitDocument = PDFFile(data: data)
        exportingKit = true
    }

    private func printKit() async {
        guard let data = await kitPDF() else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = String(localized: "Sempere recovery kit", comment: "Default file name of the saved recovery kit PDF")
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        _ = controller.present(animated: true)
    }
}

/// A PDF handed to the save panel.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Add a device key: paste another device's public key, or generate one.
/// With `replacing`, the new key replaces that one (`recipients replace`):
/// one re-encryption, after a confirmation.
private struct AddDeviceKeyView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    var replacing: DeviceKey?
    private enum Mode: String, CaseIterable, Identifiable {
        case paste = "Paste a Public Key"
        case generate = "Generate a Key"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paste: return String(localized: "Paste a Public Key", comment: "Add Device Key: segment, paste another device's public key")
            case .generate: return String(localized: "Generate a Key", comment: "Add Device Key: segment, generate a new key for another device")
            }
        }
    }

    @State private var mode = Mode.paste
    @State private var label = ""
    @State private var recipient = ""
    @State private var generated: KeyFile?
    @State private var working: String?
    @State private var failure: String?
    /// The vault this sheet was opened for: switching vaults meanwhile must not add a key to another.
    @State private var vaultID: UUID?
    @State private var confirmingReplace = false

    var body: some View {
        NavigationStack {
            Form {
                if let generated {
                    Section {
                        // Not selectable: ⌘C would put the secret on the clipboard with no
                        // expiry and let Universal Clipboard sync it; Copy Key below does not.
                        Text(generated.secret).font(.caption.monospaced())
                        Button("Copy Key", systemImage: "doc.on.doc") { SecretPasteboard.copy(generated.secret) }
                    } header: {
                        Text("Secret key for “\(generated.label)”")
                    } footer: {
                        Text("Shown once. Put it on the other device now (paste it when it asks for the key) or save it below; nothing here can show it again. The clipboard is cleared after three minutes.")
                    }
                    KeyFileActions(key: generated)
                } else {
                    Picker("Key", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let replacing {
                        Section {
                            Text(replacing.label).font(.headline)
                            Text(replacing.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } header: {
                            Text("Key to replace")
                        } footer: {
                            Text("Every note is re-encrypted with a new vault key, to the new key instead of this one. The old key can no longer open new or changed notes; it keeps what it already copied.")
                        }
                        TextField("Label (empty: keep the current one)", text: $label)
                    } else {
                        TextField("Label (for example, Anna's iPad)", text: $label)
                    }
                    if mode == .paste {
                        TextField("age1pq1…", text: $recipient, axis: .vertical)
                            .font(.caption.monospaced())
                            .autocorrectionDisabled()
                            .lineLimit(3...8)
                    }
                }
            }
            .navigationTitle(replacing == nil ? String(localized: "Add Device Key")
                             : String(localized: "Replace Device Key", comment: "Key window: title of the sheet that replaces a device's key"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey(generated == nil ? "Cancel" : "Done")) { dismiss() }
                }
                if generated == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(replacing == nil ? String(localized: "Add") : String(localized: "Replace…", comment: "Key window: confirm replacing a device's key")) {
                            if replacing == nil { Task { await add() } } else { confirmingReplace = true }
                        }
                        .disabled(mode == .paste && recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: SheetSizing.minWidth(460, isPhone: Platform.isPhone), minHeight: 320)
        .onAppear { if vaultID == nil { vaultID = model.vault?.vaultId } }
        .interactiveDismissDisabled(generated != nil || working != nil)
        .disabled(working != nil)
        .overlay {
            if let working {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(working).font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("Replace this key?", isPresented: $confirmingReplace, titleVisibility: .visible, presenting: replacing) { key in
            Button("Replace “\(key.label)”", role: .destructive) { Task { await add() } }
        } message: { _ in
            Text("Every note is re-encrypted to the new key instead of the old one. Keep this vault open until it finishes.")
        }
        .alert("Sempere", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func add() async {
        let name = label
        let text = recipient
        do {
            if let replacing {
                switch mode {
                case .paste:
                    working = String(localized: "Replacing the key and re-encrypting every note…")
                    defer { working = nil }
                    try await model.replaceDeviceKey(replacing.recipient, with: text, label: name, expectedVault: replacing.vault)
                    dismiss()
                case .generate:
                    working = String(localized: "Generating the key and re-encrypting every note…")
                    defer { working = nil }
                    let key = try await model.generateReplacementKey(for: replacing.recipient, label: name, expectedVault: replacing.vault)
                    generated = key.file
                    failure = key.problem
                }
                return
            }
            switch mode {
            case .paste:
                working = String(localized: "Adding the key and re-encrypting every note…")
                defer { working = nil }
                try await model.addDeviceKey(recipient: text, label: name, expectedVault: vaultID)
                dismiss()
            case .generate:
                working = String(localized: "Generating the key and re-encrypting every note…")
                defer { working = nil }
                let key = try await model.generateDeviceKey(label: name, expectedVault: vaultID)
                generated = key.file
                failure = key.problem
            }
        } catch is CancellationError {
        } catch {
            failure = "\(error)"
        }
    }
}
