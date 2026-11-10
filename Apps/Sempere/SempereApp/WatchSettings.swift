import Foundation
import SempereAppCore
import SwiftUI

/// Settings ▸ Audio & Transcription ▸ Use on Apple Watch (docs/design/1.1-watch.md §3.4): off by default, shown when an Apple
/// Watch is paired with Sempere installed on it. On, the watch gets this device's capture profile (age-encrypted to the
/// watch's own key), records voice notes and sends them here; they go into the vault they were recorded for.
struct WatchSettingsSection: View {
    @AppModelEnvironment private var model
    private let service = WatchConnectivityService.shared
    @State private var problem: String?

    var body: some View {
        let link = service.status
        let stored = try? model.storedQuickCaptureProfile()
        // The revision is read so that a change of the provisioner's or the receiver's state redraws this.
        let _ = link.revision
        if link.isSupported, link.isPaired, link.isWatchAppInstalled {
            Section {
                Toggle("Use on Apple Watch", isOn: Binding(get: { service.provisioner.enabled }, set: { on in
                    do {
                        try service.provisioner.setEnabled(on)
                        problem = nil
                    } catch {
                        problem = AppModel.describe(error)
                    }
                    service.provisionIfNeeded()
                }))
                if let text = statusText(service.provisioner.status(stored: stored)) {
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
                if let last = service.provisioner.lastNote {
                    LabeledContent("Last note from Watch", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                let waiting = model.quickCapture.queuedForOtherVaults()
                if waiting > 0 {
                    Text("\(waiting) Watch notes waiting for another vault").font(.footnote).foregroundStyle(.orange)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("Voice notes recorded on your watch are encrypted on the watch with the same capture key as this device, and sent here; they become notes the next time the vault is unlocked. Turning this off clears the watch but does not revoke it: someone who has your lost watch can add voice notes to your inbox until you replace this device's key. They cannot read any note.")
            }
            .onAppear { service.provisionIfNeeded() }
        }
    }

    private func statusText(_ status: WatchProvisioner.Status) -> String? {
        switch status {
        case .off: return nil
        case .needsQuickVoiceNotes: return String(localized: "Turn on Quick Voice Notes first: the watch records with its profile.")
        case .suspended: return String(localized: "This device was removed from the vault's device list, so the watch cannot record for it.")
        case .waitingForWatch: return String(localized: "Open Sempere on your Apple Watch to finish setting it up.")
        case .provisioned(let name): return String(localized: "The watch saves voice notes to “\(name)”.")
        case .notSent: return String(localized: "Sending to the watch…")
        }
    }
}
