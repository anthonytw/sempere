import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// GA-64: Settings > Photos starts with the privacy setting on.
    @MainActor
    @Suite(.serialized)
    struct SettingsConfirmationTests {
        /// An empty store.
        func scratch() -> MemoryKeyValueStore { MemoryKeyValueStore() }

        // MARK: Photo privacy

        @Test func photoPrivacyStartsOnAndTheToggleAndTheStoreAgree() {
            // `@AppStorage(PhotoPrivacy.key) var photoPrivacy = PhotoPrivacy.defaultValue` and `isOn` read the same default.
            #expect(PhotoPrivacy.defaultValue)
            let d = scratch()
            #expect(d.object(forKey: PhotoPrivacy.key) == nil)
            #expect(PhotoPrivacy.isOn(d) == PhotoPrivacy.defaultValue)
            #expect(PhotoPrivacy.key == "Sempere.photoPrivacy")
        }

        @Test func photoPrivacyKeepsTheUsersChoiceAndIgnoresDamagedValues() {
            let d = scratch()
            d.set(false, forKey: PhotoPrivacy.key)
            #expect(!PhotoPrivacy.isOn(d))
            d.set(true, forKey: PhotoPrivacy.key)
            #expect(PhotoPrivacy.isOn(d))
            d.set("no", forKey: PhotoPrivacy.key)
            #expect(PhotoPrivacy.isOn(d), "not a Bool: the safe default (on)")
            d.removeObject(forKey: PhotoPrivacy.key)
            #expect(PhotoPrivacy.isOn(d))
        }
    }
}
