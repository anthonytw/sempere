import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// A rewrap journal this device refuses (format.md §3.3.1 "Refused journals";
/// security review 2026-10, stage 4, S19): planted on the storage, it used to
/// hold the vault in the migration screen, whose resume then failed. It gives
/// no secret, so unlocking deletes it and opens the vault normally.
@Suite(.serialized)
@MainActor
struct RefusedJournalTests {
    @Test func aPlantedJournalIsDiscardedAtUnlock() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        let identity = try IdentityFile.parse(keyText)
        let journal = url.appendingPathComponent("rewrap-journal.json")
        // A secret of an attacker's own, encrypted to the vault's public key: nothing links it.
        let armored = String(decoding: try AgeFile.encrypt(VaultSecret.random().bytes, to: [identity.recipient], armor: true),
                             as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["format": "sempere/1", "previousVaultSecret": armored]).write(to: journal)
        #expect(try Vault.open(at: url, identities: [identity]).journalRefused)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: MemoryRecipientsTrustStore())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .unlocked)
        #expect(model.migration == nil)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(model.notes.count == 2)
        model.close()
    }

    /// An unfinished change's journal still leads to the migration screen, which finishes it.
    @Test func anAcceptedJournalStillLeadsToTheMigration() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        try Data(#"{"format":"sempere/1"}"#.utf8).write(to: url.appendingPathComponent("rewrap-journal.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: MemoryRecipientsTrustStore())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .migrating)
        model.close()
    }
}
