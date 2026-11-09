import Foundation
import Sempere

/// Where an app keeps each shared setting that is not the model's (docs/settings-sync.md §5,
/// `SharedSettingsCatalog`; `SettingsSyncBridge` in SempereAppCore reads the model's own keys): `UserDefaults`
/// through the settings' own types, so every value is read with its default filled in and written through the same
/// clamping as the Settings screen. The logic of sync is `SettingsSyncState` (Sempere) and the model's
/// (`AppModel+SettingsSync`, SempereAppCore); this only reads and writes values.
public struct AppSettingsStorage: SettingsSyncStorage {
    public init() {}

    public func read(_ key: String, from d: any KeyValueStore) -> JSONValue? {
        switch key {
        case "newNote.titleFormat": return .string(NewNoteSettings.titleFormat(d).rawValue)
        case "newNote.titlePattern": return .string(NewNoteSettings.titlePattern(d))
        case "editor.defaultPaper": return try? JSONValue(encoding: PaperPreference.load(from: d))
        case "editor.defaultLayout": return .string(NewNoteLayout.load(from: d).rawValue)
        case "editor.compactPalette": return .bool(d.bool(forKey: ToolPalette.compactKey))
        case "eraser.mode": return .string(EraserModeStorage.syncedName(from: d))
        case "eraser.objectRadius": return .number(ObjectEraserSize.load(from: d))
        case "recording.codec": return .string(RecordingSettings.load(from: d).codec.rawValue)
        case "recording.bitRate": return .number(Double(RecordingSettings.load(from: d).bitRate))
        case "recording.sampleRate": return .number(Double(RecordingSettings.load(from: d).sampleRate))
        case "recording.channels": return .number(Double(RecordingSettings.load(from: d).channels.rawValue))
        case "transcription.enabled": return .bool(TranscriptionSettings.isEnabled(d))
        case "transcription.language": return TranscriptionSettings.localeIdentifier(d).map { .string($0) } ?? .null
        case "math.recognize": return .bool(MathRecognitionPreference.isEnabled(d))
        case "photos.removeMetadata": return .bool(PhotoPrivacy.isOn(d))
        case "history.thinAfterDays":
            guard let n = d.object(forKey: ThinningPreference.key) as? Int else { return .number(Double(ThinningPreference.defaultDays)) }
            return .number(Double(n <= 0 ? 0 : n))
        case "editor.keepScreenOn": return .bool(KeepScreenOn.isOn(d))
        case "mouse.smoothing": return .string(d.string(forKey: MouseSmoothing.key).flatMap(StrokeSmoothing.Level.init(rawValue:))?.rawValue
                                               ?? MouseSmoothing.defaultLevel.rawValue)
        case "appearance.theme": return .string(AppTheme.load(from: d).rawValue)
        case "appearance.notePages": return .string(NotePagesAppearance.load(from: d).rawValue)
        case "drag.format": return .string(DragExportFormat.load(from: d).rawValue)
        default: return nil
        }
    }

    public func write(_ values: [String: JSONValue], to d: any KeyValueStore) {
        // The recording fields are clamped together (a bit rate depends on the codec).
        var recording = RecordingSettings.load(from: d)
        var recordingChanged = false
        for (key, value) in values {
            switch (key, value) {
            case ("newNote.titleFormat", .string(let s)):
                if let f = NewNoteSettings.TitleFormat(rawValue: s) { NewNoteSettings.setTitleFormat(f, in: d) }
            case ("newNote.titlePattern", .string(let s)): NewNoteSettings.setTitlePattern(s, in: d)
            case ("editor.defaultPaper", _): if let p = try? value.decode(Paper.self) { PaperPreference.save(p, to: d) }
            case ("editor.defaultLayout", .string(let s)): if let l = NewNoteLayout(rawValue: s) { NewNoteLayout.save(l, to: d) }
            case ("editor.compactPalette", .bool(let b)): d.set(b, forKey: ToolPalette.compactKey)
            case ("eraser.mode", .string(let s)): EraserModeStorage.store(syncedName: s, in: d)
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
            case ("photos.removeMetadata", .bool(let b)): d.set(b, forKey: PhotoPrivacy.key)
            case ("history.thinAfterDays", .number(let n)): d.set(max(Int(n), 0), forKey: ThinningPreference.key)
            case ("editor.keepScreenOn", .bool(let b)): d.set(b, forKey: KeepScreenOn.key)
            case ("mouse.smoothing", .string(let s)): d.set(s, forKey: MouseSmoothing.key)
            case ("appearance.theme", .string(let s)): if let t = AppTheme(rawValue: s) { AppTheme.save(t, to: d) }
            case ("appearance.notePages", .string(let s)):
                if let p = NotePagesAppearance(rawValue: s) { NotePagesAppearance.save(p, to: d) }
            case ("drag.format", .string(let s)): if let f = DragExportFormat(rawValue: s) { DragExportFormat.save(f, to: d) }
            default: break
            }
        }
        if recordingChanged { recording.save(to: d) }
    }
}

extension SettingsSyncBridge {
    /// The values of the settings a device of `type` uses (`AppSettingsStorage`).
    public static func values(for type: SettingsDeviceType, defaults: any KeyValueStore, extras: Extras) -> [String: JSONValue] {
        values(for: type, defaults: defaults, extras: extras, storage: AppSettingsStorage())
    }

    /// Writes `values` through `AppSettingsStorage`; returns the model's keys.
    @discardableResult
    public static func apply(_ values: [String: JSONValue], defaults: any KeyValueStore) -> [String: JSONValue] {
        apply(values, defaults: defaults, storage: AppSettingsStorage())
    }
}
