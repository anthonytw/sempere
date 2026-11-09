import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The Settings panel (docs/attachments.md §15): the behavior each setting drives.
    /// Their defaults, choices and storage: `DeviceSettingsTests` (SempereAppCoreTests).
    @MainActor
    @Suite(.serialized)
    struct SettingsTests {
        /// An empty store.
        func scratch() -> MemoryKeyValueStore { MemoryKeyValueStore() }

        // MARK: General and history

        @Test func generalSettingsKeepTheirKeysAndDefaults() {
            #expect(KeepScreenOn.key == "Sempere.keepScreenOn")
            #expect(RecognitionPreference.key == "Sempere.recognizeHandwriting")
            // What the app reads when nothing is stored, then a stored choice.
            let d = scratch()
            #expect(!KeepScreenOn.defaultValue && !KeepScreenOn.isOn(d), "off unless set")
            #expect(RecognitionPreference.defaultValue && RecognitionPreference.isEnabled(d), "on unless set")
            d.set(true, forKey: KeepScreenOn.key)
            d.set(false, forKey: RecognitionPreference.key)
            #expect(KeepScreenOn.isOn(d))
            #expect(!RecognitionPreference.isEnabled(d))
        }

        // MARK: Storage

        @Test func storageNeedsAnUnlockedVault() async throws {
            let model = AppModel(deviceStateURL: TS.deviceStateURL())
            await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.deleteUnusedAttachments([]) }
            #expect(model.attachmentStorage().unused.isEmpty)
            // Unused attachments themselves: `AttachmentIndexAppTests`.
        }
    }
}
