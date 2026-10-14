import Foundation
import XCTest

@testable import Age

final class RoundTripTests: XCTestCase {
    static let sizes = [0, 1, 64 * 1024, 64 * 1024 + 1, 200 * 1024 + 7]

    func random(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    func testX25519RoundTrips() throws {
        let id = X25519Identity()
        for size in Self.sizes {
            let plaintext = random(size)
            for armor in [false, true] {
                let ct = try AgeFile.encrypt(plaintext, to: [id.recipient], armor: armor)
                XCTAssertEqual(Armor.isArmored(ct), armor)
                XCTAssertEqual(try AgeFile.decrypt(ct, with: [id]), plaintext, "size \(size) armor \(armor)")
            }
        }
    }

    func testScryptRoundTrips() throws {
        // Low work factor keeps the debug suite fast; the format is identical.
        let recipient = ScryptRecipient(passphrase: "correct horse battery staple", workFactor: 10)
        let identity = ScryptIdentity(passphrase: "correct horse battery staple")
        for size in Self.sizes {
            let plaintext = random(size)
            for armor in [false, true] {
                let ct = try AgeFile.encrypt(plaintext, to: [recipient], armor: armor)
                XCTAssertEqual(try AgeFile.decrypt(ct, with: [identity]), plaintext, "size \(size) armor \(armor)")
            }
        }
        let ct = try AgeFile.encrypt(Data("x".utf8), to: [recipient])
        let (header, _) = try AgeFile.parseHeader(ct)
        XCTAssertEqual(header.stanzas.count, 1)
        XCTAssertEqual(header.stanzas[0].type, "scrypt")
        XCTAssertEqual(header.stanzas[0].args[1], "10")
        XCTAssertThrowsError(try AgeFile.decrypt(ct, with: [ScryptIdentity(passphrase: "wrong")])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try AgeFile.decrypt(ct, with: [ScryptIdentity(passphrase: "correct horse battery staple", maxWorkFactor: 9)])) {
            XCTAssertEqual($0 as? AgeError, .scryptWorkFactor)
        }
    }

    func testScryptMustBeAlone() {
        XCTAssertThrowsError(
            try AgeFile.encrypt(Data(), to: [ScryptRecipient(passphrase: "a", workFactor: 2), X25519Identity().recipient])
        ) { XCTAssertEqual($0 as? AgeError, .scryptNotAlone) }
        XCTAssertThrowsError(try AgeFile.encrypt(Data(), to: [ScryptRecipient(passphrase: "a", workFactor: 31)])) {
            XCTAssertEqual($0 as? AgeError, .scryptWorkFactor)
        }
    }

    func testMultipleRecipients() throws {
        let a = X25519Identity(), b = X25519Identity(), c = X25519Identity()
        let plaintext = random(1000)
        let ct = try AgeFile.encrypt(plaintext, to: [a.recipient, b.recipient])
        XCTAssertEqual(try AgeFile.parseHeader(ct).header.stanzas.count, 2)
        XCTAssertEqual(try AgeFile.decrypt(ct, with: [a]), plaintext)
        XCTAssertEqual(try AgeFile.decrypt(ct, with: [b]), plaintext)
        XCTAssertEqual(try AgeFile.decrypt(ct, with: [c, b]), plaintext)
    }

    func testWrongIdentity() throws {
        let ct = try AgeFile.encrypt(Data("hi".utf8), to: [X25519Identity().recipient])
        XCTAssertThrowsError(try AgeFile.decrypt(ct, with: [X25519Identity()])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try AgeFile.decrypt(ct, with: [ScryptIdentity(passphrase: "x")])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try AgeFile.encrypt(Data(), to: [])) { XCTAssertEqual($0 as? AgeError, .noRecipients) }
    }

    func testTamperedPayload() throws {
        let id = X25519Identity()
        let plaintext = random(70_000)
        let ct = try AgeFile.encrypt(plaintext, to: [id.recipient])
        let start = try AgeFile.parseHeader(ct).payloadStart

        // Flip one byte in the second chunk: the first chunk is still released.
        var flipped = ct
        let secondChunk: Int = start + Stream.nonceSize + Stream.encryptedChunkSize
        flipped[secondChunk + 10] ^= 1
        var released = Data()
        XCTAssertThrowsError(try AgeFile.decrypt(binary: flipped, with: [id], released: &released)) {
            XCTAssertEqual($0 as? AgeError, .payload)
        }
        XCTAssertEqual(released, plaintext.prefix(65_536))

        // Truncate the final chunk.
        XCTAssertThrowsError(try AgeFile.decrypt(ct.dropLast(1), with: [id])) { XCTAssertEqual($0 as? AgeError, .payload) }
        // Drop the final chunk entirely: the file ends after a non-final chunk.
        XCTAssertThrowsError(try AgeFile.decrypt(ct.prefix(secondChunk), with: [id])) {
            XCTAssertEqual($0 as? AgeError, .payload)
        }
        // Trailing data.
        XCTAssertThrowsError(try AgeFile.decrypt(ct + Data([0]), with: [id])) { XCTAssertEqual($0 as? AgeError, .payload) }
        // Header tampering is caught by the MAC.
        var header = ct
        let (h, _) = try AgeFile.parseHeader(ct)
        var stanzas = h.stanzas
        stanzas.append(Stanza(type: "grease", args: ["x"], body: Data()))
        var forged = Data(try HeaderCodec.encodeWithoutMAC(stanzas))
        forged += Data(" \(Base64.encodeRaw(h.mac))\n".utf8)
        forged += ct.dropFirst(start)
        XCTAssertThrowsError(try AgeFile.decrypt(forged, with: [id])) { XCTAssertEqual($0 as? AgeError, .headerMAC) }
        header[0] = UInt8(ascii: "b")
        XCTAssertThrowsError(try AgeFile.decrypt(header, with: [id])) { XCTAssertEqual($0 as? AgeError, .headerParse) }
    }

    func testStanzaBodyWrapping() throws {
        // Bodies that are exact multiples of 48 bytes end with an empty line.
        for n in [0, 1, 47, 48, 49, 96, 100] {
            let s = Stanza(type: "test", args: ["a", "b"], body: random(n))
            var encoded: [UInt8] = try HeaderCodec.encodeWithoutMAC([s])
            encoded += Array(" \(Base64.encodeRaw(Data(count: 32)))\n".utf8)
            let (h, start) = try AgeFile.parseHeader(Data(encoded))
            XCTAssertEqual(h.stanzas, [s], "body \(n)")
            XCTAssertEqual(start, encoded.count)
            let lines = String(decoding: encoded, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 64 || $0.hasPrefix("->") || $0.hasPrefix("---") })
        }
        XCTAssertThrowsError(try HeaderCodec.encodeStanza(Stanza(type: "a b", args: [], body: Data())))
        XCTAssertThrowsError(try HeaderCodec.encodeStanza(Stanza(type: "a", args: [""], body: Data())))
    }

    func testGreaseIsIgnored() throws {
        let id = X25519Identity()
        struct Grease: AgeRecipient {
            func wrap(fileKey: FileKey) throws -> [Stanza] {
                [Stanza(type: "example.com/grease", args: ["!x~"], body: Data(repeating: 7, count: 100))]
            }
        }
        let ct = try AgeFile.encrypt(Data("ok".utf8), to: [Grease(), id.recipient])
        XCTAssertEqual(try AgeFile.decrypt(ct, with: [id]), Data("ok".utf8))
    }

    func testArmorFormat() throws {
        let ct = try AgeFile.encrypt(random(500), to: [X25519Identity().recipient], armor: true)
        let text = String(decoding: ct, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("-----BEGIN AGE ENCRYPTED FILE-----\n"))
        XCTAssertTrue(text.hasSuffix("\n-----END AGE ENCRYPTED FILE-----\n"))
        let body = text.split(separator: "\n").dropFirst().dropLast()
        XCTAssertTrue(body.dropLast().allSatisfy { $0.count == 64 })
        XCTAssertLessThanOrEqual(body.last?.count ?? 0, 64)
        // Exactly 48 * k bytes: no short line, footer straight after.
        XCTAssertEqual(
            String(decoding: Armor.encode(Data(count: 96)), as: UTF8.self).split(separator: "\n").count, 4)
        XCTAssertEqual(
            String(decoding: Armor.encode(Data()), as: UTF8.self),
            "-----BEGIN AGE ENCRYPTED FILE-----\n-----END AGE ENCRYPTED FILE-----\n")
    }

    func testBase64Strictness() {
        XCTAssertEqual(Base64.decodeRaw("AAAA".utf8), [0, 0, 0])
        XCTAssertNil(Base64.decodeRaw("AB".utf8))  // non-zero trailing bits
        XCTAssertNil(Base64.decodeRaw("AA==".utf8))  // padding
        XCTAssertNil(Base64.decodeRaw("A".utf8))
        XCTAssertNil(Base64.decodeRaw("AA\nA".utf8))
        XCTAssertEqual(Base64.decodePadded("AA==".utf8), [0])
        XCTAssertNil(Base64.decodePadded("AB==".utf8))
        XCTAssertNil(Base64.decodePadded("AA".utf8))
        XCTAssertNil(Base64.decodePadded("A===".utf8))
        XCTAssertNil(Base64.decodePadded("AA=A".utf8))
    }
}

final class HeaderRuleTests: XCTestCase {
    /// A header mixing scrypt with X25519 must be rejected even when an
    /// X25519 identity (which ignores the scrypt stanza) would match.
    func testScryptMixedHeaderRejectedForX25519Identity() throws {
        let id = X25519Identity()
        let fileKey = FileKey()
        var stanzas = try id.recipient.wrap(fileKey: fileKey)
        stanzas += try ScryptRecipient(passphrase: "p", workFactor: 2).wrap(fileKey: fileKey)
        var file = Data(try HeaderCodec.encodeWithoutMAC(stanzas))
        let mac = HeaderCodec.mac(fileKey: fileKey, macInput: file)
        file += Data(" \(Base64.encodeRaw(mac))\n".utf8)
        let nonce = Data(repeating: 9, count: Stream.nonceSize)
        file += nonce
        file += try Stream.encrypt(Data("x".utf8), key: Stream.payloadKey(fileKey: fileKey, nonce: nonce))
        XCTAssertThrowsError(try AgeFile.decrypt(file, with: [id])) {
            XCTAssertEqual($0 as? AgeError, .scryptNotAlone)
        }
    }

    func testScryptMemoryBudget() throws {
        let ct = try AgeFile.encrypt(Data("x".utf8), to: [ScryptRecipient(passphrase: "p", workFactor: 10)])
        // 2^10 KiB = 1 MiB needed.
        XCTAssertThrowsError(try AgeFile.decrypt(ct, with: [ScryptIdentity(passphrase: "p", maxMemoryBytes: 1 << 19)])) {
            XCTAssertEqual($0 as? AgeError, .scryptWorkFactor)
        }
        XCTAssertEqual(
            try AgeFile.decrypt(ct, with: [ScryptIdentity(passphrase: "p", maxMemoryBytes: 1 << 20)]), Data("x".utf8))
        XCTAssertNil(Scrypt.derive(password: [], salt: [], n: 1 << 20, r: 8, p: 1, keyLength: 32, maxMemoryBytes: 1 << 29))
        XCTAssertEqual(Scrypt.memoryBytes(n: 1 << 20, r: 8), 1 << 30)
        XCTAssertNil(Scrypt.memoryBytes(n: 1 << 62, r: 8))
    }

    func testVersionLineErrors() {
        func parse(_ s: String) -> AgeError? {
            do {
                _ = try AgeFile.parseHeader(Data(s.utf8))
                return nil
            } catch { return error as? AgeError }
        }
        let rest = "-> x\n\n--- " + Base64.encodeRaw(Data(count: 32)) + "\n"
        XCTAssertNil(parse("age-encryption.org/v1\n" + rest))
        XCTAssertEqual(parse("age-encryption.org/v1\r\n" + rest), .headerParse)
        XCTAssertEqual(parse("age-encryption.org/v2\n" + rest), .unsupportedVersion)
        XCTAssertEqual(parse("age-encryption.org/\n" + rest), .headerParse)
        XCTAssertEqual(parse("age-encryption.org/v 2\n" + rest), .headerParse)
        XCTAssertEqual(parse("garbage\n" + rest), .headerParse)
    }

    func testManyStanzaArgumentsAccepted() throws {
        let s = Stanza(type: "many", args: (0..<300).map { "a\($0)" }, body: Data())
        var encoded: [UInt8] = try HeaderCodec.encodeWithoutMAC([s])
        encoded += Array(" \(Base64.encodeRaw(Data(count: 32)))\n".utf8)
        XCTAssertEqual(try AgeFile.parseHeader(Data(encoded)).header.stanzas, [s])
    }
}
