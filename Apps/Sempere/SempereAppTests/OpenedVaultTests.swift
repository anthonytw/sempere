import Age
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Security review 2026-10 stage 4, S16 (the app's counterpart of the web viewer's P3): a `.sempere`
/// folder handed to the app from outside closed the open vault without asking, the remembered key was
/// chosen by the unchecked vault id of the new folder's `vault.json`, and the quick-capture profile was
/// re-pointed to whatever folder had that id. Every `AppModelTests.fixtureVault()` copy has the same
/// vault id, so a second copy is exactly such a lookalike. The open-without-asking case is the core's
/// (`OpenedFilesTests`); the alert's words are `InsertTextTests`.
@MainActor
struct OpenedVaultTests {
    @Test func aLookalikeVaultNeverTakesOverTheCaptureProfile() async throws {
        let (mine, keyURL) = try AppModelTests.fixtureVault()
        let (lookalike, _) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let qc = QuickCapture.testing()
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
        #expect((try? SecurityScopedBookmarks().resolve(after.bookmark))?.url.standardizedFileURL.resolvingSymlinksInPath().path
                == mine.standardizedFileURL.resolvingSymlinksInPath().path)

        // Back in its own folder, the profile is refreshed as before.
        try await model.openVault(at: mine)
        try await model.unlock(identityText: key)
        model.refreshQuickCaptureProfile()
        #expect(try qc.store.load()?.profile.key != stale.profile.key)
    }
}
