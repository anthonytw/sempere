import Age
import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Build 10: a vault made without a passphrase copy can get one later (Devices ▸ Add Passphrase Copy…, from the
/// printed kit), and each vault's passphrase is saved by AutoFill under the vault's name.
@Suite(.serialized)
@MainActor
struct PassphraseCopyAppTests {
    @Test func aCopyIsAddedLaterFromTheKitAndOpensTheVault() async throws {
        let w = try DevicesAppTests.World(others: [])
        let model = try await w.model()
        defer { model.close() }
        model.ownerAuthenticator = DevicesAppTests.PassingOwner()
        #expect(model.vault?.passphraseCopyNames().isEmpty == true)
        let strong = "Wafwi4-nokmoj-jykpuf"
        let kit = ExistingKeyInput.status(ofText: IdentityFile.render(.mlkem768x25519(w.recovery), created: Date()))
        await #expect(throws: KeyProblem.self, "no key given") {
            try await model.addPassphraseCopy(recoveryKey: .empty, passphrase: strong)
        }
        let other = ExistingKeyInput.status(ofText: IdentityFile.render(.mlkem768x25519(try MLKEM768X25519Identity()), created: Date()))
        await #expect(throws: VaultError.self, "not the current kit") {
            try await model.addPassphraseCopy(recoveryKey: other, passphrase: strong)
        }
        try await model.addPassphraseCopy(recoveryKey: kit, passphrase: strong)
        let vault = try #require(model.vault)
        #expect(vault.passphraseCopyNames().count == 1)
        let copy = try vault.openPassphraseCopy(passphrase: strong)
        #expect(copy.identity.recipient.string == w.recovery.recipient.string)
        let list = try await model.loadDeviceList()
        #expect(list.passphraseCopy)
        await #expect(throws: VaultError.self, "add-only: sync never replaces a copy") {
            try await model.addPassphraseCopy(recoveryKey: kit, passphrase: "tedPes-6fiqre-rynbid")
        }
        #expect(try model.vault?.openPassphraseCopy(passphrase: strong) != nil, "the first copy is untouched")
    }

    /// Any passphrase is taken, a one-letter one too; Suggest a Passphrase's words are one more passphrase.
    @Test func anyPassphraseIsTaken() async throws {
        let w = try DevicesAppTests.World(others: [])
        let model = try await w.model()
        defer { model.close() }
        model.ownerAuthenticator = DevicesAppTests.PassingOwner()
        let kit = ExistingKeyInput.status(ofText: IdentityFile.render(.mlkem768x25519(w.recovery), created: Date()))
        try await model.addPassphraseCopy(recoveryKey: kit, passphrase: "a")
        let vault = try #require(model.vault)
        #expect(vault.passphraseCopyNames().count == 1)
        #expect(try vault.openPassphraseCopy(passphrase: "a").identity.recipient.string == w.recovery.recipient.string)
    }

    /// A vault made in the New Vault sheet with the suggestion gets its copy under it.
    @Test func newVaultTakesTheSuggestion() throws {
        let parent = try BrowserTests.tempDir()
        let suggestion = GeneratedPassphrase.make()
        var request = NewVaultRequest(name: "Taken", keySource: .generate, passphrase: suggestion)
        request.workFactor = 10
        let created = try VaultLibrary.createVault(request, folder: "Taken.sempere", in: parent)
        let vault = try Vault.open(at: created.url)
        #expect(vault.passphraseCopyNames().count == 1)
        #expect(try vault.openPassphraseCopy(passphrase: suggestion).root == vault.root)
    }

    /// Passwords keys a saved password by app and username: the pair shows the vault's name as the username, so a
    /// second vault's Strong Password is its own entry instead of replacing the first.
    @Test func thePassphrasePairCarriesTheVaultNameAsTheUsername() throws {
        let stack = PassphrasePairTextFields.makeStack(placeholders: ["Passphrase", "Repeat passphrase"], texts: ["", ""],
                                                       revealed: false, identifiers: ["a", "b"], account: "Work notes")
        let account = try #require(stack.arrangedSubviews.first as? UITextField)
        #expect(account.textContentType == .username)
        #expect(account.text == "Work notes")
        let fields = PassphrasePairTextFields.fields(of: stack)
        #expect(fields.count == 2 && fields.allSatisfy { $0.textContentType == .newPassword }, "the pair is still the pair")
        // A name typed after the pair was built still gets its username field.
        let late = PassphrasePairTextFields.makeStack(placeholders: ["p", "q"], texts: ["", ""], revealed: false,
                                                      identifiers: ["a", "b"], account: "")
        #expect(late.arrangedSubviews.first(where: { $0.tag == PassphrasePairTextFields.accountTag }) == nil)
        PassphrasePairTextFields.insertAccount("Later", into: late)
        #expect((late.arrangedSubviews.first as? UITextField)?.textContentType == .username)
        #expect(PassphrasePairTextFields.fields(of: late).count == 2)
        let plain = PassphrasePairTextFields.makeStack(placeholders: ["p", "q"], texts: ["", ""], revealed: false,
                                                       identifiers: ["a", "b"])
        #expect(plain.arrangedSubviews.compactMap { $0 as? UITextField }.count == 2, "no account, no extra field")
    }
}
