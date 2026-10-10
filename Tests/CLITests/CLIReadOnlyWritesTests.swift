import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// docs/cli.md "Vaults of a newer format version" lists every command that must refuse in a
/// read-only vault with exit 7 (gap audit GA-65). A command that forgot `requireWritable` would
/// write into a vault whose format this version cannot read whole. The commands need real
/// arguments (an item, a recording, a blob that exist), or they stop at a validation error
/// before the refusal, so the vault is built writable, filled through the CLI, and only then
/// declared newer (`sempere/2`).
final class CLIReadOnlyWritesTests: CLITestCase {
    let physics = "aaaaaaaa-1111-4111-8111-000000000001"
    let groceries = "bbbbbbbb-2222-4222-8222-000000000002"
    static let render = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereRenderTests/Fixtures/images")
    static let pdfs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SemperePDFTests/Fixtures")

    func files(_ path: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let root = URL(fileURLWithPath: path)
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            guard (try f.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            out[f.path.replacingOccurrences(of: root.path, with: "")] = try Data(contentsOf: f)
        }
        return out
    }

    func testEveryWriteCommandExitsSevenAndChangesNothing() throws {
        _ = try makeVault()
        let vault = path("mine.sempere")
        let key = ["--vault", vault, "--identity", path("mine.sempere.key")]
        func ok(_ args: [String]) throws -> [String: Any] {
            let r = try cli(args + key + ["--json"])
            XCTAssertEqual(r.status, 0, "\(args.prefix(3)): \(r.err)")
            return (r.json as? [String: Any]) ?? [:]
        }
        let png = Self.render.appendingPathComponent("grey1.png").path
        let jpg = Self.render.appendingPathComponent("grey.jpg").path
        let video = Self.fixtures.appendingPathComponent("video/clip-h264.mp4").path
        let audio = Self.fixtures.appendingPathComponent("audio/tone-aac.m4a").path
        let pdf = Self.pdfs.appendingPathComponent("classic.pdf").path

        // Fill a writable vault: an image, a video, an equation, a recording, a second copy of the image.
        _ = try ok(["attach", "image", physics, png])
        _ = try ok(["attach", "video", physics, video, "--no-poster"])
        _ = try ok(["attach", "math", physics, "--latex", "x^2"])
        let recording = try XCTUnwrap(try ok(["attach", "recording", physics, audio, "--title", "Lecture"])["recording"] as? [String: Any])
        let rid = try XCTUnwrap(recording["id"] as? String)
        let blob = try XCTUnwrap((recording["blob"] as? [String: Any])?["sha256"] as? String)
        let list = try XCTUnwrap(try cli(["items", "list", physics] + key + ["--json"]).json as? [[String: Any]])
        func item(_ kind: String) throws -> String {
            try XCTUnwrap(list.first { $0["kind"] as? String == kind }?["id"] as? String, "no \(kind) item")
        }
        let (image, clip, math) = (try item("image"), try item("video"), try item("math"))
        let transcript = path("transcript.json")
        try Transcript(recording: UUID(uuidString: rid)!, engine: "test/1", language: "en",
                       created: Date(timeIntervalSince1970: 1_760_000_000),
                       segments: [.init(start: 0, end: 1, text: "synthetic")]).encoded().write(to: URL(fileURLWithPath: transcript))
        _ = try ok(["notes", "move", groceries, "Archive"])
        _ = try ok(["notes", "delete", groceries])
        _ = try ok(["notes", "move", physics, "School"])
        let history = try XCTUnwrap(try cli(["notes", "history", physics] + key + ["--json"]).json as? [[String: Any]])
        let firstRevision = try XCTUnwrap(history.first?["revision"] as? String ?? history.first?["name"] as? String)

        // The vault is now written by a newer version: no more writes.
        let manifestURL = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        var manifest = try VaultManifest.decode(Data(contentsOf: manifestURL))
        manifest.format = "sempere/2"
        try manifest.encoded().write(to: manifestURL)
        let before = try files(vault)
        let pq = try NativeIdentity.generate(.postQuantum).recipient.string
        let pq2 = try NativeIdentity.generate(.postQuantum).recipient.string
        var writes: [[String]] = [
            ["notes", "move", physics, "Elsewhere"],
            ["notes", "move", physics, "--none"],
            ["notes", "paper", physics, "grid"],
            ["notes", "undelete", groceries],
            ["notes", "language", physics, "fr-FR"],
            ["notes", "markers", physics, "behind"],
            ["notes", "layout", physics, "pageless"],
            ["notes", "restore", physics, "--to", firstRevision],
            ["pages", "move", physics, "1", "--to", "2"],
            ["pages", "delete", physics, "2"],
            ["pages", "duplicate", physics, "1"],
            ["items", "move", physics, image, "--frame", "1,1,40,40"],
            ["items", "rotate", physics, image, "--degrees", "90"],
            ["items", "crop", physics, image, "--crop", "0,0,0.5,0.5"],
            ["items", "replace", physics, image, jpg],
            ["items", "poster", physics, clip, jpg],
            ["items", "math", physics, math, "--latex", "y^2"],
            ["items", "front", physics, image],
            ["items", "delete", physics, math],
            ["items", "duplicate", physics, image],
            ["items", "copy", physics, image, "--to", groceries],
            ["attach", "image", physics, png],
            ["attach", "pdf", physics, pdf],
            ["attach", "math", physics, "--latex", "z"],
            ["attach", "video", physics, video, "--no-poster"],
            ["attach", "recording", physics, audio],
            ["attach", "transcript", physics, rid, transcript],
            ["recordings", "place", physics, rid],
            ["recordings", "rename", physics, rid, "Renamed"],
            ["recordings", "delete", physics, rid],
            ["notebooks", "rename", "School", "Uni"],
            ["notebooks", "move", "School", "Archive"],
            ["import", "pdf", pdf],
            ["blobs", "copy", blob, "--from", physics, "--to", groceries],
        ]
        // `restore` copies a backup to a new vault and never touches the vault in use, so it is no
        // write of this vault (docs/cli.md "Backup and restore"); `recognize` is the app's Vision
        // (its Linux refusal is CLIRecognizeTests).
        #if canImport(Vision)
        writes.append(["recognize", physics])
        #endif
        var wrong: [String] = []
        for args in writes {
            let r = try cli(args + key)
            let refused = r.status == 7 && r.err.contains("read-only")
            if !refused { wrong.append("\(args.prefix(3).joined(separator: " ")) -> \(r.status): \(r.err.split(separator: "\n").last ?? "")") }
        }
        XCTAssertEqual(wrong, [], "every write command must exit 7 in a read-only vault")
        XCTAssertEqual(try files(vault), before, "nothing in the vault changed")
    }
}
