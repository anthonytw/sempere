import Age
import Foundation
import FuzzSupport
import XCTest

@testable import Sempere

/// Seeded mutation fuzzing of the blob readers (format.md §8.1, §9): the
/// plaintext framing checker fed in random splits, file names, and whole blob
/// files encrypted for real and read through the vault (read, verify,
/// inventory, collection). Every input may fail with a typed error; none may
/// trap, hang or allocate without bound.
final class BlobFuzzTests: VaultTestCase {
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is BlobError {
        } catch is VaultError {
        } catch is RevisionReadError {
        } catch is AgeError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    static func seeds() -> [Data] {
        [Data(), Data("hello, sempere!\n".utf8), syntheticBytes(300), syntheticBytes(70_000)].map { c in
            BlobFraming.header(digest: Data(SHA256Digest(c)), length: Int64(c.count)) + c
                + Data(count: Int(BlobFraming.paddedPlaintextLength(contentLength: Int64(c.count))) - 45 - c.count)
        }
    }

    func testFuzzBlobPlaintext() {
        let report = Fuzz.run("blob-plaintext", seeds: Self.seeds(), quick: 3000, maxSize: 256 << 10) { input in
            // Split at a few input-derived points so chunking is exercised.
            let cuts = [0, 1, 44, 45, 46, 64 << 10].map { min($0 + Int(input.first ?? 0) % 3, input.count) }
            var problem: String?
            for cut in cuts {
                problem = problem ?? Self.typed {
                    var checker = BlobPlaintextChecker(maxContent: 1 << 20)
                    var content = Data()
                    try checker.consume(input.prefix(cut)) { content += $0 }
                    try checker.consume(input.dropFirst(cut)) { content += $0 }
                    let h = try checker.finish()
                    if content.count != Int(h.length) || Data(SHA256Digest(content)) != h.digest
                        || content != input.dropFirst(45).prefix(Int(h.length)) {
                        throw NSError(domain: "invariant: accepted content does not match", code: 0)
                    }
                }
            }
            _ = try? BlobFraming.parseHeader(input)
            let name = String(decoding: input.prefix(96), as: UTF8.self)
            if let p = BlobName.parse(name), BlobName.fileName(name: p.name, kind: p.kind) != name {
                return "file name \(name) does not round-trip"
            }
            return problem
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// Mutated plaintexts encrypted for real under a referenced blob's
    /// name, then read through every vault entry point.
    func testFuzzBlobFiles() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let content = Data("synthetic fuzz content".utf8)
        let ref = try vault.writeBlob(note: testNote, content, type: "image/png")
        var log = LogBuilder()
        try vault.write(referencingDelta(&log, 0, refs: [ref]))
        let url = try blobURL(vault, testNote, ref)
        let recipients = try vault.ageRecipients()
        let report = Fuzz.run("blob-files", seeds: Self.seeds() + [try decryptBlob(url, id)], quick: 120,
                              maxSize: 128 << 10) { input in
            Self.typed {
                try Vault.encrypt(input, to: recipients).write(to: url)
                if let got = try? vault.readBlob(note: testNote, ref), got != content {
                    throw NSError(domain: "invariant: a reference returned other content", code: 0)
                }
                _ = vault.verify()
                _ = try vault.blobInventory(note: testNote)
                var state = BlobCollectorState()
                _ = try vault.collectBlobs(note: testNote, state: &state, now: Date(), retention: 0, dryRun: true)
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
