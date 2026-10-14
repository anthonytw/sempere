import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// An interrupted key change in the app (format.md §3.3.1,
/// `AppModel+KeyChangeResume`): unlocking leads only to the screen that
/// finishes it, and no note is read before it is done.
@MainActor
@Suite(.timeLimit(.minutes(5)))   // a gate mistake fails the suite instead of hanging the CI job
struct KeyChangeResumeTests {
    /// A private copy of the fixture with the journal of an unfinished
    /// addition, bound by vault.json (format.md §3.3.1).
    static func vaultWithPendingChange() throws -> (vault: URL, keyText: String) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        try addPendingChange(to: url, keyText: keyText)
        return (url, keyText)
    }

    /// Writes the journal of an unfinished addition into the vault at `url`, bound by vault.json.
    static func addPendingChange(to url: URL, keyText: String) throws {
        let bytes = Data(#"{"format":"sempere/1","rekeyBlobs":false}"#.utf8)
        try bytes.write(to: url.appendingPathComponent("rewrap-journal.json"))
        let manifestURL = url.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        let secret = try VaultSecret(bytes: AgeFile.decrypt(Data(m.vaultSecret.utf8), with: [try IdentityFile.parse(keyText)]))
        m.rewrapPending = RecipientsAuth.rewrapPending(vaultId: m.vaultId, journal: bytes, secret: secret)
        try m.encoded().write(to: manifestURL)
    }

    @Test func pendingKeyChangeIsFinishedBeforeTheNotes() async throws {
        let (url, keyText) = try Self.vaultWithPendingChange()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .finishingKeyChange)
        #expect(model.keyChangeResume?.step == .ready)
        // The notes are never loaded before the change is finished.
        #expect(model.notes.isEmpty)
        try await model.reload()
        #expect(model.notes.isEmpty)
        #expect(model.phase == .finishingKeyChange)
        model.selectedNoteID = AppModelTests.lecture
        await #expect(throws: (any Error).self) { try await model.openEditor(for: AppModelTests.lecture) }
        #expect(model.editor == nil)

        try await model.finishKeyChange()
        #expect(model.phase == .unlocked)
        #expect(model.keyChangeResume == nil)
        #expect(model.notes.count == 2)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("rewrap-journal.json").path))
    }

    @Test func finishingNeedsAnInterruptedChange() async throws {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: keyURL, encoding: .utf8))
        #expect(model.phase == .unlocked)
        await #expect(throws: AppModel.KeyChangeError.notFinishing) { try await model.finishKeyChange() }
    }
}
