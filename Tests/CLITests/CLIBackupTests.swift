import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `keys paper`, `backup`, `backup verify`, `restore`.
final class CLIBackupTests: CLITestCase {
    /// The text drawn on the PDF's pages (our own uncompressed `(...) Tj` lines).
    private func pdfText(_ path: String) throws -> [String] {
        let s = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        return s.split(separator: "\n").filter { $0.hasPrefix("(") && $0.hasSuffix(") Tj") }
            .map { String($0.dropFirst().dropLast(4)).replacingOccurrences(of: "\\(", with: "(")
                .replacingOccurrences(of: "\\)", with: ")").replacingOccurrences(of: "\\\\", with: "\\") }
    }

    /// The printed key file: each line is drawn as number, text, checksum.
    private func lockedFile(_ text: [String], _ begin: Int, _ end: Int) -> String {
        stride(from: begin, through: end, by: 3).map { text[$0] }.joined(separator: "\n") + "\n"
    }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - keys paper

    func testPaperKitPlain() throws {
        let out = path("kit.pdf")
        let r = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--vault", Self.fixtureVault,
                         "--out", out, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["variant"] as? String, "plain")
        XCTAssertEqual(json["qrVersion"] as? Int, 7)   // the 77-character post-quantum key at level Q
        XCTAssertEqual(json["qrErrorCorrection"] as? String, "Q")
        XCTAssertEqual(json["vaultId"] as? String, "5a3b1e00-1000-4000-8000-000000000001")
        XCTAssertEqual(try mode(out) & 0o777, 0o600)
        let key = try fixtureIdentity().string
        let text = try pdfText(out)
        for l in PaperKey.identityLines(key) { XCTAssertTrue(text.contains(l.groups.joined(separator: " "))) }
        XCTAssertTrue(text.contains("Vault:      sample"))

        let again = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--out", out])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.err.contains("refusing to overwrite"), again.err)
    }

    func testPaperKitRefusesAKeyThatDoesNotOpenTheVault() throws {
        let other = path("other.key")
        try IdentityFile.render(try NativeIdentity.generate(.postQuantum), created: Date()).write(toFile: other, atomically: true, encoding: .utf8)
        let r = try cli(["keys", "paper", "--identity", other, "--vault", Self.fixtureVault, "--out", path("k.pdf")])
        XCTAssertEqual(r.status, 4, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("k.pdf")))
        let none = try cli(["keys", "paper", "--out", path("k.pdf")])
        XCTAssertEqual(none.status, 4, none.err)
    }

    func testPaperKitFromTheVaultsStoredKeyFile() throws {
        let out = path("locked.pdf")
        let r = try cli(["keys", "paper", "--passphrase", "--vault", Self.fixtureVault, "--out", out],
                        env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(r.status, 0, r.err)
        let raw = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
        XCTAssertFalse(raw.contains("AGE-SECRET-KEY"), "a passphrase kit never holds the plain key")
        // The printed file wraps the secret key line alone (no 1959-character
        // public key, which would not fit a QR code) and opens with the passphrase.
        let text = try pdfText(out)
        let begin = try XCTUnwrap(text.firstIndex(of: "-----BEGIN AGE ENCRYPTED FILE-----"))
        let end = try XCTUnwrap(text.firstIndex(of: "-----END AGE ENCRYPTED FILE-----"))
        let armored = lockedFile(text, begin, end)
        let plain = try AgeFile.decrypt(Data(armored.utf8), with: [ScryptIdentity(passphrase: Self.passphrase)])
        XCTAssertEqual(try IdentityFile.parse(String(decoding: plain, as: UTF8.self)).recipient,
                       try fixtureIdentity().recipient)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("age1pq1"))
        XCTAssertEqual(r.status, 0)

        let wrong = try cli(["keys", "paper", "--passphrase", "--vault", Self.fixtureVault, "--out", path("w.pdf")],
                            env: ["SEMPERE_PASSPHRASE": "wrong"])
        XCTAssertEqual(wrong.status, 4, wrong.err)
    }

    /// A post-quantum kit never prints the 1959-character recipient (only a
    /// fingerprint); a classic key gets no kit ("create a new key"), and a
    /// legacy vault none either (migrate first).
    func testPaperKitIsPostQuantumOnly() throws {
        let out = path("pq.pdf")
        let r = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--vault", Self.fixtureVault, "--out", out])
        XCTAssertEqual(r.status, 0, r.err)
        let recipient = try fixtureIdentity().recipient.string
        XCTAssertEqual(recipient.count, 1959)
        let text = try pdfText(out).joined(separator: "\n")
        let raw = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
        XCTAssertFalse(raw.contains(String(recipient.dropFirst(10).prefix(40))), "the recipient is not printed")
        XCTAssertTrue(text.contains("(1959 characters), SHA-256 \(PaperKey.fingerprint(recipient))"), text)

        let classic = path("classic.key")
        try IdentityFile.render(X25519Identity(), created: Date()).write(toFile: classic, atomically: true, encoding: .utf8)
        let refused = try cli(["keys", "paper", "--identity", classic, "--out", path("c.pdf")])
        XCTAssertEqual(refused.status, 2, refused.err)
        XCTAssertTrue(refused.err.contains("create a new key"), refused.err)
        let legacy = try cli(["keys", "paper", "--identity", Self.legacyKey, "--vault", Self.legacyVault,
                              "--out", path("l.pdf")])
        XCTAssertEqual(legacy.status, 5, legacy.err)
        XCTAssertTrue(legacy.err.contains("migrate first"), legacy.err)
        for f in ["c.pdf", "l.pdf"] { XCTAssertFalse(FileManager.default.fileExists(atPath: path(f))) }
    }

    func testPaperKitWithANewPassphrase() throws {
        let out = path("new.pdf")
        let r = try cli(["keys", "paper", "--passphrase", "--identity", Self.fixtureKey, "--work-factor", "15",
                         "--paper", "a4", "--out", out, "--passphrase-env", "KIT_PASS"],
                        env: ["KIT_PASS": "correct horse"])
        XCTAssertEqual(r.status, 0, r.err)
        let text = try pdfText(out)
        let begin = try XCTUnwrap(text.firstIndex(of: "-----BEGIN AGE ENCRYPTED FILE-----"))
        let end = try XCTUnwrap(text.firstIndex(of: "-----END AGE ENCRYPTED FILE-----"))
        let plain = try AgeFile.decrypt(Data(lockedFile(text, begin, end).utf8),
                                        with: [ScryptIdentity(passphrase: "correct horse")])
        XCTAssertEqual(try IdentityFile.parse(String(decoding: plain, as: UTF8.self)).string, try fixtureIdentity().string)
        XCTAssertTrue(String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
            .contains("/MediaBox [0 0 595.28 841.89]"))
        let bad = try cli(["keys", "paper", "--identity", Self.fixtureKey, "--paper", "a3", "--out", path("x.pdf")])
        XCTAssertEqual(bad.status, 2)
    }

    // MARK: - backup, verify, restore

    func testBackupVerifyRestoreRoundTrip() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        let first = try cli(["backup", vault, "--to", dir, "--json"])
        XCTAssertEqual(first.status, 0, first.err)
        let report = try XCTUnwrap(first.json as? [String: Any])
        XCTAssertEqual((report["copied"] as? [String])?.count, 10)   // 7 revisions, key file, blob, vault.json
        let second = try cli(["backup", "--vault", vault, "--to", dir, "--json"])
        XCTAssertEqual(second.status, 0, second.err)
        XCTAssertEqual((second.json as? [String: Any])?["unchanged"] as? Int, 10)

        let locked = try cli(["backup", "verify", dir])
        XCTAssertEqual(locked.status, 0, locked.out + locked.err)
        XCTAssertTrue(locked.out.contains("not decrypted"))
        let full = try cli(["backup", "verify", dir, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(full.status, 0, full.out + full.err)
        XCTAssertEqual((full.json as? [String: Any])?["decrypted"] as? Bool, true)
        // A scripted passphrase unlocks the key file the backup holds.
        let viaPass = try cli(["backup", "verify", dir], env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(viaPass.status, 0, viaPass.out + viaPass.err)
        XCTAssertTrue(viaPass.out.contains("decrypted and verified"), viaPass.out)

        let target = path("restored.sempere")
        let restore = try cli(["restore", dir, "--to", target, "--identity", Self.fixtureKey])
        XCTAssertEqual(restore.status, 0, restore.out + restore.err)
        let verify = try cli(["vault", "verify", "--vault", target, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out)
        let notes = try cli(["notes", "list", "--deleted", "--vault", target, "--identity", Self.fixtureKey])
        XCTAssertTrue(notes.out.contains("Fixture lecture"), notes.out)

        let notVault = try cli(["restore", dir, "--to", path("plain")])
        XCTAssertEqual(notVault.status, 2)
        let again = try cli(["restore", dir, "--to", target])
        XCTAssertEqual(again.status, 1, again.err)
    }

    /// `backup status --max-age`: the app's Remind Me for scripts (exit 3 when overdue).
    func testBackupStatusMaxAge() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        XCTAssertEqual(try cli(["backup", "status", dir, "--max-age", "7"]).status, 1, "not a backup")
        XCTAssertEqual(try cli(["backup", vault, "--to", dir, "-q"]).status, 0)

        let fresh = try cli(["backup", "status", dir, "--max-age", "7", "--json"])
        XCTAssertEqual(fresh.status, 0, fresh.err)
        let json = try XCTUnwrap(fresh.json as? [String: Any])
        XCTAssertEqual(json["overdue"] as? Bool, false)
        XCTAssertEqual(json["maxAgeDays"] as? Int, 7)
        XCTAssertNotNil(json["due"] as? String)
        XCTAssertEqual(json["vaultId"] as? String, "5a3b1e00-1000-4000-8000-000000000001", "the status fields stay at the top level")

        // Ten days without a complete run: overdue, exit 3, in text and JSON.
        let index = URL(fileURLWithPath: dir).appendingPathComponent("backup.json")
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10 * 86_400))
        m["created"] = old
        m["completed"] = old
        try JSONSerialization.data(withJSONObject: m).write(to: index)
        let late = try cli(["backup", "status", dir, "--max-age", "7"])
        XCTAssertEqual(late.status, 3, late.out + late.err)
        XCTAssertTrue(late.out.contains("OVERDUE"), late.out)
        let lateJSON = try cli(["backup", "status", dir, "--max-age", "7", "--json"])
        XCTAssertEqual(lateJSON.status, 3)
        XCTAssertEqual((lateJSON.json as? [String: Any])?["overdue"] as? Bool, true)
        XCTAssertEqual(try cli(["backup", "status", dir, "--max-age", "30"]).status, 0)
        XCTAssertEqual(try cli(["backup", "status", dir]).status, 0, "without --max-age nothing is judged")

        // A run that only failed does not count: `updated` moves, `completed` stays.
        m["completed"] = nil
        try JSONSerialization.data(withJSONObject: m).write(to: index)
        XCTAssertEqual(try cli(["backup", "status", dir, "--max-age", "7"]).status, 3, "never completed: from created")
        XCTAssertTrue(try cli(["backup", "status", dir]).out.contains("never"))

        // A complete run clears it.
        XCTAssertEqual(try cli(["backup", vault, "--to", dir, "-q"]).status, 0)
        XCTAssertEqual(try cli(["backup", "status", dir, "--max-age", "7"]).status, 0)

        for bad in ["0", "3651", "-1", "x"] {
            XCTAssertEqual(try cli(["backup", "status", dir, "--max-age", bad]).status, 2, bad)
        }
    }

    func testBackupStatusAndRestoreDryRun() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        let none = try cli(["backup", "status", dir])
        XCTAssertEqual(none.status, 1, none.err)
        XCTAssertEqual(try cli(["backup", vault, "--to", dir, "-q"]).status, 0)

        let status = try cli(["backup", "status", dir, "--json"])
        XCTAssertEqual(status.status, 0, status.err)
        let json = try XCTUnwrap(status.json as? [String: Any])
        XCTAssertEqual(json["vaultId"] as? String, "5a3b1e00-1000-4000-8000-000000000001")
        XCTAssertEqual(json["files"] as? Int, 10)
        XCTAssertEqual(json["versionFiles"] as? Int, 0)
        XCTAssertEqual(json["totalBytes"] as? Int, json["bytes"] as? Int)
        XCTAssertNotNil(json["updated"] as? String)
        XCTAssertTrue(try cli(["backup", "status", dir]).out.contains("updated"))

        XCTAssertNotNil(json["completed"] as? String, "a run without errors completes")
        XCTAssertNil(json["overdue"], "no --max-age, no verdict")
        XCTAssertTrue(try cli(["backup", "status", dir]).out.contains("completed"))

        let target = path("restored.sempere")
        let dry = try cli(["restore", dir, "--to", target, "--dry-run", "--json"])
        XCTAssertEqual(dry.status, 0, dry.err)
        let preview = try XCTUnwrap(dry.json as? [String: Any])
        XCTAssertEqual(preview["isBackup"] as? Bool, true)
        XCTAssertEqual(preview["revisions"] as? Int, 7)
        XCTAssertEqual(preview["attachments"] as? Int, 1)
        XCTAssertEqual(preview["legacy"] as? Bool, false)
        XCTAssertNotNil(preview["newestRevision"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "a dry run writes nothing")

        // Never into (or inside) the vault named by --vault or $SEMPERE_VAULT.
        let inside = vault + "/inner.sempere"
        let refused = try cli(["restore", dir, "--to", inside, "--vault", vault])
        XCTAssertEqual(refused.status, 1, refused.err)
        XCTAssertTrue(refused.err.contains("open vault"), refused.err)
        let refusedEnv = try cli(["restore", dir, "--to", inside, "--dry-run"], env: ["SEMPERE_VAULT": vault])
        XCTAssertEqual(refusedEnv.status, 1, refusedEnv.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside))
        // A dry run refuses what the restore would.
        XCTAssertEqual(try cli(["restore", dir, "--to", vault, "--dry-run"]).status, 1)
    }

    func testBackupVerifyFindsDamage() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        XCTAssertEqual(try cli(["backup", vault, "--to", dir]).status, 0)
        let note = URL(fileURLWithPath: dir).appendingPathComponent("notes/\(Self.lecture)")
        let files = try FileManager.default.contentsOfDirectory(atPath: note.path).sorted()
        let victim = note.appendingPathComponent(files[0])
        var d = try Data(contentsOf: victim)
        d[d.count - 3] ^= 0x01
        try d.write(to: victim)
        try FileManager.default.removeItem(at: note.appendingPathComponent(files[1]))

        let r = try cli(["backup", "verify", dir, "--json"])
        XCTAssertEqual(r.status, 3, r.out)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["healthy"] as? Bool, false)
        let statuses = (json["files"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            $0[$1["path"] as? String ?? ""] = $1["status"] as? String
        }
        XCTAssertEqual(statuses["notes/\(Self.lecture)/\(files[0])"], "modified")
        XCTAssertEqual(statuses["notes/\(Self.lecture)/\(files[1])"], "missing")
        let human = try cli(["backup", "verify", dir, "--identity", Self.fixtureKey])
        XCTAssertEqual(human.status, 3)
        XCTAssertTrue(human.out.contains("modified  notes/\(Self.lecture)/\(files[0])"), human.out)
        let wrongKey = path("w.key")
        try IdentityFile.render(try NativeIdentity.generate(.postQuantum), created: Date()).write(toFile: wrongKey, atomically: true, encoding: .utf8)
        XCTAssertEqual(try cli(["backup", "verify", dir, "--identity", wrongKey]).status, 4)

        // The restore refuses the damaged file and says so.
        let restore = try cli(["restore", dir, "--to", path("r.sempere")])
        XCTAssertEqual(restore.status, 1)
        XCTAssertTrue(restore.err.contains(files[0]), restore.err)
    }

    func testBackupUsageAndPrune() throws {
        let vault = try copyFixtureVault()
        XCTAssertEqual(try cli(["backup", vault]).status, 2)
        XCTAssertEqual(try cli(["backup", vault, "--to", path("a"), "--archive", path("b.tar")]).status, 2)
        XCTAssertEqual(try cli(["backup", vault, "--archive", path("b.tar"), "--prune"]).status, 2)
        let noKey = try cli(["backup", vault, "--to", path("a"), "--prune"])
        XCTAssertEqual(noKey.status, 4, noKey.err)
        let pruned = try cli(["backup", vault, "--to", path("a"), "--prune", "--identity", Self.fixtureKey])
        XCTAssertEqual(pruned.status, 0, pruned.err)
        // Someone else's folder is never written into.
        let busy = path("busy")
        try FileManager.default.createDirectory(atPath: busy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: busy).appendingPathComponent("thesis.tex"))
        let refused = try cli(["backup", vault, "--to", busy])
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("not an sempere backup"), refused.err)
    }

    func testArchive() throws {
        let vault = try copyFixtureVault()
        let tar = path("notes.tar")
        let r = try cli(["backup", vault, "--archive", tar, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual((r.json as? [String: Any])?["files"] as? Int, 10)
        XCTAssertEqual(try cli(["backup", vault, "--archive", tar]).status, 1, "refuses to overwrite")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: tar))
        XCTAssertNil(String(decoding: bytes, as: UTF8.self).range(of: "Fixture lecture"), "no plaintext in the archive")
    }

    /// GA-60: the `.sempere-restore.json` marker through the command. An interrupted restore (marker,
    /// some files, no `vault.json`) is finished by running the same command again; the marker goes
    /// when the restore is complete; a marker of another vault, or a folder with other content,
    /// is refused (exit 1) and left as it was.
    func testRestoreResumesAnInterruptedRestoreThroughTheCommand() throws {
        let vault = try copyFixtureVault()
        let args = ["--vault", vault, "--identity", Self.fixtureKey]
        let backup = path("backup")
        XCTAssertEqual(try cli(["backup", "--to", backup, "-q"] + args).status, 0)
        let vaultId = try XCTUnwrap((try cli(["vault", "info", "--json"] + args).json as? [String: Any])?["vaultId"] as? String
                                    ?? (try cli(["vault", "info", "--json"] + args).json as? [String: Any])?["id"] as? String)
        let note = "22222222-2222-4222-8222-222222222222"
        let revision = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: "\(backup)/notes/\(note)").sorted().first)
        let marker = ".sempere-restore.json"

        // Another vault's marker: refused, nothing written.
        let foreign = path("foreign.sempere")
        try FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
        try Data("{\"vaultId\": \"00000000-0000-4000-8000-000000000000\"}".utf8).write(to: URL(fileURLWithPath: "\(foreign)/\(marker)"))
        let refused = try cli(["restore", backup, "--to", foreign, "--identity", Self.fixtureKey])
        XCTAssertEqual(refused.status, 1, refused.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign), [marker])
        // A folder with other content and no marker: refused too.
        let occupied = path("occupied.sempere")
        try FileManager.default.createDirectory(atPath: occupied, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: "\(occupied)/mine.txt"))
        XCTAssertEqual(try cli(["restore", backup, "--to", occupied, "--identity", Self.fixtureKey]).status, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: occupied), ["mine.txt"])

        // The interrupted one: marker plus one revision, no vault.json.
        let target = path("resumed.sempere")
        try FileManager.default.createDirectory(atPath: "\(target)/notes/\(note)", withIntermediateDirectories: true)
        try Data("{\"vaultId\": \"\(vaultId)\"}".utf8).write(to: URL(fileURLWithPath: "\(target)/\(marker)"))
        try FileManager.default.copyItem(atPath: "\(backup)/notes/\(note)/\(revision)", toPath: "\(target)/notes/\(note)/\(revision)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(target)/vault.json"), "an unfinished restore is no vault")
        let dry = try cli(["restore", backup, "--to", target, "--dry-run", "--json", "--identity", Self.fixtureKey])
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(target)/\(marker)"), "a dry run leaves the marker")

        let r = try cli(["restore", backup, "--to", target, "--json", "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 0, r.err)
        let report = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(report["alreadyPresent"] as? Int, 1, "the revision already there is not copied again")
        XCTAssertGreaterThan(report["restored"] as? Int ?? 0, 1)
        XCTAssertEqual(report["healthy"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(target)/\(marker)"), "the marker goes when the restore is complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(target)/vault.json"))
        XCTAssertEqual(try cli(["vault", "verify", "--vault", target, "--identity", Self.fixtureKey]).status, 0)
    }
}
