import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The key window (Mac): the open vault's devices, its recovery kit and the history of device changes
/// (`DevicesView`, key-hierarchy design §6.4), where home adds, renames and removes devices.
struct KeysWindowView: View {
    @AppModelEnvironment private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .unlocked {
                    DevicesView()
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
