import SempereAppCore
import SwiftUI

/// The words of the Spotlight switches and their opt-in sheets (docs/design/1.3-spotlight.md §3.6). The sheet names
/// the consequence in plain words each time a switch is turned on: Spotlight's index is the operating system's, outside
/// the vault's encryption. It says "on this device" and nothing about backups (decision 5).
enum SpotlightText {
    static var sheetTitle: String { String(localized: "Show notes in Spotlight?") }

    static var sheetMessage: String {
        Platform.isMac
            ? String(localized: "Spotlight is part of iOS and macOS, not part of Sempere. If you turn this on, your note titles, notebook names and tags are copied into Spotlight's index on this device, where they are not protected by your vault's encryption. Anyone or any app that can read your account's files, and system features such as Siri and Apple Intelligence, can read them. They stay there while this is on, even when Sempere is closed. Sempere removes them when you turn this off, delete the note, change your vault's keys or remove this device. Nothing is sent to us or anyone else.",
                           comment: "Opt-in sheet for Spotlight on a Mac")
            : String(localized: "Spotlight is part of iOS and macOS, not part of Sempere. If you turn this on, your note titles, notebook names and tags are copied into Spotlight's index on this device, where they are not protected by your vault's encryption. Anyone who can use this device while it is unlocked, and system features such as Siri and Apple Intelligence, can read them. They stay there while this is on, even when Sempere is closed. Sempere removes them when you turn this off, delete the note, change your vault's keys or remove this device. Nothing is sent to us or anyone else.",
                           comment: "Opt-in sheet for Spotlight on an iPhone or iPad")
    }

    static var textSheetTitle: String { String(localized: "Include note text in Spotlight?") }

    static var textSheetMessage: String {
        Platform.isMac
            ? String(localized: "This copies the text of your notes into Spotlight's index on this device: recognized handwriting, typed text, PDF text and recording transcripts, up to 20,000 characters per note. It is not protected by your vault's encryption. Anyone or any app that can read your account's files, and system features such as Siri and Apple Intelligence, can read whole notes. It stays there while this is on, even when Sempere is closed. Sempere removes it when you turn this off, delete the note, change your vault's keys or remove this device. Nothing is sent to us or anyone else.",
                           comment: "Opt-in sheet for Include Note Text on a Mac")
            : String(localized: "This copies the text of your notes into Spotlight's index on this device: recognized handwriting, typed text, PDF text and recording transcripts, up to 20,000 characters per note. It is not protected by your vault's encryption. Anyone who can use this device while it is unlocked, and system features such as Siri and Apple Intelligence, can read whole notes. It stays there while this is on, even when Sempere is closed. Sempere removes it when you turn this off, delete the note, change your vault's keys or remove this device. Nothing is sent to us or anyone else.",
                           comment: "Opt-in sheet for Include Note Text on an iPhone or iPad")
    }

    static func ineligible(_ e: SpotlightEligibility) -> String? {
        switch e {
        case .eligible, .notUnlocked: return nil
        case .noDeviceKeys: return String(localized: "Spotlight needs this device's own key: it is not available when the vault was opened with the recovery key.")
        case .listNotTrusted: return String(localized: "Spotlight is off until this vault's device list checks out on this device.")
        case .removed: return String(localized: "This device was removed from the vault, so its notes are not shown in Spotlight.")
        case .demo: return String(localized: "The demo vault is never added to Spotlight.")
        }
    }

    static func notice(_ n: SpotlightNotice) -> String {
        switch n {
        case .deviceRemoved: return String(localized: "Spotlight was turned off and its items removed, because this device was removed from the vault.")
        case .listNotTrusted: return String(localized: "Spotlight was turned off and its items removed, because this vault's device list does not check out on this device.")
        case .unavailable: return String(localized: "Spotlight was turned off and its items removed, because this device no longer holds the vault's key.")
        }
    }

    static func omitted(_ n: Int) -> String {
        String(localized: "\(n) older notes are left out of Spotlight (the limit is 50,000 notes per vault).",
               comment: "%lld is a count")
    }

    static var noteNotHere: String { String(localized: "That note is not on this device any more.") }
}

/// Settings ▸ Spotlight: per vault (the open one) and per device, never synced.
struct SpotlightSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var askingMetadata = false
    @State private var askingText = false

    private var eligibility: SpotlightEligibility { model.spotlightEligibility }
    private var canChange: Bool { eligibility == .eligible }

    var body: some View {
        if model.phase == .unlocked {
            Section {
                Toggle("Show This Vault's Notes in Spotlight", isOn: Binding(
                    get: { model.spotlightMode.isOn },
                    set: { on in
                        if on { askingMetadata = true } else { Task { await model.setSpotlight(.off) } }
                    }))
                    .disabled(!canChange && !model.spotlightMode.isOn)
                    .accessibilityIdentifier("spotlightSwitch")
                if model.spotlightMode.isOn {
                    Toggle("Include Note Text", isOn: Binding(
                        get: { model.spotlightMode.includesText },
                        set: { on in
                            if on { askingText = true } else { Task { await model.setSpotlight(.metadata) } }
                        }))
                        .accessibilityIdentifier("spotlightTextSwitch")
                }
                if let why = SpotlightText.ineligible(eligibility), !model.spotlightMode.isOn {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                }
                if model.spotlightOmitted > 0, model.spotlightMode.isOn {
                    Text(SpotlightText.omitted(model.spotlightOmitted)).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Spotlight")
            } footer: {
                Text("Off by default, for this vault on this device only. Spotlight's index belongs to the system and is not protected by your vault's encryption.")
            }
            .alert(SpotlightText.sheetTitle, isPresented: $askingMetadata) {
                Button("Cancel", role: .cancel) {}
                Button("Turn On") { Task { await model.setSpotlight(.metadata) } }
            } message: {
                Text(SpotlightText.sheetMessage)
            }
            .alert(SpotlightText.textSheetTitle, isPresented: $askingText) {
                Button("Cancel", role: .cancel) {}
                Button("Include Text") { Task { await model.setSpotlight(.text) } }
            } message: {
                Text(SpotlightText.textSheetMessage)
            }
            if let notice = model.spotlightNotice {
                Section {
                    Label(SpotlightText.notice(notice), systemImage: "info.circle").font(.footnote)
                    Button("Dismiss") { model.dismissSpotlightNotice() }
                }
            }
        }
    }
}

/// "That note is not on this device any more", once, when a Spotlight result's note is gone.
struct NoteLinkProblemAlert: ViewModifier {
    @AppModelEnvironment private var model

    func body(content: Content) -> some View {
        content.alert(SpotlightText.noteNotHere, isPresented: Binding(get: { model.noteLinkProblem != nil },
                                                                     set: { if !$0 { model.noteLinkProblem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

extension View {
    func noteLinkProblemAlert() -> some View { modifier(NoteLinkProblemAlert()) }
}
