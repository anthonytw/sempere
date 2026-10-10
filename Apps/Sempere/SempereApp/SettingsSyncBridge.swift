import Foundation
import Sempere

/// Maps the shared settings' keys (docs/settings-sync.md §5,
/// `SharedSettingsCatalog`) to where this app keeps each value: `UserDefaults`
/// through the settings' own types, so every value is read with its default
/// filled in and written through the same clamping as the Settings screen.
/// The logic of sync is `SettingsSyncState` (Sources); this only reads and
/// writes values. Pure Foundation, so it is typechecked with the other non-UI
/// logic on Linux.
enum SettingsSyncBridge {
    /// The kind of device this app runs on (the iPad app on a Mac is a Mac).
    static func deviceType(isMac: Bool, isPhone: Bool) -> SettingsDeviceType {
        isMac ? .mac : (isPhone ? .iphone : .ipad)
    }

    /// Values the bridge cannot read from `UserDefaults` alone, supplied by the model.
    struct Extras: Equatable, Sendable {
        /// The quick-capture profile's notebook and transcription choice, when
        /// quick capture is on for the open vault (else those keys are not read).
        var quickCapture: (notebook: String, transcribe: Bool)?
        /// The open vault's backup reminder (`BackupRecord.reminderDays`).
        var backupReminderDays: Int?
        /// The home-screen icon (`AppIconChoice` raw value), where iOS can switch icons.
        var appIcon: String?

        init(quickCapture: (notebook: String, transcribe: Bool)? = nil, backupReminderDays: Int? = nil,
             appIcon: String? = nil) {
            self.quickCapture = quickCapture; self.backupReminderDays = backupReminderDays; self.appIcon = appIcon
        }

        static func == (a: Extras, b: Extras) -> Bool {
            a.quickCapture?.notebook == b.quickCapture?.notebook && a.quickCapture?.transcribe == b.quickCapture?.transcribe
                && a.backupReminderDays == b.backupReminderDays && a.appIcon == b.appIcon
        }
    }

    /// Keys whose values live outside `UserDefaults` (or need the model to act):
    /// `apply` returns them for the model instead of writing them.
    static let modelKeys: Set<String> = ["quickCapture.notebook", "quickCapture.transcribe", "backup.reminderDays",
                                         "handwriting.recognize", "search.transcripts", "appearance.icon"]

    /// This device's effective value of every setting a device of `type` uses,
    /// in the stored form of `SharedSettingSpec.validated`. A setting that cannot
    /// be read now (quick capture off for this vault) is left out, so it is
    /// neither taken for an edit nor seeded.
    static func values(for type: SettingsDeviceType, defaults: UserDefaults, extras: Extras) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for spec in SharedSettingsCatalog.specs(for: type) {
            guard let raw = read(spec.name, defaults: defaults, extras: extras), let v = spec.validated(raw) else { continue }
            out[spec.name] = v
        }
        return out
    }

    static func read(_ key: String, defaults d: UserDefaults, extras: Extras) -> JSONValue? {
        switch key {
        case "handwriting.recognize": return .bool(RecognitionPreference.isEnabled(d))
        case "newNote.titleFormat": return .string(NewNoteSettings.titleFormat(d).rawValue)
        case "newNote.titlePattern": return .string(NewNoteSettings.titlePattern(d))
        case "editor.defaultPaper": return try? JSONValue(encoding: PaperPreference.load(from: d))
        case "editor.defaultLayout": return .string(NewNoteLayout.load(from: d).rawValue)
        case "editor.compactPalette": return .bool(d.bool(forKey: ToolPalette.compactKey))
        case "eraser.mode":
            // `EraserPreference` stores PencilKit's type names; any pixel eraser is "pixel".
            let name = d.string(forKey: EraserPreference.defaultsKey) ?? "object"
            return .string(name == "pixel" || name == "pixelFixedWidth" ? "pixel" : "object")
        case "eraser.objectRadius": return .number(ObjectEraserSize.load(from: d))
        case "recording.codec": return .string(RecordingSettings.load(from: d).codec.rawValue)
        case "recording.bitRate": return .number(Double(RecordingSettings.load(from: d).bitRate))
        case "recording.sampleRate": return .number(Double(RecordingSettings.load(from: d).sampleRate))
        case "recording.channels": return .number(Double(RecordingSettings.load(from: d).channels.rawValue))
        case "transcription.enabled": return .bool(TranscriptionSettings.isEnabled(d))
        case "transcription.language": return TranscriptionSettings.localeIdentifier(d).map { .string($0) } ?? .null
        case "math.recognize": return .bool(MathRecognitionPreference.isEnabled(d))
        case "photos.removeMetadata": return .bool(d.object(forKey: photoPrivacyKey) as? Bool ?? true)
        case "history.thinAfterDays":
            guard let n = d.object(forKey: ThinningPreference.key) as? Int else { return .number(Double(ThinningPreference.defaultDays)) }
            return .number(Double(n <= 0 ? 0 : n))
        case "search.transcripts": return .bool(TranscriptSearchPreference.isOn(d))
        case "rewrap.onAdd": return .string(RewrapSettings.onAdd(d).rawValue)
        case "rewrap.onRemove": return .string(RewrapSettings.onRemoveOrUpgrade(d).rawValue)
        case "backup.reminderDays": return extras.backupReminderDays.map { .number(Double($0)) }
        case "editor.keepScreenOn": return .bool(KeepScreenOn.isOn(d))
        case "mouse.smoothing": return .string(d.string(forKey: MouseSmoothing.key).flatMap(StrokeSmoothing.Level.init(rawValue:))?.rawValue
                                               ?? MouseSmoothing.defaultLevel.rawValue)
        case "quickCapture.notebook": return extras.quickCapture.map { .string($0.notebook) }
        case "quickCapture.transcribe": return extras.quickCapture.map { .bool($0.transcribe) }
        case "appearance.icon": return extras.appIcon.map { .string($0) }
        default: return nil
        }
    }

    /// `PhotoPrivacy.key` (ImagePreparation.swift, which needs UIKit).
    static let photoPrivacyKey = "Sempere.photoPrivacy"

    /// Writes `values` (validated by the caller) to `UserDefaults`; returns the
    /// ones in `modelKeys`, for the model to apply.
    @discardableResult
    static func apply(_ values: [String: JSONValue], defaults d: UserDefaults) -> [String: JSONValue] {
        var forModel: [String: JSONValue] = [:]
        // The recording fields are clamped together (a bit rate depends on the codec).
        var recording = RecordingSettings.load(from: d)
        var recordingChanged = false
        for (key, value) in values {
            if modelKeys.contains(key) { forModel[key] = value; continue }
            switch (key, value) {
            case ("newNote.titleFormat", .string(let s)):
                if let f = NewNoteSettings.TitleFormat(rawValue: s) { NewNoteSettings.setTitleFormat(f, in: d) }
            case ("newNote.titlePattern", .string(let s)): NewNoteSettings.setTitlePattern(s, in: d)
            case ("editor.defaultPaper", _): if let p = try? value.decode(Paper.self) { PaperPreference.save(p, to: d) }
            case ("editor.defaultLayout", .string(let s)): if let l = NewNoteLayout(rawValue: s) { NewNoteLayout.save(l, to: d) }
            case ("editor.compactPalette", .bool(let b)): d.set(b, forKey: ToolPalette.compactKey)
            case ("eraser.mode", .string(let s)): d.set(s == "pixel" ? "pixelFixedWidth" : "object", forKey: EraserPreference.defaultsKey)
            case ("eraser.objectRadius", .number(let r)): ObjectEraserSize.save(r, to: d)
            case ("recording.codec", .string(let s)):
                if let c = RecordingSettings.Codec(rawValue: s) { recording.codec = c; recordingChanged = true }
            case ("recording.bitRate", .number(let n)): recording.bitRate = Int(n); recordingChanged = true
            case ("recording.sampleRate", .number(let n)): recording.sampleRate = Int(n); recordingChanged = true
            case ("recording.channels", .number(let n)):
                if let c = RecordingSettings.Channels(rawValue: Int(n)) { recording.channels = c; recordingChanged = true }
            case ("transcription.enabled", .bool(let b)): TranscriptionSettings.setEnabled(b, in: d)
            case ("transcription.language", .string(let s)): TranscriptionSettings.setLocaleIdentifier(s, in: d)
            case ("transcription.language", .null): TranscriptionSettings.setLocaleIdentifier(nil, in: d)
            case ("math.recognize", .bool(let b)): d.set(b, forKey: MathRecognitionPreference.key)
            case ("photos.removeMetadata", .bool(let b)): d.set(b, forKey: photoPrivacyKey)
            case ("history.thinAfterDays", .number(let n)): d.set(max(Int(n), 0), forKey: ThinningPreference.key)
            case ("rewrap.onAdd", .string(let s)): if let m = RewrapMethod(rawValue: s) { RewrapSettings.setOnAdd(m, in: d) }
            case ("rewrap.onRemove", .string(let s)): if let m = RewrapMethod(rawValue: s) { RewrapSettings.setOnRemoveOrUpgrade(m, in: d) }
            case ("editor.keepScreenOn", .bool(let b)): d.set(b, forKey: KeepScreenOn.key)
            case ("mouse.smoothing", .string(let s)): d.set(s, forKey: MouseSmoothing.key)
            default: break
            }
        }
        if recordingChanged { recording.save(to: d) }
        return forModel
    }
}
