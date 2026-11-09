import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// The vault browser's creation and reopen flows and the new-note title setting (moved from the app's test target in
/// wave 6 part 8).
extension AppModelSuites.BrowserTests {
    @Test func createsGeneratedKeyVaultAndOpensUnlocked() async throws {
        let library = try Self.library()
        let model = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        let created = try await model.createVault(NewVaultRequest(name: "Fresh", keySource: .generate, passphrase: nil), library: library)
        #expect(created.url.lastPathComponent == "Fresh.sempere")
        // Generated keys are post-quantum (docs/post-quantum.md).
        #expect(created.secretKey?.hasPrefix("AGE-SECRET-KEY-PQ-1") == true)
        #expect(model.phase == .unlocked)
        #expect(model.notes.isEmpty)
        #expect(library.recents.map(\.name) == ["Fresh"])
        // This device is the vault's home, unlocked with its new device key (it writes).
        #expect(model.vault?.isHome == true)
        #expect(!model.isRecoveryOpen)
        #expect(model.vaultDevices.filter { !$0.isRecovery }.map(\.kind) == ["ipad"])
        #expect(model.vaultDevices.first { $0.isThisDevice }?.name == "This device")
        #expect(model.vault?.deviceEntry?.key == created.device.key)
        // No passphrase: no copy of the recovery key in keys/.
        #expect(try Vault.open(at: created.url).passphraseCopyNames().isEmpty)
    }

    @Test func reopensARecentStoreVaultByItsId() async throws {
        let parent = try Self.tempDir()
        let library = try Self.library()
        let first = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        let created = try await first.createVault(NewVaultRequest(name: "Again", keySource: .generate, passphrase: nil), library: library)
        first.close()
        let second = AppModel(deviceStateURL: try Self.tempDir().appendingPathComponent("device.json"))
        try await second.open(recent: try #require(library.recents.first), library: library)
        #expect(second.phase == .locked)
        #expect(second.vaultName == "Again")
        try await second.unlock(identityText: try #require(created.unlockKey))
        #expect(second.phase == .unlocked)
    }

    /// The Settings choice is the one the model uses: Blank leaves the note
    /// untitled (`createNote` never puts a date over it).
    @Test func theDefaultTitleFollowsTheNewNotesSetting() async throws {
        let model = try await Self.unlockedFixtureModel()
        model.defaultTitle = { NewNoteSettings.title(.blank, now: $0) }
        let id = try await model.createNote(title: NewNoteSettings.title(.blank), paper: .ruled, notebook: nil)
        #expect(model.notes.first { $0.id == id }?.title == "")
        let d = MemoryKeyValueStore()
        NewNoteSettings.setTitleFormat(.dateOnly, in: d)
        #expect(NewNoteSettings.resolvedTitle(typed: " ", defaults: d) == NewNoteSettings.title(.dateOnly))
    }
}
