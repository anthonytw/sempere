import AVFAudio
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
    /// The profile could not be read (`QuickCaptureError.profileUnreadable`): not "off".
    @State private var unreadable = false
    @State private var notebook = CaptureProfile.defaultNotebook
    @State private var notebookSelection: TextSelection?
    @State private var problem: String?
    /// Bumped when the app becomes active again, so the permission notices re-check after a visit to the system Settings.
    @State private var activations = 0

    var body: some View {
        Section {
            Toggle("Quick Voice Notes", isOn: Binding(get: { model.quickCaptureSwitchIsOn }, set: { on in
                do {
                    if on { try model.enableQuickCapture(notebook: notebook) } else { try model.disableQuickCapture() }
                    problem = nil
                } catch {
                    problem = "\(error)"
                }
                reload()
            }))
            .disabled(model.phase != .unlocked)
            if model.phase != .unlocked, !model.quickCaptureIsForOpenVault, stored == nil, !unreadable {
                // Why the switch is gray (build 7: "nothing said it was disabled").
                Text("Open and unlock the vault that voice notes should go to, then turn this on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let stored, model.quickCaptureIsForOpenVault {
                TextField("Notebook", text: $notebook, selection: $notebookSelection)
                    .syncedSetting("quickCapture.notebook")
                    .emojiCompletion(text: $notebook, onSubmit: {
                        update { $0.profile.notebook = NoteOps.normalizedNotebook(notebook) ?? CaptureProfile.defaultNotebook }
                    }, selection: $notebookSelection)
                Toggle("Transcribe Voice Notes", isOn: Binding(get: { stored.transcribe }, set: { on in
                    update { $0.transcribe = on }
                }))
                .syncedSetting("quickCapture.transcribe")
            } else if let stored {
                LabeledContent("Voice notes go to", value: stored.vaultName)
            }
            if unreadable {
                // Not "off" and not "set up": the settings are there, or may be, and cannot be read now.
                Text(QuickCaptureError.profileUnreadable.description).font(.footnote).foregroundStyle(.orange)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
            // Why the Lock Screen / Control Center / Action button / widget shortcuts cannot record,
            // whether or not Quick Voice Notes is set up yet, with the way to the system Settings.
            if !model.quickCapture.recentStarts.isEmpty {
                RecentStartsView(attempts: model.quickCapture.recentStarts) { model.quickCapture.startLog.clear() }
            }
            ForEach(blockers, id: \.self) { blocker in
                VStack(alignment: .leading, spacing: 4) {
                    Label(blocker.title, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(blocker.explanation).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button("Open Sempere's Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Quick Voice Notes")
        } footer: {
            if Platform.isMac {
                Text("Record from the menu-bar item, File ▸ Start Voice Note, Siri or Shortcuts, without unlocking the vault. Each voice note is encrypted on this Mac to your vault's keys as soon as it stops, and becomes a note in the notebook above, titled with the date and time, the next time the vault is unlocked. Transcription runs on this Mac only. This Mac keeps the vault's public keys and a capture key that can add voice notes but cannot read any note.")
            } else {
                Text("Record from the Lock Screen, Control Center, the Action button, a widget or Siri (“Record a Sempere voice note”), without unlocking the vault or using Face ID or Touch ID. Each voice note is encrypted on this device to your vault's keys as soon as it stops, and becomes a note in the notebook above, titled with the date and time, the next time the vault is unlocked. Transcription runs on this device only. This device keeps the vault's public keys and a capture key that can add voice notes but cannot read any note.")
            }
        }
        .id(Self.anchor)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in activations += 1 }
        .onChange(of: model.settingsAppliedRevision) { reload() }
        .onAppear {
            reload()
            // Live Activities may have been switched in Settings ▸ Sempere meanwhile.
            model.quickCapture.publishStatus()
        }
    }

    /// What keeps voice notes from recording on this device right now.
    private var blockers: [VoiceNoteBlocker] {
        _ = activations
        return VoiceNoteBlocker.current(liveActivitiesEnabled: Self.liveActivitiesEnabled,
                                 microphoneDenied: AVAudioApplication.shared.recordPermission == .denied)
    }

    private static var liveActivitiesEnabled: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return true   // Live Activities are not used on a Mac
        #endif
    }

    private func reload() {
        switch model.quickCaptureSetting {
        case .off:
            stored = nil
            unreadable = false
        case .on(let s):
            stored = s
            unreadable = false
            notebook = s.profile.notebook
        case .unreadable:
            stored = nil
            unreadable = true
        }
    }

    private func update(_ change: (inout StoredCaptureProfile) -> Void) {
        let s: StoredCaptureProfile?
        do { s = try model.storedQuickCaptureProfile() } catch {
            // The change is not made: say why rather than dropping it.
            unreadable = true
            return
        }
        guard var s else { return }
        change(&s)
        do { try model.quickCapture.store.save(s) } catch { problem = "\(error)" }
        model.quickCapture.publishStatus()
        model.settingsChanged()   // a synced setting (docs/settings-sync.md §5.2)
        reload()
    }
}

/// A system permission that keeps voice notes (widgets, Lock Screen, Control Center, Action button,
/// Siri) from recording, shown in Settings ▸ Quick Voice Notes with a way to turn it on.
enum VoiceNoteBlocker: Hashable {
    case liveActivitiesOff
    case microphoneDenied

    static func current(liveActivitiesEnabled: Bool, microphoneDenied: Bool) -> [VoiceNoteBlocker] {
        var out: [VoiceNoteBlocker] = []
        if !liveActivitiesEnabled { out.append(.liveActivitiesOff) }
        if microphoneDenied { out.append(.microphoneDenied) }
        return out
    }

    var title: String {
        switch self {
        case .liveActivitiesOff: return String(localized: "Live Activities are off", comment: "Settings ▸ Quick Voice Notes: a permission is missing")
        case .microphoneDenied: return String(localized: "Microphone access is off", comment: "Settings ▸ Quick Voice Notes: a permission is missing")
        }
    }

    var explanation: String {
        switch self {
        case .liveActivitiesOff:
            return String(localized: "The voice-note widgets, Lock Screen control and Action button cannot record until Live Activities are on, because iOS ends a recording that shows none. Open Sempere's Settings and turn on Live Activities.",
                          comment: "Settings ▸ Quick Voice Notes: why voice notes cannot record, and what to do")
        case .microphoneDenied:
            return String(localized: "Voice notes cannot record without the microphone. Open Sempere's Settings and turn on Microphone.",
                          comment: "Settings ▸ Quick Voice Notes: why voice notes cannot record, and what to do")
        }
    }
}

/// Settings ▸ Quick Voice Notes ▸ Recent Starts: the last few voice-note starts on this device
/// (`QuickCapture.recentStarts`, `VoiceNoteStartLog`), for the owner to read or copy when a widget,
/// the control, Siri or Shortcuts did not record. Where each came from, the app's state, what the
/// Live Activity request and the audio system answered, and how it ended; nothing personal.
struct RecentStartsView: View {
    let attempts: [VoiceNoteStartAttempt]
    let clear: () -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(attempts) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.sourceTitle(a.source)).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(a.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Label(Self.outcomeTitle(a.outcome), systemImage: a.outcome == .failed ? "xmark.circle" : "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(a.outcome == .failed ? .orange : .green)
                    ForEach(Array(Self.lines(a).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button("Copy All") { UIPasteboard.general.string = Self.report(attempts) }
            Button("Clear Recent Starts", role: .destructive, action: clear)
        } label: {
            LabeledContent("Recent Starts", value: attempts.first.map { Self.outcomeTitle($0.outcome) } ?? "")
        }
    }

    static func sourceTitle(_ source: VoiceNoteStartSource) -> String {
        switch source {
        case .shortcut: return String(localized: "Siri or Shortcuts", comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: where a voice note was started")
        case .widgetOrControl: return String(localized: "Widget or Control Center", comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: where a voice note was started")
        case .app: return String(localized: "In Sempere", comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: where a voice note was started")
        }
    }

    static func outcomeTitle(_ outcome: VoiceNoteStartAttempt.Outcome) -> String {
        switch outcome {
        case .recording: return String(localized: "Recorded", comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: the start worked")
        case .recordingInApp: return String(localized: "Recorded after opening Sempere", comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: refused in the background, recorded with the app in front")
        case .failed: return String(localized: "Did not record", comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: the start failed")
        }
    }

    /// One line per step: the first try, the move to the app, the retry. Technical values (states,
    /// error domains and codes) stay as the system gives them, untranslated.
    static func lines(_ a: VoiceNoteStartAttempt) -> [String] {
        var out = [String(localized: "First try: \(VoiceNoteStartLog.describe(a.first))",
                          comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: technical details of the first try")]
        if let f = a.foreground {
            let waited = String(format: "%.1f", f.waited)
            let error = f.error.map { " \($0.type) \($0.summary)" } ?? ""
            out.append(String(localized: "Opened Sempere: active \(String(f.becameActive)) after \(waited) s\(error)",
                              comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: technical details of continuing in the app"))
        }
        if let r = a.retry {
            out.append(String(localized: "Second try: \(VoiceNoteStartLog.describe(r))",
                              comment: "Settings ▸ Quick Voice Notes ▸ Recent Starts: technical details of the try with the app in front"))
        }
        return out
    }

    /// Plain text of every attempt, for "Copy All" (to paste into a bug report).
    static func report(_ attempts: [VoiceNoteStartAttempt]) -> String {
        attempts.map { a in
            ([ "\(a.date.ISO8601Format()) \(a.source.rawValue) mode=\(a.intentMode ?? "-") \(a.outcome.rawValue)" ] + lines(a))   // l10n:ignore
                .joined(separator: "\n  ")
        }.joined(separator: "\n")
    }
}
