import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Settings sync's mapping in the app (docs/settings-sync.md): `AppSettingsStorage` through
/// `SettingsSyncBridge` against `UserDefaults`. The model's passes are tested on Linux
/// (`SettingsSyncTests`, SempereAppCoreTests), and so are the rules (`SettingsSyncStateTests`, `SharedSettingsTests`).
@MainActor
@Suite(.serialized)
struct SettingsSyncAppTests {
    /// A defaults suite of its own.
    final class Scratch {
        let name = "sempere-settings-sync-tests-\(UUID().uuidString)"
        lazy var defaults = TestDefaults.suite(name)!
        func cleanUp() { defaults.removePersistentDomain(forName: name) }
    }

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
        }
    }

    // MARK: - Bridge

    @Test func everyUserDefaultsKeyRoundTrips() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        for type in SettingsDeviceType.allCases {
            let specs = SharedSettingsCatalog.specs(for: type).filter { !SettingsSyncBridge.modelKeys.contains($0.name) }
            let before = SettingsSyncBridge.values(for: type, defaults: scratch.defaults, extras: .init())
            for spec in specs {
                #expect(before[spec.name] == spec.defaultValue, "\(spec.name) default")
            }
            var wanted: [String: JSONValue] = [:]
            for spec in specs { wanted[spec.name] = try #require(spec.validated(Self.otherValue(spec))) }
            // Quality: HE-AAC offers no 24 kbit/s step above 64, so pick a rate both codecs offer.
            wanted["recording.bitRate"] = .number(32_000)
            // Sample rate: HE-AAC offers 32 kHz and up, so pick a rate both codecs offer.
            wanted["recording.sampleRate"] = .number(44_100)
            let leftover = SettingsSyncBridge.apply(wanted, defaults: scratch.defaults)
            #expect(leftover.isEmpty)
            let after = SettingsSyncBridge.values(for: type, defaults: scratch.defaults, extras: .init())
            for spec in specs { #expect(after[spec.name] == wanted[spec.name], "\(spec.name) on \(type)") }
            scratch.cleanUp()
        }
    }

    @Test func modelKeysAndExtras() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let none = SettingsSyncBridge.values(for: .ipad, defaults: scratch.defaults, extras: .init())
        #expect(none["quickCapture.notebook"] == nil, "quick capture off: not read")
        #expect(none["backup.reminderDays"] == nil)
        let extras = SettingsSyncBridge.Extras(quickCapture: (notebook: "Inbox/Voice", transcribe: false), backupReminderDays: 7)
        let some = SettingsSyncBridge.values(for: .ipad, defaults: scratch.defaults, extras: extras)
        #expect(some["quickCapture.notebook"] == .string("Inbox/Voice"))
        #expect(some["quickCapture.transcribe"] == .bool(false))
        #expect(some["backup.reminderDays"] == .number(7))
        #expect(SettingsSyncBridge.values(for: .mac, defaults: scratch.defaults, extras: extras)["quickCapture.notebook"]
                == .string("Inbox/Voice"), "a Mac has Quick Voice Notes too")
        #expect(SettingsSyncBridge.values(for: .mac, defaults: scratch.defaults, extras: extras)["editor.keepScreenOn"] == nil,
                "a Mac has no Keep Screen On")
        let forModel = SettingsSyncBridge.apply(["handwriting.recognize": .bool(false), "eraser.mode": .string("pixel")],
                                                defaults: scratch.defaults)
        #expect(forModel == ["handwriting.recognize": .bool(false)])
        #expect(scratch.defaults.string(forKey: EraserPreference.defaultsKey) == "pixelFixedWidth")
    }
}
