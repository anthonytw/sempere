import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Legacy vaults in the app (format.md §3.3.2, `AppModel+Migration`): the
/// fixture `legacy.sempere` lists a classic X25519 key, so unlocking it
/// leads only to the migration, whose result is an ordinary post-quantum vault.
@MainActor
@Suite(.timeLimit(.minutes(5)))   // a gate mistake fails the suite instead of hanging the CI job
struct MigrationTests {
    /// A private copy of the legacy fixture and the text of its classic key.
    static func legacyVault() throws -> (vault: URL, keyText: String) {
        let bundle = Bundle(for: MigrationBundleToken.self)
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Fixtures missing from test bundle"])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("legacy.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("legacy.sempere"), to: vault)
        let key = try String(contentsOf: fixtures.appendingPathComponent("legacy.key"), encoding: .utf8)
        return (vault, key)
    }

    static let passphrase = "sempere-test"   // the fixture's stored classic key uses it too

    @Test func legacyUnlockShowsOnlyTheMigration() async throws {
        let (url, keyText) = try Self.legacyVault()
        let classic = try IdentityFile.parse(keyText)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .migrating)
        let migration = try #require(model.migration)
        #expect(migration.classicRecipients == [classic.recipient.string])
        #expect(migration.keyIsNew)
        #expect(migration.key?.isPostQuantum == true)
        #expect(migration.step == .ready)
        // The notes are never loaded before the migration.
        #expect(model.notes.isEmpty)
        try await model.reload()
        #expect(model.notes.isEmpty)
        #expect(model.phase == .migrating)
        model.selectedNoteID = AppModelTests.lecture
        await #expect(throws: (any Error).self) { try await model.openEditor(for: AppModelTests.lecture) }
        #expect(model.editor == nil)
    }

    @Test func migrationOpensTheVaultWithTheNewKey() async throws {
        let (url, keyText) = try Self.legacyVault()
        let classic = try IdentityFile.parse(keyText)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        let key = try #require(model.migration?.key)
        try await model.migrate(passphrase: Self.passphrase)
        #expect(model.phase == .unlocked)
        #expect(model.migration == nil)
        #expect(model.notes.map(\.id) == [AppModelTests.deleted, AppModelTests.lecture])

        let after = try Vault.open(at: url)
        #expect(!after.isLegacy)
        #expect(!after.pendingRewrap)
        #expect(after.recipients.map(\.key) == [key.recipient.string])
        // Only the new key file is offered: the classic one (same passphrase) stays but no longer opens it.
        #expect(try after.identityFiles() == [key.recipient])
        #expect(throws: (any Error).self) { try Vault.open(at: url, identities: [classic]) }

        let next = AppModel(deviceStateURL: TS.deviceStateURL())
        try await next.openVault(at: url)
        try await next.unlock(passphrase: Self.passphrase)
        #expect(next.phase == .unlocked)
        #expect(next.notes.count == 2)
    }

    /// The app is killed after the post-quantum key was added (the classic
    /// key is still listed): the classic key unlocks into the migration
    /// again, and the saved key finishes it.
    @Test func interruptedMigrationResumesWithTheSavedKey() async throws {
        let (url, keyText) = try Self.legacyVault()
        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: { await gate.pass() })
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        let key = try #require(model.migration?.key)
        await gate.close()
        let before = await gate.arrivals
        let run = Task { try await model.migrate() }
        await gate.waitForArrivals(before + 1)   // the new key is added, the classic one not yet removed
        model.close()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await run.value }
        let mid = try Vault.open(at: url)
        #expect(mid.isLegacy)
        #expect(Set(mid.recipients.map(\.key)).contains(key.recipient.string))

        let next = AppModel(deviceStateURL: TS.deviceStateURL())
        try await next.openVault(at: url)
        try await next.unlock(identityText: keyText)
        #expect(next.phase == .migrating)
        #expect(next.notes.isEmpty)
        try next.useMigrationKey(identityText: key.string)
        #expect(next.migration?.keyIsNew == false)
        try await next.migrate()
        #expect(next.phase == .unlocked)
        #expect(try Vault.open(at: url).recipients.map(\.key) == [key.recipient.string])
        #expect(next.notes.count == 2)
    }

    /// Interrupted the same way with the key stored under the passphrase:
    /// the passphrase opens both stored keys, and the migration resumes
    /// without asking for anything else.
    @Test func interruptedMigrationResumesWithThePassphrase() async throws {
        let (url, keyText) = try Self.legacyVault()
        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: { await gate.pass() })
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        let key = try #require(model.migration?.key)
        await gate.close()
        let before = await gate.arrivals
        let run = Task { try await model.migrate(passphrase: Self.passphrase) }
        // Each I/O step waits at the closed gate, so the second can only
        // arrive once the first is let through.
        await gate.waitForArrivals(before + 1)   // key file written
        await gate.releaseOne()
        await gate.waitForArrivals(before + 2)   // new key added, classic not yet removed
        model.close()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await run.value }

        let next = AppModel(deviceStateURL: TS.deviceStateURL())
        try await next.openVault(at: url)
        try await next.unlock(passphrase: Self.passphrase)
        #expect(next.phase == .migrating)
        #expect(next.migration?.key == key)
        #expect(next.migration?.keyIsNew == false)
        try await next.migrate()
        #expect(next.phase == .unlocked)
        #expect(try Vault.open(at: url).recipients.map(\.key) == [key.recipient.string])
    }

    /// A key change interrupted after the classic key was gone (the vault is
    /// no longer legacy but a rewrap is pending) is finished first.
    @Test func pendingKeyChangeIsFinishedBeforeTheNotes() async throws {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        // The journal of an unfinished change is bound by vault.json (format.md §3.3.1).
        let bytes = Data(#"{"format":"sempere/1"}"#.utf8)
        try bytes.write(to: url.appendingPathComponent("rewrap-journal.json"))
        let manifestURL = url.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        let secret = try VaultSecret(bytes: AgeFile.decrypt(Data(m.vaultSecret.utf8), with: [try IdentityFile.parse(keyText)]))
        m.rewrapPending = RecipientsAuth.rewrapPending(vaultId: m.vaultId, journal: bytes, secret: secret)
        try m.encoded().write(to: manifestURL)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .migrating)
        #expect(model.migration?.finishingOnly == true)
        #expect(model.notes.isEmpty)
        try await model.migrate()
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("rewrap-journal.json").path))
    }

    @Test func classicKeyIsNotAMigrationTarget() async throws {
        let (url, keyText) = try Self.legacyVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(throws: AppModel.MigrationError.notPostQuantum) { try model.useMigrationKey(identityText: keyText) }
        #expect(model.migration?.keyIsNew == true)
    }
}

private final class MigrationBundleToken {}
