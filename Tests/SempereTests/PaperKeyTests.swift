import Foundation
import XCTest
@testable import Sempere

final class PaperKeyTests: XCTestCase {
    // The throwaway fixture key (Fixtures/sample.key).
    let key = "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN"

    func testIdentityLinesJoinBackAndCarryChecksums() {
        let lines = PaperKey.identityLines(key)
        XCTAssertEqual(lines.map(\.text), ["AGE-SECRET-KEY-1", "JQ4L7CGCHC2TE7JUJ7YG", "4Y4DREUWFD7Y6U5XKFZ3",
                                           "EYTNY62Z5PES6MWJVN"])
        XCTAssertEqual(lines.map(\.text).joined(), key)
        XCTAssertEqual(lines.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(lines[1].groups, ["JQ4L7", "CGCHC", "2TE7J", "UJ7YG"])
        XCTAssertEqual(lines[0].groups, ["AGE-SECRET-KEY-1"])
        for l in lines { XCTAssertEqual(l.groups.joined(), l.text) }
    }

    func testChecksumIsTheSha256PrefixStockToolsPrint() {
        // printf '%s' 'JQ4L7CGCHC2TE7JUJ7YG' | sha256sum | cut -c1-4
        XCTAssertEqual(PaperKey.checksum("JQ4L7CGCHC2TE7JUJ7YG"), "907a")
        // printf '%s' '' | sha256sum → e3b0c442...
        XCTAssertEqual(PaperKey.checksum(""), "e3b0")
        // One typo changes the line's checksum.
        XCTAssertNotEqual(PaperKey.checksum("JQ4L7CGCHC2TE7JUJ7YH"), "907a")
    }

    func testTextLinesKeepLinesAsIs() {
        let lines = PaperKey.textLines("-----BEGIN AGE ENCRYPTED FILE-----\nYWdl\n-----END AGE ENCRYPTED FILE-----\n")
        XCTAssertEqual(lines.map(\.text), ["-----BEGIN AGE ENCRYPTED FILE-----", "YWdl", "-----END AGE ENCRYPTED FILE-----"])
        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
    }

    func testPostQuantumIdentityKeepsItsPrefixOnItsOwnLine() {
        // Shape of `age-keygen -pq` output (77 characters); not a real key.
        let pq = "AGE-SECRET-KEY-PQ-15FERYXHRDZ9M6Y09MR8WRERWZGJ6F8NTXVHXYRDLM5AAHN0T09NL4UJY86"
        XCTAssertEqual(pq.count, 77)
        let lines = PaperKey.identityLines(pq)
        XCTAssertEqual(lines.map(\.text), ["AGE-SECRET-KEY-PQ-1", String(pq.dropFirst(19).prefix(20)),
                                           String(pq.dropFirst(39).prefix(20)), String(pq.dropFirst(59))])
        XCTAssertEqual(lines.map(\.text).joined(), pq)
        XCTAssertEqual(lines[0].groups, ["AGE-SECRET-KEY-PQ-1"])
        for l in lines.dropFirst() { XCTAssertTrue(l.groups.dropLast().allSatisfy { $0.count == 5 }, l.text) }
    }

    func testFingerprintIsTheSha256PrefixStockToolsPrint() {
        // printf '' | sha256sum → e3b0c44298fc1c14...
        XCTAssertEqual(PaperKey.fingerprint(""), "e3b0c44298fc1c14")
        XCTAssertEqual(PaperKey.fingerprint("", digits: 4), "e3b0")
        XCTAssertEqual(PaperKey.fingerprint("", digits: 500).count, 64)
        XCTAssertEqual(PaperKey.fingerprint("", digits: -1), "")
    }
}
