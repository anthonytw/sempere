import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Settings sync through the vault in the app (docs/settings-sync.md):
/// `SettingsSyncBridge` against `UserDefaults`, and the model's passes against
/// a copy of the fixture vault. The rules themselves are tested on Linux
/// (`SettingsSyncStateTests`, `SharedSettingsTests`).
@MainActor
@Suite(.serialized)
struct SettingsSyncAppTests {
    /// A defaults suite of its own.
    final class Scratch {
        let name = "sempere-settings-sync-tests-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: name)!
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
        #expect(SettingsSyncBridge.values(for: .mac, defaults: scratch.defaults, extras: extras)["quickCapture.notebook"] == nil,
                "a Mac does not use quick capture")
        let forModel = SettingsSyncBridge.apply(["handwriting.recognize": .bool(false), "eraser.mode": .string("pixel")],
                                                defaults: scratch.defaults)
        #expect(forModel == ["handwriting.recognize": .bool(false)])
        #expect(scratch.defaults.string(forKey: EraserPreference.defaultsKey) == "pixelFixedWidth")
    }

    @Test func deviceTypes() {
        #expect(SettingsSyncBridge.deviceType(isMac: true, isPhone: false) == .mac)
        #expect(SettingsSyncBridge.deviceType(isMac: false, isPhone: true) == .iphone)
        #expect(SettingsSyncBridge.deviceType(isMac: false, isPhone: false) == .ipad)
    }

    // MARK: - The model

    /// The fixture vault, unlocked, syncing settings from a scratch suite as an iPad.
    func model(_ scratch: Scratch) async throws -> (AppModel, Vault, URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.settingsDefaults = scratch.defaults
        model.settingsDeviceTypeOverride = .ipad
        model.settingsSyncDebounce = .milliseconds(10)
        try await model.openVault(at: url)
        let text = try String(contentsOf: key, encoding: .utf8)
        try await model.unlock(identityText: text)
        let vault = try Vault.open(at: url, identities: [try IdentityFile.parse(text)])
        return (model, vault, url)
    }

    @Test func firstEnableSeedsAnEmptyVaultAndLocalEditsSync() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        scratch.defaults.set(false, forKey: SettingsSyncBridge.photoPrivacyKey)
        let (model, vault, _) = try await model(scratch)
        #expect(try vault.readSharedSettings() == nil)
        await model.setSettingsSync(true)
        #expect(model.settingsSync.enabled)
        #expect(model.settingsSyncPrompt == nil)
        let written = try #require(try vault.readSharedSettings())
        #expect(written.value(SettingSlotKey("photos.removeMetadata")) == .bool(false))
        #expect(written.slots[SettingSlotKey("photos.removeMetadata")]?.meta?.type == "ipad")
        #expect(written.value(SettingSlotKey("mouse.smoothing")) == nil, "an iPad does not write what only Macs use")

        // An edit here reaches the file.
        scratch.defaults.set(90, forKey: ThinningPreference.key)
        await model.syncSettingsNow()
        #expect(try vault.readSharedSettings()?.value(SettingSlotKey("history.thinAfterDays")) == .number(90))
        // The state is kept for the vault.
        #expect(AppModel.loadSettingsSyncState(scratch.defaults, vaultId: vault.vaultId).enabled)
    }

    @Test func remoteChangesApplyUnlessOverridden() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let (model, vault, _) = try await model(scratch)
        await model.setSettingsSync(true)
        let revision = model.settingsAppliedRevision

        // Another device changes two settings.
        try vault.updateSharedSettings { s in
            try s.set(SettingSlotKey("newNote.titleFormat"), to: .string("weekday"), type: .mac, now: Date().addingTimeInterval(5))
            try s.set(SettingSlotKey("recording.codec"), to: .string("alac"), type: .mac, now: Date().addingTimeInterval(5))
        }
        model.overrideSetting("recording.codec")
        #expect(model.settingsSync.rowState("recording.codec", type: .ipad) == .overridden)
        await model.syncSettingsNow()
        #expect(NewNoteSettings.titleFormat(scratch.defaults) == .weekday)
        #expect(RecordingSettings.load(from: scratch.defaults).codec == .aacLC, "overridden: kept")
        #expect(model.settingsAppliedRevision > revision)

        // Use Synced Value relinks it.
        await model.useSyncedSetting("recording.codec")
        #expect(RecordingSettings.load(from: scratch.defaults).codec == .appleLossless)
        #expect(model.settingsSync.rowState("recording.codec", type: .ipad) == .synced)
    }

    @Test func firstEnableAsksWhenTheVaultDiffers() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let (model, vault, _) = try await model(scratch)
        var other = SharedSettings()
        try other.set(SettingSlotKey("eraser.objectRadius"), to: .number(32), type: .mac, now: Date())
        try vault.writeSharedSettings(other)

        await model.setSettingsSync(true)
        let prompt = try #require(model.settingsSyncPrompt)
        #expect(prompt.differences.map(\.key) == ["eraser.objectRadius"])
        #expect(!model.settingsSync.enabled, "nothing changes until the user answers")
        await model.answerSettingsSyncPrompt(nil)
        #expect(!model.settingsSync.enabled)

        await model.setSettingsSync(true)
        await model.answerSettingsSyncPrompt(.useVault)
        #expect(model.settingsSync.enabled)
        #expect(ObjectEraserSize.load(from: scratch.defaults) == 32)

        // Off and on again, replacing the vault's.
        await model.setSettingsSync(false)
        scratch.defaults.set(4.0, forKey: ObjectEraserSize.defaultsKey)
        await model.setSettingsSync(true)
        await model.answerSettingsSyncPrompt(.replaceVault)
        #expect(try vault.readSharedSettings()?.value(SettingSlotKey("eraser.objectRadius")) == .number(4))
    }

    @Test func aFileForANewerAppPausesSyncAndIsNeverWritten() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let (model, vault, _) = try await model(scratch)
        await model.setSettingsSync(true)
        var later = SharedSettings(schemaVersion: 9, minReaderVersion: 9)
        later.slots[SettingSlotKey("newNote.titleFormat")] = SettingSlot(value: .string("weekday"), meta: nil)
        try vault.writeSharedSettings(later)
        let bytes = try Data(contentsOf: vault.sharedSettingsURL)

        scratch.defaults.set(7, forKey: ThinningPreference.key)
        await model.syncSettingsNow()
        #expect(model.settingsSyncProblem == .needsNewerApp)
        #expect(try Data(contentsOf: vault.sharedSettingsURL) == bytes)
        #expect(NewNoteSettings.titleFormat(scratch.defaults) == NewNoteSettings.defaultTitleFormat, "nothing applied")
        #expect(scratch.defaults.object(forKey: ThinningPreference.key) as? Int == 7, "local values stay")
    }

    @Test func typeBlocksFromTheRowMenu() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let (model, vault, _) = try await model(scratch)
        await model.setSettingsSync(true)
        scratch.defaults.set(true, forKey: ToolPalette.compactKey)
        await model.keepSettingForThisType("editor.compactPalette")
        let s = try #require(try vault.readSharedSettings())
        #expect(s.value(SettingSlotKey("editor.compactPalette", type: .ipad)) == .bool(true))
        #expect(model.settingsSync.rowState("editor.compactPalette", type: .ipad) == .typeSpecific)
        await model.useSettingOnAllDevices("editor.compactPalette")
        #expect(scratch.defaults.bool(forKey: ToolPalette.compactKey) == false, "the top level applies again")
        #expect(model.settingsSync.rowState("editor.compactPalette", type: .ipad) == .synced)
    }
}
