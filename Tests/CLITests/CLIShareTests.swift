import Age
import CLITestSupport
import Foundation
import Sempere
import SempereRender
import XCTest

/// `sempere share` (docs/cli.md "share", docs/design/1.3-share.md §3.10), end to end through the binary and the
/// committed viewer template. The payload's content is covered by `WebPageShareTests`.
final class CLIShareTests: CLITestCase {
    static let renderImages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereRenderTests/Fixtures/images")
    let physics = "Physics / Week 3"
    let phrase = "a-passphrase-that-is-long-enough"

    func access() throws -> [String] {
        _ = try makeVault()
        return ["--vault", path("mine.sempere"), "--identity", path("mine.sempere.key")]
    }

    func passphraseFile(_ text: String? = nil) throws -> String {
        let f = path("passphrase.txt")
        try ((text ?? phrase) + "\n").write(toFile: f, atomically: true, encoding: .utf8)
        return f
    }

    /// The payload JSON of a share file.
    func open(_ file: String, passphrase: String? = nil) throws -> (json: [String: Any], blobs: [String: Data]) {
        let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
        let begin = try XCTUnwrap(text.range(of: "-----BEGIN AGE ENCRYPTED FILE-----"))
        let end = try XCTUnwrap(text.range(of: "-----END AGE ENCRYPTED FILE-----"))
        let plain = try AgeFile.decrypt(Data(text[begin.lowerBound..<end.upperBound].utf8),
                                        with: [ScryptIdentity(passphrase: passphrase ?? phrase)])
        let parsed = try WebPageShare.parse(container: plain)
        return (try XCTUnwrap(try JSONSerialization.jsonObject(with: parsed.json) as? [String: Any]), parsed.blobs)
    }

    func testSharesAFileThatOpensOnlyWithThePassphrase() throws {
        let a = try access()
        let out = path("note.html")
        let r = try cli(["share", physics, "--out", out, "--passphrase-file", try passphraseFile(), "--json"] + a)
        XCTAssertEqual(r.status, 0, r.err)
        let j = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(j["file"] as? String, out)
        XCTAssertEqual(j["scryptLog2N"] as? Int, 18)
        XCTAssertEqual(j["bytes"] as? Int, try FileManager.default.attributesOfItem(atPath: out)[.size] as? Int)
        XCTAssertNil(j["passphrase"], "only a generated one is printed")
        let sections = try XCTUnwrap(j["sections"] as? [String: Int])
        XCTAssertGreaterThan(sections["template"] ?? 0, 100_000)
        XCTAssertEqual(sections["audio"], 0)
        XCTAssertNotNil(j["scriptSha256"] as? String)

        let payload = try open(out)
        let note = try XCTUnwrap(payload.json["note"] as? [String: Any])
        let meta = try XCTUnwrap(note["meta"] as? [String: Any])
        XCTAssertEqual(meta["title"] as? String, "Physics / Week 3")
        XCTAssertEqual(meta["tags"] as? [String], [], "no tags unless --tags")
        XCTAssertNil(meta["notebook"])
        XCTAssertThrowsError(try open(out, passphrase: "wrong"))

        let html = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
        XCTAssertTrue(html.contains("<title>Shared note</title>"))
        XCTAssertFalse(html.contains("Physics"), "the title is inside the ciphertext only")
        XCTAssertTrue(html.contains("Content-Security-Policy"))

        // --verify: this release's viewer, work factor, never decrypts (no passphrase given).
        let v = try cli(["share", "--verify", out, "--json"])
        XCTAssertEqual(v.status, 0, v.err)
        let vj = try XCTUnwrap(v.json as? [String: Any])
        XCTAssertEqual(vj["ok"] as? Bool, true)
        XCTAssertEqual(vj["scryptLog2N"] as? Int, 18)
        XCTAssertEqual(vj["scriptSha256"] as? String, j["scriptSha256"] as? String)
        let text = try cli(["share", "--verify", out])
        XCTAssertEqual(text.status, 0)
        XCTAssertTrue(text.out.contains("matches this release's viewer"), text.out)
    }

    /// A voice note with no title of its own: the page shows its shown title, with the capture's date and time only under
    /// --dates (docs/design/1.3-share.md), and still never names the file.
    func testAVoiceNoteSharesItsShownTitleAndItsCaptureTimeOnlyWithDates() throws {
        let a = try access()
        let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SempereTests/Fixtures/audio/tone-aac.m4a").path
        XCTAssertEqual(try cli(["inbox", "enable", "--notebook", "Voice"] + a).status, 0)
        let captured = try cli(["inbox", "capture", tone, "--started", "2026-10-07T14:32:00Z", "--json"] + a)
        let note = try XCTUnwrap((captured.json as? [String: Any])?["note"] as? String, captured.err)
        XCTAssertEqual(try cli(["inbox", "import", "--json"] + a).status, 0)
        func title(_ flags: [String], _ file: String) throws -> String? {
            let r = try cli(["share", note, "--out", path(file), "--passphrase-file", try passphraseFile()] + flags + a)
            XCTAssertEqual(r.status, 0, r.err)
            return ((try open(path(file))).json["note"] as? [String: Any]).flatMap { $0["meta"] as? [String: Any] }?["title"] as? String
        }
        XCTAssertEqual(try title([], "plain.html"), "Voice note", "no capture time without --dates")
        let dated = try XCTUnwrap(try title(["--dates"], "dated.html"))
        XCTAssertTrue(dated.hasPrefix("Voice note Oct 7, 2026"), dated)
    }

    func testVerifyFailsAnEditedPolicyAndAFileThatIsNotAShare() throws {
        let a = try access()
        let out = path("note.html")
        XCTAssertEqual(try cli(["share", physics, "--out", out, "--passphrase-file", try passphraseFile()] + a).status, 0)
        var html = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertTrue(html.contains("connect-src 'none'"))
        html = html.replacingOccurrences(of: "connect-src 'none'", with: "connect-src *")
        let edited = path("edited.html")
        try html.write(toFile: edited, atomically: true, encoding: .utf8)
        let r = try cli(["share", "--verify", edited, "--json"])
        XCTAssertNotEqual(r.status, 0)
        let j = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(j["ok"] as? Bool, false)
        XCTAssertEqual(j["policyMatches"] as? Bool, false)
        XCTAssertTrue(r.err.contains("not a share file made by this release"), r.err)
        let other = path("other.html")
        try "<html></html>".write(toFile: other, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try cli(["share", "--verify", other]).status, 0)
    }

    func testEveryPassphraseSource() throws {
        let a = try access()
        // A file.
        XCTAssertEqual(try cli(["share", physics, "--out", path("f.html"), "--passphrase-file", try passphraseFile()] + a).status, 0)
        XCTAssertNoThrow(try open(path("f.html")))
        // The environment.
        let e = try cli(["share", physics, "--out", path("e.html"), "--share-passphrase-env", "MY_SHARE_PASS"] + a, env: ["MY_SHARE_PASS": phrase])
        XCTAssertEqual(e.status, 0, e.err)
        XCTAssertNoThrow(try open(path("e.html")))
        XCTAssertNotEqual(try cli(["share", physics, "--out", path("e2.html"), "--share-passphrase-env", "UNSET_VAR_X"] + a).status, 0)
        // Standard input.
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = ["share", physics, "--out", path("s.html"), "--passphrase-file", "-"] + a
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SEMPERE_") }
        env["XDG_STATE_HOME"] = path("state"); env["XDG_CACHE_HOME"] = path("cache")
        p.environment = env
        let stdin = Pipe(), err = Pipe()
        p.standardInput = stdin; p.standardError = err; p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data((phrase + "\n").utf8))
        try stdin.fileHandleForWriting.close()
        let said = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: said, as: UTF8.self))
        XCTAssertNoThrow(try open(path("s.html")))
        // Generated: seven words, once, in the JSON; on stderr in text mode.
        let g = try cli(["share", physics, "--out", path("g.html"), "--generate-passphrase", "--json"] + a)
        XCTAssertEqual(g.status, 0, g.err)
        let generated = try XCTUnwrap((g.json as? [String: Any])?["passphrase"] as? String)
        XCTAssertEqual(generated.split(separator: "-").count, 7)
        XCTAssertNoThrow(try open(path("g.html"), passphrase: generated))
        let t = try cli(["share", physics, "--out", path("g2.html"), "--generate-passphrase"] + a)
        XCTAssertTrue(t.err.contains("Passphrase: "), t.err)
        XCTAssertFalse(t.out.contains("Passphrase"), "stdout stays clean")
    }

    func testAPassphraseIsNeverAnArgumentAndExactlyOneSourceIsRequired() throws {
        let a = try access()
        let arg = try cli(["share", physics, "--out", path("x.html"), "--passphrase", "hunter2"] + a)
        XCTAssertNotEqual(arg.status, 0)
        XCTAssertTrue(arg.err.contains("passphrase"), arg.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("x.html")))
        let none = try cli(["share", physics, "--out", path("x.html")] + a)
        XCTAssertEqual(none.status, 2, none.err)
        XCTAssertTrue(none.err.contains("exactly one"), none.err)
        let two = try cli(["share", physics, "--out", path("x.html"), "--generate-passphrase", "--passphrase-file", try passphraseFile()] + a)
        XCTAssertEqual(two.status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("x.html")))
        let empty = try cli(["share", physics, "--out", path("x.html"), "--passphrase-file", try passphraseFile("")] + a)
        XCTAssertNotEqual(empty.status, 0)
    }

    func testFlagsBringBackWhatIsLeftOutAndTheFileNameIsNeverTheTitle() throws {
        let a = try access()
        let folder = path("out")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let r = try cli(["share", physics, "--out", folder, "--passphrase-file", try passphraseFile(), "--tags", "--dates", "--json"] + a)
        XCTAssertEqual(r.status, 0, r.err)
        let file = folder + "/Shared note.html"
        XCTAssertEqual((r.json as? [String: Any])?["file"] as? String, file)
        let meta = try XCTUnwrap(((try open(file)).json["note"] as? [String: Any])?["meta"] as? [String: Any])
        XCTAssertEqual(meta["tags"] as? [String], ["physics"])
        XCTAssertNotEqual(meta["created"] as? String, "1970-01-01T00:00:00.000Z")
        // Never over an existing file.
        let again = try cli(["share", physics, "--out", folder, "--passphrase-file", try passphraseFile()] + a)
        XCTAssertNotEqual(again.status, 0)
        XCTAssertTrue(again.err.contains("refusing to overwrite"), again.err)
        // An unknown note, and --verify with a note.
        XCTAssertNotEqual(try cli(["share", "No such note", "--out", path("n.html"), "--passphrase-file", try passphraseFile()] + a).status, 0)
        XCTAssertNotEqual(try cli(["share", physics, "--verify", file]).status, 0)
    }

    func testAnImageIsReencodedWithoutItsMetadata() throws {
        let a = try access()
        let image = Self.renderImages.appendingPathComponent("metadata.jpg").path
        XCTAssertEqual(try cli(["attach", "image", physics, image, "--keep-metadata"] + a).status, 0)
        let source = try Data(contentsOf: URL(fileURLWithPath: image))
        XCTAssertTrue(source.contains(Data("Exif".utf8)), "the fixture carries metadata")
        XCTAssertEqual(try cli(["share", physics, "--out", path("img.html"), "--passphrase-file", try passphraseFile()] + a).status, 0)
        let payload = try open(path("img.html"))
        XCTAssertEqual(payload.blobs.count, 1)
        let blob = try XCTUnwrap(payload.blobs.values.first)
        XCTAssertEqual(Array(blob.prefix(2)), [0xFF, 0xD8])
        XCTAssertFalse(blob.contains(Data("Exif".utf8)))
        XCTAssertFalse(blob.contains(Data("GPS".utf8)))
    }

    func testANoteThatCannotFitFailsWithTheBreakdownAndWritesNothing() throws {
        let a = try access()
        for seed in 1...4 {
            let png = path("noise\(seed).png")
            try SyntheticImage.png(width: 1800, height: 1800, seed: UInt64(seed)).write(to: URL(fileURLWithPath: png))
            XCTAssertEqual(try cli(["attach", "image", physics, png] + a).status, 0)
        }
        let r = try cli(["share", physics, "--out", path("big.html"), "--passphrase-file", try passphraseFile(), "--max-size", "1"] + a)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.err.contains("limit is 1.0 MB") && r.err.contains("pictures"), r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("big.html")), "never a truncated file")
        XCTAssertEqual(try cli(["share", physics, "--out", path("ok.html"), "--passphrase-file", try passphraseFile(), "--max-size", "40"] + a).status, 0)
        XCTAssertNotEqual(try cli(["share", physics, "--out", path("zero.html"), "--passphrase-file", try passphraseFile(), "--max-size", "0"] + a).status, 0)
    }

    func testAReadOnlyVaultWorksBecauseNothingIsWrittenToIt() throws {
        let before = try FileManager.default.subpathsOfDirectory(atPath: Self.fixtureVault).sorted()
        let r = try cli(["share", Self.lecture, "--out", path("ro.html"), "--passphrase-file", try passphraseFile(),
                         "--vault", Self.fixtureVault, "--recovery-key", Self.fixtureRecoveryKey], env: [:])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertNoThrow(try open(path("ro.html")))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: Self.fixtureVault).sorted(), before)
    }

    /// The share passphrase is never the vault's: its variable, its value, or one the vault was opened with (exit 2, no file).
    func testTheVaultPassphraseIsRefusedAsTheSharePassphrase() throws {
        let a = try access()
        func refused(_ args: [String], env: [String: String], _ why: String) throws {
            let out = path("refused.html")
            let r = try cli(["share", physics, "--out", out] + args, env: env)
            XCTAssertEqual(r.status, 2, "\(why): \(r.err)")
            XCTAssertTrue(r.err.contains("vault"), r.err)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out), why)
        }
        try refused(["--share-passphrase-env", "SEMPERE_PASSPHRASE"] + a, env: ["SEMPERE_PASSPHRASE": phrase], "the default variable")
        try refused(["--share-passphrase-env", "VAULT_PASS", "--passphrase-env", "VAULT_PASS"] + a, env: ["VAULT_PASS": phrase],
                    "the named variable")
        try refused(["--passphrase-file", try passphraseFile()] + a, env: ["SEMPERE_PASSPHRASE": phrase], "the default variable's value")
        try refused(["--share-passphrase-env", "MY_SHARE_PASS", "--passphrase-env", "VAULT_PASS"] + a,
                    env: ["MY_SHARE_PASS": phrase, "VAULT_PASS": phrase], "the named variable's value")
        // Read through the recovery key's passphrase copy.
        let keys = try FileManager.default.contentsOfDirectory(atPath: Self.fixtureVault + "/keys").filter { $0.hasSuffix(".key.age") }
        let copy = Self.fixtureVault + "/keys/" + (try XCTUnwrap(keys.first))
        let opened = ["--vault", Self.fixtureVault, "--recovery-key", copy]
        let viaCopy = try cli(["share", Self.lecture, "--out", path("copy.html"), "--passphrase-file", try passphraseFile(Self.passphrase)]
                              + opened + ["--passphrase-env", "VAULT_PASS"], env: ["VAULT_PASS": Self.passphrase])
        XCTAssertEqual(viaCopy.status, 2, viaCopy.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("copy.html")))
        // A passphrase of its own still works, beside a vault passphrase.
        let own = try cli(["share", Self.lecture, "--out", path("own.html"), "--passphrase-file", try passphraseFile()]
                          + opened + ["--passphrase-env", "VAULT_PASS"], env: ["VAULT_PASS": Self.passphrase])
        XCTAssertEqual(own.status, 0, own.err)
        XCTAssertNoThrow(try open(path("own.html")))
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool { range(of: other) != nil }
}
