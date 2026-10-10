import Age
import Foundation
import XCTest
@testable import Sempere

/// The blob store (format.md §8.1): names, framing, Padmé, write, read,
/// verify, copy, and the binding of a blob to its name, its reference and the
/// vault secret.
final class BlobStoreTests: VaultTestCase {
    // MARK: - Primitives

    /// The test vector of format.md §8.1.3.
    func testSpecVector() throws {
        let secret = try VaultSecret(bytes: Data(0..<32))
        let content = Data("hello, sempere!\n".utf8)
        let ref = BlobRef(content: content, type: "text/plain")
        XCTAssertEqual(ref.sha256, "8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65")
        XCTAssertEqual(ref.kind, .bin)
        let name = BlobName.name(digest: try XCTUnwrap(ref.digest), secret: secret)
        XCTAssertEqual(name, "13ddeae851cf51d7e9a970d82ca2c99f1dbaa3efaf792248da32b8374d6869af")
        XCTAssertEqual(BlobName.fileName(name: name, kind: ref.kind), name + ".bin.age")
        let header = BlobFraming.header(digest: try XCTUnwrap(ref.digest), length: 16)
        XCTAssertEqual(header.map { String(format: "%02x", $0) }.joined(),
                       "494e4b4201" + ref.sha256 + "0000000000000010")
        XCTAssertEqual(BlobFraming.paddedPlaintextLength(contentLength: 16), 64)
    }

    func testPadme() {
        XCTAssertEqual(BlobFraming.padme(0), 0)
        XCTAssertEqual(BlobFraming.padme(1), 1)
        XCTAssertEqual(BlobFraming.padme(61), 64)
        XCTAssertEqual(BlobFraming.padme(1000), 1024)
        XCTAssertEqual(BlobFraming.padme(482_158), 483_328)
        XCTAssertEqual(BlobFraming.padme(28_311_597), 28_835_840)
        // Never smaller, at most 12 % larger, idempotent, monotone.
        var last: Int64 = 0
        for n in Array(Int64(0)...5000) + [65_581, 1 << 20, (1 << 30) + 45, 123_456_789] {
            let p = BlobFraming.padme(n)
            XCTAssertGreaterThanOrEqual(p, n)
            XCTAssertLessThanOrEqual(Double(p), Double(n) * 1.12 + 1, "n = \(n)")
            XCTAssertEqual(BlobFraming.padme(p), p, "n = \(n)")
            if n <= 5000 { XCTAssertGreaterThanOrEqual(p, last); last = p }
        }
    }

    func testHeaderParsing() throws {
        let digest = Data(repeating: 0xab, count: 32)
        let h = try BlobFraming.parseHeader(BlobFraming.header(digest: digest, length: 1 << 30))
        XCTAssertEqual(h.length, 1 << 30)
        XCTAssertEqual(h.digest, digest)
        var bad = BlobFraming.header(digest: digest, length: 1)
        XCTAssertThrowsError(try BlobFraming.parseHeader(bad.prefix(44))) { XCTAssertEqual($0 as? BlobError, .truncated) }
        bad[0] = 0x58
        XCTAssertThrowsError(try BlobFraming.parseHeader(bad)) { XCTAssertEqual($0 as? BlobError, .badMagic) }
        bad = BlobFraming.header(digest: digest, length: 1)
        bad[4] = 2
        XCTAssertThrowsError(try BlobFraming.parseHeader(bad)) { XCTAssertEqual($0 as? BlobError, .unsupportedVersion(2)) }
        bad = BlobFraming.header(digest: digest, length: 1)
        bad.replaceSubrange(37..<45, with: Data(repeating: 0xff, count: 8))
        XCTAssertThrowsError(try BlobFraming.parseHeader(bad)) {
            XCTAssertEqual($0 as? BlobError, .lengthOutOfRange(UInt64.max))
        }
    }

    func testFileNameParsing() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(BlobName.parse("\(hex).image.age")?.kind, .image)
        XCTAssertEqual(BlobName.parse("\(hex).x9.age")?.kind, BlobKind(rawValue: "x9"))
        for bad in ["\(hex).Image.age", "\(hex.uppercased()).image.age", "\(hex.dropLast()).image.age",
                    "\(hex).image", "\(hex)..age", "\(hex).abcdefghijklmnopq.age", "\(hex).image.age.tmp",
                    ".sempere-tmp-x", "\(hex).im-g.age", "\(hex)0.image.age"] {
            XCTAssertNil(BlobName.parse(bad), bad)
        }
    }

    // MARK: - Write and read

    func testWriteReadRoundTripAcrossChunkBoundaries() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let chunk = 64 << 10
        for (i, n) in [0, 1, 16, chunk - 45, chunk - 44, chunk, chunk + 1, 3 * chunk + 7, 300_000].enumerated() {
            let content = syntheticBytes(n, seed: UInt8(i))
            let ref = try vault.writeBlob(note: testNote, content, type: "image/png")
            XCTAssertEqual(ref, BlobRef(content: content, type: "image/png"))
            XCTAssertEqual(try vault.readBlob(note: testNote, ref), content, "n = \(n)")
            let url = try blobURL(vault, testNote, ref)
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".image.age"))
            let plain = try decryptBlob(url, id)
            XCTAssertEqual(Int64(plain.count), BlobFraming.paddedPlaintextLength(contentLength: Int64(n)), "Padmé, n = \(n)")
            XCTAssertEqual(plain.prefix(45 + n), blobPlaintext(content), "framing, n = \(n)")
            XCTAssertTrue(plain.dropFirst(45 + n).allSatisfy { $0 == 0 })
            XCTAssertEqual(try stanzaCount(url), 1)
            // Mode 0600: only the owner may read the ciphertext either.
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms?.intValue, 0o600)
        }
        XCTAssertTrue(attEntries(vault, testNote).allSatisfy { BlobName.parse($0) != nil }, "no temp files left")
    }

    func testStreamingWriteMatchesInMemoryWrite() throws {
        let vault = try makeVault(pqIdentity())
        let content = syntheticBytes(2_500_000, seed: 3)
        let file = tmp.appendingPathComponent("photo.jpg")
        try content.write(to: file)
        let ref = try vault.writeBlob(note: testNote, contentsOf: file, type: "image/jpeg")
        XCTAssertEqual(ref, BlobRef(content: content, type: "image/jpeg"))
        XCTAssertEqual(try vault.readBlob(note: testNote, ref), content)
        // Same content again, either API: the existing blob is reused untouched.
        let url = try blobURL(vault, testNote, ref)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(try vault.writeBlob(note: testNote, content, type: "image/jpeg"), ref)
        XCTAssertEqual(try vault.writeBlob(note: testNote, contentsOf: file, type: "image/jpeg"), ref)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testReplacesAnInvalidFileUnderTheName() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let content = Data("synthetic page".utf8)
        let ref = BlobRef(content: content, type: "application/pdf")
        let url = try blobURL(vault, testNote, ref)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try vault.readBlob(note: testNote, ref))
        XCTAssertEqual(try vault.writeBlob(note: testNote, content, type: "application/pdf"), ref)
        XCTAssertEqual(try vault.readBlob(note: testNote, ref), content)
    }

    func testLimitsAndPreconditions() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let ref = try vault.writeBlob(note: testNote, syntheticBytes(5000), type: "audio/mp4")
        XCTAssertThrowsError(try vault.readBlob(note: testNote, ref, maxBytes: 4999)) {
            XCTAssertEqual($0 as? BlobError, .contentTooLarge(limit: 4999))
        }
        XCTAssertThrowsError(try vault.readBlob(note: testNote, BlobRef(sha256: "XYZ", size: 1, type: "image/png"))) {
            XCTAssertEqual($0 as? BlobError, .invalidReference)
        }
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.readBlob(note: testNote, ref)) { XCTAssertEqual($0 as? VaultError, .locked) }
        XCTAssertThrowsError(try locked.writeBlob(note: testNote, Data([1]), type: "image/png")) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }
        let legacy = try makeLegacyVault(X25519Identity(), name: "Legacy")
        XCTAssertThrowsError(try legacy.writeBlob(note: testNote, Data([1]), type: "image/png")) {
            guard case .legacyVault = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    func testWithBlobFileIsPrivateAndRemoved() throws {
        let vault = try makeVault(pqIdentity())
        let content = syntheticBytes(200_000)
        let ref = try vault.writeBlob(note: testNote, content, type: "application/pdf")
        var seen: URL?
        let count = try vault.withBlobFile(note: testNote, ref, pathExtension: "pdf") { url -> Int in
            seen = url
            XCTAssertEqual(url.pathExtension, "pdf")
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms?.intValue, 0o600)
            return try Data(contentsOf: url).count
        }
        XCTAssertEqual(count, content.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(seen).path))
        let source = vault.blobSource(note: testNote)
        XCTAssertEqual(try source.data(for: ref, maxBytes: 1 << 20), content)
    }

    // MARK: - Binding (format.md §8.1.2, §8.1.4)

    func testBindingRejectsEveryMismatch() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let a = Data("synthetic content A".utf8), b = Data("synthetic content B, longer".utf8)
        let refA = try vault.writeBlob(note: testNote, a, type: "image/png")
        let refB = try vault.writeBlob(note: testNote, b, type: "image/png")
        let urlA = try blobURL(vault, testNote, refA), urlB = try blobURL(vault, testNote, refB)
        func assertFails(_ ref: BlobRef, _ expected: BlobError, line: UInt = #line) {
            XCTAssertThrowsError(try vault.readBlob(note: testNote, ref), line: line) {
                XCTAssertEqual($0 as? BlobError, expected, line: line)
            }
        }

        // Renamed: A's file under B's name. The reference to B finds a blob
        // whose header names A.
        let savedB = try Data(contentsOf: urlB)
        try FileManager.default.removeItem(at: urlB)
        try FileManager.default.copyItem(at: urlA, to: urlB)
        assertFails(refB, .referenceMismatch)
        // ...and read without a reference, the name does not verify.
        XCTAssertThrowsError(try Vault.readBlobFile(urlB, identities: [id], secrets: vault.blobSecrets, expected: nil,
                                                    maxContent: 1 << 20)) {
            XCTAssertEqual($0 as? BlobError, .nameMismatch)
        }
        try savedB.write(to: urlB)
        XCTAssertEqual(try vault.readBlob(note: testNote, refB), b)

        // Swapped content: B's header (hash) with other bytes.
        try plant(vault, testNote, blobPlaintext(a, digest: try XCTUnwrap(refB.digest), length: Int64(a.count)),
                  as: urlB.lastPathComponent)
        assertFails(refB, .referenceMismatch)
        try plant(vault, testNote, blobPlaintext(syntheticBytes(b.count), digest: try XCTUnwrap(refB.digest)),
                  as: urlB.lastPathComponent)
        assertFails(refB, .contentHashMismatch)

        // Non-zero padding.
        try plant(vault, testNote, blobPlaintext(b, padding: Data([0, 0, 1, 0])), as: urlB.lastPathComponent)
        assertFails(refB, .nonZeroPadding)
        // Zero padding of any length is fine (writers may skip Padmé).
        try plant(vault, testNote, blobPlaintext(b, padding: Data(count: 70_000)), as: urlB.lastPathComponent)
        XCTAssertEqual(try vault.readBlob(note: testNote, refB), b)
        try plant(vault, testNote, blobPlaintext(b), as: urlB.lastPathComponent)
        XCTAssertEqual(try vault.readBlob(note: testNote, refB), b)

        // Wrong length: longer than the content, shorter, or than the reference.
        try plant(vault, testNote, blobPlaintext(b, length: Int64(b.count + 1)), as: urlB.lastPathComponent)
        assertFails(BlobRef(sha256: refB.sha256, size: Int64(b.count + 1), type: refB.type), .truncated)
        try plant(vault, testNote, blobPlaintext(b, length: Int64(b.count - 1)), as: urlB.lastPathComponent)
        assertFails(BlobRef(sha256: refB.sha256, size: Int64(b.count - 1), type: refB.type), .nonZeroPadding)
        try savedB.write(to: urlB)
        assertFails(BlobRef(sha256: refB.sha256, size: refB.size + 1, type: refB.type), .referenceMismatch)

        // Wrong kind suffix: lookups never guess another kind.
        let pdfRef = BlobRef(sha256: refA.sha256, size: refA.size, type: "application/pdf")
        XCTAssertThrowsError(try vault.readBlob(note: testNote, pdfRef)) {
            guard case .missing? = $0 as? BlobError else { return XCTFail("a .image.age file resolved a PDF reference: \($0)") }
        }

        // Bad magic, tampered ciphertext, wrong vault.
        try plant(vault, testNote, Data("SMPR\u{1}".utf8) + Data(count: 60), as: urlB.lastPathComponent)
        assertFails(refB, .badMagic)
        try savedB.write(to: urlB)
        try flipByte(urlB, at: 20)
        XCTAssertThrowsError(try vault.readBlob(note: testNote, refB)) {
            guard case .undecryptable? = $0 as? BlobError else { return XCTFail("tampered ciphertext: \($0)") }
        }

        // A blob of another vault (same key, other secret) under its own name.
        let other = try makeVault(id, name: "Other")
        let foreign = try other.writeBlob(note: testNote, b, type: "image/png")
        let foreignName = try other.blobFileName(for: foreign)
        XCTAssertNotEqual(foreignName, urlB.lastPathComponent, "names are keyed per vault")
        let planted = attDir(vault, testNote).appendingPathComponent(foreignName)
        try FileManager.default.copyItem(at: try blobURL(other, testNote, foreign), to: planted)
        XCTAssertThrowsError(try Vault.readBlobFile(planted, identities: [id], secrets: vault.blobSecrets, expected: nil,
                                                    maxContent: 1 << 20)) {
            XCTAssertEqual($0 as? BlobError, .nameMismatch)
        }
        XCTAssertEqual(vault.verify().files.first { $0.path.hasSuffix(foreignName) }?.status, .invalid)
        try FileManager.default.removeItem(at: urlB)
        assertFails(refB, .missing(urlB.path))
    }

    /// A reader that hands out content stops before any content when the
    /// name does not verify (the check needs only the header).
    func testNameIsCheckedBeforeContentIsHandedOut() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let content = syntheticBytes(200_000)
        let ref = try vault.writeBlob(note: testNote, content, type: "audio/mp4")
        let url = try blobURL(vault, testNote, ref)
        let bogus = url.deletingLastPathComponent()
            .appendingPathComponent(String(repeating: "0", count: 64) + ".audio.age")
        try FileManager.default.moveItem(at: url, to: bogus)
        var received = 0
        XCTAssertThrowsError(try Vault.readBlobFile(bogus, identities: [id], secrets: vault.blobSecrets, expected: nil,
                                                    maxContent: BlobRef.maxSize, sink: { received += $0.count })) {
            XCTAssertEqual($0 as? BlobError, .nameMismatch)
        }
        XCTAssertEqual(received, 0)
    }

    func testNonRegularFileIsRefusedWithoutBlocking() throws {
        let vault = try makeVault(pqIdentity())
        let ref = BlobRef(content: Data("x".utf8), type: "image/png")
        let url = try blobURL(vault, testNote, ref)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertThrowsError(try vault.readBlob(note: testNote, ref)) {
            guard case .unreadable? = $0 as? BlobError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Copy (format.md §8.1.4)

    func testCopyIsAByteCopyValidInTheOtherNote() throws {
        let vault = try makeVault(pqIdentity())
        let content = syntheticBytes(150_000)
        let ref = try vault.writeBlob(note: testNote, content, type: "image/jpeg")
        try vault.copyBlob(ref, from: testNote, to: otherNote)
        XCTAssertEqual(try Data(contentsOf: blobURL(vault, otherNote, ref)), try Data(contentsOf: blobURL(vault, testNote, ref)))
        XCTAssertEqual(try vault.readBlob(note: otherNote, ref), content)
        // Again: kept; and copying a damaged source copies nothing.
        try vault.copyBlob(ref, from: testNote, to: otherNote)
        let third = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        try flipByte(try blobURL(vault, testNote, ref), at: 100)
        XCTAssertThrowsError(try vault.copyBlob(ref, from: testNote, to: third))
        XCTAssertEqual(attEntries(vault, third), [])
        XCTAssertThrowsError(try vault.copyBlob(ref, from: third, to: testNote)) {
            guard case .missing? = $0 as? BlobError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - features (format.md §2)

    func testFeaturesAreAddedAndUnknownOnesBlockWrites() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let manifestURL = vault.url.appendingPathComponent("vault.json")
        XCTAssertEqual(try Vault.open(at: vault.url).manifest.features, ["recipients-tag", "signed-secret-link", "markers-tag"], "format.md §2.1")
        var log = LogBuilder()
        try vault.write(log.delta(devA, 0, [.addPage(Page(id: blobPage, order: "a0"))]))
        XCTAssertEqual(try Vault.open(at: vault.url).manifest.features, ["recipients-tag", "signed-secret-link", "markers-tag"], "plain revisions add nothing")
        let ref = try vault.writeBlob(note: testNote, Data("x".utf8), type: "image/png")
        XCTAssertEqual(try Vault.open(at: vault.url).manifest.features, ["recipients-tag", "signed-secret-link", "markers-tag", "attachments"])
        try vault.write(referencingDelta(&log, 10, refs: [ref], newPage: false))
        XCTAssertEqual(try Vault.open(at: vault.url).manifest.features, ["recipients-tag", "signed-secret-link", "markers-tag", "attachments"], "added once")
        XCTAssertTrue(vault.verify().isHealthy, "a feature added after open is not a manifest change")

        // A revision with attachment ops adds it too (fresh vault).
        let v2 = try makeVault(id, name: "Two")
        var log2 = LogBuilder()
        try v2.write(referencingDelta(&log2, 0, refs: [BlobRef(content: Data("y".utf8), type: "image/png")]))
        XCTAssertEqual(try Vault.open(at: v2.url).manifest.features, ["recipients-tag", "signed-secret-link", "markers-tag", "attachments"])

        // An unknown feature: readable, never written.
        var m = try Vault.open(at: vault.url).manifest
        m.features.append("holograms")
        m.tagMarkers(secret: try vault.requireSecret())   // as the newer writer would (format.md §7.6)
        try m.encoded().write(to: manifestURL)
        let newer = try Vault.open(at: vault.url, identities: [id])
        XCTAssertEqual(try newer.readBlob(note: testNote, ref), Data("x".utf8))
        XCTAssertNoThrow(try newer.loadNote(testNote))
        for attempt in [{ try newer.write(log.delta(devA, 20, [])) },
                        { _ = try newer.writeBlob(note: testNote, Data("z".utf8), type: "image/png") },
                        { try newer.copyBlob(ref, from: testNote, to: otherNote) }] as [() throws -> Void] {
            XCTAssertThrowsError(try attempt()) {
                XCTAssertEqual($0 as? VaultError, .readOnly(ReadOnlyReasons(unknownFeatures: ["holograms"])))
            }
        }
        // Compaction deletes revisions, which is writing too.
        XCTAssertThrowsError(try newer.compact(noteId: testNote, retention: 0)) {
            XCTAssertEqual($0 as? VaultError, .readOnly(ReadOnlyReasons(unknownFeatures: ["holograms"])))
        }
        var changing = newer
        XCTAssertThrowsError(try changing.addRecipient(pqIdentity().recipient, label: "x")) {
            XCTAssertEqual($0 as? VaultError, .readOnly(ReadOnlyReasons(unknownFeatures: ["holograms"])))
        }
    }

    func testRevisionListingsIgnoreAtt() throws {
        let vault = try makeVault(pqIdentity())
        var log = LogBuilder()
        let ref = try vault.writeBlob(note: testNote, Data("x".utf8), type: "image/png")
        let d = referencingDelta(&log, 0, refs: [ref])
        try vault.write(d)
        XCTAssertEqual(try vault.revisionNames(of: testNote), [d.name])
        XCTAssertEqual(try vault.loadNote(testNote).failures, [:])
        XCTAssertEqual(try vault.nextSeq(noteId: testNote, device: devA), 2)
    }
}
