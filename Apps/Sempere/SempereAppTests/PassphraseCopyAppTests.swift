import Age
import Foundation
import Sempere
import SempereAppCore
import Testing
import UIKit
@testable import SempereApp

/// Build 10: each vault's passphrase is saved by AutoFill under the vault's name, and a new vault takes Suggest a
/// Passphrase's words. Adding a copy later (Devices ▸ Add Passphrase Copy…) is the model's: `DevicesTests` in
/// `SempereAppCoreTests`.
@Suite(.serialized)
@MainActor
struct PassphraseCopyAppTests {
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
