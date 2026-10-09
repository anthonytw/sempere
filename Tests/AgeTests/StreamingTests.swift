import Crypto
import Foundation
import FuzzSupport
import TempDirSupport
import XCTest

@testable import Age

/// Streaming encryption and decryption, header-only rewrap and streaming
/// re-encryption (attachments task B1). CCTV vectors through the streaming
/// paths are in CCTVTests; `age` CLI interop in StreamingInteropTests.
final class StreamingTests: TempDirTestCase {
    static let chunk = 64 * 1024
    static let sealedChunk = chunk + 16

    static func bytes(_ n: Int, seed: UInt64 = 1) -> Data {
        var g = FuzzRNG(seed: seed)
        var out = [UInt8]()
        out.reserveCapacity(n)
        while out.count < n {
            var r = g.next()
            for _ in 0..<min(8, n - out.count) {
                out.append(UInt8(truncatingIfNeeded: r))
                r >>= 8
            }
        }
        return Data(out)
    }

    /// Streams `plain` through an encryptor in pieces of `piece` bytes.
    static func streamEncrypt(_ plain: Data, piece: Int, encryptor: AgeEncryptor) throws -> Data {
        var out = Data()
        var i = 0
        while i < plain.count {
            let end = min(i + piece, plain.count)
            out += try encryptor.update(plain.subdata(in: i..<end))
            i = end
        }
        return out + (try encryptor.finish())
    }

    /// All chunks a decryptor releases, and the error that ended it (nil
    /// for a clean end).
    static func drain(_ d: AgeDecryptor) -> (chunks: [Data], error: AgeError?) {
        var chunks: [Data] = []
        do {
            while let c = try d.next() { chunks.append(c) }
            return (chunks, nil)
        } catch {
            return (chunks, error as? AgeError)
        }
    }

    static let boundarySizes = [0, 1, chunk - 1, chunk, chunk + 1, 2 * chunk, 2 * chunk + 1, 200_000]

    // MARK: - Encryption

    /// For the same file key, nonce and header the streaming encryptor
    /// writes exactly the whole-buffer encoding, whatever the piece sizes,
    /// at every size around a chunk boundary.
    func testEncryptorMatchesBufferEncoding() throws {
        let id = X25519Identity()
        let key = FileKey()
        let header = try AgeFile.header(fileKey: key, recipients: [id.recipient], allowMixedPostQuantum: false)
        let nonce = Data(repeating: 7, count: 16)
        for size in Self.boundarySizes {
            let plain = Self.bytes(size, seed: UInt64(size))
            let expected = header + nonce
                + (try Stream.encrypt(plain, key: Stream.payloadKey(fileKey: key, nonce: nonce)))
            let pieces = (size <= 1000 ? [1, 7] : []) + [4096, Self.chunk - 1, Self.chunk, Self.chunk + 1, 1 << 20]
            for piece in pieces {
                let out = try Self.streamEncrypt(plain, piece: piece,
                                                 encryptor: AgeEncryptor(header: header, fileKey: key, nonce: nonce))
                XCTAssertEqual(out, expected, "size \(size) piece \(piece)")
            }
            // A random-key encryptor round-trips through both decrypt APIs.
            let ct = try Self.streamEncrypt(plain, piece: 10_000, encryptor: AgeEncryptor(to: [id.recipient]))
            XCTAssertEqual(try AgeFile.decrypt(ct, with: [id]), plain, "size \(size)")
            let (chunks, error) = Self.drain(try AgeDecryptor(ct, identities: [id]))
            XCTAssertNil(error)
            XCTAssertEqual(chunks.reduce(Data(), +), plain)
            // Chunks are full except the last, which is empty only for an empty file.
            XCTAssertEqual(chunks.count, max(1, (size + Self.chunk - 1) / Self.chunk), "size \(size)")
            XCTAssertTrue(chunks.dropLast().allSatisfy { $0.count == Self.chunk })
        }
    }

    func testEncryptorOutputLagsOneChunk() throws {
        let enc = try AgeEncryptor(to: [X25519Identity().recipient])
        let first = try enc.update(Self.bytes(Self.chunk))
        // Header and nonce only: the full chunk might still be the last one.
        XCTAssertEqual(try AgeFile.parseHeader(first).payloadStart + 16, first.count)
        let second = try enc.update(Data([1]))
        XCTAssertEqual(second.count, Self.sealedChunk)
        XCTAssertEqual(try enc.finish().count, 1 + 16)
    }

    func testEncryptorAfterFinishThrows() throws {
        let enc = try AgeEncryptor(to: [X25519Identity().recipient])
        _ = try enc.finish()
        XCTAssertThrowsError(try enc.update(Data([1]))) { XCTAssertEqual($0 as? AgeError, .streamFinished) }
        XCTAssertThrowsError(try enc.finish()) { XCTAssertEqual($0 as? AgeError, .streamFinished) }
    }

    /// The recipient rules of the buffer API hold for the streaming one.
    func testEncryptorRecipientRules() throws {
        XCTAssertThrowsError(try AgeEncryptor(to: [])) { XCTAssertEqual($0 as? AgeError, .noRecipients) }
        let scrypt = ScryptRecipient(passphrase: "x", workFactor: 2)
        XCTAssertThrowsError(try AgeEncryptor(to: [scrypt, X25519Identity().recipient])) {
            XCTAssertEqual($0 as? AgeError, .scryptNotAlone)
        }
        guard postQuantumAvailable else { return }
        let pq = try MLKEM768X25519Identity().recipient
        XCTAssertThrowsError(try AgeEncryptor(to: [pq, X25519Identity().recipient])) {
            XCTAssertEqual($0 as? AgeError, .incompatibleRecipients)
        }
        XCTAssertNoThrow(try AgeEncryptor(to: [pq, X25519Identity().recipient], allowMixedPostQuantum: true))
    }

    // MARK: - Decryption

    func testDecryptorWithOneByteReads() throws {
        let id = X25519Identity()
        let plain = Self.bytes(Self.chunk + 5)
        let ct = try AgeFile.encrypt(plain, to: [id.recipient])
        var offset = 0
        let d = try AgeDecryptor(identities: [id]) { _ in
            guard offset < ct.count else { return Data() }
            defer { offset += 1 }
            return ct.subdata(in: offset..<offset + 1)
        }
        let (chunks, error) = Self.drain(d)
        XCTAssertNil(error)
        XCTAssertEqual(chunks.reduce(Data(), +), plain)
        XCTAssertNil(try d.next(), "stays finished")
    }

    /// A reader returning more than asked is tolerated (the rest is kept).
    func testDecryptorWithOverlongReads() throws {
        let id = X25519Identity()
        let plain = Self.bytes(3 * Self.chunk)
        let ct = try AgeFile.encrypt(plain, to: [id.recipient])
        var sent = false
        let d = try AgeDecryptor(identities: [id]) { _ in
            defer { sent = true }
            return sent ? Data() : ct
        }
        XCTAssertEqual(Self.drain(d).chunks.reduce(Data(), +), plain)
    }

    /// Chunk tampering (age spec "Payload"): each chunk is bound to its
    /// position and to the final flag, so reordering, dropping, duplicating
    /// or truncating fails at the first chunk out of place, after releasing
    /// exactly the chunks before it.
    func testTamperedChunksFailAtTheRightChunk() throws {
        let id = X25519Identity()
        let plain = Self.bytes(4 * Self.chunk + 100)  // chunks 0...3 full, 4 short (final)
        let ct = try AgeFile.encrypt(plain, to: [id.recipient])
        let start = try AgeFile.parseHeader(ct).payloadStart + 16
        let head = ct.prefix(start)
        var sealed: [Data] = []
        var i = start
        while i < ct.count {
            sealed.append(ct.subdata(in: i..<min(i + Self.sealedChunk, ct.count)))
            i += Self.sealedChunk
        }
        XCTAssertEqual(sealed.count, 5)
        let plainChunks = (0..<5).map { plain.subdata(in: $0 * Self.chunk..<min(($0 + 1) * Self.chunk, plain.count)) }

        func check(_ payload: [Data], released: Int, _ label: String, extra: Data = Data(), file: StaticString = #filePath,
                   line: UInt = #line) throws {
            let (chunks, error) = Self.drain(try AgeDecryptor(head + payload.reduce(Data(), +) + extra, identities: [id]))
            XCTAssertEqual(error, .payload, label, file: file, line: line)
            XCTAssertEqual(chunks, Array(plainChunks.prefix(released)), label, file: file, line: line)
            // The buffer API releases the same prefix before failing.
            var buffered = Data()
            XCTAssertThrowsError(try AgeFile.decrypt(binary: head + payload.reduce(Data(), +) + extra, with: [id],
                                                     released: &buffered), label, file: file, line: line)
            XCTAssertEqual(buffered, plainChunks.prefix(released).reduce(Data(), +), label, file: file, line: line)
        }

        try check([sealed[1], sealed[0]] + sealed[2...], released: 0, "swap 0 and 1")
        try check([sealed[0], sealed[2], sealed[1]] + sealed[3...], released: 1, "swap 1 and 2")
        try check([sealed[0], sealed[1], sealed[3], sealed[4]], released: 2, "drop 2")
        try check([sealed[0], sealed[1], sealed[1]] + sealed[2...], released: 2, "duplicate 1")
        try check(Array(sealed.prefix(3)), released: 3, "cut at a chunk boundary")
        try check(Array(sealed.prefix(3)) + [sealed[3].prefix(1000)], released: 3, "cut inside chunk 3")
        try check(Array(sealed.prefix(4)) + [sealed[4].prefix(15)], released: 4, "final chunk shorter than a tag")
        try check(Array(sealed.prefix(4)), released: 4, "final chunk dropped")
        try check(Array(sealed.dropLast()) + [sealed[0]], released: 4, "chunk 0 replayed as last")
        var flipped = sealed
        flipped[2][flipped[2].startIndex + 17] ^= 1
        try check(flipped, released: 2, "bit flip in chunk 2")
        // Trailing data after a short final chunk is read as part of it, so
        // that chunk fails to authenticate.
        try check(sealed, released: 4, "trailing byte", extra: Data([0]))
        try check(sealed, released: 4, "trailing chunk", extra: sealed[4])
        // After a full-length final chunk, the chunk authenticates and is
        // released, then the stream fails (as age's reader does: "trailing
        // data after end of encrypted file").
        let full = try AgeFile.encrypt(plain.prefix(2 * Self.chunk), to: [id.recipient])
        for extra in [Data([0]), Data(count: Self.sealedChunk)] {
            let (chunks, error) = Self.drain(try AgeDecryptor(full + extra, identities: [id]))
            XCTAssertEqual(error, .payload)
            XCTAssertEqual(chunks, Array(plainChunks.prefix(2)))
        }
        XCTAssertEqual(Self.drain(try AgeDecryptor(full, identities: [id])).chunks, Array(plainChunks.prefix(2)))
        // An empty final chunk after a full one.
        let key = Stream.payloadKey(fileKey: try AgeDecryptor(ct, identities: [id]).fileKey, nonce: ct.subdata(in: start - 16..<start))
        let fullThenEmpty = [try Stream.seal(plainChunks[0], key: key, counter: 0, last: false),
                             try Stream.seal(Data(), key: key, counter: 1, last: true)]
        try check(fullThenEmpty, released: 1, "empty final chunk")
    }

    func testErrorsAreSticky() throws {
        let id = X25519Identity()
        let ct = try AgeFile.encrypt(Self.bytes(2 * Self.chunk + 1), to: [id.recipient])
        var bad = ct
        bad[bad.count - 1] ^= 1
        let d = try AgeDecryptor(bad, identities: [id])
        XCTAssertNotNil(try d.next())
        XCTAssertNotNil(try d.next())
        for _ in 0..<2 { XCTAssertThrowsError(try d.next()) { XCTAssertEqual($0 as? AgeError, .payload) } }
    }

    /// Header failures surface from `init`, with the buffer API's errors.
    func testHeaderFailures() throws {
        let id = X25519Identity(), other = X25519Identity()
        let ct = try AgeFile.encrypt(Data("x".utf8), to: [id.recipient])
        let start = try AgeFile.parseHeader(ct).payloadStart
        func error(_ data: Data, _ ids: [any AgeIdentity]) -> AgeError? {
            do { _ = try AgeDecryptor(data, identities: ids); return nil } catch { return error as? AgeError }
        }
        XCTAssertEqual(error(ct, [other]), .noMatchingIdentity)
        XCTAssertEqual(error(ct, []), .noIdentities)
        XCTAssertEqual(error(Data(), [id]), .headerParse)
        XCTAssertEqual(error(ct.prefix(start - 1), [id]), .headerParse)
        XCTAssertEqual(error(ct.prefix(start + 15), [id]), .headerParse, "nonce cut short")
        XCTAssertEqual(error(Data("age-encryption.org/v2\n".utf8), [id]), .unsupportedVersion)
        XCTAssertEqual(error(try AgeFile.encrypt(Data(), to: [id.recipient], armor: true), [id]), .headerParse,
                       "armor is not streamed")
        var badMAC = ct
        badMAC[start - 2] ^= 1  // inside the base64 MAC: a different valid MAC or a parse error
        let macError = error(badMAC, [id])
        XCTAssertTrue(macError == .headerMAC || macError == .headerParse, "\(String(describing: macError))")
        // Exactly the nonce and nothing else: a payload failure, not a header one.
        let d = try AgeDecryptor(ct.prefix(start + 16), identities: [id])
        XCTAssertThrowsError(try d.next()) { XCTAssertEqual($0 as? AgeError, .payload) }
    }

    /// A hostile source with an endless header is cut off after the 2 MiB
    /// header cap (plus one read), not read forever.
    func testEndlessHeaderIsBounded() throws {
        let line = Data((String(repeating: "A", count: 64) + "\n").utf8)
        var served = 0
        let prefix = Data("age-encryption.org/v1\n-> X25519 AAAA\n".utf8)
        XCTAssertThrowsError(try AgeDecryptor(identities: [X25519Identity()]) { n in
            defer { served += n }
            if served == 0 { return prefix }
            var out = Data()
            while out.count < n { out += line }
            return out.prefix(n)
        }) { XCTAssertEqual($0 as? AgeError, .headerParse) }
        XCTAssertLessThanOrEqual(served, HeaderCodec.maxHeaderBytes + 2 * 4096)
    }

    /// A MAC line (`---`) whose LF never comes, delivered one byte at a
    /// time: the search for the LF was restarted at the `---` on every read,
    /// quadratic in the line's length (128 KiB took 5 s, the 2 MiB cap about
    /// 20 minutes). It must be linear.
    func testUnterminatedMACLineWithTinyReadsIsLinear() throws {
        let input = Data("age-encryption.org/v1\n---".utf8) + Data(repeating: UInt8(ascii: "A"), count: 512 * 1024)
        var offset = 0
        let start = Date()
        XCTAssertThrowsError(try AgeDecryptor(identities: [X25519Identity()]) { _ in
            guard offset < input.count else { return Data() }
            defer { offset += 1 }
            return input.subdata(in: offset..<offset + 1)
        }) { XCTAssertEqual($0 as? AgeError, .headerParse) }
        XCTAssertEqual(offset, input.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// `macLineEnd` across calls: found once the LF arrives, never searched
    /// again from the start of the line.
    func testMACLineEndAcrossCalls() {
        var scan = AgeDecryptor.MacScan()
        let head = Data("age-encryption.org/v1\n-> X25519 AAAA\nAAAA\n--- abc".utf8)
        XCTAssertNil(AgeDecryptor.macLineEnd(head, scan: &scan))
        XCTAssertNotNil(scan.macStart)
        XCTAssertEqual(scan.lfFrom, head.count)
        let full = head + Data("def\nNONCE".utf8)
        XCTAssertEqual(AgeDecryptor.macLineEnd(full, scan: &scan), head.count + 4)
    }

    /// A source that keeps producing payload is read chunk by chunk, so a
    /// consumer can stop at any point.
    func testEndlessPayloadIsLazy() throws {
        let id = X25519Identity()
        let ct = try AgeFile.encrypt(Self.bytes(3 * Self.chunk), to: [id.recipient])
        let headerAndFirst = ct.prefix(try AgeFile.parseHeader(ct).payloadStart + 16 + Self.sealedChunk)
        var served = 0
        let d = try AgeDecryptor(identities: [id]) { n in
            defer { served += n }
            if served < headerAndFirst.count {
                return headerAndFirst.subdata(in: served..<min(served + n, headerAndFirst.count))
            }
            return Data(count: n)
        }
        XCTAssertEqual(try d.next()?.count, Self.chunk)
        XCTAssertThrowsError(try d.next())
        XCTAssertLessThan(served, headerAndFirst.count + 2 * Self.sealedChunk)
    }

    func testReadHeaderMatchesParseHeader() throws {
        let ids = [X25519Identity(), X25519Identity()]
        let ct = try AgeFile.encrypt(Self.bytes(100_000), to: ids.map(\.recipient))
        let url = tmp.appendingPathComponent("h.age")
        try ct.write(to: url)
        XCTAssertEqual(try AgeFile.readHeader(contentsOf: url), try AgeFile.parseHeader(ct).header)
        try Data("not age".utf8).write(to: tmp.appendingPathComponent("bad"))
        XCTAssertThrowsError(try AgeFile.readHeader(contentsOf: tmp.appendingPathComponent("bad"))) {
            XCTAssertEqual($0 as? AgeError, .headerParse)
        }
    }

    // MARK: - Files

    func testFileRoundTrips() throws {
        let id = X25519Identity()
        for size in [0, 1, Self.chunk, Self.chunk + 1, 300_000] {
            let plain = Self.bytes(size, seed: 9)
            let input = tmp.appendingPathComponent("in-\(size)")
            try plain.write(to: input)
            let enc = tmp.appendingPathComponent("enc-\(size).age")
            try AgeFile.encrypt(contentsOf: input, to: enc, recipients: [id.recipient])
            XCTAssertEqual(try AgeFile.decrypt(try Data(contentsOf: enc), with: [id]), plain)
            let dec = tmp.appendingPathComponent("dec-\(size)")
            try AgeFile.decrypt(contentsOf: enc, to: dec, identities: [id])
            XCTAssertEqual(try Data(contentsOf: dec), plain)
            // Chunk sequence of odd sizes.
            let seqOut = tmp.appendingPathComponent("seq-\(size).age")
            let pieces = stride(from: 0, to: size, by: 9_999).map { plain.subdata(in: $0..<min($0 + 9_999, size)) }
            try AgeFile.encrypt(pieces, to: seqOut, recipients: [id.recipient])
            XCTAssertEqual(try AgeFile.decrypt(try Data(contentsOf: seqOut), with: [id]), plain)
        }
    }

    func testOutputsArePrivateAndNeverOverwritten() throws {
        let id = X25519Identity()
        let input = tmp.appendingPathComponent("in")
        try Data("secret".utf8).write(to: input)
        let enc = tmp.appendingPathComponent("enc.age")
        try AgeFile.encrypt(contentsOf: input, to: enc, recipients: [id.recipient])
        let dec = tmp.appendingPathComponent("dec")
        try AgeFile.decrypt(contentsOf: enc, to: dec, identities: [id])
        for url in [enc, dec] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600, url.lastPathComponent)
        }
        let before = try Data(contentsOf: dec)
        XCTAssertThrowsError(try AgeFile.decrypt(contentsOf: enc, to: dec, identities: [id])) {
            guard case .io = $0 as? AgeError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AgeFile.encrypt(contentsOf: input, to: enc, recipients: [id.recipient]))
        XCTAssertThrowsError(try AgeFile.rewrapHeader(contentsOf: enc, to: dec, identities: [id], recipients: [id.recipient]))
        XCTAssertThrowsError(try AgeFile.reencrypt(contentsOf: enc, to: dec, identities: [id], recipients: [id.recipient]))
        XCTAssertEqual(try Data(contentsOf: dec), before, "existing output untouched")
        XCTAssertThrowsError(try AgeFile.encrypt(contentsOf: tmp.appendingPathComponent("missing"),
                                                 to: tmp.appendingPathComponent("x"), recipients: [id.recipient])) {
            guard case .io = $0 as? AgeError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("x").path))
    }

    /// A damaged input leaves no output behind for any of the file
    /// operations, even though earlier chunks were written.
    func testDamagedInputLeavesNoOutput() throws {
        let id = X25519Identity()
        var ct = try AgeFile.encrypt(Self.bytes(3 * Self.chunk), to: [id.recipient])
        ct[ct.count - 20] ^= 1
        let bad = tmp.appendingPathComponent("bad.age")
        try ct.write(to: bad)
        let ops: [(String, (URL) throws -> Void)] = [
            ("decrypt", { try AgeFile.decrypt(contentsOf: bad, to: $0, identities: [id]) }),
            ("rewrap", { try AgeFile.rewrapHeader(contentsOf: bad, to: $0, identities: [id], recipients: [id.recipient]) }),
            ("reencrypt", { try AgeFile.reencrypt(contentsOf: bad, to: $0, identities: [id], recipients: [id.recipient]) }),
        ]
        for (name, op) in ops {
            let out = tmp.appendingPathComponent("out-\(name)")
            XCTAssertThrowsError(try op(out), name) { XCTAssertEqual($0 as? AgeError, .payload, name) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), name)
        }
        // Wrong key: header failure, no output.
        let out = tmp.appendingPathComponent("out-wrongkey")
        XCTAssertThrowsError(try AgeFile.rewrapHeader(contentsOf: bad, to: out, identities: [X25519Identity()],
                                                      recipients: [id.recipient])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Rewrap and re-encrypt

    /// Header-only rewrap (format.md §8.1.5): same file key, nonce and
    /// payload bytes; one stanza per new recipient; new MAC; the old key
    /// stops opening the new file when it is not among the recipients.
    func testRewrapHeaderKeepsPayload() throws {
        let a = X25519Identity(), b = X25519Identity(), c = X25519Identity()
        let plain = Self.bytes(2 * Self.chunk + 3)
        let ct = try AgeFile.encrypt(plain, to: [a.recipient])
        let input = tmp.appendingPathComponent("in.age")
        try ct.write(to: input)
        let out = tmp.appendingPathComponent("out.age")
        try AgeFile.rewrapHeader(contentsOf: input, to: out, identities: [a], recipients: [b.recipient, c.recipient])
        let rewrapped = try Data(contentsOf: out)
        // The Data API gives the same layout (stanza bodies differ: fresh ephemeral shares).
        XCTAssertEqual(try AgeFile.rewrapHeader(ct, identities: [a], recipients: [b.recipient, c.recipient]).count,
                       rewrapped.count)
        let (oldHeader, oldStart) = try AgeFile.parseHeader(ct)
        let (newHeader, newStart) = try AgeFile.parseHeader(rewrapped)
        XCTAssertEqual(newHeader.stanzas.count, 2)
        XCTAssertNotEqual(newHeader.mac, oldHeader.mac)
        XCTAssertEqual(rewrapped.dropFirst(newStart), ct.dropFirst(oldStart), "nonce and payload unchanged")
        XCTAssertEqual(try AgeDecryptor(rewrapped, identities: [b]).fileKey.bytes,
                       try AgeDecryptor(ct, identities: [a]).fileKey.bytes, "file key kept")
        XCTAssertEqual(try AgeFile.decrypt(rewrapped, with: [b]), plain)
        XCTAssertEqual(try AgeFile.decrypt(rewrapped, with: [c]), plain)
        XCTAssertThrowsError(try AgeFile.decrypt(rewrapped, with: [a])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        // Armored in, armored out.
        let armored = try AgeFile.encrypt(plain, to: [a.recipient], armor: true)
        let armoredOut = try AgeFile.rewrapHeader(armored, identities: [a], recipients: [b.recipient])
        XCTAssertTrue(Armor.isArmored(armoredOut))
        XCTAssertEqual(try AgeFile.decrypt(armoredOut, with: [b]), plain)
        // The recipient rules apply to the new header.
        XCTAssertThrowsError(try AgeFile.rewrapHeader(ct, identities: [a], recipients: [])) {
            XCTAssertEqual($0 as? AgeError, .noRecipients)
        }
        XCTAssertThrowsError(try AgeFile.rewrapHeader(ct, identities: [a], recipients: [
            ScryptRecipient(passphrase: "p", workFactor: 2), b.recipient,
        ])) { XCTAssertEqual($0 as? AgeError, .scryptNotAlone) }
        // A passphrase file can be rewrapped to keys and back.
        let pw = try AgeFile.encrypt(plain, to: [ScryptRecipient(passphrase: "p", workFactor: 2)])
        let toKey = try AgeFile.rewrapHeader(pw, identities: [ScryptIdentity(passphrase: "p")], recipients: [b.recipient])
        XCTAssertEqual(try AgeFile.decrypt(toKey, with: [b]), plain)
    }

    func testRewrapHeaderPostQuantum() throws {
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS") }
        let x = X25519Identity(), p1 = try MLKEM768X25519Identity(), p2 = try MLKEM768X25519Identity()
        let plain = Self.bytes(Self.chunk + 1)
        let ct = try AgeFile.encrypt(plain, to: [p1.recipient])
        let both = try AgeFile.rewrapHeader(ct, identities: [p1], recipients: [p1.recipient, p2.recipient])
        XCTAssertEqual(try AgeFile.parseHeader(both).header.stanzas.map(\.type), ["mlkem768x25519", "mlkem768x25519"])
        XCTAssertEqual(try AgeFile.decrypt(both, with: [p2]), plain)
        XCTAssertThrowsError(try AgeFile.rewrapHeader(ct, identities: [p1], recipients: [p1.recipient, x.recipient])) {
            XCTAssertEqual($0 as? AgeError, .incompatibleRecipients)
        }
        let mixed = try AgeFile.rewrapHeader(ct, identities: [p1], recipients: [p1.recipient, x.recipient],
                                             allowMixedPostQuantum: true)
        XCTAssertEqual(try AgeFile.decrypt(mixed, with: [x]), plain)
    }

    /// Full re-encryption: new file key and nonce, so no byte of the
    /// payload is shared; the content is the same.
    func testReencrypt() throws {
        let a = X25519Identity(), b = X25519Identity()
        let plain = Self.bytes(3 * Self.chunk + 7)
        let input = tmp.appendingPathComponent("in.age")
        let ct = try AgeFile.encrypt(plain, to: [a.recipient])
        try ct.write(to: input)
        let out = tmp.appendingPathComponent("out.age")
        try AgeFile.reencrypt(contentsOf: input, to: out, identities: [a], recipients: [b.recipient])
        let re = try Data(contentsOf: out)
        XCTAssertEqual(re.count, ct.count)
        XCTAssertEqual(try AgeFile.decrypt(re, with: [b]), plain)
        XCTAssertThrowsError(try AgeFile.decrypt(re, with: [a]))
        let oldStart = try AgeFile.parseHeader(ct).payloadStart, newStart = try AgeFile.parseHeader(re).payloadStart
        XCTAssertNotEqual(re.subdata(in: newStart..<newStart + 16), ct.subdata(in: oldStart..<oldStart + 16), "new nonce")
        XCTAssertNotEqual(try AgeDecryptor(re, identities: [b]).fileKey.bytes,
                          try AgeDecryptor(ct, identities: [a]).fileKey.bytes, "new file key")
        XCTAssertNotEqual(re.suffix(Self.sealedChunk), ct.suffix(Self.sealedChunk))
    }

    // MARK: - Large files

    /// 300 MB through every streaming path with bounded memory: encrypt
    /// from a lazily generated chunk sequence, decrypt chunk by chunk,
    /// header-only rewrap, full re-encryption, decrypt to a file. Peak RSS
    /// must not grow by anything near the file size (whole-file `Data`
    /// would add at least 300 MB).
    func testLarge300MBRoundTripInBoundedMemory() throws {
        let total = 300 * 1_000_000
        let pieceSize = 1 << 20
        let a = X25519Identity(), b = X25519Identity()
        var base = Self.bytes(pieceSize, seed: 42)
        var expected = SHA256()
        let pieces = (0..<(total + pieceSize - 1) / pieceSize).lazy.map { (i: Int) -> Data in
            // Vary every piece so a repeated or dropped chunk changes the hash.
            let tag = Data((0..<8).map { UInt8(truncatingIfNeeded: UInt64(i) >> (56 - 8 * $0)) })
            base.replaceSubrange(0..<8, with: tag)
            let piece = base.prefix(min(pieceSize, total - i * pieceSize))
            expected.update(data: piece)
            return Data(piece)
        }
        let sampler = ResidentSampler()
        let baseline = peakResidentBytes()

        let encrypted = tmp.appendingPathComponent("large.age")
        try AgeFile.encrypt(pieces, to: encrypted, recipients: [a.recipient])
        let digest = Data(expected.finalize())
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: encrypted.path)[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(size, total)

        func streamedDigest(_ url: URL, _ id: X25519Identity) throws -> Data {
            let d = try AgeDecryptor(contentsOf: url, identities: [id])
            var h = SHA256()
            var count = 0
            while let chunk = try d.next() {
                h.update(data: chunk)
                count += chunk.count
            }
            XCTAssertEqual(count, total)
            return Data(h.finalize())
        }
        XCTAssertEqual(try streamedDigest(encrypted, a), digest, "encrypt → decrypt")

        let rewrapped = tmp.appendingPathComponent("rewrapped.age")
        try AgeFile.rewrapHeader(contentsOf: encrypted, to: rewrapped, identities: [a], recipients: [b.recipient])
        try FileManager.default.removeItem(at: encrypted)
        let reencrypted = tmp.appendingPathComponent("reencrypted.age")
        try AgeFile.reencrypt(contentsOf: rewrapped, to: reencrypted, identities: [b], recipients: [a.recipient])
        try FileManager.default.removeItem(at: rewrapped)
        XCTAssertEqual(try streamedDigest(reencrypted, a), digest, "rewrap → re-encrypt → decrypt")

        // Process-wide peak: only grows past what earlier tests in this
        // process reached, so it misses smaller leaks; the sampled current
        // RSS (Linux) catches those.
        let growth = peakResidentBytes() - baseline
        let sampled = sampler.stop()
        print("300 MB streaming: peak RSS grew by \(growth >> 20) MiB; sampled RSS range \(sampled.map { "\($0 >> 20) MiB" } ?? "n/a")")
        XCTAssertLessThan(growth, 64 << 20, "peak RSS grew by \(growth) bytes")
        if let sampled { XCTAssertLessThan(sampled, 64 << 20, "resident set grew by \(sampled) bytes while streaming") }
    }
}
