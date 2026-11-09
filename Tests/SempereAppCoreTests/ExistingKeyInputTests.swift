import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// "Use an existing key" in the New Vault sheet: what the pasted text or the picked file is
/// (`ExistingKeyInput`'s status; the sheet's words for each problem are the app's, `NewVaultKeyTests`).
struct ExistingKeyInputTests {
    static let strong = "Wafwi4-nokmoj-jykpuf"

    @Test func aPastedKeyIsReadyAndTheRestIsNamed() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let pasted = IdentityFile.render(identity, created: Date()).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(ExistingKeyInput.status(ofText: "  " + pasted + "\n\n") == .ready(identity))
        #expect(ExistingKeyInput.status(ofText: "") == .empty)
        #expect(ExistingKeyInput.status(ofText: " \n ") == .empty)

        func problem(_ text: String) -> KeyText.Problem? {
            if case .problem(.key(let p)) = ExistingKeyInput.status(ofText: text) { return p }
            return nil
        }
        if case .publicKey? = problem(identity.recipient.string) {} else { Issue.record("a public key cannot open the vault") }
        #expect(problem(try NativeIdentity.generate(.x25519).string) == .classicSecretKey)
        #expect(problem("hunter2") == .notAKey)
        #expect(problem(String(identity.string.dropLast(3))) == .damagedSecretKey)
        #expect(problem(String(repeating: "x", count: KeyText.maximumBytes + 10)) != nil)
    }

    @Test func aPassphraseWrappedKeyFileOpensWithItsPassphrase() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        // Another vault's passphrase copy of its recovery key (format.md §15.11).
        var request = NewVaultRequest(name: "Other", keySource: .identity(identity), passphrase: Self.strong)
        request.workFactor = 10
        let parent = TestTemp.root.appendingPathComponent("existing-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let other = try VaultLibrary.createVault(request, folder: "Other.sempere", in: parent)
        let name = try #require(try Vault.open(at: other.url).passphraseCopyNames().first)
        let data = try Data(contentsOf: other.url.appendingPathComponent("keys").appendingPathComponent(name))
        guard case .needsPassphrase(let wrapped) = ExistingKeyInput.status(ofFile: data) else {
            Issue.record("not recognised as a wrapped key file")
            return
        }
        #expect(ExistingKeyInput.unwrap(wrapped, passphrase: Self.strong) == .ready(identity))
        #expect(ExistingKeyInput.unwrap(wrapped, passphrase: "orbit") == .problem(.key(.wrongPassphrase)))
        // A vault file encrypted to keys is no key file.
        let note = try AgeFile.encrypt(Data("x".utf8), to: [identity.recipient])
        #expect(ExistingKeyInput.status(ofFile: note) == .problem(.key(.encryptedToKeys)))
    }

    @Test func recipientsAreAbbreviatedForTheSheet() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let short = ExistingKeyInput.shortRecipient(identity)
        #expect(short.hasPrefix("age1pq1"))
        #expect(short.count < 30)
        #expect(identity.recipient.string.hasSuffix(String(short.suffix(6))))
    }
}
