import Sempere
import SwiftUI

/// Settings ▸ Sync Settings with This Vault (docs/settings-sync.md §4, §9): the
/// switch, why sync is paused, and the question asked when the vault's settings
/// differ from this device's.
struct SettingsSyncSection: View {
    @AppModelEnvironment private var model

    var body: some View {
        Section {
            Toggle("Sync Settings with This Vault", isOn: Binding(
                get: { model.settingsSync.enabled },
                set: { on in Task { await model.setSettingsSync(on) } }))
                .disabled(model.phase != .unlocked)
                .accessibilityIdentifier("settingsSyncToggle")
            if let problem = model.settingsSyncProblem {
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Sync")
        } footer: {
            if model.phase != .unlocked {
                Text("Unlock a vault to sync settings with it.")
            } else if model.settingsSync.enabled {
                Text("Settings are stored encrypted in this vault and follow it to every device that syncs with it. Changing a setting here changes it there. To keep a different value on this device, touch and hold the setting and choose Only on This Device.")
            } else {
                Text("Store settings encrypted in this vault, so every device that opens it can use the same ones. Device keys and Face ID stay on each device.")
            }
        }
        .sheet(item: Binding(get: { model.settingsSyncPrompt }, set: { if $0 == nil { model.settingsSyncPrompt = nil } })) { prompt in
            SettingsSyncPromptView(prompt: prompt)
        }
        .task(id: model.phase == .unlocked) {
            // Opening Settings reads the vault's settings again.
            if model.phase == .unlocked { await model.syncSettingsNow() }
        }
    }
}

/// "This vault already has settings": what differs and which to keep.
struct SettingsSyncPromptView: View {
    @AppModelEnvironment private var model
    let prompt: SettingsSyncPrompt

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(prompt.differences, id: \.key) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SettingsSyncText.title(d.key))
                            Text("This vault: \(SettingsSyncText.value(d.vault, key: d.key))")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("This device: \(SettingsSyncText.value(d.device, key: d.key))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("This vault already has settings, and some differ from this device's.")
                }
                Section {
                    Button("Use the Vault's Settings") { Task { await model.answerSettingsSyncPrompt(.useVault) } }
                        .bold()
                        .accessibilityIdentifier("settingsSyncUseVault")
                    Button("Replace the Vault's Settings with This Device's") {
                        Task { await model.answerSettingsSyncPrompt(.replaceVault) }
                    }
                    .accessibilityIdentifier("settingsSyncReplaceVault")
                } footer: {
                    Text("Replacing changes these settings on every device that syncs with this vault.")
                }
            }
            .navigationTitle("Sync Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Task { await model.answerSettingsSyncPrompt(nil) } }
                }
            }
        }
    }
}

extension View {
    /// Marks a Settings row as the shared setting `key` (docs/settings-sync.md
    /// §4.3): while sync is on, a context menu to keep it on this device (or
    /// this kind of device) or follow the vault again, and a badge when it is
    /// not following the shared value.
    func syncedSetting(_ key: String) -> some View {
        modifier(SyncedSettingRow(key: key))
    }
}

struct SyncedSettingRow: ViewModifier {
    @AppModelEnvironment private var model
    let key: String

    func body(content: Content) -> some View {
        if model.settingsSync.enabled, model.phase == .unlocked {
            let state = model.settingsSync.rowState(key, type: model.settingsDeviceType)
            VStack(alignment: .leading, spacing: 4) {
                content
                if state != .synced {
                    Menu {
                        actions(state)
                    } label: {
                        Label(state == .overridden ? SettingsSyncText.thisDevice : SettingsSyncText.typeName(model.settingsDeviceType),
                              systemImage: state == .overridden ? "lock.fill" : "rectangle.on.rectangle")
                            .font(.caption)
                    }
                    .help(state == .overridden ? Text("Kept on this device only") : Text("Kept for this kind of device only"))
                    .accessibilityIdentifier("settingsSyncBadge.\(key)")
                }
            }
            .contextMenu { actions(state) }
        } else {
            content
        }
    }

    @ViewBuilder
    // help-lint: titled
    private func actions(_ state: SettingsSyncState.RowState) -> some View {
        switch state {
        case .synced:
            Button("Only on This Device", systemImage: "lock") { model.overrideSetting(key) }
            Button(SettingsSyncText.onlyOnType(model.settingsDeviceType), systemImage: "rectangle.on.rectangle") {
                Task { await model.keepSettingForThisType(key) }
            }
        case .overridden:
            Button("Use Synced Value", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.useSyncedSetting(key) }
            }
        case .typeSpecific:
            Button("Use on All Devices", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.useSettingOnAllDevices(key) }
            }
            Button("Only on This Device", systemImage: "lock") { model.overrideSetting(key) }
        }
    }
}

/// Words for shared settings in the interface.
enum SettingsSyncText {
    static var thisDevice: String { String(localized: "This Device", comment: "Settings badge: the setting is kept on this device only") }

    /// "iPads", "Macs", "iPhones": the badge of a setting kept for one kind of device.
    static func typeName(_ type: SettingsDeviceType) -> String {
        switch type {
        case .mac: return String(localized: "Macs", comment: "Settings badge: the setting has its own value on Macs")
        case .ipad: return String(localized: "iPads", comment: "Settings badge: the setting has its own value on iPads")
        case .iphone: return String(localized: "iPhones", comment: "Settings badge: the setting has its own value on iPhones")
        }
    }

    /// "Only on iPads": keep the value for this kind of device.
    static func onlyOnType(_ type: SettingsDeviceType) -> String {
        switch type {
        case .mac: return String(localized: "Only on Macs", comment: "Settings row menu: keep this value on every Mac, not on other devices")
        case .ipad: return String(localized: "Only on iPads", comment: "Settings row menu: keep this value on every iPad, not on other devices")
        case .iphone: return String(localized: "Only on iPhones", comment: "Settings row menu: keep this value on every iPhone, not on other devices")
        }
    }

    /// The name of the setting `key` as its row shows it.
    static func title(_ key: String) -> String {
        switch key {
        case "handwriting.recognize": return String(localized: "Recognize Handwriting")
        case "newNote.titleFormat": return String(localized: "Title", comment: "Settings ▸ New Notes: the default title of new notes")
        case "newNote.titlePattern": return String(localized: "Title pattern")
        case "editor.defaultPaper": return String(localized: "Paper")
        case "editor.defaultLayout": return String(localized: "Layout", comment: "Settings ▸ New Notes: pages or pageless, and the paper size")
        case "editor.compactPalette": return String(localized: "Compact Palette")
        case "eraser.mode": return String(localized: "Eraser", comment: "Settings sync: the eraser's mode, object or pixel")
        case "eraser.objectRadius": return String(localized: "Object Eraser Size")
        case "recording.codec": return String(localized: "Format")
        case "recording.bitRate": return String(localized: "Quality")
        case "recording.sampleRate": return String(localized: "Sample Rate")
        case "recording.channels": return String(localized: "Channels")
        case "transcription.enabled": return String(localized: "Transcribe Recordings on This Device")
        case "transcription.language": return String(localized: "Language")
        case "math.recognize": return String(localized: "Convert Handwriting to Math")
        case "photos.removeMetadata": return String(localized: "Remove Location and Camera Data")
        case "history.thinAfterDays": return String(localized: "Thin Autosaves Older Than")
        case "search.transcripts": return String(localized: "Search Recording Transcripts")
        case "rewrap.onAdd": return String(localized: "When Adding a Device")
        case "rewrap.onRemove": return String(localized: "When Removing a Device or Upgrading to Post-Quantum Keys")
        case "backup.reminderDays": return String(localized: "Remind Me")
        case "editor.keepScreenOn": return String(localized: "Keep Screen On")
        case "mouse.smoothing": return String(localized: "Smooth Mouse Strokes")
        case "quickCapture.notebook": return String(localized: "Notebook")
        case "quickCapture.transcribe": return String(localized: "Transcribe Voice Notes")
        case "appearance.icon": return String(localized: "App Icon")
        default: return key
        }
    }

    /// A value as the prompt shows it: On / Off, a paper's kind, a name or a number.
    static func value(_ v: JSONValue, key: String) -> String {
        switch v {
        case .bool(let on): return on ? String(localized: "On", comment: "A switch setting's value") : String(localized: "Off")
        case .null: return String(localized: "Same as Device")
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .object:
            if key == "editor.defaultPaper", let paper = try? v.decode(Paper.self) { return paper.kind.localizedTitle }
            return String(describing: v)
        case .array: return String(describing: v)
        }
    }
}
