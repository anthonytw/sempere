import Age
import Crypto
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// Getting attachments out without the app (format.md §8.1.7), and large
/// blobs in bounded memory (§8.1.4).
final class BlobRecoveryTests: VaultTestCase {
    func bash(_ script: String) throws -> Data {
        let r = try ExternalTool.run(URL(fileURLWithPath: "/bin/bash"), ["-c", script])
        XCTAssertEqual(r.status, 0, r.errText)
        return r.out
    }

    func quote(_ s: String) -> String { ExternalTool.shellQuote(s) }

    /// `age` from PATH, at least `minor` (1.x). Post-quantum keys need 1.3;
    /// SEMPERE_REQUIRE_AGE_PQ (CI) turns a missing one into a failure.
    func age(atLeast minor: Int) throws -> URL {
        let required = minor >= 3 && ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard let age = ExternalTool.find("age") else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is not on PATH") }
            throw XCTSkip("age not on PATH")
        }
        let version = String(decoding: try bash("\(quote(age.path)) --version"), as: UTF8.self)
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }.split(separator: ".")
            .prefix(2).compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 1 || parts[1] >= minor else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is \(version)") }
            throw XCTSkip("age \(version) is older than 1.\(minor)")
        }
        return age
    }

    /// Runs the documented commands against a blob file and checks each.
    func assertStockRecovery(age: URL, key: URL, blob: URL, content: Data, ref: BlobRef,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let dec = "\(quote(age.path)) -d -i \(quote(key.path)) \(quote(blob.path))"
        let hex = "od -An -v -tx1 | tr -d ' \\n'"   // as `xxd -p` prints it, without line breaks
        let sha = String(decoding: try bash("\(dec) | head -c 37 | tail -c 32 | \(hex)"), as: UTF8.self)
        XCTAssertEqual(sha, ref.sha256, file: file, line: line)
        let lHex = String(decoding: try bash("\(dec) | head -c 45 | tail -c 8 | \(hex)"), as: UTF8.self)
        XCTAssertEqual(Int(lHex, radix: 16), content.count, file: file, line: line)
        // BSD head (macOS) refuses `-c 0`: an empty blob has nothing to extract.
        if !content.isEmpty {
            let out = tmp.appendingPathComponent("out-\(UUID().uuidString)")
            _ = try bash("\(dec) | tail -c +46 | head -c \"$((16#\(lHex)))\" > \(quote(out.path))")
            XCTAssertEqual(try Data(contentsOf: out), content, file: file, line: line)
        }
        // Without head -c the zero padding follows.
        let padded = try bash("\(dec) | tail -c +46")
        XCTAssertEqual(padded.prefix(content.count), content, file: file, line: line)
        XCTAssertTrue(padded.dropFirst(content.count).allSatisfy { $0 == 0 }, file: file, line: line)
        if ExternalTool.find("xxd") != nil {
            let x = String(decoding: try bash("\(dec) | head -c 37 | tail -c 32 | xxd -p -c 32"), as: UTF8.self)
            XCTAssertEqual(x.trimmingCharacters(in: .whitespacesAndNewlines), ref.sha256, file: file, line: line)
        }
    }

    /// The stock `age` CLI recovers a blob's content byte for byte (any age:
    /// a legacy X25519 vault, whose on-disk format is the same).
    func testStockAgeRecoversBlobs() throws {
        let age = try age(atLeast: 1)
        let id = X25519Identity()
        let vault = try makeLegacyVault(id).allowingLegacyContent()
        let key = tmp.appendingPathComponent("key.txt")
        try IdentityFile.render(id, created: Date()).write(to: key, atomically: true, encoding: .utf8)
        for (n, type) in [(0, "image/png"), (16, "text/plain"), (70_000, "application/pdf"), (200_001, "audio/mp4")] {
            let content = syntheticBytes(n, seed: UInt8(n % 251))
            let ref = try vault.writeBlob(note: testNote, content, type: type)
            try assertStockRecovery(age: age, key: key, blob: try blobURL(vault, testNote, ref), content: content, ref: ref)
        }
    }

    /// The same with a post-quantum vault (age 1.3+), after a header-only
    /// rewrap and after a full re-encryption.
    func testStockAgeRecoversPostQuantumBlobsAfterRewraps() throws {
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS") }
        let age = try age(atLeast: 3)
        let a = pqIdentity(), b = pqIdentity()
        var vault = try makeVault(a)
        let keyA = tmp.appendingPathComponent("a.txt"), keyB = tmp.appendingPathComponent("b.txt")
        try IdentityFile.render(a, created: Date()).write(to: keyA, atomically: true, encoding: .utf8)
        try IdentityFile.render(b, created: Date()).write(to: keyB, atomically: true, encoding: .utf8)
        let content = syntheticBytes(150_000)
        let ref = try vault.writeBlob(note: testNote, content, type: "image/jpeg")
        try assertStockRecovery(age: age, key: keyA, blob: try blobURL(vault, testNote, ref), content: content, ref: ref)
        try vault.addRecipient(b.recipient, label: "B")
        try assertStockRecovery(age: age, key: keyB, blob: try blobURL(vault, testNote, ref), content: content, ref: ref)
        try vault.removeRecipient(a.recipient)
        let reopened = try Vault.open(at: vault.url, identities: [b])
        try assertStockRecovery(age: age, key: keyB, blob: try blobURL(reopened, testNote, ref), content: content, ref: ref)
        XCTAssertEqual(try reopened.readBlob(note: testNote, ref), content)
    }

    /// `Recovery.decryptBlob`: content checked always, the name with a vault.
    func testRecoveryDecryptBlob() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let content = syntheticBytes(90_000)
        let ref = try vault.writeBlob(note: testNote, content, type: "application/pdf")
        let url = try blobURL(vault, testNote, ref)
        var out = Data()
        var r = try Recovery.decryptBlob(at: url, identities: [id], vault: vault) { out += $0 }
        XCTAssertEqual(out, content)
        XCTAssertEqual(r.header.sha256, ref.sha256)
        XCTAssertTrue(r.nameVerified)
        out = Data()
        r = try Recovery.decryptBlob(at: url, identities: [id], vault: nil) { out += $0 }
        XCTAssertEqual(out, content)
        XCTAssertFalse(r.nameVerified)
        let moved = url.deletingLastPathComponent().appendingPathComponent(String(repeating: "e", count: 64) + ".pdf.age")
        try FileManager.default.moveItem(at: url, to: moved)
        XCTAssertThrowsError(try Recovery.decryptBlob(at: moved, identities: [id], vault: vault) { _ in }) {
            XCTAssertEqual($0 as? BlobError, .nameMismatch)
        }
        XCTAssertNoThrow(try Recovery.decryptBlob(at: moved, identities: [id], vault: nil) { _ in })
    }

    // MARK: - Large blobs (format.md §8.1.4)

    /// A large blob through every path (streaming write from a file, read,
    /// temporary file, copy to another note, header-only rewrap on add, full
    /// re-encryption and rename on removal, verify) with bounded memory:
    /// resident memory must not grow by anything near the blob's size.
    func testLargeBlobInBoundedMemory() throws {
        let megabytes = Int(ProcessInfo.processInfo.environment["SEMPERE_LARGE_BLOB_MB"] ?? "") ?? 200
        let total = megabytes * 1_000_000
        let a = pqIdentity(), b = pqIdentity()
        var vault = try makeVault(a)
        let source = tmp.appendingPathComponent("lecture.m4a")
        var digest = SHA256()
        try FileIO.writeNewFile(source) { write in
            var piece = syntheticBytes(1 << 20, seed: 9)
            var written = 0, i: UInt64 = 0
            while written < total {
                piece.replaceSubrange(0..<8, with: withUnsafeBytes(of: i.bigEndian) { Data($0) })
                let p = piece.prefix(total - written)
                digest.update(data: p)
                try write(Data(p))
                written += p.count
                i += 1
            }
        }
        let expected = Data(digest.finalize()).map { String(format: "%02x", $0) }.joined()
        let sampler = ResidentSampler()
        let baseline = peakResidentBytes()

        let ref = try vault.writeBlob(note: testNote, contentsOf: source, type: "audio/mp4")
        XCTAssertEqual(ref.sha256, expected)
        XCTAssertEqual(ref.size, Int64(total))
        try FileManager.default.removeItem(at: source)

        func streamedHash(_ v: Vault, _ note: UUID) throws -> String {
            var h = SHA256()
            try v.streamBlob(note: note, ref) { h.update(data: $0) }
            return Data(h.finalize()).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(try streamedHash(vault, testNote), expected)
        XCTAssertEqual(try vault.withBlobFile(note: testNote, ref) { url in
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        }?.intValue, total)
        try vault.copyBlob(ref, from: testNote, to: otherNote)
        try FileManager.default.removeItem(at: try blobURL(vault, testNote, ref))
        XCTAssertTrue(try vault.addRecipient(b.recipient, label: "B").isComplete)
        XCTAssertTrue(try vault.removeRecipient(a.recipient).isComplete)
        let after = try Vault.open(at: vault.url, identities: [b])
        XCTAssertEqual(try streamedHash(after, otherNote), expected)
        XCTAssertTrue(after.verify().isHealthy)

        let growth = peakResidentBytes() - baseline
        let sampled = sampler.stop()
        print("\(megabytes) MB blob: peak RSS grew by \(growth >> 20) MiB; sampled RSS range \(sampled.map { "\($0 >> 20) MiB" } ?? "n/a")")
        XCTAssertLessThan(growth, 64 << 20, "peak RSS grew by \(growth) bytes")
        if let sampled { XCTAssertLessThan(sampled, 64 << 20, "resident set grew by \(sampled) bytes") }
    }
}

extension BlobRecoveryTests {
    /// format.md §2.1 changes vault.json only: after a tamper and a repair
    /// (secret rotated, every file rewrapped) the stock-CLI recovery of
    /// revisions (§4) and blobs (§8.1.7) still works, with the new secret.
    func testStockRecoveryAfterRecipientsRepair() throws {
        let id = pqIdentity(), attacker = pqIdentity()
        let store = MemoryRecipientsTrustStore()
        let made = try Vault.create(at: vaultURL(), recipients: [id.recipient, pqIdentity().recipient],
                                    identities: [id], trust: store)
        let log = sampleLog()
        for r in log { try made.write(r) }
        let content = Data("recipients repair".utf8)
        let ref = try made.writeBlob(note: testNote, content, type: "image/png")
        try RecipientsTamper.addedRecipient.apply(to: made.url, attacker: attacker.recipient,
                                                  other: made.manifest)
        var vault = try Vault.open(at: made.url, identities: [id], trust: store)
        XCTAssertTrue(try vault.repairRecipients().isComplete)

        // The pipeline's steps through the library (always run).
        for rev in log {
            let plain = try AgeFile.decrypt(Data(contentsOf: fileURL(vault, testNote, rev.name)), with: [id])
            XCTAssertEqual(try Gzip.decompress(Data(plain.dropFirst(37))), try InkJSON.encoder().encode(rev))
        }

        let age = try age(atLeast: 3)
        let keyFile = tmp.appendingPathComponent("key.txt")
        try IdentityFile.render(id, created: Date()).write(to: keyFile, atomically: true, encoding: .utf8)
        for rev in log {
            let file = fileURL(vault, testNote, rev.name)
            let json = try bash("\(quote(age.path)) -d -i \(quote(keyFile.path)) \(quote(file.path)) | tail -c +38 | gunzip")
            XCTAssertEqual(json, try InkJSON.encoder().encode(rev))
        }
        let blob = try vault.blobCandidates(note: testNote, ref)[0]
        let out = try bash("\(quote(age.path)) -d -i \(quote(keyFile.path)) \(quote(blob.path)) | tail -c +46 | head -c \(ref.size)")
        XCTAssertEqual(out, content)
    }
}
