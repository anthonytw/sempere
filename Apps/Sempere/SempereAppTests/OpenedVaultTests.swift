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
        VaultLibrary(storeURL: TestTemp.root
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
        // Confirmed: copied onto this device (the in-app store) and the copy opened, as a vault from outside.
        #expect(await model.handleOpened(lookalike, library: library, confirmed: true) == nil)
        #expect(model.phase == .locked)
        let copy = try #require(library.storedVaults.first)
        #expect(model.vaultURL?.standardizedFileURL == copy.url.standardizedFileURL)
        #expect(model.vaultOpenedExternally)
        // With no vault open there is nothing to replace: opened at once. The store holds one copy per
        // vault id, so a second folder with the same id opens that copy (nothing is copied again).
        model.close()
        #expect(!model.vaultOpenedExternally)
        #expect(await model.handleOpened(mine, library: library) == nil)
        #expect(model.phase == .locked)
        #expect(model.vaultURL?.standardizedFileURL == copy.url.standardizedFileURL)
        #expect(model.vaultOpenedExternally)
        #expect(library.vaultStore.list().count == 1)
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
