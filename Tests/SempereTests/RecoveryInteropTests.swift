import Age
import Foundation
import FuzzSupport
import VaultTestSupport
import XCTest
@testable import Sempere

/// Guards the no-app recovery promise (CLAUDE.md, format.md §4, §15.13): a listed key (the recovery key, or
/// a device key file) opens its wrap in `vault.json` with stock `age`, which gives `vault-keys.txt`, and
/// `age -d -i vault-keys.txt FILE.age | tail -c +38 | gunzip` yields the revision JSON. Skipped when `age`
/// is not on PATH.
final class RecoveryInteropTests: VaultTestCase {
    func shell(_ script: String) throws -> Data {
        let r = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
        XCTAssertEqual(r.status, 0, r.errText)
        return r.out
    }

    func quote(_ s: String) -> String { ExternalTool.shellQuote(s) }

    /// Post-quantum keys need `age` 1.3 or later (CI sets SEMPERE_REQUIRE_AGE_PQ).
    func pqAge() throws -> URL {
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
        return age
    }

    /// Writes `wrap` (an armored age file from `vault.json`) and opens it with `key` into vault-keys.txt.
    func vaultKeys(_ age: URL, wrap: String, key: URL, name: String) throws -> URL {
        let wrapFile = tmp.appendingPathComponent("\(name).wrap.age"), out = tmp.appendingPathComponent("\(name)-vault-keys.txt")
        try Data(wrap.utf8).write(to: wrapFile)
        _ = try shell("\(quote(age.path)) -d -i \(quote(key.path)) \(quote(wrapFile.path)) > \(quote(out.path))")
        return out
    }

    func testStockAgeRecoveryPipeline() throws {
        let age = try pqAge()
        let id = pqIdentity()
        let recovery = try MLKEM768X25519Identity()
        let vault = try TestVaults.create(at: vaultURL(), identities: [id], recovery: recovery)
        var clock = HybridClock()
        let log = sampleLog()
        for r in log { try vault.write(r) }
        let snap = try vault.snapshot(noteId: testNote, device: devC, clock: &clock, wall: wallAt(baseMillis + 50),
                                      app: "test/0")

        // The recovery key as the kit's text, and the device key file: each opens its own wrap with stock age.
        let recoveryFile = tmp.appendingPathComponent("recovery.txt"), deviceFile = tmp.appendingPathComponent("device.key")
        try IdentityFile.render(.mlkem768x25519(recovery), created: Date()).write(to: recoveryFile, atomically: true, encoding: .utf8)
        try TestVaults.deviceKeyFile(id).write(to: deviceFile, atomically: true, encoding: .utf8)
        let fromRecovery = try vaultKeys(age, wrap: try XCTUnwrap(vault.manifest.recoveryEntry?.wrap), key: recoveryFile, name: "r")
        let fromDevice = try vaultKeys(age, wrap: try XCTUnwrap(vault.devices.first?.wrap), key: deviceFile, name: "d")
        XCTAssertEqual(try Data(contentsOf: fromRecovery), try Data(contentsOf: fromDevice), "one key, wrapped twice")

        for rev in [log[0], log[2], snap] {
            let file = fileURL(vault, testNote, rev.name)
            let json = try shell("\(quote(age.path)) -d -i \(quote(fromRecovery.path)) \(quote(file.path)) | tail -c +38 | gunzip")
            XCTAssertEqual(json, try InkJSON.encoder().encode(rev), "byte-identical JSON for \(rev.name)")
            XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: json),
                           try vault.readRevision(noteId: testNote, name: rev.name))
            // One stanza, to the vault identity (format.md §15.2), whatever the number of devices.
            XCTAssertEqual(try Vault.stanzaCounts(Data(contentsOf: file)), ["mlkem768x25519": 1])
        }
        // The device key alone opens no note: files are encrypted to the vault identity only.
        let file = fileURL(vault, testNote, log[0].name)
        let r = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"),
                                     ["-c", "\(quote(age.path)) -d -i \(quote(deviceFile.path)) \(quote(file.path))"])
        XCTAssertNotEqual(r.status, 0)
    }

    /// The stock-CLI recovery path reads revisions a newer version wrote
    /// (format.md §7.6): `newer.sempere` is post-quantum, so this needs
    /// `age` 1.3 or later (CI sets SEMPERE_REQUIRE_AGE_PQ).
    func testStockAgeRecoversNewerRevisions() throws {
        let age = try pqAge()
        let key = try FixtureTests.bundled("sample.key")
        let vault = try Vault.open(at: FixtureTests.bundled("newer.sempere"),
                                   identities: [try IdentityFile.parse(String(contentsOf: key, encoding: .utf8))])
        let keys = try vaultKeys(age, wrap: try XCTUnwrap(vault.deviceEntry?.wrap), key: key, name: "newer")
        let note = NewerFixture.mixed
        for name in try vault.revisionNames(of: note) {
            let file = vault.noteURL(note).appendingPathComponent(name.filename)
            let json = try shell("\(quote(age.path)) -d -i \(quote(keys.path)) \(quote(file.path)) | tail -c +38 | gunzip")
            XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: json),
                           try vault.readRevision(noteId: note, name: name))
        }
    }
}
