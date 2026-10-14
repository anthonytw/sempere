import Age
import Foundation
import XCTest
@testable import Sempere

final class BodyFramingTests: VaultTestCase {
    let note = "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c"
    let file = "17596320000000003-a1b2c3d4-12.delta.age"
    let json = Data(#"{"type":"delta","ops":[]}"#.utf8)

    func testGzipRoundTripAndStrictness() throws {
        let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for input in [Data(), json, big] {
            let gz = try Gzip.compress(input)
            XCTAssertEqual(Array(gz.prefix(2)), [0x1F, 0x8B], "gzip magic")
            XCTAssertEqual(gz[9], 255, "OS byte is fixed for cross-platform determinism")
            XCTAssertEqual(try Gzip.decompress(gz), input)
        }
        let gz = try Gzip.compress(big)
        XCTAssertThrowsError(try Gzip.decompress(gz.dropLast(1)))          // truncated
        XCTAssertThrowsError(try Gzip.decompress(gz + Data([0])))          // trailing bytes
        XCTAssertThrowsError(try Gzip.decompress(Data("not gzip".utf8)))
        XCTAssertThrowsError(try Gzip.decompress(gz, maxOutput: 1000)) { error in
            XCTAssertEqual(error as? GzipError, .tooLarge(limit: 1000))
        }
    }

    /// zlib's `avail_in` is 32-bit: input of 4 GiB or more (a zip64 entry)
    /// must be fed in slices, not trap converting its length. Small slices
    /// exercise the same refill, with the same strictness.
    func testInflateFeedsInputInSlices() throws {
        let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) })
        let gz = try Gzip.compress(big)
        let gzipBits: Int32 = 15 + 16
        for slice in [1, 7, 4096, gz.count - 1, gz.count, gz.count + 1] {
            XCTAssertEqual(try Gzip.inflateStream(gz, windowBits: gzipBits, maxOutput: 1 << 20, maxInputSlice: slice),
                           big, "slice \(slice)")
            XCTAssertThrowsError(try Gzip.inflateStream(gz.dropLast(1), windowBits: gzipBits, maxOutput: 1 << 20,
                                                        maxInputSlice: slice), "truncated, slice \(slice)")
            XCTAssertThrowsError(try Gzip.inflateStream(gz + Data([0]), windowBits: gzipBits, maxOutput: 1 << 20,
                                                        maxInputSlice: slice), "trailing byte, slice \(slice)")
        }
    }

    func testRoundTrip() throws {
        let secret = VaultSecret.random()
        let framed = try BodyFraming.frame(json: json, noteId: note, filename: file, secret: secret)
        XCTAssertEqual(Array(framed.prefix(5)), Array("SMPR".utf8) + [1])
        let un = try BodyFraming.unframe(framed, noteId: note, filename: file, secret: secret)
        XCTAssertTrue(un.verified)
        XCTAssertEqual(try Gzip.decompress(un.gzip), json)
        // The recovery path skips exactly 37 bytes.
        XCTAssertEqual(Data(framed.dropFirst(37)), un.gzip)
        XCTAssertEqual(Data(framed[5..<37]), BodyFraming.tag(gzip: un.gzip, noteId: note, filename: file, secret: secret))
    }

    /// Known answer computed with Python's `hmac` over the message layout of
    /// format.md §4.
    func testTagKnownAnswer() throws {
        let secret = try VaultSecret(bytes: Data(0..<32))
        let tag = BodyFraming.tag(gzip: Data("gzip-bytes".utf8), noteId: note, filename: file, secret: secret)
        XCTAssertEqual(tag.map { String(format: "%02x", $0) }.joined(),
                       "a3916b8445d2f161c500931a5565501b80780428843018f147291c3ebdc0a15f")
    }

    func testFlippedByteIsTagMismatch() throws {
        let secret = VaultSecret.random()
        let framed = try BodyFraming.frame(json: json, noteId: note, filename: file, secret: secret)
        for i in [5, 20, 36, 40, framed.count - 1] {
            var bad = framed
            bad[i] ^= 0x80
            XCTAssertThrowsError(try BodyFraming.unframe(bad, noteId: note, filename: file, secret: secret)) {
                XCTAssertEqual($0 as? BodyFramingError, .tagMismatch, "byte \(i)")
            }
        }
        XCTAssertThrowsError(try BodyFraming.unframe(framed, noteId: note, filename: file, secret: .random())) {
            XCTAssertEqual($0 as? BodyFramingError, .tagMismatch)
        }
    }

    func testBindingToNoteAndFileName() throws {
        let secret = VaultSecret.random()
        let framed = try BodyFraming.frame(json: json, noteId: note, filename: file, secret: secret)
        let otherNote = "11111111-1111-4111-8111-111111111111"
        let otherFile = "17596320000000003-a1b2c3d4-13.delta.age"
        for (n, f) in [(otherNote, file), (note, otherFile)] {
            XCTAssertThrowsError(try BodyFraming.unframe(framed, noteId: n, filename: f, secret: secret)) {
                XCTAssertEqual($0 as? BodyFramingError, .tagMismatch)
            }
        }
    }

    func testHeaderErrors() throws {
        let secret = VaultSecret.random()
        var framed = try BodyFraming.frame(json: json, noteId: note, filename: file, secret: secret)
        XCTAssertThrowsError(try BodyFraming.unframe(framed.prefix(36), noteId: note, filename: file, secret: secret)) {
            XCTAssertEqual($0 as? BodyFramingError, .tooShort)
        }
        framed[4] = 2
        XCTAssertThrowsError(try BodyFraming.unframe(framed, noteId: note, filename: file, secret: secret)) {
            XCTAssertEqual($0 as? BodyFramingError, .unsupportedVersion(2))
        }
        framed[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try BodyFraming.unframe(framed, noteId: note, filename: file, secret: nil)) {
            XCTAssertEqual($0 as? BodyFramingError, .badMagic)
        }
        XCTAssertThrowsError(try VaultSecret(bytes: Data(count: 31)))
    }

    func testUnverifiedModeReturnsBodyFlagged() throws {
        let framed = try BodyFraming.frame(json: json, noteId: note, filename: file, secret: .random())
        let un = try BodyFraming.unframe(framed, noteId: "whatever", filename: "x", secret: nil)
        XCTAssertFalse(un.verified)
        XCTAssertEqual(try Gzip.decompress(un.gzip), json)
    }

    // MARK: - Through the vault

    func testFileMovedToAnotherNoteOrNameIsTagMismatch() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let rev = sampleLog()[0]
        try vault.write(rev)
        let src = fileURL(vault, testNote, rev.name)

        // Same file name, other note directory.
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let dst = fileURL(vault, other, rev.name)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dst)
        XCTAssertThrowsError(try vault.readRevision(noteId: other, name: rev.name)) {
            XCTAssertEqual($0 as? RevisionReadError, .tagMismatch)
        }

        // Same note, other name.
        var renamed = rev.name
        renamed.seq = 99
        try FileManager.default.copyItem(at: src, to: fileURL(vault, testNote, renamed))
        XCTAssertThrowsError(try vault.readRevision(noteId: testNote, name: renamed)) {
            XCTAssertEqual($0 as? RevisionReadError, .tagMismatch)
        }
        XCTAssertEqual(try vault.readRevision(noteId: testNote, name: rev.name), rev)
    }
}

