import Foundation
import Sempere
import Testing
@testable import SempereApp

/// GA-64: Settings > Photos starts with the privacy setting on.
@MainActor
@Suite(.serialized)
struct SettingsConfirmationTests {
    /// An empty defaults suite (one fixed name, emptied per use; the suite runs serially).
    func scratch() -> UserDefaults {
        let name = "sempere-settings-confirmation-tests"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

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

    /// Nothing the app does by default stores location data from a photo.
    @Test func theDefaultPrivacyStripsWhatTheSettingOffKeeps() throws {
        let jpeg = try #require(ImageInsertTests.photo(.jpeg, orientation: 1))
        let d = scratch()
        let stored = try ImagePreparation.prepare(jpeg, privacy: PhotoPrivacy.isOn(d))
        #expect(!ImageInsertTests.hasLocation(stored.data))
        d.set(false, forKey: PhotoPrivacy.key)
        let kept = try ImagePreparation.prepare(jpeg, privacy: PhotoPrivacy.isOn(d))
        #expect(ImageInsertTests.hasLocation(kept.data))
    }
}
