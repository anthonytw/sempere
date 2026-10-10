import SwiftUI

/// "Don't see iCloud Drive?": what to check when the folder picker shows no
/// iCloud Drive (TestFlight build 6, on an iPhone with iCloud on).
///
/// The picker is the system's (`fileImporter`, open mode, `.sempere` and
/// `.folder`); it needs no entitlement or Info.plist key to list iCloud
/// Drive, and it is the same on compact width. When iCloud Drive is missing
/// from it, the device does not sync iCloud Drive or Files hides it, both
/// settings of the device, which the app cannot change or reliably detect
/// without an iCloud container entitlement (docs/iphone.md "iCloud Drive").
enum ICloudDriveHelp {
    /// The steps, worded for an iPhone or an iPad.
    static func steps(device: String) -> [String] {
        [
            String(localized: "Open the Settings app ▸ your name ▸ iCloud ▸ iCloud Drive and turn on “Sync this \(device)”. (On older versions the switch is called iCloud Drive.)",
                   comment: "iCloud Drive help step; %@ is iPhone or iPad. Use the system's own names of these settings."),
            String(localized: "In the picker, tap Browse, then iCloud Drive under Locations. If it is not listed, tap ⋯ (More) ▸ Edit at the top of Browse and turn iCloud Drive on.",
                   comment: "iCloud Drive help step (iPhone and iPad only). Use the Files app's own names of Browse, Locations, More, Edit."),
            String(localized: "Open the Files app once: iCloud Drive may take a minute to appear on a device that has just started syncing it.",
                   comment: "iCloud Drive help step (iPhone and iPad only)"),
            String(localized: "Still missing? Create the vault “On This Device” for now and move it to iCloud Drive later in Files.",
                   comment: "iCloud Drive help step; “On This Device” is the new-vault location option"),
        ]
    }

    /// "iPhone" or "iPad".
    @MainActor static var deviceName: String { Platform.isPhone ? "iPhone" : "iPad" }

    /// Shown on the iPhone and iPad; a Mac's open panel lists iCloud Drive from Finder's settings.
    @MainActor static var isShown: Bool { !Platform.isMac }
}

/// A "Don't see iCloud Drive?" button that opens the steps.
struct ICloudDriveHelpButton: View {
    @State private var showing = false

    var body: some View {
        if ICloudDriveHelp.isShown {
            Button("Don’t see iCloud Drive?", systemImage: "icloud.slash") { showing = true }
                .sheet(isPresented: $showing) { ICloudDriveHelpView() }
                .help("How to make iCloud Drive appear in the folder picker")
        }
    }
}

struct ICloudDriveHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(ICloudDriveHelp.steps(device: ICloudDriveHelp.deviceName).enumerated()), id: \.offset) { i, step in
                        Label { Text(step) } icon: { Text("\(i + 1)").font(.headline.monospacedDigit()) }
                    }
                } footer: {
                    Text("Sempere opens vaults through the system’s file picker, so it sees exactly the locations the Files app shows.")
                }
            }
            .navigationTitle("iCloud Drive")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
