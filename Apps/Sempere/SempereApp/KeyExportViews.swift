import Sempere
import SempereRender
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

/// Save to Files, Share and the recovery kit for a new vault's recovery key.
/// The share sheet's staged file is deleted when it closes and when this view
/// goes away.
struct KeyFileActions: View {
    let key: KeyFile
    /// The vault the kit is printed for (its id, creation date and root).
    let vault: RecoveryKit.VaultInfo
    @State private var savingFile = false
    @State private var shared: URL?
    @State private var kit: PDFFile?
    @State private var savingKit = false
    @State private var failure: String?

    var body: some View {
        // Each presentation on the button that owns it, not on a section: a section's modifier
        // is on each of its rows, and several rows presenting at once can close it again on Mac
        // Catalyst 27. One file exporter per view: SwiftUI presents only one of several on the same view.
        Section {
            Button("Save to Files…", systemImage: "folder") {
                if MacSavePanel.isAvailable { saveOnMac(Data(key.text.utf8), named: key.fileName) } else { savingFile = true }
            }
                .fileExporter(isPresented: $savingFile, document: KeyTextFile(text: key.text), contentType: .plainText,
                              defaultFilename: (key.fileName as NSString).deletingPathExtension) { result in
                    switch result {
                    case .failure(let error):
                        failure = String(localized: "The key was not saved: \(error.localizedDescription)")
                    case .success(let url):
                        // Never a key inside a vault or a backup (a sync folder carries it to every device).
                        if let reason = ExportHandOff.removeRefused([url]) { failure = reason }
                    }
                }
            Button("Share…", systemImage: "square.and.arrow.up") { share() }
                .sheet(isPresented: Binding(get: { shared != nil }, set: { if !$0 { unshare() } })) {
                    if let shared { ShareSheet(items: [shared], secret: true) { unshare() } }
                }
        } header: {
            Text("Key file")
        } footer: {
            Text("\(KeyExportText.warning) A password manager that takes files or text (for example from the share sheet) is the best place.")
        }
        Section {
            Button("Print Recovery Kit…", systemImage: "printer") { printKit() }
                // Any action's failure: on one row that is always there.
                .alert("Sempere", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(failure ?? "")
                }
            Button("Save Recovery Kit as PDF…", systemImage: "doc.richtext") { saveKit() }
                .fileExporter(isPresented: $savingKit, document: kit, contentType: .pdf,
                              defaultFilename: "Sempere recovery kit - \(key.label)") { result in
                    kit = nil
                    // Never the kit inside a vault or a backup (a sync folder carries it to every device).
                    if case .success(let url) = result, let reason = ExportHandOff.removeRefused([url]) { failure = reason }
                }
        } header: {
            Text("Paper recovery kit")
        } footer: {
            Text("A printed page with the recovery key as a QR code and checked text, the vault's root fingerprint, and how to open the vault with stock tools. Print it now and keep it somewhere safe: no device keeps the recovery key, so the kit cannot be printed later. Do not keep the PDF.")
        }
        .onDisappear {
            unshare()
            kit = nil
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
        do { return try AppModel.recoveryKitPDF(for: key, vault: vault) } catch { failure = "\(error)"; return nil }
    }

    private func saveKit() {
        guard let data = kitPDF() else { return }
        if MacSavePanel.isAvailable { return saveOnMac(data, named: "Sempere recovery kit - \(key.label).pdf") }
        kit = PDFFile(data: data)
        savingKit = true
    }

    /// Save… on a Mac: the app's own save panel (`MacSavePanel`), never UIKit's export picker (`fileExporter`), which
    /// froze on a vault folder in build 12; the panel refuses a vault or a backup before anything is written
    /// (review of #123). The file is staged with owner-only permissions and removed once copied or canceled.
    private func saveOnMac(_ data: Data, named name: String) {
        let staged: URL
        do { staged = try KeyShareFile.stageForSaving(data, named: name) } catch {
            failure = String(localized: "The key was not saved: \(error.localizedDescription)")
            return
        }
        let started = MacSavePanel.run(fileName: name) { dest in
            guard let dest else { return KeyShareFile.discard(staged) }
            ExportHandOff.place(checking: [dest], scope: dest, report: { _, message in failure = message },
                                pairs: { [(staged, dest)] }, done: { KeyShareFile.discard(staged) })
        }
        if !started { KeyShareFile.discard(staged) }
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

/// Puts a secret on this device's clipboard only (no Universal Clipboard),
/// cleared after three minutes.
enum SecretPasteboard {
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(180)])
    }
}
