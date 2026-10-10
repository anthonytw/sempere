import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Security review 2026-10 stage 4, S16 (the app's counterpart of the web viewer's P3): a `.sempere`
/// folder handed to the app from outside closed the open vault without asking, the remembered key was
/// chosen by the unchecked vault id of the new folder's `vault.json`, and the quick-capture profile was
/// re-pointed to whatever folder had that id. Every `AppModelTests.fixtureVault()` copy has the same
/// vault id, so a second copy is exactly such a lookalike.
@MainActor
struct OpenedVaultTests {
    static func library() -> VaultLibrary {
        VaultLibrary(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString)/recents.json"))
    }

    @Test func anOpenedVaultDoesNotReplaceTheOpenOneWithoutConfirmation() async throws {
        let (mine, key) = try AppModelTests.fixtureVault()
        let (lookalike, _) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let library = Self.library()
        try await model.openVault(at: mine)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let asked = try #require(await model.handleOpened(lookalike, library: library))
        #expect(asked.url == lookalike)
        #expect(asked.current == "sample")
        #expect(model.phase == .unlocked, "the open vault stays open and unlocked")
        #expect(model.vaultURL == mine)
        // Confirmed: opened, as a vault from outside.
        #expect(await model.handleOpened(lookalike, library: library, confirmed: true) == nil)
        #expect(model.phase == .locked)
        #expect(model.vaultURL?.standardizedFileURL == lookalike.standardizedFileURL)
        #expect(model.vaultOpenedExternally)
        // With no vault open there is nothing to replace: opened at once.
        model.close()
        #expect(!model.vaultOpenedExternally)
        #expect(await model.handleOpened(mine, library: library) == nil)
        #expect(model.phase == .locked)
    }

    @Test func aRememberedKeyIsOfferedOnlyWhereItOpenedItsVault() async throws {
        let (mine, keyURL) = try AppModelTests.fixtureVault()
        let (lookalike, _) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let store = FakeKeyStore()
        let keys = RememberedKeys(store: store)
        try await model.openVault(at: mine)
        let id = try #require(model.vault?.vaultId)
        // Remembered after a manual unlock here: bound to this folder.
        try await keys.unlock(model, identityText: key)
        try await keys.answer(try #require(keys.offer), storage: .thisDevice)
        #expect(keys.locations.locations(for: id) == [RememberedKeyLocations.location(of: mine)])

        // A lookalike with the same id, opened from outside or in the app: no offer, no Face ID prompt.
        for external in [true, false] {
            try await model.openVault(at: lookalike, external: external)
            #expect(!keys.offersSavedKey(for: model))
            #expect(await keys.unlockWithRememberedKey(model) == .notHere)
            #expect(model.phase == .locked)
            #expect(await store.reads == 0)
        }
        // Its own folder, even handed over from outside (tapped in Files): offered.
        try await model.openVault(at: mine, external: true)
        #expect(keys.offersSavedKey(for: model))
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        // Forgetting the key forgets its locations.
        try await keys.forget(model)
        #expect(keys.locations.locations(for: id).isEmpty)
    }

    @Test func aKeyWithoutALocationIsOfferedOnlyForAVaultOpenedInTheApp() async throws {
        let (mine, keyURL) = try AppModelTests.fixtureVault()
        let (received, _) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let store = FakeKeyStore()
        try await model.openVault(at: received, external: true)
        let id = try #require(model.vault?.vaultId)
        // Remembered by an earlier build (or arriving through iCloud Keychain): no location yet.
        await store.put((try IdentityFile.parse(key)).string, for: id)
        let keys = RememberedKeys(store: store)
        #expect(await keys.unlockWithRememberedKey(model) == .notHere)
        #expect(await store.reads == 0)
        // Opened in the app (recents, the picker): offered, and bound to where it unlocked.
        try await model.openVault(at: mine)
        #expect(await keys.unlockWithRememberedKey(model) == .unlocked)
        #expect(keys.locations.locations(for: id) == [RememberedKeyLocations.location(of: mine)])
        try await model.openVault(at: received)
        #expect(await keys.unlockWithRememberedKey(model) == .notHere)
    }

    @Test func onlyAListThisDeviceConfirmedBindsAPastedKeysLocation() {
        #expect(RememberedKeys.listIsConfirmed(.verified(.unchanged)))
        #expect(RememberedKeys.listIsConfirmed(.verified(.rotated)))
        #expect(!RememberedKeys.listIsConfirmed(.verified(.firstUse)))
        #expect(!RememberedKeys.listIsConfirmed(.untagged))
        #expect(!RememberedKeys.listIsConfirmed(.notChecked))
        #expect(!RememberedKeys.listIsConfirmed(nil))
    }

    @Test func locationsPersistAndIgnoreJunk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString).json")
        let id = UUID()
        let folder = URL(fileURLWithPath: "/tmp/Vaults/Mine.sempere")
        RememberedKeyLocations(url: file).bind(id, to: folder)
        let again = RememberedKeyLocations(url: file)
        #expect(again.locations(for: id) == [RememberedKeyLocations.location(of: folder)])
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("Mine"), "no folder names in the file")
        try Data(#"{"not-a-uuid":["x"],"\#(id.uuidString)":["short"]}"#.utf8).write(to: file)
        #expect(RememberedKeyLocations(url: file).locations(for: id).isEmpty)
    }

    @Test func aLookalikeVaultNeverTakesOverTheCaptureProfile() async throws {
        let (mine, keyURL) = try AppModelTests.fixtureVault()
        let (lookalike, _) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let qc = QuickCapture()
        qc.store = MemoryCaptureProfileStore()
        qc.showsActivity = false
        model.quickCapture = qc
        try await model.openVault(at: mine)
        try await model.unlock(identityText: key)
        try model.enableQuickCapture(notebook: "Voice", transcribe: false)
        var stale = try #require(try qc.store.load())
        stale.profile.key = Data(repeating: 0, count: 32)
        try qc.store.save(stale)

        // The lookalike (same vault id) is unlocked: the profile keeps its folder and is not refreshed.
        try await model.openVault(at: lookalike, external: true)
        try await model.unlock(identityText: key)
        model.refreshQuickCaptureProfile()
        let after = try #require(try qc.store.load())
        #expect(after.bookmark == stale.bookmark)
        #expect(after.profile == stale.profile)
        #expect(QuickCapture.resolve(after.bookmark)?.standardizedFileURL.resolvingSymlinksInPath().path
                == mine.standardizedFileURL.resolvingSymlinksInPath().path)

        // Back in its own folder, the profile is refreshed as before.
        try await model.openVault(at: mine)
        try await model.unlock(identityText: key)
        model.refreshQuickCaptureProfile()
        #expect(try qc.store.load()?.profile.key != stale.profile.key)
    }
}
