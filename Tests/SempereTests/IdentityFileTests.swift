import Age
import Foundation
import XCTest
@testable import Sempere

final class IdentityFileTests: VaultTestCase {
    func testRoundTripWithPassphrase() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let created = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T16:20:00Z"))
        let url = try vault.writeIdentityFile(id, passphrase: "correct horse", workFactor: 15, created: created)
        XCTAssertEqual(url.lastPathComponent, IdentityFile.fileName(for: id.recipient))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("age1pq-"))
        XCTAssertEqual(try vault.identityFiles(), [id.recipient])

        // Plaintext is age-keygen style under a single scrypt stanza.
        let data = try Data(contentsOf: url)
        let stanzas = try AgeFile.parseHeader(data).header.stanzas
        XCTAssertEqual(stanzas.map(\.type), ["scrypt"])
        XCTAssertEqual(stanzas[0].args.last, "15")
        let text = String(decoding: try AgeFile.decrypt(data, with: [ScryptIdentity(passphrase: "correct horse")]),
                          as: UTF8.self)
        XCTAssertEqual(text, "# created: 2026-10-04T16:20:00Z\n# public key: \(id.recipient.string)\n\(id.string)\n")

        // A locked vault can read it, and the identity then unlocks the vault.
        let locked = try Vault.open(at: vault.url)
        let back = try locked.readIdentityFile(recipient: id.recipient, passphrase: "correct horse")
        XCTAssertEqual(back.string, id.string)
        XCTAssertFalse(try Vault.open(at: vault.url, identities: [back]).isLocked)

        XCTAssertThrowsError(try vault.readIdentityFile(recipient: id.recipient, passphrase: "wrong")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        XCTAssertThrowsError(try vault.writeIdentityFile(id, passphrase: "x", workFactor: 15)) {
            guard case .alreadyExists = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        try vault.writeIdentityFile(id, passphrase: "new", workFactor: 15, replace: true)
        XCTAssertNotEqual(try Data(contentsOf: url), data, "replaced")
        let stranger = pqIdentity().recipient
        XCTAssertThrowsError(try vault.readIdentityFile(recipient: stranger, passphrase: "new")) {
            XCTAssertEqual($0 as? VaultError, .identityFileMissing(IdentityFile.fileName(for: stranger)))
        }
    }

    /// A classic X25519 key is never stored in `keys/`: no vault lists one
    /// (format.md §3.1).
    func testClassicIdentityIsNotWritten() throws {
        let vault = try makeVault(pqIdentity())
        let classic = NativeIdentity.x25519(X25519Identity())
        XCTAssertThrowsError(try vault.writeIdentityFile(classic, passphrase: "p", workFactor: 15)) {
            XCTAssertEqual($0 as? VaultError, .classicRecipient(classic.recipient.string))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.keysURL.path), [])
        XCTAssertFalse(IdentityFile.isKeyFileName(classic.recipient.string + ".key.age"))
    }

    /// No key file is written under an empty passphrase (as the app
    /// refuses one); one written earlier by another writer still opens.
    func testEmptyPassphraseIsNotWrittenButStillRead() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        XCTAssertThrowsError(try vault.writeIdentityFile(id, passphrase: "", workFactor: 15)) {
            XCTAssertEqual($0 as? VaultError, .emptyPassphrase)
        }
        XCTAssertEqual(try vault.identityFiles(), [], "nothing written")
        let wrapped = try AgeFile.encrypt(Data(IdentityFile.render(id, created: Date()).utf8),
                                          to: [ScryptRecipient(passphrase: "", workFactor: 15)])
        try FileManager.default.createDirectory(at: vault.keysURL, withIntermediateDirectories: true)
        try wrapped.write(to: vault.keysURL.appendingPathComponent(IdentityFile.fileName(for: id.recipient)))
        XCTAssertEqual(try vault.readIdentityFile(recipient: id.recipient, passphrase: "").string, id.string)
    }

    func testWriterWorkFactorRange() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        for wf in [1, 14, 19, 22] {
            XCTAssertThrowsError(try vault.writeIdentityFile(id, passphrase: "p", workFactor: wf)) {
                XCTAssertEqual($0 as? VaultError, .workFactorOutOfRange(wf))
            }
        }
        XCTAssertEqual(try vault.identityFiles(), [])
    }

    func testWorkFactorAboveCapIsRefused() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let url = try vault.writeIdentityFile(id, passphrase: "p", workFactor: 15)
        // Reader with a lower cap.
        XCTAssertThrowsError(try vault.readIdentityFile(recipient: id.recipient, passphrase: "p", maxWorkFactor: 14)) {
            XCTAssertEqual($0 as? VaultError, .workFactorTooHigh)
        }
        // A file claiming work factor 21 (above the default cap of 20) is
        // refused before any scrypt work, so editing the header is enough.
        var data = try Data(contentsOf: url)
        let marker = Data("-> scrypt ".utf8)
        let start = try XCTUnwrap(data.range(of: marker)).upperBound
        let eol = try XCTUnwrap(data[start...].firstIndex(of: 0x0A))
        XCTAssertEqual(Data(data[(eol - 3)..<eol]), Data(" 15".utf8))
        data.replaceSubrange((eol - 2)..<eol, with: Data("21".utf8))
        try data.write(to: url)
        XCTAssertThrowsError(try vault.readIdentityFile(recipient: id.recipient, passphrase: "p")) {
            XCTAssertEqual($0 as? VaultError, .workFactorTooHigh)
        }
    }

    /// An interrupted key replacement is finished with the passphrase alone:
    /// while the journal exists, the old key's stored file (no longer listed)
    /// is tried too, after the listed ones (B21).
    func testPassphraseUnlockFinishesAnInterruptedReplacement() throws {
        let old = pqIdentity(), new = pqIdentity()
        var vault = try makeVault(old)
        let revs = try populate(vault)
        try vault.writeIdentityFile(old, passphrase: "pw", workFactor: 15)
        try vault.writeIdentityFile(new, passphrase: "pw", workFactor: 15)
        XCTAssertThrowsError(try vault.replaceRecipient(old.recipient, with: new.recipient, label: nil, added: Date(),
                                                        stopAfter: 1))
        let locked = try Vault.open(at: vaultURL())
        let ids = try locked.identitiesFromKeyFiles(passphrase: "pw")
        XCTAssertEqual(ids.first?.recipient, new.recipient, "the listed key first")
        var again = try Vault.open(at: vaultURL(), identities: ids)
        let report = try again.resumeRewrap()
        XCTAssertTrue(report.isComplete, "\(report.failures)")
        XCTAssertFalse(again.pendingRewrap)
        try assertReadable(revs, at: vaultURL(), by: new)
        // Nothing pending: the old key is not offered.
        XCTAssertEqual(try Vault.open(at: vaultURL()).identitiesFromKeyFiles(passphrase: "pw").map(\.recipient),
                       [new.recipient])
    }

    func testParseAgeKeygenText() throws {
        let id = pqIdentity()
        XCTAssertEqual(try IdentityFile.parse("\(id.string)\n").string, id.string)
        XCTAssertEqual(try IdentityFile.parse(IdentityFile.render(id, created: Date())).string, id.string)
        XCTAssertThrowsError(try IdentityFile.parse("# only comments\n")) {
            XCTAssertEqual($0 as? VaultError, .identityFileMalformed)
        }
        let other = pqIdentity().recipient.string
        XCTAssertThrowsError(try IdentityFile.parse("# public key: \(other)\n\(id.string)\n")) {
            XCTAssertEqual($0 as? VaultError, .identityMismatch(other))
        }
    }

    func testExportFileName() {
        XCTAssertEqual(IdentityFile.exportFileName(label: "Anna's iPad"), "Sempere key - Anna's iPad.txt")
        XCTAssertEqual(IdentityFile.exportFileName(label: ""), "Sempere key.txt")
        XCTAssertEqual(IdentityFile.exportFileName(label: " \n\t "), "Sempere key.txt")
        XCTAssertEqual(IdentityFile.exportFileName(label: "../a/b:c\nd"), "Sempere key - .. a b c d.txt")
        XCTAssertEqual(IdentityFile.exportFileName(label: "x\u{0}y"), "Sempere key - x y.txt")
        let long = IdentityFile.exportFileName(label: String(repeating: "é", count: 200))
        XCTAssertEqual(long, "Sempere key - \(String(repeating: "é", count: 60)).txt")
    }
}
