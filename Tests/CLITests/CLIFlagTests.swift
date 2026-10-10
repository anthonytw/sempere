import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// Flags `docs/cli.md` documents that no other test exercised (gap audit GA-66): each is run through
/// the binary and its effect on the stored note, vault or backup is checked.
final class CLIFlagTests: CLITestCase {
    let physics = "aaaaaaaa-1111-4111-8111-000000000001"
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"
    static let images = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereRenderTests/Fixtures/images")

    var key: [String] { ["--vault", path("mine.sempere"), "--identity", path("mine.sempere.key")] }

    func ok(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        let r = try cli(args + key + ["--json"])
        XCTAssertEqual(r.status, 0, "\(args.prefix(3)): \(r.err)", file: file, line: line)
        return r.json as Any
    }

    func jpg(_ name: String = "grey.jpg") -> String { Self.images.appendingPathComponent(name).path }

    /// The items of the note's first page as `items list` prints them.
    func items(_ note: String) throws -> [[String: Any]] {
        try XCTUnwrap(try ok(["items", "list", note]) as? [[String: Any]])
    }

    func frame(_ item: [String: Any]) throws -> [Double] { try XCTUnwrap(item["frame"] as? [Double]) }

    // MARK: paper

    func testPaperOptionsAreStoredAndRangeChecked() throws {
        _ = try makeVault()
        let cornell = try XCTUnwrap(try ok(["notes", "paper", physics, "cornell", "--page", "1",
                                            "--cue-width", "120", "--summary-height", "90", "--line-width", "1.5",
                                            "--margin-left", "30", "--margin-top", "20", "--background", "#FFFFE0",
                                            "--line-color", "#112233", "--margin-color", "#AA000080"]) as? [String: Any])
        let paper = try XCTUnwrap(cornell["paper"] as? [String: Any])
        XCTAssertEqual(paper["kind"] as? String, "cornell")
        XCTAssertEqual(paper["cueWidth"] as? Double, 120)
        XCTAssertEqual(paper["summaryHeight"] as? Double, 90)
        XCTAssertEqual(paper["lineWidth"] as? Double, 1.5)
        XCTAssertEqual(paper["marginLeft"] as? Double, 30)
        XCTAssertEqual(paper["marginTop"] as? Double, 20)
        XCTAssertEqual(paper["background"] as? String, "#FFFFE0FF", "RGB gets full alpha")
        XCTAssertEqual(paper["lineColor"] as? String, "#112233FF")
        XCTAssertEqual(paper["marginColor"] as? String, "#AA000080")

        let staff = try XCTUnwrap((try XCTUnwrap(try ok(["notes", "paper", physics, "staff", "--page", "1",
                                                         "--staff-spacing", "9", "--staff-gap", "50"]) as? [String: Any]))["paper"] as? [String: Any])
        XCTAssertEqual(staff["kind"] as? String, "staff")
        XCTAssertEqual(staff["staffSpacing"] as? Double, 9)
        XCTAssertEqual(staff["staffGap"] as? Double, 50)

        let dots = try XCTUnwrap((try XCTUnwrap(try ok(["notes", "paper", physics, "dot", "--page", "1",
                                                        "--dot-radius", "1.2", "--spacing", "20"]) as? [String: Any]))["paper"] as? [String: Any])
        XCTAssertEqual(dots["dotRadius"] as? Double, 1.2)
        XCTAssertEqual(dots["spacing"] as? Double, 20)

        // Out of range or malformed: usage error, nothing written.
        let before = try Vault.open(at: URL(fileURLWithPath: path("mine.sempere")),
                                    identities: [try IdentityFile.parse(String(contentsOfFile: path("mine.sempere.key"), encoding: .utf8))])
            .loadNote(UUID(uuidString: physics)!).revisions.count
        for bad in [["--line-width", "0"], ["--line-width", "5"], ["--dot-radius", "0.1"], ["--margin-left", "301"],
                    ["--cue-width", "39"], ["--summary-height", "401"], ["--staff-spacing", "2"], ["--staff-gap", "151"],
                    ["--background", "red"], ["--line-color", "#12345"], ["--margin-color", "#GGGGGG"]] {
            let r = try cli(["notes", "paper", physics, "cornell"] + bad + key)
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        let after = try Vault.open(at: URL(fileURLWithPath: path("mine.sempere")),
                                   identities: [try IdentityFile.parse(String(contentsOfFile: path("mine.sempere.key"), encoding: .utf8))])
            .loadNote(UUID(uuidString: physics)!).revisions.count
        XCTAssertEqual(after, before)
    }

    // MARK: items

    func testDuplicateShiftsByDxAndDyAndCropKeepFrameKeepsTheFrame() throws {
        _ = try makeVault()
        _ = try ok(["attach", "image", physics, jpg()])
        let original = try XCTUnwrap(try items(physics).first)
        let id = try XCTUnwrap(original["id"] as? String)
        let f = try frame(original)

        // Default shift is 20 pt right and down; --dx/--dy replace it (a negative value needs the `=` form).
        _ = try ok(["items", "duplicate", physics, id])
        _ = try ok(["items", "duplicate", physics, id, "--dx", "5", "--dy=-3"])
        let copies = try items(physics).filter { $0["id"] as? String != id }
        let shifts = try copies.map { c -> [Double] in let g = try frame(c); return [g[0] - f[0], g[1] - f[1], g[2] - f[2], g[3] - f[3]] }
        XCTAssertEqual(shifts.sorted { $0[0] < $1[0] }, [[5, -3, 0, 0], [20, 20, 0, 0]])

        // Crop without --keep-frame refits the frame to the crop; with it the frame stays.
        _ = try ok(["items", "crop", physics, id, "--crop", "0,0,30,20", "--keep-frame"])
        XCTAssertEqual(try frame(try XCTUnwrap(try items(physics).first { $0["id"] as? String == id })), f, "--keep-frame leaves the frame")
        _ = try ok(["items", "crop", physics, id, "--clear", "--keep-frame"])
        _ = try ok(["items", "crop", physics, id, "--crop", "0,0,30,20"])
        let refit = try frame(try XCTUnwrap(try items(physics).first { $0["id"] as? String == id }))
        XCTAssertNotEqual(refit, f, "without --keep-frame the frame follows the crop")
        XCTAssertEqual(refit[2] / refit[3], 30.0 / 20.0, accuracy: 0.01, "the new frame has the crop's aspect")
    }

    // MARK: attach

    func testAttachTextItalicAndRecordingHeaderOverrides() throws {
        _ = try makeVault()
        let text = try XCTUnwrap(try ok(["attach", "text", physics, "slanted", "--italic"]) as? [String: Any])
        let item = try XCTUnwrap(((text["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])
        let runs = try XCTUnwrap((item["text"] as? [String: Any])?["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["i"] as? Bool }, [true])
        let plain = try XCTUnwrap(try ok(["attach", "text", physics, "upright"]) as? [String: Any])
        let plainRuns = try XCTUnwrap(((((plain["items"] as? [[String: Any]])?.first)?["item"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]])
        XCTAssertNil(plainRuns.first?["i"], "no italic unless asked")

        let audio = Self.fixtures.appendingPathComponent("audio/tone-aac.m4a").path
        let header = try XCTUnwrap((try XCTUnwrap(try ok(["attach", "recording", physics, audio]) as? [String: Any]))["recording"] as? [String: Any])
        XCTAssertEqual(header["sampleRate"] as? Int, 48000, "read from the file")
        XCTAssertEqual(header["channels"] as? Int, 1)
        let given = try XCTUnwrap((try XCTUnwrap(try ok(["attach", "recording", physics, audio, "--sample-rate", "44100", "--channels", "2"]) as? [String: Any]))["recording"] as? [String: Any])
        XCTAssertEqual(given["sampleRate"] as? Int, 44100)
        XCTAssertEqual(given["channels"] as? Int, 2)
        for bad in [["--sample-rate", "0"], ["--channels", "0"], ["--channels", "-1"]] {
            XCTAssertEqual(try cli(["attach", "recording", physics, audio] + bad + key).status, 2, "\(bad)")
        }
    }

    // MARK: search

    // MARK: backup

    func testBackupChecksumFindsAFileThatKeptItsSize() throws {
        let (vault, _, keyPath) = try makeVault()
        let dest = path("backup")
        let args = ["--vault", vault.url.path, "--identity", keyPath]
        XCTAssertEqual(try cli(["backup", "--to", dest] + args).status, 0)
        // Damage one backed-up revision without changing its size.
        let note = URL(fileURLWithPath: dest).appendingPathComponent("notes/\(groceries)")
        let revision = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: note.path).sorted().first { $0.hasSuffix(".age") })
        let file = note.appendingPathComponent(revision)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)

        let quick = try XCTUnwrap(try cli(["backup", "--to", dest, "--json"] + args).json as? [String: Any])
        XCTAssertEqual((quick["replaced"] as? [Any])?.count, 0, "the size shortcut trusts the recorded hash")
        let full = try XCTUnwrap(try cli(["backup", "--to", dest, "--checksum", "--json"] + args).json as? [String: Any])
        XCTAssertEqual((full["replaced"] as? [String])?.count, 1, "\(full)")
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: vault.url.appendingPathComponent("notes/\(groceries)/\(revision)")))
        XCTAssertEqual((full["versioned"] as? [String])?.count, 1, "the damaged copy is kept under versions/")
        // --checksum belongs to --to.
        XCTAssertEqual(try cli(["backup", "--archive", path("b.tar"), "--checksum"] + args).status, 2)
    }

    // MARK: export

    func testPdfTimeoutIsValidated() throws {
        _ = try makeVault()
        let out = path("g.pdf")
        for bad in ["0", "-1", "3601", "nan"] {
            let r = try cli(["export", groceries, "--format", "pdf", "--pdf-timeout", bad, "--out", out] + key)
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        let good = try cli(["export", groceries, "--format", "pdf", "--pdf-timeout", "5", "--out", out, "-q"] + key)
        XCTAssertEqual(good.status, 0, good.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
    }

    // MARK: recipients, blobs

    func testStoredKeyIsWrappedWithTheStorePassphraseVariable() throws {
        _ = try makeVault()
        let newKey = path("second.key")
        let pub = try cli(["keys", "generate", "--out", newKey, "-q"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try cli(["vault", "recipients", "add", pub, "--store-key", newKey, "--store-passphrase-env", "SECOND_PASS",
                         "--work-factor", "15"] + key, env: ["SECOND_PASS": "second secret"])
        XCTAssertEqual(r.status, 0, r.err)
        let info = try XCTUnwrap(try cli(["vault", "info", "--vault", path("mine.sempere"), "--json"]).json as? [String: Any])
        XCTAssertEqual(info["keyFiles"] as? [String], [pub])
        // The stored file opens with that passphrase (and only that one), without an identity file.
        let list = try cli(["notes", "list", "--vault", path("mine.sempere"), "--passphrase-env", "SECOND_PASS"],
                           env: ["SECOND_PASS": "second secret"])
        XCTAssertEqual(list.status, 0, list.err)
        let wrong = try cli(["notes", "list", "--vault", path("mine.sempere"), "--passphrase-env", "SECOND_PASS"],
                            env: ["SECOND_PASS": "not it"])
        XCTAssertEqual(wrong.status, 4, wrong.err)
    }

    func testBlobsRepairFixesAWrongKindAndVerifyAgrees() throws {
        _ = try makeVault()
        _ = try ok(["attach", "image", physics, jpg()])
        let att = URL(fileURLWithPath: path("mine.sempere")).appendingPathComponent("notes/\(physics)/att")
        let blob = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: att.path).first { $0.contains(".image.") })
        let wrong = blob.replacingOccurrences(of: ".image.", with: ".bin.")
        try FileManager.default.moveItem(at: att.appendingPathComponent(blob), to: att.appendingPathComponent(wrong))
        XCTAssertEqual(try cli(["blobs", "verify", physics, "-q"] + key).status, 3, "the misnamed blob does not verify")
        let r = try cli(["blobs", "repair", physics, "--json"] + key)
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: att.path), [blob])
        XCTAssertEqual(try cli(["blobs", "verify", physics, "-q"] + key).status, 0)
        let again = try cli(["blobs", "repair", physics] + key)
        XCTAssertEqual(again.status, 0, again.err)
    }

    // MARK: fixture vault with items (GA-63)

    func testItemsFixtureThroughTheCLI() throws {
        let vault = path("items.sempere")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("items.sempere"), to: URL(fileURLWithPath: vault))
        let args = ["--vault", vault, "--identity", Self.fixtureKey]
        let items = try XCTUnwrap(try cli(["items", "list", "Fixture items", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["kind"] as? String }, ["text", "image", "math"])
        XCTAssertEqual(try cli(["blobs", "verify", "-q"] + args).status, 0)
        XCTAssertEqual(try cli(["vault", "verify", "-q"] + args).status, 0)
        let svg = path("items.svg")
        let r = try cli(["export", "Fixture items", "--format", "svg", "--pdf-renderer", "none", "--out", svg, "-q"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        var file = URL(fileURLWithPath: svg)
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            file = file.appendingPathComponent(try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: svg).sorted().first))
        }
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(text.contains("Fixture text box") && text.contains("<image"), "the text box and the image are drawn")
        let found = try XCTUnwrap(try cli(["search", "Fixture text", "--json"] + args).json as? [[String: Any]])
        XCTAssertEqual(found.first?["source"] as? String, "text")
    }
}
