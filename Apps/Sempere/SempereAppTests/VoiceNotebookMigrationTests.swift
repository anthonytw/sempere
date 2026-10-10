import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The notebook of quick voice notes is one setting, the capture profile's
/// (Settings ▸ Quick Voice Notes). A value an older build kept in Settings ▸
/// New Notes under `LegacyVoiceNotebook.key`, which capture never read, is
/// carried over once and removed.
@Suite(.serialized)
@MainActor
struct VoiceNotebookMigrationTests {
    func scratch() -> UserDefaults {
        let name = "sempere-voice-notebook-tests"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func model(notebook: String?) throws -> (AppModel, MemoryCaptureProfileStore) {
        let store = MemoryCaptureProfileStore()
        if let notebook {
            let profile = CaptureProfile(vaultId: UUID(), recipients: [], key: Data(count: 32), device: "0badf00d",
                                         notebook: notebook)
            try store.save(StoredCaptureProfile(profile: profile, vaultName: "v", bookmark: Data(), transcribe: true))
        }
        let qc = QuickCapture()
        qc.store = store
        qc.showsActivity = false
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = qc
        return (model, store)
    }

    @Test func legacyValueIsCanonicalAndBlankIsNone() {
        let d = scratch()
        #expect(LegacyVoiceNotebook.value(d) == nil)
        d.set(" School // Audio ", forKey: LegacyVoiceNotebook.key)
        #expect(LegacyVoiceNotebook.value(d) == "School/Audio")
        d.set(" / ", forKey: LegacyVoiceNotebook.key)
        #expect(LegacyVoiceNotebook.value(d) == nil)
        LegacyVoiceNotebook.remove(from: d)
        #expect(d.object(forKey: LegacyVoiceNotebook.key) == nil)
    }

    @Test func anUntouchedProfileTakesTheOldValueAndTheKeyGoes() throws {
        let d = scratch()
        d.set("School/Audio", forKey: LegacyVoiceNotebook.key)
        let (model, store) = try model(notebook: CaptureProfile.defaultNotebook)
        model.migrateLegacyVoiceNotebook(defaults: d)
        #expect(try store.load()?.profile.notebook == "School/Audio")
        #expect(d.object(forKey: LegacyVoiceNotebook.key) == nil)
        model.migrateLegacyVoiceNotebook(defaults: d)   // idempotent
        #expect(try store.load()?.profile.notebook == "School/Audio")
    }

    @Test func aProfileTheUserChangedWinsOverTheOldValue() throws {
        let d = scratch()
        d.set("School/Audio", forKey: LegacyVoiceNotebook.key)
        let (model, store) = try model(notebook: "Lectures")
        model.migrateLegacyVoiceNotebook(defaults: d)
        #expect(try store.load()?.profile.notebook == "Lectures")
        #expect(d.object(forKey: LegacyVoiceNotebook.key) == nil)
    }

    @Test func withoutAProfileTheOldValueWaitsForTurningCaptureOn() throws {
        let d = scratch()
        d.set("School/Audio", forKey: LegacyVoiceNotebook.key)
        let (model, store) = try model(notebook: nil)
        model.migrateLegacyVoiceNotebook(defaults: d)
        #expect(try store.load() == nil)
        #expect(LegacyVoiceNotebook.value(d) == "School/Audio", "kept until a profile exists")
    }

    @Test func turningCaptureOnUsesTheOldValueOnceThenTheGivenNotebook() async throws {
        let d = scratch()
        d.set("School/Audio", forKey: LegacyVoiceNotebook.key)
        let (url, key) = try AppModelTests.fixtureVault()
        let (model, store) = try model(notebook: nil)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try model.enableQuickCapture(defaults: d)
        #expect(try store.load()?.profile.notebook == "School/Audio")
        #expect(d.object(forKey: LegacyVoiceNotebook.key) == nil)
        try model.enableQuickCapture(notebook: "Inbox", defaults: d)
        #expect(try store.load()?.profile.notebook == "Inbox", "an explicit notebook is used as given")
        model.close()
    }
}
