import Foundation
import XCTest

@testable import Age

final class KeyTests: XCTestCase {
    // From the age spec (c2sp.org/age, "The X25519 recipient type"): the
    // identity is the 32 bytes 0x42 ("BBBB..."); the recipient is its public key.
    static let specIdentity = "AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX"
    static let specRecipient = "age1zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj"

    func testSpecExampleKeys() throws {
        let id = try X25519Identity(string: Self.specIdentity)
        XCTAssertEqual(id.string, Self.specIdentity)
        XCTAssertEqual(id.secretKey, Data(repeating: 0x42, count: 32))
        XCTAssertEqual(id.recipient.string, Self.specRecipient)
        let r = try X25519Recipient(string: Self.specRecipient)
        XCTAssertEqual(r, id.recipient)
        XCTAssertEqual(r.string, Self.specRecipient)
    }

    func testGeneratedKeysRoundTrip() throws {
        let id = X25519Identity()
        XCTAssertTrue(id.string.hasPrefix("AGE-SECRET-KEY-1"))
        XCTAssertEqual(id.string, id.string.uppercased())
        XCTAssertTrue(id.recipient.string.hasPrefix("age1"))
        XCTAssertEqual(try X25519Identity(string: id.string).string, id.string)
        XCTAssertEqual(try X25519Recipient(string: id.recipient.string), id.recipient)
    }

    func testBadChecksumRejected() {
        var s = Array(Self.specRecipient)
        s[s.count - 1] = s[s.count - 1] == "q" ? "p" : "q"
        XCTAssertThrowsError(try X25519Recipient(string: String(s))) { XCTAssertEqual($0 as? AgeError, .invalidKey) }
        var i = Array(Self.specIdentity)
        i[20] = i[20] == "Q" ? "P" : "Q"
        XCTAssertThrowsError(try X25519Identity(string: String(i))) { XCTAssertEqual($0 as? AgeError, .invalidKey) }
    }

    func testMixedCaseRejected() {
        let mixedRecipient = "Age1" + Self.specRecipient.dropFirst(4)
        XCTAssertNil(Bech32.decode(String(mixedRecipient)))
        XCTAssertThrowsError(try X25519Recipient(string: String(mixedRecipient)))
        let mixedIdentity = Self.specIdentity.prefix(20) + Self.specIdentity.dropFirst(20).lowercased()
        XCTAssertThrowsError(try X25519Identity(string: String(mixedIdentity)))
    }

    func testCaseAndTypeMustMatchAge() {
        // age accepts recipients only lowercase and identities only uppercase.
        XCTAssertThrowsError(try X25519Recipient(string: Self.specRecipient.uppercased()))
        XCTAssertThrowsError(try X25519Identity(string: Self.specIdentity.lowercased()))
        // Swapping the HRPs is a type error.
        XCTAssertThrowsError(try X25519Recipient(string: Self.specIdentity))
        XCTAssertThrowsError(try X25519Identity(string: Self.specRecipient))
        XCTAssertThrowsError(try X25519Recipient(string: ""))
        XCTAssertThrowsError(try X25519Recipient(string: "age1"))
    }

    func testBech32NoLengthLimit() throws {
        let data = [UInt8](repeating: 0xAB, count: 200)
        let s = try XCTUnwrap(Bech32.encode(hrp: "test", data: data))
        XCTAssertGreaterThan(s.count, 90)
        let decoded = try XCTUnwrap(Bech32.decode(s))
        XCTAssertEqual(decoded.hrp, "test")
        XCTAssertEqual(decoded.data, data)
        let upper = try XCTUnwrap(Bech32.encode(hrp: "TEST", data: data))
        XCTAssertEqual(upper, s.uppercased())
    }

    func testBIP173ValidChecksums() {
        // Valid Bech32 strings from BIP 173 (those whose data part is also
        // valid 8-bit data, since decode() converts it).
        for s in [
            "A12UEL5L", "a12uel5l",
            "an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
            "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
            "split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w",
        ] {
            XCTAssertNotNil(Bech32.decode(s), s)
        }
        for s in ["pzry9x0s0muk", "1pzry9x0s0muk", "x1b4n0q5v", "li1dgmt3", "A1G7SGD8", "10a06t8", "1qzzfhee"] {
            XCTAssertNil(Bech32.decode(s), s)
        }
    }
}
