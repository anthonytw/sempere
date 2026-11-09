import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// GA-64: Settings > Photos starts with the privacy setting on.
@MainActor
@Suite(.serialized)
struct SettingsConfirmationTests {
    /// An empty defaults suite (one fixed name, emptied per use; the suite runs serially).
    func scratch() -> UserDefaults {
        let name = "sempere-settings-confirmation-tests"
        let d = TestDefaults.suite(name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Photo privacy

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
