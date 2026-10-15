import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The New Vault sheet's choices (c26 and the owner's "what goes in that
/// box"): an existing key pasted or picked, a new folder for the vault, and
/// the live checklist for the stored copy's passphrase.
@MainActor
struct NewVaultKeyTests {
    // MARK: - Existing key

    @Test func anExistingKeyMakesAVaultThatOpensWithIt() async throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let pasted = IdentityFile.render(identity, created: Date()).replacingOccurrences(of: "\n", with: "\r\n")
        let status = ExistingKeyInput.status(ofText: "  " + pasted + "\n\n")
        #expect(status == .ready(identity))
        let parent = try BrowserTests.tempDir()
        let library = try BrowserTests.library()
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        let created = try await model.createVault(
            NewVaultRequest(name: "Reused", keySource: .identity(identity), passphrase: "lunar-pickle-tundra-mosaic-quiver"),
            in: parent, library: library)
        // No receipt: the user already has the key.
        #expect(created.secretKey == nil)
        #expect(created.unlockKey == identity.string)
        #expect(model.phase == .unlocked)
        let vault = try Vault.open(at: created.url)
        #expect(vault.recipients.map(\.key) == [identity.recipient.string])
        // The stored copy opens with the passphrase and is the same key.
        let stored = try vault.readIdentityFile(recipient: identity.recipient, passphrase: "lunar-pickle-tundra-mosaic-quiver",
                                                maxWorkFactor: 18)
        #expect(stored == identity)
    }

    @Test func aClassicIdentityIsRefusedByTheLibraryToo() throws {
        let classic = try NativeIdentity.generate(.x25519)
        #expect(throws: VaultLibrary.LibraryError.classicIdentity) {
            try VaultLibrary.createVault(NewVaultRequest(name: "Old", keySource: .identity(classic), passphrase: nil),
                                         folder: "Old.sempere", in: try BrowserTests.tempDir())
        }
    }

    @Test func whatWasPastedIsNamed() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        func message(_ text: String) -> String? {
            if case .problem(let m) = ExistingKeyInput.status(ofText: text) { return m }
            return nil
        }
        #expect(ExistingKeyInput.status(ofText: "") == .empty)
        #expect(ExistingKeyInput.status(ofText: " \n ") == .empty)
        #expect(message(identity.recipient.string)?.contains("public key") == true)
        #expect(message(identity.recipient.string)?.contains("…") == true, "abbreviated")
        #expect(message(try NativeIdentity.generate(.x25519).string)?.contains("AGE-SECRET-KEY-1") == true)
        #expect(message("hunter2")?.contains("not an age key") == true)
        #expect(message(String(identity.string.dropLast(3)))?.contains("incomplete") == true)
        #expect(message(String(repeating: "x", count: KeyText.maximumBytes + 10))?.contains("too large") == true)
        // Each problem has a message of its own.
        let problems: [KeyText.Problem] = [.empty, .tooLarge(1), .publicKey("k"), .classicPublicKey("k"), .classicSecretKey,
                                           .damagedSecretKey, .mismatchedPublicKey("k"), .severalSecretKeys(2),
                                           .encryptedToKeys, .damagedFile, .wrongPassphrase, .workFactorTooHigh,
                                           .postQuantumUnavailable, .notAKey]
        #expect(Set(problems.map(ExistingKeyInput.message)).count == problems.count)
    }

    @Test func aPassphraseWrappedKeyFileOpensWithItsPassphrase() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let vault = try BrowserTests.tempDir().appendingPathComponent("Other.sempere")
        let other = try Vault.create(at: vault, recipients: [identity.recipient], identities: [identity])
        let file = try other.writeIdentityFile(identity, passphrase: "orbit falcon", workFactor: 15)
        let data = try Data(contentsOf: file)
        guard case .needsPassphrase(let wrapped) = ExistingKeyInput.status(ofFile: data) else {
            Issue.record("not recognised as a wrapped key file")
            return
        }
        #expect(ExistingKeyInput.unwrap(wrapped, passphrase: "orbit falcon") == .ready(identity))
        if case .problem(let m) = ExistingKeyInput.unwrap(wrapped, passphrase: "orbit") {
            #expect(m.contains("passphrase"))
        } else {
            Issue.record("a wrong passphrase opened it")
        }
        // A vault file encrypted to keys is no key file.
        let note = try AgeFile.encrypt(Data("x".utf8), to: [identity.recipient])
        if case .problem = ExistingKeyInput.status(ofFile: note) {} else { Issue.record("an encrypted note was accepted") }
    }

    @Test func recipientsAreAbbreviatedForTheSheet() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let short = ExistingKeyInput.shortRecipient(identity)
        #expect(short.hasPrefix("age1pq1"))
        #expect(short.count < 30)
        #expect(identity.recipient.string.hasSuffix(String(short.suffix(6))))
    }

    @Test func eachKeyChoiceSaysWhatItDoes() {
        #expect(NewVaultView.keyFooter(.generate).contains("AGE-SECRET-KEY-PQ-1"))
        #expect(NewVaultView.keyFooter(.existing).contains("AGE-SECRET-KEY-PQ-1"))
        #expect(NewVaultView.keyFooter(.existing).contains("age1pq1"))
        #expect(NewVaultView.keyFooter(.existing).contains("AGE-SECRET-KEY-1"))
        #expect(NewVaultView.keyFooter(.recipient).contains("age1pq1"))
    }

    // MARK: - New folder

    @Test func aNewFolderIsMadeForTheVault() async throws {
        let parent = try BrowserTests.tempDir()
        let library = try BrowserTests.library()
        let created = try await library.create(
            NewVaultRequest(name: "Notes", keySource: .generate, passphrase: nil, subfolder: " Vaults "), in: parent)
        #expect(created.url.standardizedFileURL == parent.appendingPathComponent("Vaults/Notes.sempere").standardizedFileURL)
        #expect(try Vault.open(at: created.url).recipients.count == 1)
        // A folder of that name already there is used; a vault of the same name in it is still refused.
        let second = try await library.create(
            NewVaultRequest(name: "Other", keySource: .generate, passphrase: nil, subfolder: "Vaults"), in: parent)
        #expect(second.url.deletingLastPathComponent().lastPathComponent == "Vaults")
        await #expect(throws: (any Error).self) {
            try await library.create(NewVaultRequest(name: "Notes", keySource: .generate, passphrase: nil, subfolder: "Vaults"),
                                     in: parent)
        }
        // A file where the folder should be is an error, not a vault beside it.
        try Data("x".utf8).write(to: parent.appendingPathComponent("Plain"))
        await #expect(throws: (any Error).self) {
            try await library.create(NewVaultRequest(name: "N", keySource: .generate, passphrase: nil, subfolder: "Plain"),
                                     in: parent)
        }
    }

    @Test func newFolderNamesAreValidated() throws {
        #expect(try VaultLibrary.subfolderName("  Vaults ") == "Vaults")
        #expect(try VaultLibrary.subfolderName("Notas de clase") == "Notas de clase")
        for bad in ["", "   ", ".hidden", "a/b", "a:b", "x.sempere", "X.SEMPERE", "a\nb", "a\u{0}b", "a\u{7}b",
                    String(repeating: "é", count: 200)] {
            #expect(throws: VaultLibrary.LibraryError.invalidFolderName) { try VaultLibrary.subfolderName(bad) }
        }
    }

    // MARK: - Passphrase checklist

    @Test func theChecklistUpdatesAsTheUserTypes() {
        func met(_ p: String, _ c: String) -> [Bool] { StoredKeyPassphrase.requirements(p, confirmation: c).map(\.met) }
        #expect(met("", "") == [false, false])
        #expect(met("lunar", "lunar") == [false, true])
        #expect(met("lunar-pickle-tundra-mosaic-quiver", "") == [true, false])
        #expect(met("lunar-pickle-tundra-mosaic-quiver", "lunar-pickle-tundra-mosaic-quiver") == [true, true])
        // Apple's generated passwords (c26) pass.
        #expect(met("vuspot-Bekfu4-qobqag", "vuspot-Bekfu4-qobqag") == [true, true])
        let line = StoredKeyPassphrase.requirements("lunar", confirmation: "").first?.text ?? ""
        #expect(line.contains("60"))
        #expect(StoredKeyPassphrase.progress("") == 0)
        #expect(StoredKeyPassphrase.progress("lunar-pickle-tundra-mosaic-quiver") == 1)
    }

    @Test func hintsSayWhyWhileItIsWeak() {
        #expect(StoredKeyPassphrase.hints("").isEmpty)
        #expect(StoredKeyPassphrase.hints("qwertyuiop").contains { $0.contains("keyboard") })
        #expect(StoredKeyPassphrase.hints("password1").contains { $0.contains("common") })
        #expect(StoredKeyPassphrase.hints("lunar pickle").contains { $0.contains("five or more") })
        #expect(StoredKeyPassphrase.hints("lunar-pickle-tundra-mosaic-quiver").isEmpty, "strong: no hints")
    }

    @Test func autoFillIsAskedForAPasswordThatPasses() {
        // The rules ask for Apple's default format: 20 characters with a digit and a capital.
        #expect(PassphraseTextField.rules.contains("minlength: 20"))
        #expect(StoredKeyPassphrase.accepts("zixwos-gUnhy4-bobsuc"))
    }
}
