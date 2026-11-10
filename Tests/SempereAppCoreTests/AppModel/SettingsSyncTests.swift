import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// Records the notifications the model asked for.
@MainActor
final class RecordingNotifier: BackupNotifying {
    private(set) var scheduled: [String: (date: Date, notice: LocalNotice)] = [:]
    /// Whether the permission is already given, and the times the system's prompt was asked for.
    var allowed = true
    private(set) var prompts = 0
    func authorize() async -> Bool { prompts += 1; return allowed }
    func isAuthorized() async -> Bool { allowed }
    func schedule(id: String, at date: Date, notice: LocalNotice) async { scheduled[id] = (date, notice) }
    func cancel(id: String) async { scheduled[id] = nil }
}

extension AppModelSuites {
    /// Settings sync through the vault (`AppModel+SettingsSync`, docs/settings-sync.md; wave 5b part 3, moved from
    /// the app's `AppSettingsStorageTests`, which keeps the app's `UserDefaults` mapping): the model's passes against a
    /// copy of the fixture vault, this device's values in memory (`StoredSettingsSyncStorage`). The rules themselves
    /// are `SettingsSyncStateTests` and `SharedSettingsTests` (SempereTests).
    @MainActor
    struct SettingsSyncTests {
        let settings = MemoryKeyValueStore()
        let storage = StoredSettingsSyncStorage()

        func set(_ key: String, _ value: JSONValue) { storage.write([key: value], to: settings) }
        func local(_ key: String) -> JSONValue? { storage.read(key, from: settings) }

        /// The fixture vault, unlocked, syncing settings from `settings` as an iPad.
        func model(platform: HeadlessPlatform = HeadlessPlatform(),
                   notifier: (any BackupNotifying)? = nil) async throws -> (AppModel, Vault, URL) {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless(settings: settings)
            services.platform = platform
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), backupNotifier: notifier, services: services)
            model.settingsDeviceTypeOverride = .ipad
            model.settingsSyncDebounce = .milliseconds(10)
            try await model.openVault(at: url)
            let text = try await ModelFixture.keyText(key)
            try await model.unlock(identityText: text)
            let vault = try await Self.open(url, try IdentityFile.parse(text))
            return (model, vault, url)
        }

        @concurrent static func open(_ url: URL, _ identity: NativeIdentity) async throws -> Vault {
            try Vault.open(at: url, identities: [identity])
        }

        @Test func deviceTypes() {
            #expect(SettingsSyncBridge.deviceType(isMac: true, isPhone: false) == .mac)
            #expect(SettingsSyncBridge.deviceType(isMac: false, isPhone: true) == .iphone)
            #expect(SettingsSyncBridge.deviceType(isMac: false, isPhone: false) == .ipad)
        }

        /// The model's keys are read here, the rest from the storage; `apply` hands the model's back.
        @Test func theBridgeSplitsTheModelsKeysFromTheStorages() {
            let none = SettingsSyncBridge.values(for: .ipad, defaults: settings, extras: .init(), storage: storage)
            #expect(none["quickCapture.notebook"] == nil, "quick capture off: not read")
            #expect(none["backup.reminderDays"] == nil)
            #expect(none["appearance.icon"] == nil, "no icons to switch")
            #expect(none["handwriting.recognize"] == .bool(true), "on unless set")
            #expect(none["newNote.titleFormat"] == SharedSettingsCatalog.spec(named: "newNote.titleFormat")?.defaultValue)
            let extras = SettingsSyncBridge.Extras(quickCapture: (notebook: "Inbox/Voice", transcribe: false),
                                                   backupReminderDays: 7)
            let some = SettingsSyncBridge.values(for: .ipad, defaults: settings, extras: extras, storage: storage)
            #expect(some["quickCapture.notebook"] == .string("Inbox/Voice"))
            #expect(some["quickCapture.transcribe"] == .bool(false))
            #expect(some["backup.reminderDays"] == .number(7))
            let forModel = SettingsSyncBridge.apply(["handwriting.recognize": .bool(false), "eraser.mode": .string("pixel")],
                                                    defaults: settings, storage: storage)
            #expect(forModel == ["handwriting.recognize": .bool(false)])
            #expect(local("eraser.mode") == .string("pixel"))
        }

        @Test func firstEnableSeedsAnEmptyVaultAndLocalEditsSync() async throws {
            set("photos.removeMetadata", .bool(false))
            let (model, vault, _) = try await model()
            #expect(try vault.readSharedSettings() == nil)
            await model.setSettingsSync(true)
            #expect(model.settingsSync.enabled)
            #expect(model.settingsSyncPrompt == nil)
            let written = try #require(try vault.readSharedSettings())
            #expect(written.value(SettingSlotKey("photos.removeMetadata")) == .bool(false))
            #expect(written.slots[SettingSlotKey("photos.removeMetadata")]?.meta?.type == "ipad")
            #expect(written.value(SettingSlotKey("mouse.smoothing")) == nil, "an iPad does not write what only Macs use")

            // An edit here reaches the file.
            set("history.thinAfterDays", .number(90))
            await model.syncSettingsNow()
            #expect(try vault.readSharedSettings()?.value(SettingSlotKey("history.thinAfterDays")) == .number(90))
            // The state is kept for the vault.
            #expect(AppModel.loadSettingsSyncState(settings, vaultId: vault.vaultId).enabled)
        }

        /// A change to the settings store schedules a pass by itself (`settingsDefaultsChanged`, the store's
        /// observation), after the debounce.
        @Test func aLocalChangeIsSyncedWithoutBeingAskedFor() async throws {
            let (model, vault, _) = try await model()
            await model.setSettingsSync(true)
            set("history.thinAfterDays", .number(90))   // one of the choices (45 is not)
            #expect(await TS.waitUntil(timeout: .seconds(60)) {
                (try? vault.readSharedSettings())??.value(SettingSlotKey("history.thinAfterDays")) == .number(90)
            })
        }

        @Test func remoteChangesApplyUnlessOverridden() async throws {
            let (model, vault, _) = try await model()
            await model.setSettingsSync(true)
            let revision = model.settingsAppliedRevision

            // Another device changes two settings.
            try vault.updateSharedSettings { s in
                try s.set(SettingSlotKey("newNote.titleFormat"), to: .string("weekday"), type: .mac, now: Date().addingTimeInterval(5))
                try s.set(SettingSlotKey("recording.codec"), to: .string("alac"), type: .mac, now: Date().addingTimeInterval(5))
            }
            let codec = local("recording.codec")
            model.overrideSetting("recording.codec")
            #expect(model.settingsSync.rowState("recording.codec", type: .ipad) == .overridden)
            await model.syncSettingsNow()
            #expect(local("newNote.titleFormat") == .string("weekday"))
            #expect(local("recording.codec") == codec, "overridden: kept")
            #expect(model.settingsAppliedRevision > revision)

            // Use Synced Value relinks it.
            await model.useSyncedSetting("recording.codec")
            #expect(local("recording.codec") == .string("alac"))
            #expect(model.settingsSync.rowState("recording.codec", type: .ipad) == .synced)
        }

        @Test func firstEnableAsksWhenTheVaultDiffers() async throws {
            let (model, vault, _) = try await model()
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
            #expect(local("eraser.objectRadius") == .number(32))

            // Off and on again, replacing the vault's.
            await model.setSettingsSync(false)
            set("eraser.objectRadius", .number(4))
            await model.setSettingsSync(true)
            await model.answerSettingsSyncPrompt(.replaceVault)
            #expect(try vault.readSharedSettings()?.value(SettingSlotKey("eraser.objectRadius")) == .number(4))
        }

        @Test func aFileForANewerAppPausesSyncAndIsNeverWritten() async throws {
            let (model, vault, _) = try await model()
            await model.setSettingsSync(true)
            var later = SharedSettings(schemaVersion: 9, minReaderVersion: 9)
            later.slots[SettingSlotKey("newNote.titleFormat")] = SettingSlot(value: .string("weekday"), meta: nil)
            try vault.writeSharedSettings(later)
            let bytes = try Data(contentsOf: vault.sharedSettingsURL)
            let format = local("newNote.titleFormat")

            set("history.thinAfterDays", .number(7))
            await model.syncSettingsNow()
            #expect(model.settingsSyncProblem == .needsNewerApp)
            #expect(try Data(contentsOf: vault.sharedSettingsURL) == bytes)
            #expect(local("newNote.titleFormat") == format, "nothing applied")
            #expect(local("history.thinAfterDays") == .number(7), "local values stay")
        }

        @Test func typeBlocksFromTheRowMenu() async throws {
            let (model, vault, _) = try await model()
            await model.setSettingsSync(true)
            set("editor.compactPalette", .bool(true))
            await model.keepSettingForThisType("editor.compactPalette")
            let s = try #require(try vault.readSharedSettings())
            #expect(s.value(SettingSlotKey("editor.compactPalette", type: .ipad)) == .bool(true))
            #expect(model.settingsSync.rowState("editor.compactPalette", type: .ipad) == .typeSpecific)
            await model.useSettingOnAllDevices("editor.compactPalette")
            #expect(local("editor.compactPalette") == .bool(false), "the top level applies again")
            #expect(model.settingsSync.rowState("editor.compactPalette", type: .ipad) == .synced)
        }

        /// The keys the model applies itself: recognition and transcript search into the store (and the model),
        /// the icon through the platform, the backup reminder through the notifier, the voice notes' notebook into
        /// the quick-capture profile.
        @Test func theModelsKeysApplyThroughTheModel() async throws {
            let platform = HeadlessPlatform(appIcon: "keyholeNib")
            let notifier = RecordingNotifier()
            let (model, vault, url) = try await model(platform: platform, notifier: notifier)
            model.recognizer = FakeRecognizer()
            let device = try model.deviceClockForWriting().device
            let profile = try vault.captureProfile(device: device)
            try model.quickCapture.store.save(StoredCaptureProfile(profile: profile, vaultName: "sample",
                                                                   transcribe: true))
            #expect(model.currentSettingsValues()["appearance.icon"] == .string("keyholeNib"))
            model.applySharedSettings(["handwriting.recognize": .bool(false), "search.transcripts": .bool(false),
                                       "appearance.icon": .string("inkWind"), "backup.reminderDays": .number(7),
                                       "quickCapture.notebook": .string("Voice/Inbox"),
                                       "quickCapture.transcribe": .bool(false)])
            #expect(RecognitionPreference.isEnabled(settings) == false)
            #expect(model.recognizer == nil)
            #expect(TranscriptSearchPreference.isOn(settings) == false && !model.searchTranscripts)
            #expect(platform.appIcon == "inkWind")
            let stored = try #require(try model.storedQuickCaptureProfile())
            #expect(stored.profile.notebook == "Voice/Inbox")
            #expect(stored.transcribe == false)
            let id = BackupReminder.identifier(vault.vaultId)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { notifier.scheduled[id] != nil })
            guard case .backupReminder(let name, let record)? = notifier.scheduled[id]?.notice else {
                Issue.record("no reminder"); return
            }
            #expect(name == "sample" && record.reminderDays == 7)
            #expect(model.currentSettingsValues()["quickCapture.notebook"] == .string("Voice/Inbox"))
            #expect(notifier.prompts == 0, "a setting from another device never asks for permission")
        }

        /// A reminder switched on by another device's synced setting stays quiet where notifications are not allowed,
        /// and asks nothing (the permission prompt belongs to the user's own Remind Me).
        @Test func aSyncedReminderNeverPromptsWhereNotificationsAreOff() async throws {
            let notifier = RecordingNotifier()
            notifier.allowed = false
            let (model, _, _) = try await model(notifier: notifier)
            defer { model.close() }
            model.applySharedSettings(["backup.reminderDays": .number(7)])
            #expect(await TS.waitUntil(timeout: .seconds(30)) { model.backupRecord()?.reminderDays == 7 })
            #expect(notifier.prompts == 0)
            // The user's own switch is the one that asks.
            #expect(await model.setBackupReminder(days: 3) == false)
            #expect(notifier.prompts == 1)
        }
    }
}
