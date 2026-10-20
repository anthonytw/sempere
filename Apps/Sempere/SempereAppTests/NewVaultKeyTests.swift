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

    static let strong = "lunar-pickle-tundra-mosaic-quiver-banjo"

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
        // Another vault's passphrase copy of its recovery key (format.md §15.11).
        var request = NewVaultRequest(name: "Other", keySource: .identity(identity), passphrase: Self.strong)
        request.workFactor = 10
        let other = try VaultLibrary.createVault(request, folder: "Other.sempere", in: try BrowserTests.tempDir())
        let name = try #require(try Vault.open(at: other.url).passphraseCopyNames().first)
        let data = try Data(contentsOf: other.url.appendingPathComponent("keys").appendingPathComponent(name))
        guard case .needsPassphrase(let wrapped) = ExistingKeyInput.status(ofFile: data) else {
            Issue.record("not recognised as a wrapped key file")
            return
        }
        #expect(ExistingKeyInput.unwrap(wrapped, passphrase: Self.strong) == .ready(identity))
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
    }

    // MARK: - Passphrase checklist

    @Test func theChecklistUpdatesAsTheUserTypes() {
        func met(_ p: String, _ c: String) -> [Bool] { StoredKeyPassphrase.requirements(p, confirmation: c).map(\.met) }
        #expect(met("", "") == [false, false])
        #expect(met("lunar", "lunar") == [false, true])
        #expect(met(Self.strong, "") == [true, false])
        #expect(met(Self.strong, Self.strong) == [true, true])
        // Apple's generated passwords (c26) pass.
        #expect(met("vuspot-Bekfu4-qobqag", "vuspot-Bekfu4-qobqag") == [true, true])
        let line = StoredKeyPassphrase.requirements("lunar", confirmation: "").first?.text ?? ""
        #expect(line.contains("70"))
        #expect(StoredKeyPassphrase.progress("") == 0)
        #expect(StoredKeyPassphrase.progress(Self.strong) == 1)
    }

    @Test func hintsSayWhyWhileItIsWeak() {
        #expect(StoredKeyPassphrase.hints("").isEmpty)
        #expect(StoredKeyPassphrase.hints("qwertyuiop").contains { $0.contains("keyboard") })
        #expect(StoredKeyPassphrase.hints("password1").contains { $0.contains("common") })
        #expect(StoredKeyPassphrase.hints("lunar pickle").contains { $0.contains("six or more") })
        #expect(StoredKeyPassphrase.hints(Self.strong).isEmpty, "strong: no hints")
    }

    @Test func autoFillIsAskedForAPasswordThatPasses() {
        // The rules ask for Apple's default format: 20 characters with a digit and a capital.
        #expect(PassphraseTextField.rules.contains("minlength: 20"))
        #expect(StoredKeyPassphrase.accepts("zixwos-gUnhy4-bobsuc"))
    }
}
