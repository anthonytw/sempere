import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The key window (Mac): the open vault's devices and its recovery key
/// (format.md §15.3), read-only.
///
/// TODO(KH5): add, approve, rename, remove and replace devices here (join
/// requests and new epochs). Until then the window lists the devices and
/// says how to change them from a terminal.
struct KeysWindowView: View {
    @AppModelEnvironment private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .unlocked {
                    devices
                } else {
                    ContentUnavailableView("No Vault Unlocked", systemImage: "key.slash",
                                           description: Text("Open and unlock a vault in the library window to see its devices."))
                }
            }
            .accessibilityIdentifier("keysWindow")
            .navigationTitle(model.vaultName.map { String(localized: "Keys of “\($0)”", comment: "Key window title; the value is the vault name") }
                             ?? String(localized: "Vault Keys", comment: "Key window title when the vault has no name"))
        }
    }

    private var devices: some View {
        List {
            Section {
                ForEach(model.vaultDevices.filter { !$0.isRecovery }) { device in
                    row(device)
                }
            } header: {
                Text("Devices that can open this vault")
            } footer: {
                Text("Adding, renaming and removing devices is not available in the app yet. From a terminal: sempere device.")
            }
            Section {
                ForEach(model.vaultDevices.filter(\.isRecovery)) { device in
                    row(device)
                }
            } header: {
                Text("Recovery key")
            } footer: {
                Text("The recovery key is on the kit printed when the vault was created; no device keeps it. It opens the vault read-only.")
            }
        }
    }

    private func row(_ key: VaultDevice) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(key.name).font(.headline)
                if !key.deviceID.isEmpty {
                    Text(key.deviceID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if key.isHome { Text("Home", comment: "Key window: the vault's home device").font(.caption).foregroundStyle(.blue) }
                if key.isThisDevice { Text("This device").font(.caption).foregroundStyle(.green) }
                Spacer()
            }
            Text(key.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let added = key.added {
                Text("Added \(added.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Copy Public Key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key.recipient }
        }
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
