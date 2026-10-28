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

    private func recoveryIdentity() throws -> NativeIdentity {
        try IdentityFile.parse(String(contentsOfFile: Self.fixtureRecoveryKey, encoding: .utf8))
    }

    func testPaperKitPlain() throws {
        let out = path("kit.pdf")
        let r = try cli(["keys", "paper", "--identity", Self.fixtureRecoveryKey, "--vault", Self.fixtureVault,
                         "--out", out, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let json = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(json["variant"] as? String, "plain")
        XCTAssertEqual(json["qrVersion"] as? Int, 7)   // the 77-character post-quantum key at level Q
        XCTAssertEqual(json["qrErrorCorrection"] as? String, "Q")
        XCTAssertEqual(json["vaultId"] as? String, "5a3b1e00-1000-4000-8000-000000000001")
        XCTAssertEqual(try mode(out) & 0o777, 0o600)
        let key = try recoveryIdentity().string
        let text = try pdfText(out)
        for l in PaperKey.identityLines(key) { XCTAssertTrue(text.contains(l.groups.joined(separator: " "))) }
        XCTAssertTrue(text.contains("Vault:      sample"))

        let again = try cli(["keys", "paper", "--identity", Self.fixtureRecoveryKey, "--out", out])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.err.contains("refusing to overwrite"), again.err)
    }

    /// Only the vault's recovery key gets a kit for it: a device key (or any other key) is refused.
    func testPaperKitRefusesAKeyThatIsNotTheRecoveryKey() throws {
        let other = path("other.key")
        try IdentityFile.render(try NativeIdentity.generate(.postQuantum), created: Date()).write(toFile: other, atomically: true, encoding: .utf8)
        for key in [other, Self.fixtureKey] {
            let r = try cli(["keys", "paper", "--identity", key, "--vault", Self.fixtureVault, "--out", path("k.pdf")])
            XCTAssertEqual(r.status, 4, r.err)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path("k.pdf")))
        }
        let none = try cli(["keys", "paper", "--out", path("k.pdf")])
        XCTAssertEqual(none.status, 2, none.err)
        XCTAssertTrue(none.err.contains("no device keeps it"), none.err)
    }

    func testPaperKitWrappedWithAPassphrase() throws {
        let out = path("locked.pdf")
        let r = try cli(["keys", "paper", "--passphrase", "--identity", Self.fixtureRecoveryKey, "--vault", Self.fixtureVault,
                         "--work-factor", "15", "--out", out],
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
                       try recoveryIdentity().recipient)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("age1pq1"))
    }

    /// A post-quantum kit never prints the 1959-character recipient (only a
    /// fingerprint); a classic key gets no kit ("create a new key").
    func testPaperKitIsPostQuantumOnly() throws {
        let out = path("pq.pdf")
        let r = try cli(["keys", "paper", "--identity", Self.fixtureRecoveryKey, "--vault", Self.fixtureVault, "--out", out])
        XCTAssertEqual(r.status, 0, r.err)
        let recipient = try recoveryIdentity().recipient.string
        XCTAssertEqual(recipient.count, 1959)
        let text = try pdfText(out).joined(separator: "\n")
        let raw = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
        XCTAssertFalse(raw.contains(String(recipient.dropFirst(10).prefix(40))), "the recipient is not printed")
        XCTAssertTrue(text.contains("(1959 characters), SHA-256 \(PaperKey.fingerprint(recipient))"), text)

        let classic = path("classic.key")
        try IdentityFile.render(.x25519(X25519Identity()), created: Date()).write(toFile: classic, atomically: true, encoding: .utf8)
        let refused = try cli(["keys", "paper", "--identity", classic, "--out", path("c.pdf")])
        XCTAssertEqual(refused.status, 2, refused.err)
        XCTAssertTrue(refused.err.contains("create a new key"), refused.err)
    }

    // MARK: - backup, verify, restore

    func testBackupVerifyRestoreRoundTrip() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        let first = try cli(["backup", vault, "--to", dir, "--json"])
        XCTAssertEqual(first.status, 0, first.err)
        let report = try XCTUnwrap(first.json as? [String: Any])
        // 7 revisions, the recovery passphrase copy, a blob, the epoch record and vault.json
        XCTAssertEqual((report["copied"] as? [String])?.count, 11)
        let second = try cli(["backup", "--vault", vault, "--to", dir, "--json"])
        XCTAssertEqual(second.status, 0, second.err)
        XCTAssertEqual((second.json as? [String: Any])?["unchanged"] as? Int, 11)

        let locked = try cli(["backup", "verify", dir])
        XCTAssertEqual(locked.status, 0, locked.out + locked.err)
        XCTAssertTrue(locked.out.contains("not decrypted"))
        let full = try cli(["backup", "verify", dir, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(full.status, 0, full.out + full.err)
        XCTAssertEqual((full.json as? [String: Any])?["decrypted"] as? Bool, true)
        // A scripted passphrase unlocks the recovery passphrase copy the backup holds.
        let copy = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir + "/keys").first { $0.hasPrefix("recovery-") })
        let viaPass = try cli(["backup", "verify", dir, "--recovery-key", dir + "/keys/" + copy],
                              env: ["SEMPERE_PASSPHRASE": Self.passphrase])
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

    #if os(macOS)
    /// Owner's build 12: iCloud vault folders carried the Finder's `kHasBundle` flag, so they showed as packages. Like
    /// the app, `sempere backup` clears it on the vault and the backup folder at each run, and says so on stderr
    /// (stdout stays the backup's own report); a run with nothing to clear says nothing about it.
    func testBackupClearsTheFindersBundleFlag() throws {
        let vault = try copyFixtureVault()
        let drive = path("Drive")
        try FileManager.default.createDirectory(atPath: drive, withIntermediateDirectories: true)
        let first = try cli(["backup", vault, "--into", drive, "--json"])
        XCTAssertEqual(first.status, 0, first.err)
        let dest = try XCTUnwrap((first.json as? [String: Any])?["destination"] as? String)
        XCTAssertFalse(first.err.contains("bundle flag"), first.err)
        func isPackage(_ p: String) -> Bool {
            (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
        }
        for p in [vault, dest] {
            try (URL(fileURLWithPath: p) as NSURL).setResourceValue(true, forKey: .isPackageKey)
            XCTAssertTrue(isPackage(p), p)
        }
        let again = try cli(["backup", vault, "--into", drive])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertFalse(isPackage(vault), "the vault is a folder again")
        XCTAssertFalse(isPackage(dest), "the backup is a folder again")
        XCTAssertTrue(again.err.contains("Cleared the Finder's bundle flag on \(URL(fileURLWithPath: dest).lastPathComponent)"), again.err)
        XCTAssertFalse(again.out.contains("bundle flag"), "stdout is the backup's report")
    }
    #endif

    /// `backup --into FOLDER`: the app's Back Up, `<vault name>.sempere-backup` inside the folder, continued by the
    /// next run, and a folder `store import` (the app's Open Vault…) copies in under the vault's own name.
    func testBackupIntoMakesANamedBackupFolder() throws {
        let vault = try copyFixtureVault()
        let drive = path("Drive")
        try FileManager.default.createDirectory(atPath: drive, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: vault).deletingPathExtension().lastPathComponent
        let first = try cli(["backup", vault, "--into", drive, "--json"])
        XCTAssertEqual(first.status, 0, first.err)
        let dest = try XCTUnwrap((first.json as? [String: Any])?["destination"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: dest).lastPathComponent, "\(name).sempere-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest + "/backup.json"))
        let again = try cli(["backup", vault, "--into", drive])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("0 copied"), again.out)
        XCTAssertTrue(again.out.contains("Backup folder: "), again.out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drive), ["\(name).sempere-backup"])
        let imported = try cli(["store", "import", dest, "--store", path("store"), "--json"])
        XCTAssertEqual(imported.status, 0, imported.err)
        let listedStore = try cli(["store", "list", "--store", path("store"), "--json"])
        let entry = try XCTUnwrap((listedStore.json as? [[String: Any]])?.first, listedStore.out)
        XCTAssertEqual(entry["name"] as? String, name, "a backup copied in is <name>.sempere, not <name>.sempere-backup.sempere")
        XCTAssertEqual(try cli(["backup", vault, "--into", drive, "--to", path("x")]).status, 2)
        // `restore` reads a `.sempere-backup` as it reads any backup folder.
        let restored = try cli(["restore", dest, "--to", path("Restored.sempere")])
        XCTAssertEqual(restored.status, 0, restored.out + restored.err)

        // Review of #108: the backup is never a sync target, neither added nor kept by an import.
        let store = path("store")
        let target = try cli(["store", "target", "add", "\(name)", "--folder", dest, "--store", store])
        XCTAssertEqual(target.status, 1, target.out + target.err)
        XCTAssertTrue(target.err.contains("is a backup"), target.err)
        // Review of #109: nor any folder inside it (or inside a vault).
        let inside = try cli(["store", "target", "add", "\(name)", "--folder", "\(dest)/versions", "--store", store])
        XCTAssertEqual(inside.status, 1, inside.out + inside.err)
        XCTAssertTrue(inside.err.contains("is inside the vault or backup"), inside.err)
        let keep = try cli(["store", "import", dest, "--keep-syncing", "--store", path("store2")])
        XCTAssertEqual(keep.status, 1, keep.out + keep.err)
        XCTAssertTrue(keep.err.contains("is a backup"), keep.err)
        let listed = try cli(["store", "list", "--store", path("store2"), "--json"])
        XCTAssertEqual((listed.json as? [Any])?.count, 0, "nothing was copied: \(listed.out)")
    }

    /// `backup --into` renames this vault's backup an earlier version made ("<name> Backup", "<name>.sempere") to
    /// "<name>.sempere-backup" and continues it; and it agrees with the app on the iPad's nested backup: this vault's
    /// "<name>.sempere-backup" inside this vault's older backup is taken, any other folder inside a backup is not.
    func testBackupIntoRenamesLegacyAndAgreesWithTheApp() throws {
        let vault = try copyFixtureVault()
        let name = URL(fileURLWithPath: vault).deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        let drive = path("Drive")
        XCTAssertEqual(try cli(["backup", vault, "--to", drive + "/\(name) Backup", "-q"]).status, 0)
        let run = try cli(["backup", vault, "--into", drive])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.out.contains("Renamed \(name) Backup to \(name).sempere-backup"), run.out)
        XCTAssertTrue(run.out.contains("0 copied"), "continued, not started over: \(run.out)")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: drive), ["\(name).sempere-backup"])

        let pad = path("Pad")
        XCTAssertEqual(try cli(["backup", vault, "--to", pad, "-q"]).status, 0)   // the iPad's: straight into the folder
        let nested = try cli(["backup", vault, "--into", pad, "--json"])
        XCTAssertEqual(nested.status, 0, nested.err)
        let dest = try XCTUnwrap((nested.json as? [String: Any])?["destination"] as? String)
        XCTAssertEqual(dest, URL(fileURLWithPath: pad).appendingPathComponent("\(name).sempere-backup").path)
        let direct = try cli(["backup", vault, "--into", dest])
        XCTAssertEqual(direct.status, 0, "the app continues it at every run; so does the CLI: \(direct.err)")
        try fm.createDirectory(atPath: pad + "/elsewhere", withIntermediateDirectories: true)
        let refused = try cli(["backup", vault, "--into", pad + "/elsewhere"])
        XCTAssertEqual(refused.status, 1, refused.out + refused.err)
        XCTAssertTrue(refused.err.contains("inside the vault or backup"), refused.err)
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

    /// Human output prints times in local time with an offset (docs/cli.md),
    /// only --json in UTC (B46).
    func testBackupStatusAndRestorePreviewPrintLocalTimes() throws {
        let vault = try copyFixtureVault()
        let dir = path("backup")
        XCTAssertEqual(try cli(["backup", vault, "--to", dir, "-q"]).status, 0)
        let ny = ["TZ": "America/New_York"]
        let status = try cli(["backup", "status", dir, "--max-age", "7"], env: ny)
        XCTAssertEqual(status.status, 0, status.err)
        let preview = try cli(["restore", dir, "--to", path("new.sempere"), "--dry-run"], env: ny)
        XCTAssertEqual(preview.status, 0, preview.err)
        for line in (status.out + preview.out).split(separator: "\n")
        where ["created", "updated", "completed", "due", "backed up", "newest"].contains(where: { line.hasPrefix($0) }) {
            XCTAssertFalse(line.hasSuffix("Z"), String(line))
            XCTAssertTrue(line.contains("-04:00") || line.contains("-05:00") || line.hasSuffix("none"), String(line))
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
        XCTAssertEqual(json["files"] as? Int, 11)
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
        XCTAssertEqual((r.json as? [String: Any])?["files"] as? Int, 11)
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
