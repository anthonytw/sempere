import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The key window's model: list, add, generate, remove, recovery kit.
@MainActor
struct KeyManagementTests {
    static let lecture = AppModelTests.lecture

    static func unlockedModel() async throws -> (AppModel, URL) {
        try await NoteWindowTests.unlockedModel()
    }

    @Test func listsTheVaultsKeysAndMarksTheOneInUse() async throws {
        let (model, _) = try await Self.unlockedModel()
        let keys = model.deviceKeys
        #expect(keys.count == 1)
        #expect(keys[0].isInUse)
        #expect(keys[0].isPostQuantum)
        #expect(keys[0].recipient.hasPrefix("age1pq1"))
        #expect(keys[0].summary.count < 100, "the 1959-character key is abbreviated")
        #expect(keys[0].summary.contains("SHA-256"))
    }

    @Test func aPastedPublicKeyIsAddedAndOpensTheVault() async throws {
        let (model, url) = try await Self.unlockedModel()
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: "  \(other.recipient.string)\n", label: " Anna's iPad ", authenticator: PassingOwnerAuthenticator())
        #expect(model.deviceKeys.count == 2)
        let added = try #require(model.deviceKeys.first { $0.recipient == other.recipient.string })
        #expect(added.label == "Anna's iPad")
        #expect(!added.isInUse)
        #expect(model.keyEpoch == 1)
        let vault = try Vault.open(at: url, identities: [other])
        #expect(try vault.summaries().count == 2, "the new key reads every note")
    }

    @Test func aGeneratedKeyIsAddedAndItsSecretReturnedOnce() async throws {
        let (model, url) = try await Self.unlockedModel()
        let generated = try await model.generateDeviceKey(label: "", authenticator: PassingOwnerAuthenticator())
        #expect(generated.problem == nil)
        let secret = generated.secret
        let identity = try IdentityFile.parse(secret)
        #expect(identity.isPostQuantum)
        #expect(model.deviceKeys.map(\.label).contains("Device"))
        #expect(model.deviceKeys.contains { $0.recipient == identity.recipient.string })
        #expect(try Vault.open(at: url, identities: [identity]).summaries().count == 2)
    }

    @Test func removingAKeyLocksItOutAndKeepsTheOthers() async throws {
        let (model, url) = try await Self.unlockedModel()
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "Old iPad", authenticator: PassingOwnerAuthenticator())
        try await model.removeDeviceKey(other.recipient.string)
        #expect(model.deviceKeys.count == 1)
        #expect(model.keyEpoch == 2)
        #expect(throws: (any Error).self) { _ = try Vault.open(at: url, identities: [other]).summaries() }
        let mine = try Vault.open(at: url, identities: model.unlockIdentities)
        #expect(try mine.summaries().count == 2)
    }

    @Test func theKeyInUseAndTheLastKeyCannotBeRemoved() async throws {
        let (model, _) = try await Self.unlockedModel()
        let mine = model.deviceKeys[0].recipient
        await #expect(throws: AppModel.KeyError.lastKey) { try await model.removeDeviceKey(mine) }
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B", authenticator: PassingOwnerAuthenticator())
        await #expect(throws: AppModel.KeyError.inUse) { try await model.removeDeviceKey(mine) }
        await #expect(throws: AppModel.KeyError.notListed) {
            try await model.removeDeviceKey(try NativeIdentity.generate(.postQuantum).recipient.string)
        }
    }

    /// GA-17: Replace (the CLI's `vault recipients replace`) swaps another
    /// device's key in one re-encryption; a blank label keeps the old one.
    @Test func replacingAKeyLocksTheOldOneOutAndOpensWithTheNew() async throws {
        let (model, url) = try await Self.unlockedModel()
        let old = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: old.recipient.string, label: "Old iPad", authenticator: PassingOwnerAuthenticator())
        let new = try NativeIdentity.generate(.postQuantum)
        let auth = KeyExportTests.FakeAuthenticator()
        try await model.replaceDeviceKey(old.recipient.string, with: " \(new.recipient.string)\n", label: "  ",
                                         authenticator: auth)
        #expect(auth.reasons.count == 1, "a new key reads the vault: the owner is asked")
        #expect(model.deviceKeys.count == 2)
        #expect(model.deviceKeys.first { $0.recipient == new.recipient.string }?.label == "Old iPad")
        #expect(!model.deviceKeys.contains { $0.recipient == old.recipient.string })
        #expect(model.keyEpoch == 2)
        #expect(try Vault.open(at: url, identities: [new]).summaries().count == 2)
        #expect(throws: (any Error).self) { _ = try Vault.open(at: url, identities: [old]).summaries() }
        #expect(try Vault.open(at: url, identities: model.unlockIdentities).summaries().count == 2)
    }

    @Test func aGeneratedReplacementReturnsItsSecret() async throws {
        let (model, url) = try await Self.unlockedModel()
        let old = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: old.recipient.string, label: "Old iPad", authenticator: PassingOwnerAuthenticator())
        let generated = try await model.generateReplacementKey(for: old.recipient.string, label: "New iPad",
                                                               authenticator: PassingOwnerAuthenticator())
        #expect(generated.problem == nil)
        let identity = try IdentityFile.parse(generated.secret)
        #expect(model.deviceKeys.first { $0.recipient == identity.recipient.string }?.label == "New iPad")
        #expect(!model.deviceKeys.contains { $0.recipient == old.recipient.string })
        #expect(try Vault.open(at: url, identities: [identity]).summaries().count == 2)
    }

    @Test func replaceRefusesTheKeyInUseAndBadKeysBeforeAnythingChanges() async throws {
        let (model, _) = try await Self.unlockedModel()
        let mine = model.deviceKeys[0].recipient
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B", authenticator: PassingOwnerAuthenticator())
        let fresh = try NativeIdentity.generate(.postQuantum).recipient.string
        let pass = PassingOwnerAuthenticator()
        await #expect(throws: AppModel.KeyError.replaceInUse) {
            try await model.replaceDeviceKey(mine, with: fresh, label: "", authenticator: pass)
        }
        await #expect(throws: AppModel.KeyError.replaceInUse) {
            _ = try await model.generateReplacementKey(for: mine, label: "", authenticator: pass)
        }
        await #expect(throws: AppModel.KeyError.notListed) {
            try await model.replaceDeviceKey(fresh, with: fresh, label: "", authenticator: pass)
        }
        await #expect(throws: AppModel.KeyError.alreadyListed) {
            try await model.replaceDeviceKey(other.recipient.string, with: mine, label: "", authenticator: pass)
        }
        await #expect(throws: AppModel.KeyError.notPostQuantum) {
            try await model.replaceDeviceKey(other.recipient.string, with: "age1hello", label: "", authenticator: pass)
        }
        await #expect(throws: AppModel.KeyError.vaultChanged) {
            try await model.replaceDeviceKey(other.recipient.string, with: fresh, label: "", expectedVault: UUID(), authenticator: pass)
        }
        let refused = KeyExportTests.FakeAuthenticator(outcome: AppModel.KeyExportError.notAuthenticated)
        await #expect(throws: (any Error).self) {
            try await model.replaceDeviceKey(other.recipient.string, with: fresh, label: "", authenticator: refused)
        }
        #expect(model.deviceKeys.map(\.recipient) == [mine, other.recipient.string], "nothing changed")
        #expect(model.keyEpoch == 1)
    }

    @Test func badKeysAreRefusedBeforeAnythingChanges() async throws {
        let (model, _) = try await Self.unlockedModel()
        for text in ["", "hello", "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq", "AGE-SECRET-KEY-PQ-1ABC"] {
            await #expect(throws: AppModel.KeyError.notPostQuantum) { try await model.addDeviceKey(recipient: text, label: "x", authenticator: PassingOwnerAuthenticator()) }
        }
        await #expect(throws: AppModel.KeyError.alreadyListed) {
            try await model.addDeviceKey(recipient: model.deviceKeys[0].recipient, label: "again", authenticator: PassingOwnerAuthenticator())
        }
        #expect(model.deviceKeys.count == 1)
        #expect(model.keyEpoch == 0)
    }

    @Test func keyChangesNeedAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let other = try NativeIdentity.generate(.postQuantum)
        await #expect(throws: AppModel.KeyError.notUnlocked) {
            try await model.addDeviceKey(recipient: other.recipient.string, label: "x", authenticator: PassingOwnerAuthenticator())
        }
        await #expect(throws: AppModel.KeyError.notUnlocked) { _ = try await model.generateDeviceKey(label: "x", authenticator: PassingOwnerAuthenticator()) }
        await #expect(throws: AppModel.KeyError.notUnlocked) { _ = try await model.recoveryKitPDF(authenticator: PassingOwnerAuthenticator()) }
        #expect(model.deviceKeys.isEmpty)
    }

    @Test func everyEditorIsClosedAndNotesWriteAgainAfterAKeyChange() async throws {
        let (model, url) = try await Self.unlockedModel()
        await model.claimNote(Self.lecture)
        let window = try await model.openWindowNote(Self.lecture)
        window.addPage()   // pending: saved before the vault changes
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B", authenticator: PassingOwnerAuthenticator())
        #expect(model.windowEditors.isEmpty)
        #expect(model.editor == nil)
        var vault = try Vault.open(at: url, identities: model.unlockIdentities)
        #expect(try NoteReducer.reconstruct(vault.loadNote(Self.lecture).revisions).pages.count == 3)

        // A rotation (removal) changes the vault secret: a fresh editor writes with the new one.
        try await model.removeDeviceKey(other.recipient.string)
        let again = try await model.openWindowNote(Self.lecture)
        again.addPage()
        await again.flush()
        vault = try Vault.open(at: url, identities: model.unlockIdentities)
        #expect(try NoteReducer.reconstruct(vault.loadNote(Self.lecture).revisions).pages.count == 4)
        #expect(try vault.loadNote(Self.lecture).failures.isEmpty)
    }

    /// The vault lists the generated key as soon as the manifest is written:
    /// a change that then stays pending must still hand the secret over.
    @Test func aGeneratedKeyIsReturnedEvenWhenTheChangeStaysPending() async throws {
        let (model, url) = try await Self.unlockedModel()
        let folder = url.appendingPathComponent("notes/\(AppModelTests.deleted.uuidString.lowercased())")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".age") && !$0.hasPrefix(".") }.sorted().first)
        try Data("not an age file".utf8).write(to: folder.appendingPathComponent(file))
        let generated = try await model.generateDeviceKey(label: "Tablet", authenticator: PassingOwnerAuthenticator())
        #expect(generated.problem != nil, "one file could not be re-encrypted")
        let identity = try IdentityFile.parse(generated.secret)
        #expect(model.deviceKeys.contains { $0.recipient == identity.recipient.string })
        let vault = try Vault.open(at: url, identities: [identity])
        #expect(try vault.loadNote(Self.lecture).failures.isEmpty, "the secret opens the vault")
    }

    @Test func aRequestMadeForAnotherVaultChangesNothing() async throws {
        let (model, _) = try await Self.unlockedModel()
        let other = try NativeIdentity.generate(.postQuantum)
        await #expect(throws: AppModel.KeyError.vaultChanged) {
            try await model.addDeviceKey(recipient: other.recipient.string, label: "x", expectedVault: UUID(), authenticator: PassingOwnerAuthenticator())
        }
        await #expect(throws: AppModel.KeyError.vaultChanged) {
            _ = try await model.generateDeviceKey(label: "x", expectedVault: UUID(), authenticator: PassingOwnerAuthenticator())
        }
        try await model.addDeviceKey(recipient: other.recipient.string, label: "x", expectedVault: model.vault?.vaultId, authenticator: PassingOwnerAuthenticator())
        let key = try #require(model.deviceKeys.first { $0.recipient == other.recipient.string })
        await #expect(throws: AppModel.KeyError.vaultChanged) {
            try await model.removeDeviceKey(key.recipient, expectedVault: UUID())
        }
        #expect(model.deviceKeys.count == 2)
        try await model.removeDeviceKey(key.recipient, expectedVault: key.vault)
        #expect(model.deviceKeys.count == 1)
    }

    /// A window editor closed for a key change holds the old vault and
    /// secret: whatever still reaches it must never be written.
    @Test func anEditorClosedForAKeyChangeWritesNothingMore() async throws {
        let (model, url) = try await Self.unlockedModel()
        await model.claimNote(Self.lecture)
        let window = try await model.openWindowNote(Self.lecture)
        let other = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B", authenticator: PassingOwnerAuthenticator())
        #expect(window.isShutDown)
        let before = try Vault.open(at: url, identities: model.unlockIdentities).revisionNames(of: Self.lecture).count
        window.addPage()
        await window.flush()
        let after = try Vault.open(at: url, identities: model.unlockIdentities).revisionNames(of: Self.lecture).count
        #expect(after == before)
        #expect(window.pages.count == 2, "a closed editor takes no changes")
    }

    @Test func noEditorOpensWhileTheKeysChange() async throws {
        let (model, _) = try await Self.unlockedModel()
        model.selectedNoteID = Self.lecture
        await model.claimNote(AppModelTests.deleted)
        model.isChangingKeys = true
        await #expect(throws: CancellationError.self) { try await model.openEditor(for: Self.lecture) }
        await #expect(throws: CancellationError.self) { _ = try await model.openWindowNote(AppModelTests.deleted) }
        #expect(model.editor == nil)
        #expect(model.windowEditors.isEmpty)
        model.isChangingKeys = false
        try await model.openEditor(for: Self.lecture)
        #expect(model.editor?.noteID == Self.lecture)
    }

    @Test func theRecoveryKitIsAPDFOfTheKeyInUse() async throws {
        let (model, _) = try await Self.unlockedModel()
        let letter = try await model.recoveryKitPDF(authenticator: PassingOwnerAuthenticator())
        let a4 = try await model.recoveryKitPDF(a4: true, authenticator: PassingOwnerAuthenticator())
        #expect(letter.starts(with: Data("%PDF-".utf8)))
        #expect(a4.starts(with: Data("%PDF-".utf8)))
        #expect(letter != a4)
    }

    @Test func labelsAreOneShortLine() {
        #expect(AppModel.cleanLabel("  Anna's\niPad  ") == "Anna's iPad")
        #expect(AppModel.cleanLabel("") == "Device")
        #expect(AppModel.cleanLabel("\n \n") == "Device")
        #expect(AppModel.cleanLabel(String(repeating: "x", count: 300)).count == 80)
    }
}
