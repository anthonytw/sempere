import Age
import Foundation
import XCTest
@testable import Sempere

/// "Use an existing key" (New Vault in the app, identity files in the CLI):
/// what is accepted, and the error naming what was given otherwise.
final class KeyTextTests: XCTestCase {
    private func identity() throws -> NativeIdentity {
        try XCTSkipUnless(postQuantumAvailable)
        return try NativeIdentity.generate(.postQuantum)
    }

    private func accepted(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> NativeIdentity? {
        switch KeyText.classify(input) {
        case .success(.identity(let id)): return id
        case .success(.passphraseWrapped): XCTFail("wrapped", file: file, line: line)
        case .failure(let problem): XCTFail("\(problem)", file: file, line: line)
        }
        return nil
    }

    private func problem(_ input: String) -> KeyText.Problem? {
        if case .failure(let p) = KeyText.classify(input) { return p }
        return nil
    }

    func testTheSecretKeyAloneOrInAgeKeygenOutputIsAccepted() throws {
        let id = try identity()
        let keygen = IdentityFile.render(id, created: Date())
        for input in [id.string, keygen, "  \(id.string)  \n", keygen.replacingOccurrences(of: "\n", with: "\r\n"),
                      "\u{FEFF}\(id.string)", "\u{200B}\(id.string)\u{00A0}", "\t\n\n\(id.string)\n\n",
                      id.string.lowercased(), "Public key: \(id.recipient.string)\n\(id.string)",
                      "\"\(id.string)\"", "# a note\n# created: 2026-10-14T10:00:00Z\n\(id.string)\n# trailing",
                      "\(id.string)\n\(id.string)"] {
            XCTAssertEqual(accepted(input), id, input.prefix(40).description)
        }
    }

    func testPublicKeysAreRefusedNamingThem() throws {
        let id = try identity()
        guard case .publicKey(let shown) = problem(id.recipient.string) else { return XCTFail("\(String(describing: problem(id.recipient.string)))") }
        XCTAssertTrue(shown.hasPrefix("age1pq1"))
        XCTAssertLessThan(shown.count, 40, "abbreviated")
        XCTAssertTrue(KeyText.Problem.publicKey(shown).description.contains("public key"))
        guard case .publicKey = problem("# public key: \(id.recipient.string)\n") else { return XCTFail() }
        guard case .publicKey = problem("Public key: \(id.recipient.string)") else { return XCTFail() }
    }

    func testClassicKeysAreRefused() throws {
        let classic = try NativeIdentity.generate(.x25519)
        XCTAssertEqual(problem(classic.string), .classicSecretKey)
        XCTAssertEqual(problem(IdentityFile.render(classic, created: Date())), .classicSecretKey)
        guard case .classicPublicKey(let shown) = problem(classic.recipient.string) else { return XCTFail() }
        XCTAssertEqual(shown, classic.recipient.string)
    }

    func testDamagedSeveralAndMismatchedKeysAreRefused() throws {
        let id = try identity(), other = try identity()
        XCTAssertEqual(problem(String(id.string.dropLast(5))), .damagedSecretKey)
        XCTAssertEqual(problem(id.string + "x"), .damagedSecretKey)
        XCTAssertEqual(problem("\(id.string)\n\(other.string)"), .severalSecretKeys(2))
        guard case .mismatchedPublicKey = problem("# public key: \(other.recipient.string)\n\(id.string)") else {
            return XCTFail()
        }
        // A secret key commented out is not offered.
        guard case .publicKey = problem("# \(id.string)\n# public key: \(id.recipient.string)") else { return XCTFail() }
    }

    func testOtherInputIsNotAKeyAndNeverEchoed() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem(" \n\t\r\n "), .empty)
        XCTAssertEqual(problem("correct horse battery staple"), .notAKey)
        XCTAssertEqual(problem("AGE-PLUGIN-YUBIKEY-1QQQ"), .notAKey)
        XCTAssertFalse(KeyText.Problem.notAKey.description.contains("horse"))
        let huge = String(repeating: "a", count: KeyText.maximumBytes + 1)
        XCTAssertEqual(problem(huge), .tooLarge(KeyText.maximumBytes + 1))
        XCTAssertEqual(problem(String(repeating: "AGE-SECRET-KEY-PQ-1", count: 3000)), .damagedSecretKey)
        if case .failure(.notAKey) = KeyText.classify(Data([0xFF, 0xFE, 0x00, 0x01])) {} else { XCTFail() }
    }

    func testPassphraseWrappedKeyFilesOpenWithTheirPassphrase() throws {
        let id = try identity()
        let plain = Data(IdentityFile.render(id, created: Date()).utf8)
        for armor in [false, true] {
            let wrapped = try AgeFile.encrypt(plain, to: [ScryptRecipient(passphrase: "lunar pickle", workFactor: 10)],
                                              armor: armor)
            guard case .success(.passphraseWrapped(let data)) = KeyText.classify(wrapped) else { return XCTFail() }
            XCTAssertEqual(try KeyText.unwrap(data, passphrase: "lunar pickle").get(), id)
            XCTAssertEqual(KeyText.unwrap(data, passphrase: "wrong"), .failure(.wrongPassphrase))
            XCTAssertEqual(KeyText.unwrap(data, passphrase: ""), .failure(.wrongPassphrase))
            if armor {
                // Pasted armored text works too.
                guard case .success(.passphraseWrapped) = KeyText.classify(String(decoding: wrapped, as: UTF8.self)) else {
                    return XCTFail()
                }
            }
        }
        // A wrapped classic key is refused once opened.
        let classic = try NativeIdentity.generate(.x25519)
        let wrappedClassic = try AgeFile.encrypt(Data(classic.string.utf8),
                                                 to: [ScryptRecipient(passphrase: "p", workFactor: 10)])
        XCTAssertEqual(KeyText.unwrap(wrappedClassic, passphrase: "p"), .failure(.classicSecretKey))
        // Too much scrypt work for the cap.
        let costly = try AgeFile.encrypt(plain, to: [ScryptRecipient(passphrase: "p", workFactor: 12)])
        XCTAssertEqual(KeyText.unwrap(costly, passphrase: "p", maxWorkFactor: 11), .failure(.workFactorTooHigh))
    }

    func testAgeFilesNotForAPassphraseOrDamagedAreRefused() throws {
        let id = try identity()
        let toKey = try AgeFile.encrypt(Data("x".utf8), to: [id.recipient])
        if case .failure(.encryptedToKeys) = KeyText.classify(toKey) {} else { XCTFail() }
        var damaged = try AgeFile.encrypt(Data("x".utf8), to: [ScryptRecipient(passphrase: "p", workFactor: 10)])
        damaged = damaged.prefix(30)
        if case .failure(.damagedFile) = KeyText.classify(damaged) {} else { XCTFail() }
        if case .failure(.damagedFile) = KeyText.classify("-----BEGIN AGE ENCRYPTED FILE-----\n!!!\n-----END AGE ENCRYPTED FILE-----\n") {
        } else { XCTFail() }
    }
}
