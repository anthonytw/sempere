import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

final class CLICommandTests: CLITestCase {
    // MARK: keys

    func testKeysGenerateAndShow() throws {
        let key = path("id.key")
        let gen = try cli(["keys", "generate", "--out", key])
        XCTAssertEqual(gen.status, 0, gen.err)
        let pub = try XCTUnwrap(gen.out.split(separator: "\n").compactMap { l -> String? in
            l.hasPrefix("Public key: ") ? String(l.dropFirst("Public key: ".count)) : nil
        }.first)
        XCTAssertTrue(pub.hasPrefix("age1"))
        let mode = try FileManager.default.attributesOfItem(atPath: key)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let show = try cli(["keys", "show", key])
        XCTAssertEqual(show.status, 0, show.err)
        XCTAssertEqual(show.out.trimmingCharacters(in: .whitespacesAndNewlines), pub)
        XCTAssertFalse(gen.out.contains("AGE-SECRET-KEY"))

        let again = try cli(["keys", "generate", "--out", key])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.err.contains("refusing to overwrite"), again.err)
        XCTAssertEqual(try cli(["keys", "show", key, "--json"]).json as? [String: String] ?? [:],
                       ["publicKey": pub, "path": key])
    }

    func testKeysExportMovesKeyToAnotherDevice() throws {
        let out = path("exported.key")
        let r = try cli(["keys", "export", "--vault", Self.fixtureVault, "--out", out],
                        env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(r.status, 0, r.err)
        let exported = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertEqual(try IdentityFile.parse(exported).string, try fixtureIdentity().string)
        // The exported file opens the vault.
        let list = try cli(["notes", "list", "--vault", Self.fixtureVault, "--identity", out, "--json"])
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertEqual((list.json as? [[String: Any]])?.count, 1)
        // Wrong passphrase: exit 4, no key file written.
        let bad = try cli(["keys", "export", "--vault", Self.fixtureVault, "--out", path("nope.key")],
                          env: ["SEMPERE_PASSPHRASE": "wrong"])
        XCTAssertEqual(bad.status, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("nope.key")))
    }

    // MARK: vault

    func testInitAndInfo() throws {
        let key = path("a.key")
        let pub = try {
            let r = try cli(["keys", "generate", "--out", key, "-q"])
            return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let vault = path("fresh.sempere")
        // A key is never stored under an empty passphrase (as in the app and `keys paper`).
        let empty = try cli(["vault", "init", vault, "--recipient", pub, "--store-key", key, "--work-factor", "15"],
                            env: ["SEMPERE_PASSPHRASE": ""])
        XCTAssertEqual(empty.status, 2, empty.err)
        XCTAssertTrue(empty.err.contains("the passphrase is empty"), empty.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault), "nothing created")
        let r = try cli(["vault", "init", vault, "--recipient", pub, "--label", "laptop", "--store-key", key,
                         "--passphrase-env", "MY_PASS", "--work-factor", "15"], env: ["MY_PASS": "s3cret"])
        XCTAssertEqual(r.status, 0, r.err)
        // Stored key works through the passphrase path.
        let info = try cli(["vault", "info", "--vault", vault, "--json"])
        XCTAssertEqual(info.status, 0, info.err)
        let obj = try XCTUnwrap(info.json as? [String: Any])
        XCTAssertEqual(obj["notes"] as? Int, 0)
        XCTAssertEqual(obj["pendingRewrap"] as? Bool, false)
        XCTAssertEqual((obj["recipients"] as? [[String: Any]])?.first?["label"] as? String, "laptop")
        XCTAssertEqual((obj["keyFiles"] as? [String])?.first, pub)
        let text = try cli(["vault", "info", "--vault", vault])
        // Keys are post-quantum by default; `info` abbreviates the long key.
        XCTAssertTrue(pub.hasPrefix("age1pq1"), pub)
        XCTAssertTrue(text.out.contains(String(pub.prefix(16))) && text.out.contains("laptop"), text.out)
        XCTAssertTrue(text.out.contains("Post-quantum:   yes"), text.out)
        XCTAssertEqual((obj["recipients"] as? [[String: Any]])?.first?["type"] as? String, "mlkem768x25519")
        let verify = try cli(["vault", "verify", "--vault", vault], env: ["SEMPERE_PASSPHRASE": "s3cret"])
        XCTAssertEqual(verify.status, 0, verify.err)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", vault], env: ["SEMPERE_PASSPHRASE": "bad"]).status, 4)
        // Refuses to init twice and rejects bad names / recipients.
        XCTAssertEqual(try cli(["vault", "init", vault, "--recipient", pub]).status, 1)
        XCTAssertEqual(try cli(["vault", "init", path("x"), "--recipient", pub]).status, 1)
        XCTAssertEqual(try cli(["vault", "init", path("y.sempere"), "--recipient", "nope"]).status, 2)
        XCTAssertEqual(try cli(["vault", "init", path("y.sempere")]).status, 2)
    }

    func testVerifyHealthyFixtureAndCorruption() throws {
        let ok = try cli(["vault", "verify", "--vault", Self.fixtureVault, "--identity", Self.fixtureKey])
        XCTAssertEqual(ok.status, 0, ok.err)
        XCTAssertTrue(ok.out.contains("healthy"), ok.out)
        let json = try cli(["vault", "verify", "--vault", Self.fixtureVault, "--identity", Self.fixtureKey, "--json"])
        let obj = try XCTUnwrap(json.json as? [String: Any])
        XCTAssertEqual(obj["healthy"] as? Bool, true)
        XCTAssertEqual((obj["files"] as? [[String: Any]])?.count, 9)   // 7 revisions, 1 key file, 1 blob

        let copy = try copyFixtureVault()
        let victim = "notes/\(Self.lecture)/17911308020000000-99ee00ff-1.delta.age"
        let url = URL(fileURLWithPath: copy).appendingPathComponent(victim)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 5] ^= 0x01
        try bytes.write(to: url)
        let bad = try cli(["vault", "verify", "--vault", copy, "--identity", Self.fixtureKey])
        XCTAssertEqual(bad.status, 3, bad.err)
        XCTAssertTrue(bad.out.contains("17911308020000000-99ee00ff-1.delta.age"), bad.out)
        XCTAssertTrue(bad.out.contains("UNHEALTHY"), bad.out)
        let badJSON = try cli(["vault", "verify", "--vault", copy, "--identity", Self.fixtureKey, "--json", "-q"])
        XCTAssertEqual(badJSON.status, 3)
        XCTAssertEqual((badJSON.json as? [String: Any])?["healthy"] as? Bool, false)
        // -q lists only the problem file.
        let quiet = try cli(["vault", "verify", "--vault", copy, "--identity", Self.fixtureKey, "-q"])
        XCTAssertEqual(quiet.out.split(separator: "\n").filter { $0.hasPrefix("ok") }.count, 0)
    }

    func testPassphraseFromEnvironmentOnFixture() throws {
        let r = try cli(["notes", "list", "--vault", Self.fixtureVault, "--json"],
                        env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual((r.json as? [[String: Any]])?.first?["title"] as? String, "Fixture lecture")
        // A named variable works too, and a wrong passphrase is exit 4.
        XCTAssertEqual(try cli(["notes", "list", "--vault", Self.fixtureVault, "--passphrase-env", "P"],
                               env: ["P": Self.passphrase]).status, 0)
        let bad = try cli(["notes", "list", "--vault", Self.fixtureVault], env: ["SEMPERE_PASSPHRASE": "nope"])
        XCTAssertEqual(bad.status, 4)
        XCTAssertEqual(bad.err.split(separator: "\n").count, 1, bad.err)
        // No key and no way to ask (stdin is /dev/null): exit 4.
        let noKey = try cli(["notes", "list", "--vault", Self.fixtureVault])
        XCTAssertEqual(noKey.status, 4)
        XCTAssertTrue(noKey.err.contains("no passphrase"), noKey.err)
        // A named variable that is not set is an error, also for `vault info` (which must not run locked).
        for cmd in [["notes", "list"], ["vault", "info"], ["vault", "verify"]] {
            let unset = try cli(cmd + ["--vault", Self.fixtureVault, "--passphrase-env", "NOT_SET_ANYWHERE"])
            XCTAssertEqual(unset.status, 4, "\(cmd)")
            XCTAssertTrue(unset.err.contains("NOT_SET_ANYWHERE"), unset.err)
        }
        // Library errors read as sentences, not enum dumps.
        let notVault = try cli(["vault", "init", path("notes"), "--recipient",
                                try NativeIdentity.generate(.postQuantum).recipient.string])
        XCTAssertEqual(notVault.status, 1)
        XCTAssertTrue(notVault.err.contains("must end in .sempere"), notVault.err)
        // Environment variables stand in for the options.
        let env = try cli(["notes", "list", "--json"], env: ["SEMPERE_VAULT": Self.fixtureVault,
                                                             "SEMPERE_IDENTITY": Self.fixtureKey])
        XCTAssertEqual(env.status, 0, env.err)
    }

    func testRecipientsAddThenExportWithNewIdentity() throws {
        let copy = try copyFixtureVault()
        let newKey = path("new.key")
        let pub = try cli(["keys", "generate", "--out", newKey, "-q"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let add = try cli(["vault", "recipients", "add", pub, "--label", "  my\nphone ", "--vault", copy,
                           "--identity", Self.fixtureKey])
        XCTAssertEqual(add.status, 0, add.err)
        XCTAssertTrue(add.out.contains("Rewrapped"), add.out)
        // Labels are stored as the app stores them: one line, trimmed.
        let labels = (try cli(["vault", "info", "--vault", copy, "--json"]).json as? [String: Any])?["recipients"]
        XCTAssertEqual((labels as? [[String: Any]])?.last?["label"] as? String, "my phone")
        let unnamed = path("unnamed.sempere")
        XCTAssertEqual(try cli(["vault", "init", unnamed, "--recipient", pub]).status, 0)
        let shown = try cli(["vault", "info", "--vault", unnamed])
        XCTAssertTrue(shown.out.contains("  Device  "), "an empty label shows as the app shows it: \(shown.out)")
        // The new identity alone can now export.
        let out = path("export")
        let ex = try cli(["export", "--all", "--format", "json", "--out", out, "--vault", copy, "--identity", newKey])
        XCTAssertEqual(ex.status, 0, ex.err)
        let files = try FileManager.default.contentsOfDirectory(atPath: out)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", copy, "--identity", newKey]).status, 0)
        let info = try cli(["vault", "info", "--vault", copy, "--json"])
        XCTAssertEqual((info.json as? [String: Any])?["recipients"].flatMap { ($0 as? [Any])?.count }, 2)
        // Removing the original key locks it out.
        let fixturePub = try fixtureIdentity().recipient.string
        let rm = try cli(["vault", "recipients", "remove", fixturePub, "--vault", copy, "--identity", newKey])
        XCTAssertEqual(rm.status, 0, rm.err)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", copy, "--identity", Self.fixtureKey]).status, 4)
        XCTAssertEqual(try cli(["vault", "verify", "--vault", copy, "--identity", newKey]).status, 0)
        XCTAssertEqual(try cli(["vault", "rewrap-resume", "--vault", copy, "--identity", newKey]).status, 0)
    }

    // MARK: notes and export

    func testListShowExport() throws {
        let (_, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let list = try cli(["notes", "list", "--vault", v, "--identity", keyPath, "--json"])
        XCTAssertEqual(list.status, 0, list.err)
        let notes = try XCTUnwrap(list.json as? [[String: Any]])
        XCTAssertEqual(notes.count, 2)
        let physics = try XCTUnwrap(notes.first { $0["title"] as? String == "Physics / Week 3" })
        XCTAssertEqual(physics["pages"] as? Int, 2)
        XCTAssertEqual(physics["strokes"] as? Int, 3)
        XCTAssertEqual(try cli(["notes", "list", "--vault", v, "--identity", keyPath, "--tag", "physics", "--json"])
            .json.flatMap { ($0 as? [Any])?.count }, 1)
        let human = try cli(["notes", "list", "--vault", v, "--identity", keyPath])
        XCTAssertTrue(human.out.contains("Groceries") && human.out.hasPrefix("ID"), human.out)

        let show = try cli(["notes", "show", "Groceries", "--vault", v, "--identity", keyPath])
        XCTAssertEqual(show.status, 0, show.err)
        XCTAssertTrue(show.out.contains("Revisions (1)") && show.out.contains(".delta.age"), show.out)
        let showJSON = try cli(["notes", "show", "aaaaaaaa", "--vault", v, "--identity", keyPath, "--json"])
        XCTAssertEqual(((showJSON.json as? [String: Any])?["revisions"] as? [Any])?.count, 2)
        XCTAssertEqual(try cli(["notes", "show", "nothing", "--vault", v, "--identity", keyPath]).status, 1)

        // PDF per note.
        let pdfDir = path("pdf")
        let pdf = try cli(["export", "--all", "--format", "pdf", "--out", pdfDir, "--vault", v, "--identity", keyPath])
        XCTAssertEqual(pdf.status, 0, pdf.err)
        // The hidden `.sempere-export-bulk.json` records what was written, for a re-run to skip.
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: pdfDir).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(pdfs, ["Groceries-bbbbbbbb.pdf", "Physics-Week-3-aaaaaaaa.pdf"])
        for f in pdfs {
            let data = try Data(contentsOf: URL(fileURLWithPath: pdfDir + "/" + f))
            XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-", f)
            XCTAssertTrue(pdf.out.contains(f), pdf.out)
        }
        // Merged PDF, single-note PDF to a named file.
        let merged = path("all.pdf")
        XCTAssertEqual(try cli(["export", "--all", "--merge", "--format", "pdf", "--out", merged, "--vault", v,
                                "--identity", keyPath]).status, 0)
        XCTAssertEqual(String(decoding: try Data(contentsOf: URL(fileURLWithPath: merged)).prefix(5), as: UTF8.self), "%PDF-")
        let one = path("one.pdf")
        XCTAssertEqual(try cli(["export", "Groceries", "--format", "pdf", "--out", one, "--vault", v,
                                "--identity", keyPath]).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: one))

        // SVG: one file per page.
        let svgDir = path("svg")
        let svg = try cli(["export", "aaaaaaaa-1111-4111-8111-000000000001", "--format", "svg", "--out", svgDir,
                           "--vault", v, "--identity", keyPath])
        XCTAssertEqual(svg.status, 0, svg.err)
        let svgs = try FileManager.default.contentsOfDirectory(atPath: svgDir).sorted()
        XCTAssertEqual(svgs, ["Physics-Week-3-aaaaaaaa-p001.svg", "Physics-Week-3-aaaaaaaa-p002.svg"])
        XCTAssertTrue(try String(contentsOfFile: svgDir + "/" + svgs[0], encoding: .utf8).contains("<svg"))

        // PNG: one file per page, `--dpi` scales the image, bad values are usage errors.
        func pngSize(_ file: String) throws -> (Int, Int) {
            let b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
            XCTAssertEqual(Array(b.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
            return (u32(16), u32(20))
        }
        let pngDir = path("png")
        let png = try cli(["export", "aaaaaaaa-1111-4111-8111-000000000001", "--format", "png", "--out", pngDir,
                           "--vault", v, "--identity", keyPath])
        XCTAssertEqual(png.status, 0, png.err)
        let pngs = try FileManager.default.contentsOfDirectory(atPath: pngDir).sorted()
        XCTAssertEqual(pngs, ["Physics-Week-3-aaaaaaaa-p001.png", "Physics-Week-3-aaaaaaaa-p002.png"])
        XCTAssertTrue(png.out.contains("Physics-Week-3-aaaaaaaa-p002.png"), png.out)
        let (w2, h2) = try pngSize(pngDir + "/" + pngs[0])
        XCTAssertEqual([w2, h2], [1224, 1584])   // letter at the default 144 dpi
        let png72Dir = path("png72")
        XCTAssertEqual(try cli(["export", "Groceries", "--format", "png", "--dpi", "72", "--out", png72Dir,
                                "--vault", v, "--identity", keyPath]).status, 0)
        let (w1, h1) = try pngSize(png72Dir + "/Groceries-bbbbbbbb-p001.png")
        XCTAssertEqual([w1, h1], [612, 792])
        let pngAll = path("pngall")
        XCTAssertEqual(try cli(["export", "--all", "--format", "png", "--dpi", "36", "--out", pngAll, "--vault", v,
                                "--identity", keyPath]).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pngAll + "/Groceries-bbbbbbbb"), ["p001.png"])
        for bad in ["0", "-3", "nan", "inf", "99999"] {
            XCTAssertEqual(try cli(["export", "--all", "--format", "png", "--dpi", bad, "--out", path("nope"),
                                    "--vault", v, "--identity", keyPath]).status, 2, bad)
        }
        // A dpi that passes validation but exceeds the pixel cap fails cleanly (exit 1, nothing written).
        let huge = try cli(["export", "Groceries", "--format", "png", "--dpi", "2400", "--out", path("huge"),
                            "--vault", v, "--identity", keyPath])
        XCTAssertEqual(huge.status, 1)
        XCTAssertTrue(huge.err.contains("exceeds the limit"), huge.err)

        // JSON: the reconstructed NoteState.
        let jsonDir = path("json")
        XCTAssertEqual(try cli(["export", "--all", "--format", "json", "--out", jsonDir, "--vault", v,
                                "--identity", keyPath]).status, 0)
        let state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: jsonDir + "/Physics-Week-3-aaaaaaaa.json"))) as? [String: Any]
        XCTAssertEqual((state?["meta"] as? [String: Any])?["title"] as? String, "Physics / Week 3")
        XCTAssertEqual((state?["pages"] as? [Any])?.count, 2)
    }

    func testExportSkipsDeletedUnlessAsked() throws {
        let dir = path("e")
        let r = try cli(["export", "--all", "--format", "json", "--out", dir, "--vault", Self.fixtureVault,
                         "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["Fixture-lecture-11111111.json"])
        let dir2 = path("e2")
        XCTAssertEqual(try cli(["export", "--all", "--deleted", "--format", "json", "--out", dir2, "--vault",
                                Self.fixtureVault, "--identity", Self.fixtureKey]).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir2).count, 2)
        // Needs exactly one of note and --all.
        XCTAssertEqual(try cli(["export", "--format", "pdf", "--out", dir, "--vault", Self.fixtureVault]).status, 2)
    }

    func testCompactSnapshotsFirstAndSnapshotCommand() throws {
        let (_, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", keyPath]
        let note = "aaaaaaaa-1111-4111-8111-000000000001"
        let dir = v + "/notes/" + note
        func count() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: dir).count }
        let state = tmp.appendingPathComponent("state/sempere/device.json")
        func device() throws -> String? {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])?["device"] as? String
        }
        // No snapshot: a dry run says it would snapshot and delete both old deltas, and touches nothing.
        let dry = try cli(["compact", "Physics / Week 3", "--retention", "0", "--dry-run"] + args)
        XCTAssertEqual(dry.status, 0, dry.err)
        XCTAssertTrue(dry.out.contains("would snapshot") && dry.out.contains("Would delete 2"), dry.out)
        XCTAssertEqual(try count(), 2)
        // A long retention needs nothing.
        let keep = try cli(["compact", note, "--retention", "100000", "--dry-run"] + args)
        XCTAssertTrue(keep.out.contains("Would delete 0") && !keep.out.contains("would snapshot"), keep.out)
        // For real: snapshot written, old deltas gone.
        let real = try cli(["compact", note, "--retention", "0"] + args)
        XCTAssertEqual(real.status, 0, real.err)
        XCTAssertTrue(real.out.contains("snapshot ") && real.out.contains("Deleted 2"), real.out)
        XCTAssertEqual(try count(), 1)
        XCTAssertEqual(try device()?.count, 8)
        // Now covered: a second compact writes no further snapshot.
        let again = try cli(["compact", note, "--retention", "0", "--dry-run"] + args)
        XCTAssertTrue(!again.out.contains("would snapshot") && again.out.contains("Would delete 0"), again.out)
        // `snapshot` reuses the device id.
        let id = try device()
        XCTAssertEqual(try cli(["snapshot", "Physics / Week 3"] + args).status, 0)
        XCTAssertEqual(try device(), id)
        XCTAssertEqual(try cli(["vault", "verify"] + args).status, 0)
        let shown = try cli(["notes", "list", "--json"] + args)
        XCTAssertEqual((shown.json as? [[String: Any]])?.first { $0["id"] as? String == note }?["strokes"] as? Int, 3)
    }

    func testCompactDryRunMatchesRealRunWithTwoSnapshots() throws {
        let (vault, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", keyPath]
        let note = UUID(uuidString: "aaaaaaaa-1111-4111-8111-000000000001")!
        XCTAssertEqual(try cli(["snapshot", note.uuidString.lowercased()] + args).status, 0)   // S1
        // A new old delta that S1 does not cover.
        let ms: Int64 = 1_760_000_009_000
        try vault.write(Revision(noteId: note, device: DeviceID("abcdef01")!, seq: 3, hlc: HLC(millis: ms, counter: 0)!,
                                 wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "t",
                                 body: .delta(ops: [.setMeta(.favorite(true))])))
        let dry = try cli(["compact", note.uuidString.lowercased(), "--retention", "0", "--dry-run"] + args)
        XCTAssertEqual(dry.status, 0, dry.err)
        let real = try cli(["compact", note.uuidString.lowercased(), "--retention", "0"] + args)
        XCTAssertEqual(real.status, 0, real.err)
        func deletions(_ r: CLIResult, _ word: String) -> [String] {
            r.out.split(separator: "\n").filter { $0.hasPrefix(word) }.map { String($0.dropFirst(word.count)) }
        }
        XCTAssertEqual(deletions(dry, "would delete "), deletions(real, "deleted "))
        XCTAssertEqual(deletions(real, "deleted ").count, 4)   // three deltas and S1
        let jsonDry = try cli(["compact", "--all", "--retention", "0", "--dry-run", "--json"] + args)
        let items = try XCTUnwrap(jsonDry.json as? [[String: Any]])
        XCTAssertTrue(items.allSatisfy { $0["snapshotNeeded"] is Bool })
    }

    func testCompactAllContinuesPastABrokenNote() throws {
        _ = try makeVault()
        let v = path("mine.sempere")
        let keyPath = path("mine.sempere.key")
        let broken = v + "/notes/aaaaaaaa-1111-4111-8111-000000000001"
        let file = broken + "/" + (try FileManager.default.contentsOfDirectory(atPath: broken).sorted()[0])
        var bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        bytes[bytes.count - 5] ^= 1
        try bytes.write(to: URL(fileURLWithPath: file))
        let args = ["--vault", v, "--identity", keyPath, "--retention", "0"]
        let dry = try cli(["compact", "--all", "--dry-run"] + args)
        XCTAssertEqual(dry.status, 1, dry.out + dry.err)
        let real = try cli(["compact", "--all"] + args)
        XCTAssertEqual(real.status, 1)
        XCTAssertTrue(real.err.contains("aaaaaaaa-1111"), real.err)
        XCTAssertTrue(real.out.contains("bbbbbbbb-2222"), real.out)   // the healthy note was still compacted
        let groceries = try FileManager.default.contentsOfDirectory(atPath: v + "/notes/bbbbbbbb-2222-4222-8222-000000000002")
        XCTAssertEqual(groceries.count, 1)
        XCTAssertTrue(groceries[0].hasSuffix(".snapshot.age"))
    }

    func testSvgLayoutAllVersusSingle() throws {
        let (_, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let all = path("svgall")
        XCTAssertEqual(try cli(["export", "--all", "--format", "svg", "--out", all, "--vault", v, "--identity", keyPath]).status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: all + "/Physics-Week-3-aaaaaaaa").sorted(),
                       ["p001.svg", "p002.svg"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: all + "/Groceries-bbbbbbbb"), ["p001.svg"])
    }

    // MARK: recover

    var firstRevision: String {
        Self.fixtureVault + "/notes/\(Self.lecture)/17911308010000000-a1b2c3d4-1.delta.age"
    }

    func testRecoverWithPlainKey() throws {
        let r = try cli(["recover", firstRevision, "--identity", Self.fixtureKey, "-v"])
        XCTAssertEqual(r.status, 0, r.err)
        let obj = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "delta")
        XCTAssertTrue(r.out.contains("Fixture lecture"))
        XCTAssertTrue(r.err.contains("tag verified"), r.err)
        // Wrong key: exit 4.
        let other = path("other.key")
        XCTAssertEqual(try cli(["keys", "generate", "--out", other]).status, 0)
        let bad = try cli(["recover", firstRevision, "--identity", other])
        XCTAssertEqual(bad.status, 4)
        XCTAssertTrue(bad.out.isEmpty)
        // Stored key plus passphrase works too, with no identity file.
        let viaPass = try cli(["recover", firstRevision], env: ["SEMPERE_PASSPHRASE": Self.passphrase])
        XCTAssertEqual(viaPass.status, 0, viaPass.err)
        XCTAssertEqual(viaPass.out, r.out)
    }

    func testRecoverLoneFileIsUnverified() throws {
        let lone = path("rev.age")
        try FileManager.default.copyItem(atPath: firstRevision, toPath: lone)
        let r = try cli(["recover", lone, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("UNVERIFIED"), r.err)
        XCTAssertNotNil(r.json)
        // Wrong --note-id with the vault around: the tag does not match.
        let wrong = try cli(["recover", firstRevision, "--identity", Self.fixtureKey, "--note-id",
                             "22222222-2222-4222-8222-222222222222"])
        XCTAssertEqual(wrong.status, 1)
        XCTAssertTrue(wrong.err.contains("tag mismatch") && wrong.err.contains("--no-verify"), wrong.err)
        XCTAssertTrue(wrong.out.isEmpty)
        let forced = try cli(["recover", firstRevision, "--identity", Self.fixtureKey, "--note-id",
                              "22222222-2222-4222-8222-222222222222", "--no-verify"])
        XCTAssertEqual(forced.status, 3)
        XCTAssertTrue(forced.err.contains("WARNING: tag mismatch, content may be tampered or from another vault"), forced.err)
        XCTAssertNotNil(forced.json)
        // A file that is not age at all.
        let junk = path("junk.age")
        try Data("not age".utf8).write(to: URL(fileURLWithPath: junk))
        XCTAssertEqual(try cli(["recover", junk, "--identity", Self.fixtureKey]).status, 1)
    }

    func testRecoverMatchesStockAgePipeline() throws {
        // The fixture key is post-quantum: stock recovery needs age 1.3 or later.
        guard let age = CLIPostQuantumTests.agePQ() else {
            if ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil {
                XCTFail("SEMPERE_REQUIRE_AGE_PQ set but no age >= 1.3 on PATH")
            }
            throw XCTSkip("no age >= 1.3 on PATH")
        }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "\"$0\" -d -i \"$1\" \"$2\" | tail -c +38 | gunzip", age, Self.fixtureKey, firstRevision]
        let pipe = Pipe()
        sh.standardOutput = pipe
        try sh.run()
        let expected = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0)
        XCTAssertFalse(expected.isEmpty)
        let mine = try cli(["recover", firstRevision, "--identity", Self.fixtureKey])
        XCTAssertEqual(mine.outData, expected)
    }

    // MARK: misc

    func testUsageAndHelp() throws {
        // The first line is `sempere VERSION`; the GPL notice follows (CLIAboutTests).
        XCTAssertEqual(try cli(["--version"]).out.split(separator: "\n").first.map(String.init), "sempere 0.5.0")
        XCTAssertEqual(try cli(["bogus"]).status, 2)
        XCTAssertEqual(try cli(["notes", "list"]).status, 2)   // no vault given
        // Every usage error is one `sempere:` line (docs/cli.md), whether the
        // command or ArgumentParser found it.
        XCTAssertEqual(try cli(["notes", "list"]).err, "sempere: no vault: pass --vault PATH or set SEMPERE_VAULT\n")
        XCTAssertEqual(try cli(["blobs", "copy", "abc", "--from", "a", "--to", "b"]).err,
                       "sempere: give the content's SHA-256: 8 to 64 lowercase hex digits (see 'sempere blobs copy --help')\n")
        XCTAssertEqual(try cli(["notes", "list", "--bogus"]).err,
                       "sempere: Unknown option '--bogus' (see 'sempere notes list --help')\n")
        for sub in [["keys", "generate"], ["vault", "init"], ["vault", "recipients", "add"], ["export"], ["recover"],
                    ["compact"], ["snapshot"], ["notes", "show"], ["vault", "verify"]] {
            let h = try cli(sub + ["--help"])
            XCTAssertEqual(h.status, 0, "\(sub)")
            XCTAssertTrue(h.out.contains("USAGE"), "\(sub): \(h.out)")
        }
        let root = try cli(["--help"])
        for word in ["keys", "vault", "notes", "export", "recover", "compact", "snapshot"] {
            XCTAssertTrue(root.out.contains(word), word)
        }
        // Every exit code and environment variable docs/cli.md lists is in the help too.
        let help = root.out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for code in ["0 ok", "1 failure", "2 usage error", "3 unhealthy", "4 cannot decrypt", "5 legacy vault",
                     "6 untrusted device list", "7 read-only vault"] {
            XCTAssertTrue(help.contains(code), code)
        }
        for variable in ["SEMPERE_VAULT", "SEMPERE_IDENTITY", "SEMPERE_PASSPHRASE", "SEMPERE_TITLE_FORMAT",
                         "SEMPERE_PDFTOPPM", "SEMPERE_PDFTOTEXT", "SEMPERE_WEBDAV_PASSWORD", "SEMPERE_BUNDLED_FONTS",
                         "SEMPERE_FONT_DIR", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"] {
            XCTAssertTrue(help.contains(variable), variable)
        }
    }

    func testSameTitledNotesExportToDistinctFilesAndTitleLookupIsAmbiguous() throws {
        let copy = try copyFixtureVault()
        let vault = try Vault.open(at: URL(fileURLWithPath: copy), identities: [try fixtureIdentity()])
        let state = tmp.appendingPathComponent("dup-device.json")
        let ids = [UUID(), UUID()]
        for (i, id) in ids.enumerated() {
            try vault.apply(NoteOps.newNote(title: "Same", notebook: i == 0 ? "A" : "B", tags: ["Math"]), to: id,
                            deviceState: state, app: "test")
        }
        let out = path("dup-export")
        let ex = try cli(["export", "--all", "--format", "json", "--out", out, "--vault", copy, "--identity", Self.fixtureKey])
        XCTAssertEqual(ex.status, 0, ex.err)
        let files = try FileManager.default.contentsOfDirectory(atPath: out)
        XCTAssertEqual(Set(files).count, files.count)
        XCTAssertEqual(files.filter { $0.hasPrefix("Same-") }.count, 2, "\(files)")
        let ambiguous = try cli(["notes", "history", "Same", "--vault", copy, "--identity", Self.fixtureKey])
        XCTAssertEqual(ambiguous.status, 1)
        for id in ids { XCTAssertTrue(ambiguous.err.contains(id.uuidString.lowercased()), ambiguous.err) }
        // The tag filter ignores case.
        let tagged = try cli(["notes", "list", "--tag", "MATH", "--json", "--vault", copy, "--identity", Self.fixtureKey])
        XCTAssertEqual((tagged.json as? [Any])?.count, 2)
    }

    /// Two devices tag one note concurrently (format.md §5.4.1): the filter
    /// finds it by both tags, in any case, and not by a removed one; the
    /// legacy fixture tag still filters until a per-tag remove drops it.
    func testTagFilterSeesConcurrentPerTagEdits() throws {
        let copy = try copyFixtureVault()
        let vault = try Vault.open(at: URL(fileURLWithPath: copy), identities: [try fixtureIdentity()])
        let ipad = tmp.appendingPathComponent("ipad-device.json"), mac = tmp.appendingPathComponent("mac-device.json")
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: "Tagged", tags: ["old"]), to: id, deviceState: ipad, app: "test")
        let base = try vault.reconstruct(noteId: id)
        // Both devices start from `base` and do not see each other's edit.
        try vault.apply([try XCTUnwrap(NoteOps.addTag("Exam", to: base))], to: id, deviceState: ipad, app: "test")
        try vault.apply([try XCTUnwrap(NoteOps.addTag("math", to: base)),
                         try XCTUnwrap(NoteOps.removeTag("old", from: base))], to: id, deviceState: mac, app: "test")
        func listed(_ tag: String) throws -> [String] {
            let r = try cli(["notes", "list", "--tag", tag, "--json", "--vault", copy, "--identity", Self.fixtureKey])
            XCTAssertEqual(r.status, 0, r.err)
            return ((r.json as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
        }
        XCTAssertEqual(try listed("exam"), ["Tagged"])
        XCTAssertEqual(try listed("MATH"), ["Tagged"])
        XCTAssertEqual(try listed("old"), [])
        let show = try cli(["notes", "list", "--json", "--vault", copy, "--identity", Self.fixtureKey])
        let note = (show.json as? [[String: Any]])?.first { $0["title"] as? String == "Tagged" }
        XCTAssertEqual(note?["tags"] as? [String], ["Exam", "math"])

        // The fixture lecture's tag is a legacy write.
        XCTAssertEqual(try listed("Fixture"), ["Fixture lecture"])
        let lectureId = try XCTUnwrap(UUID(uuidString: Self.lecture))
        let lecture = try vault.reconstruct(noteId: lectureId)
        try vault.apply([try XCTUnwrap(NoteOps.removeTag("fixture", from: lecture))], to: lectureId,
                        deviceState: mac, app: "test")
        XCTAssertEqual(try listed("fixture"), [])
    }
}
