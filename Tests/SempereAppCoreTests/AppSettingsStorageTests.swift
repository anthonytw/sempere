import Foundation
import Sempere
import Testing
@testable import SempereAppCore

/// Settings sync's mapping (docs/settings-sync.md): `AppSettingsStorage` through
/// `SettingsSyncBridge` against a `MemoryKeyValueStore` (the app's `UserDefaults` is the same protocol). The model's passes are tested on Linux
/// (`SettingsSyncTests`, SempereAppCoreTests), and so are the rules (`SettingsSyncStateTests`, `SharedSettingsTests`).
struct AppSettingsStorageTests {
    /// A value of `spec` other than its default.
    static func otherValue(_ spec: SharedSettingSpec) -> JSONValue {
        switch spec.kind {
        case .bool: return .bool(spec.defaultValue != .bool(true))
        case .choice(let names): return .string(names.first { .string($0) != spec.defaultValue } ?? names[0])
        case .integer(let values): return .number(Double(values.first { .number(Double($0)) != spec.defaultValue } ?? values[0]))
        case .titlePattern: return .string("'Lecture' d MMM")
        case .notebook: return .string("Work/Meetings")
        case .paper: return (try? JSONValue(encoding: Paper(kind: .grid, spacing: 20))) ?? .null
        case .localeOrNull: return .string("es_ES")
        case .deviceIdOrNull: return .string("a1b2c3d4")
        case .revisionPins: return .object(["en": .number(1)])
        case .voiceTitleFormat: return .string("{slug} {date}")
        }
    }

    // MARK: - Bridge

    @Test func everyStoredKeyRoundTrips() throws {
        for type in SettingsDeviceType.allCases {
            let defaults = MemoryKeyValueStore()   // a fresh device per type
            let specs = SharedSettingsCatalog.specs(for: type).filter { !SettingsSyncBridge.modelKeys.contains($0.name) }
            let before = SettingsSyncBridge.values(for: type, defaults: defaults, extras: .init())
            for spec in specs {
                #expect(before[spec.name] == spec.defaultValue, "\(spec.name) default")
            }
            var wanted: [String: JSONValue] = [:]
            for spec in specs { wanted[spec.name] = try #require(spec.validated(Self.otherValue(spec))) }
            // Quality: HE-AAC offers no 24 kbit/s step above 64, so pick a rate both codecs offer.
            wanted["recording.bitRate"] = .number(32_000)
            // Sample rate: HE-AAC offers 32 kHz and up, so pick a rate both codecs offer.
            wanted["recording.sampleRate"] = .number(44_100)
            let leftover = SettingsSyncBridge.apply(wanted, defaults: defaults)
            #expect(leftover.isEmpty)
            let after = SettingsSyncBridge.values(for: type, defaults: defaults, extras: .init())
            for spec in specs { #expect(after[spec.name] == wanted[spec.name], "\(spec.name) on \(type)") }
        }
    }

    @Test func modelKeysAndExtras() throws {
        let defaults = MemoryKeyValueStore()
        let none = SettingsSyncBridge.values(for: .ipad, defaults: defaults, extras: .init())
        #expect(none["quickCapture.notebook"] == nil, "quick capture off: not read")
        #expect(none["backup.reminderDays"] == nil)
        let extras = SettingsSyncBridge.Extras(quickCapture: (notebook: "Inbox/Voice", transcribe: false), backupReminderDays: 7)
        let some = SettingsSyncBridge.values(for: .ipad, defaults: defaults, extras: extras)
        #expect(some["quickCapture.notebook"] == .string("Inbox/Voice"))
        #expect(some["quickCapture.transcribe"] == .bool(false))
        #expect(some["backup.reminderDays"] == .number(7))
        #expect(SettingsSyncBridge.values(for: .mac, defaults: defaults, extras: extras)["quickCapture.notebook"]
                == .string("Inbox/Voice"), "a Mac has Quick Voice Notes too")
        #expect(SettingsSyncBridge.values(for: .mac, defaults: defaults, extras: extras)["editor.keepScreenOn"] == nil,
                "a Mac has no Keep Screen On")
        let forModel = SettingsSyncBridge.apply(["handwriting.recognize": .bool(false), "eraser.mode": .string("pixel")],
                                                defaults: defaults)
        #expect(forModel == ["handwriting.recognize": .bool(false)])
        #expect(defaults.string(forKey: EraserModeStorage.key) == "pixelFixedWidth")
    }
}
