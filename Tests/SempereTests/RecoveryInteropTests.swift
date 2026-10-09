import Age
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// Guards the no-app recovery promise (CLAUDE.md, format.md §4):
/// `age -d -i key FILE.age | tail -c +38 | gunzip` yields the revision JSON.
/// Skipped when `age` is not on PATH.
final class RecoveryInteropTests: VaultTestCase {
    func shell(_ script: String) throws -> Data {
        let r = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
        XCTAssertEqual(r.status, 0, r.errText)
        return r.out
    }

    func quote(_ s: String) -> String { ExternalTool.shellQuote(s) }

    func testStockAgeRecoveryPipeline() throws {
        guard let age = ExternalTool.find("age") else { throw XCTSkip("age not on PATH") }
        // A legacy X25519 vault: the library refuses its notes until it is
        // migrated, but the stock-CLI recovery path keeps working on it.
        let id = X25519Identity()
        let legacy = try Vault.create(at: vaultURL(), recipients: [id.recipient], identities: [id])
        XCTAssertThrowsError(try legacy.summaries()) {
            XCTAssertEqual($0 as? VaultError, .legacyVault(recipients: [id.recipient.string]))
        }
        let vault = legacy.allowingLegacyContent()   // test seam: write the notes to recover
        var clock = HybridClock()
        let log = sampleLog()
        for r in log { try vault.write(r) }
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                      app: "test/0")

        // Identity as plain text, the way a user would export it.
        let keyFile = tmp.appendingPathComponent("key.txt")
        try IdentityFile.render(id, created: Date()).write(to: keyFile, atomically: true, encoding: .utf8)

        for rev in [log[0], log[2], snap] {
            let file = fileURL(vault, testNote, rev.name)
            let json = try shell("\(quote(age.path)) -d -i \(quote(keyFile.path)) \(quote(file.path)) | tail -c +38 | gunzip")
            XCTAssertEqual(json, try InkJSON.encoder().encode(rev), "byte-identical JSON for \(rev.name)")
            XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: json),
                           try vault.readRevision(noteId: testNote, name: rev.name))
        }

        // The armored vault secret also opens with stock age.
        let secretFile = tmp.appendingPathComponent("secret.age")
        try Data(vault.manifest.vaultSecret.utf8).write(to: secretFile)
        let secret = try shell("\(quote(age.path)) -d -i \(quote(keyFile.path)) \(quote(secretFile.path))")
        XCTAssertEqual(secret, vault.secret?.bytes)
    }

    /// The stock-CLI recovery path reads revisions a newer version wrote
    /// (format.md §7.6): `newer.sempere` is post-quantum, so this needs
    /// `age` 1.3 or later (CI sets SEMPERE_REQUIRE_AGE_PQ).
    func testStockAgeRecoversNewerRevisions() throws {
        let required = ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard let age = ExternalTool.find("age") else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is not on PATH") }
            throw XCTSkip("age not on PATH")
        }
        let version = String(decoding: try shell("\(quote(age.path)) --version"), as: UTF8.self)
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
            .split(separator: ".").prefix(2).compactMap { Int($0) }
        guard postQuantumAvailable, parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is \(version)") }
            throw XCTSkip("age \(version) predates post-quantum recipients (needs 1.3)")
        }
        let key = try FixtureTests.bundled("sample.key")
        let vault = try Vault.open(at: FixtureTests.bundled("newer.sempere"),
                                   identities: [try IdentityFile.parse(String(contentsOf: key, encoding: .utf8))])
        let note = NewerFixture.mixed
        for name in try vault.revisionNames(of: note) {
            let file = vault.noteURL(note).appendingPathComponent(name.filename)
            let json = try shell("\(quote(age.path)) -d -i \(quote(key.path)) \(quote(file.path)) | tail -c +38 | gunzip")
            XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: json),
                           try vault.readRevision(noteId: note, name: name))
        }
    }
}
