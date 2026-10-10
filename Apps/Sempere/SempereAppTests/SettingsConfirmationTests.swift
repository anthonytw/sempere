import Foundation
import Sempere
import Testing
@testable import SempereApp

/// GA-64: Settings > Device Keys asks before "Rewrite headers only" is chosen for a
/// removal or upgrade (`DeviceKeySettingsSection`), and Settings > Photos starts with
/// the privacy setting on. The picker's choice goes through `RewrapSettings.removalStep`;
/// the dialog's buttons store through `setOnRemoveOrUpgrade`.
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

    // MARK: Removal: headers only

    @Test func choosingHeadersOnlyForARemovalWaitsForTheConfirmation() {
        #expect(RewrapSettings.removalStep(choosing: .headerOnly, current: .reencrypt) == .confirm)
    }

    @Test func everyOtherChoiceIsAppliedAtOnce() {
        #expect(RewrapSettings.removalStep(choosing: .reencrypt, current: .headerOnly) == .apply, "the safe way back needs no question")
        #expect(RewrapSettings.removalStep(choosing: .reencrypt, current: .reencrypt) == .apply)
        #expect(RewrapSettings.removalStep(choosing: .headerOnly, current: .headerOnly) == .apply,
                "already confirmed once: picking it again does not ask again")
    }

    @Test func theDefaultIsTheSafeOneAndOnlyHeadersOnlyIsAsked() {
        #expect(RewrapSettings.onRemoveOrUpgrade(scratch()) == .reencrypt)
        for method in RewrapMethod.allCases {
            #expect(RewrapSettings.needsConfirmation(forRemoval: method) == (method == .headerOnly), "\(method)")
        }
    }

    /// The flow of the section: the picker asks, "Keep Re-encrypting Everything" (cancel) changes nothing,
    /// "Rewrite Headers Only" stores the choice, and the policy the vault operations get follows.
    @Test func theDialogsButtonsDecideWhatIsStored() {
        let d = scratch()
        var current = RewrapSettings.onRemoveOrUpgrade(d)

        // Pick headers only: the dialog opens, nothing stored yet.
        #expect(RewrapSettings.removalStep(choosing: .headerOnly, current: current) == .confirm)
        #expect(RewrapSettings.onRemoveOrUpgrade(d) == .reencrypt)
        #expect(RewrapSettings.policy(d).onRemoveOrTypeChange == .reencrypt)

        // Cancel ("Keep Re-encrypting Everything"): the dialog's cancel action stores nothing.
        #expect(RewrapSettings.onRemoveOrUpgrade(d) == .reencrypt)

        // Confirm ("Rewrite Headers Only"): stored and used.
        RewrapSettings.setOnRemoveOrUpgrade(.headerOnly, in: d)
        current = RewrapSettings.onRemoveOrUpgrade(d)
        #expect(current == .headerOnly)
        #expect(RewrapSettings.policy(d).onRemoveOrTypeChange == .headerOnly)

        // Back to re-encrypting: applied without a question.
        #expect(RewrapSettings.removalStep(choosing: .reencrypt, current: current) == .apply)
        RewrapSettings.setOnRemoveOrUpgrade(.reencrypt, in: d)
        #expect(RewrapSettings.policy(d).onRemoveOrTypeChange == .reencrypt)
    }

    @Test func theAddChoiceIsIndependentOfTheRemovalChoice() {
        let d = scratch()
        RewrapSettings.setOnRemoveOrUpgrade(.headerOnly, in: d)
        #expect(RewrapSettings.onAdd(d) == .headerOnly, "adding a device is header-only by default and asks nothing")
        RewrapSettings.setOnAdd(.reencrypt, in: d)
        #expect(RewrapSettings.onRemoveOrUpgrade(d) == .headerOnly)
        #expect(RewrapSettings.policy(d) == RewrapPolicy(onAdd: .reencrypt, onRemoveOrTypeChange: .headerOnly))
    }

    @Test func aDamagedStoredRemovalChoiceFallsBackToReencrypting() {
        let d = scratch()
        d.set("header-ish", forKey: RewrapSettings.onRemoveKey)
        #expect(RewrapSettings.onRemoveOrUpgrade(d) == .reencrypt, "never silently the weaker choice")
        d.set(true, forKey: RewrapSettings.onRemoveKey)
        #expect(RewrapSettings.onRemoveOrUpgrade(d) == .reencrypt)
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
