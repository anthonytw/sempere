import Age
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// The New Vault sheet's choices (c26 and the owner's "what goes in that
/// box"): an existing key pasted or picked, a new folder for the vault, and
/// the stored copy's passphrase fields.
@MainActor
struct NewVaultKeyTests {
    // MARK: - Existing key

    /// A passphrase for the recovery key's copy.
    static let strong = "Wafwi4-nokmoj-jykpuf"

    /// An existing key becomes the vault's recovery key; this device still gets its own key.
    @Test func anExistingKeyBecomesTheRecoveryKey() async throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let pasted = IdentityFile.render(identity, created: Date()).replacingOccurrences(of: "\n", with: "\r\n")
        let status = ExistingKeyInput.status(ofText: "  " + pasted + "\n\n")
        #expect(status == .ready(identity))
        let library = try BrowserTests.library()
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        var request = NewVaultRequest(name: "Reused", keySource: .identity(identity), passphrase: Self.strong)
        request.workFactor = 10
        let created = try await model.createVault(request, library: library)
        // No receipt: the user already has the key.
        #expect(created.secretKey == nil)
        #expect(created.recoveryKey == nil)
        #expect(created.unlockKey != nil)
        #expect(model.phase == .unlocked)
        #expect(!model.isRecoveryOpen, "unlocked with this device's own key")
        let vault = try Vault.open(at: created.url)
        #expect(vault.manifest.recoveryEntry?.key == identity.recipient.string)
        #expect(vault.devices.map(\.key) == [created.device.key])
        // The stored copy opens with the passphrase and is the same key.
        let stored = try vault.openPassphraseCopy(passphrase: Self.strong)
        #expect(NativeIdentity.mlkem768x25519(stored.identity) == identity)
    }

    @Test func whatWasPastedIsNamed() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        func message(_ text: String) -> String? {
            if case .problem(let issue) = ExistingKeyInput.status(ofText: text) { return ExistingKeyInput.message(issue) }
            return nil
        }
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
        #expect(Set(problems.map { ExistingKeyInput.message($0) }).count == problems.count)
    }

    /// The rules of a wrapped key file are `ExistingKeyInputTests` (Linux); these are the sheet's words for them.
    @Test func aWrongPassphraseAndAnEncryptedNoteAreExplained() {
        #expect(ExistingKeyInput.message(.key(.wrongPassphrase)).contains("passphrase"))
        #expect(ExistingKeyInput.message(.key(.encryptedToKeys)).contains("not a key file"))
        #expect(ExistingKeyInput.message(.unreadable("disk error")).contains("disk error"))
    }

    /// Review of #109: a pick goes to the section whose button opened the picker (the role is kept apart from the
    /// picker's binding, which the Mac's panel clears before it delivers the pick).
    @Test func aPickedFolderGoesToTheSectionThatAskedForIt() {
        var sync: URL?, backup: URL?
        let a = URL(fileURLWithPath: "/tmp/A"), b = URL(fileURLWithPath: "/tmp/B")
        NewVaultView.apply(a, to: .sync, sync: &sync, backup: &backup)
        NewVaultView.apply(b, to: .backup, sync: &sync, backup: &backup)
        #expect(sync == a && backup == b)
        NewVaultView.apply(b, to: nil, sync: &sync, backup: &backup)
        #expect(sync == a && backup == b)
    }

    @Test func eachKeyChoiceSaysWhatItDoes() {
        #expect(NewVaultView.keyFooter(.generate).contains("AGE-SECRET-KEY-PQ-1"))
        #expect(NewVaultView.keyFooter(.existing).contains("AGE-SECRET-KEY-PQ-1"))
        #expect(NewVaultView.keyFooter(.existing).contains("age1pq1"))
        #expect(NewVaultView.keyFooter(.existing).contains("AGE-SECRET-KEY-1"))
    }

    // MARK: - Passphrase

    @Test func autoFillIsAskedForAPasswordInAppleDefaultFormat() {
        // The rules ask for Apple's default format: 20 characters with a digit and a capital.
        #expect(PassphraseTextField.rules.contains("minlength: 20"))
    }

    /// Replace Recovery Kit: an empty first field with a filled "Again" is not agreement (it would delete the old
    /// copy and write none); both empty means no copy.
    @Test func replaceKitNeedsTheTwoEntriesToAgree() {
        #expect(ReplaceKitSheet.passphrasesAgree("", ""))
        #expect(ReplaceKitSheet.passphrasesAgree("a", "a"))
        #expect(!ReplaceKitSheet.passphrasesAgree("", "a"))
        #expect(!ReplaceKitSheet.passphrasesAgree("a", ""))
        #expect(!ReplaceKitSheet.passphrasesAgree("a", "b"))
    }

    @Test func theFootnoteOffersTheSuggestionAndDemandsNothing() {
        #expect(StoredKeyPassphrase.footnote.contains("Suggest a Passphrase"))
        #expect(!StoredKeyPassphrase.footnote.contains("Apple Strong Password"))
    }
}
