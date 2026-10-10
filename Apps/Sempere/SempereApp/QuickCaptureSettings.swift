#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import Sempere
import SwiftUI
import UIKit

/// Settings ▸ Quick Voice Notes (docs/quick-capture.md): turn it on for the
/// open vault, the notebook voice notes land in, and on-device transcription.
struct QuickCaptureSettingsSection: View {
    /// Where `SettingsView(scrollTo:)` scrolls for `sempere://quick-voice/settings`.
    static let anchor = "quickVoiceNotes"

    @AppModelEnvironment private var model
    @State private var stored: StoredCaptureProfile?
    @State private var notebook = LegacyVoiceNotebook.value() ?? CaptureProfile.defaultNotebook
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Quick Voice Notes", isOn: Binding(get: { model.quickCaptureIsForOpenVault }, set: { on in
                do {
                    if on { try model.enableQuickCapture(notebook: notebook) } else { try model.disableQuickCapture() }
                    problem = nil
                } catch {
                    problem = "\(error)"
                }
                reload()
            }))
            .disabled(model.phase != .unlocked)
            if model.phase != .unlocked, !model.quickCaptureIsForOpenVault, stored == nil {
                // Why the switch is grey (build 7: "nothing said it was disabled").
                Text("Open and unlock the vault that voice notes should go to, then turn this on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let stored, model.quickCaptureIsForOpenVault {
                TextField("Notebook", text: $notebook)
                    .onSubmit { update { $0.profile.notebook = NoteOps.normalizedNotebook(notebook) ?? CaptureProfile.defaultNotebook } }
                    .syncedSetting("quickCapture.notebook")
                Toggle("Transcribe Voice Notes", isOn: Binding(get: { stored.transcribe }, set: { on in
                    update { $0.transcribe = on }
                }))
                .syncedSetting("quickCapture.transcribe")
            } else if let stored {
                LabeledContent("Voice notes go to", value: stored.vaultName)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if stored != nil, !ActivityAuthorizationInfo().areActivitiesEnabled {
                Text(QuickCaptureError.liveActivitiesOff.description).font(.footnote).foregroundStyle(.orange)
                Button("Open Sempere's Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            #endif
        } header: {
            Text("Quick Voice Notes")
        } footer: {
            if Platform.isMac {
                Text("Record from the menu-bar item, File > Start Voice Note, Siri or Shortcuts, without unlocking the vault. Each voice note is encrypted on this Mac to your vault's keys as soon as it stops, and becomes a note in the notebook above, titled with the date and time, the next time the vault is unlocked. Transcription runs on this Mac only. This Mac keeps the vault's public keys and a capture key that can add voice notes but cannot read any note.")
            } else {
                Text("Record from the Lock Screen, Control Center, the Action button, a widget or Siri (“Record a Sempere voice note”), without unlocking the vault or using Face ID or Touch ID. Each voice note is encrypted on this device to your vault's keys as soon as it stops, and becomes a note in the notebook above, titled with the date and time, the next time the vault is unlocked. Transcription runs on this device only. This device keeps the vault's public keys and a capture key that can add voice notes but cannot read any note.")
            }
        }
        .id(Self.anchor)
        .onChange(of: model.settingsAppliedRevision) { reload() }
        .onAppear {
            model.migrateLegacyVoiceNotebook()
            reload()
            // Live Activities may have been switched in Settings ▸ Sempere meanwhile.
            model.quickCapture.publishStatus()
        }
    }

    private func reload() {
        stored = model.quickCaptureProfile
        if let s = stored { notebook = s.profile.notebook }
    }

    private func update(_ change: (inout StoredCaptureProfile) -> Void) {
        guard var s = model.quickCaptureProfile else { return }
        change(&s)
        do { try model.quickCapture.store.save(s) } catch { problem = "\(error)" }
        model.quickCapture.publishStatus()
        model.settingsChanged()   // a synced setting (docs/settings-sync.md §5.2)
        reload()
    }
}
