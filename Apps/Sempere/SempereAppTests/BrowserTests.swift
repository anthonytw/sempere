import Age
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Vault creation, bookmarks, recents and the sidebar's edits.
@MainActor
struct BrowserTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    static func tempDir() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model on a private copy of the fixture vault, unlocked.
    static func unlockedFixtureModel() async throws -> AppModel {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: try tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return model
    }

    static func library() throws -> VaultLibrary {
        VaultLibrary(storeURL: try tempDir().appendingPathComponent("recents.json"))
    }

    // MARK: - Creating

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

    /// A passphrase for the recovery key's copy.
    static let strongPassphrase = "vuspot-Bekfu4-qobqag"

    // MARK: - Bookmarks and recents

    @Test func bookmarkRoundTrips() throws {
        let dir = try Self.tempDir()
        let resolved = try VaultBookmark.resolve(try VaultBookmark.make(for: dir))
        #expect(resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
                == dir.standardizedFileURL.resolvingSymlinksInPath().path)
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

    // MARK: - Edits

    /// The Settings choice is the one the model uses: Blank leaves the note
    /// untitled (`createNote` never puts a date over it).
    @Test func theDefaultTitleFollowsTheNewNotesSetting() async throws {
        let model = try await Self.unlockedFixtureModel()
        model.defaultTitle = { NewNoteSettings.title(.blank, now: $0) }
        let id = try await model.createNote(title: NewNoteSettings.title(.blank), paper: .ruled, notebook: nil)
        #expect(model.notes.first { $0.id == id }?.title == "")
        let d = try #require(TestDefaults.suite("TitleFormat-\(UUID().uuidString)"))
        NewNoteSettings.setTitleFormat(.dateOnly, in: d)
        #expect(NewNoteSettings.resolvedTitle(typed: " ", defaults: d) == NewNoteSettings.title(.dateOnly))
    }

    // MARK: - Search and sort

}
