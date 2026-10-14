import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `notes checkpoint`, `notes history --sessions` and `compact --thin-older-than`
/// (format.md §5.8).
final class CLIVersionHistoryTests: CLITestCase {
    static let physics = "aaaaaaaa-1111-4111-8111-000000000001"

    func revisionFiles(_ vault: String, _ note: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vault + "/notes/\(note)").filter { $0.hasSuffix(".age") }.sorted()
    }

    func testCheckpointIsListedAndGrouped() throws {
        _ = try makeVault()
        let args = ["--vault", path("mine.sempere"), "--identity", path("mine.sempere.key")]
        let saved = try cli(["notes", "checkpoint", "Physics / Week 3", "--name", "  Before the exam ", "--json"] + args)
        XCTAssertEqual(saved.status, 0, saved.err)
        let out = try XCTUnwrap(saved.json as? [String: Any])
        XCTAssertEqual(out["name"] as? String, "Before the exam")
        let file = try XCTUnwrap(out["file"] as? String)
        XCTAssertTrue(file.hasSuffix(".delta.age"))
        XCTAssertTrue(try revisionFiles(path("mine.sempere"), Self.physics).contains(file))

        let unnamed = try cli(["notes", "checkpoint", Self.physics] + args)
        XCTAssertEqual(unnamed.status, 0, unnamed.err)
        XCTAssertTrue(unnamed.out.contains("Saved version of"), unnamed.out)

        let history = try cli(["notes", "history", Self.physics, "--json"] + args)
        let points = try XCTUnwrap(history.json as? [[String: Any]])
        XCTAssertEqual(points.map { $0["checkpoint"] as? Bool }, [false, false, true, true])
        XCTAssertEqual(points[2]["name"] as? String, "Before the exam")
        XCTAssertNil(points[3]["name"])
        XCTAssertEqual(points.map { $0["group"] as? Int }, [0, 0, 1, 2])
        XCTAssertTrue(points.allSatisfy { $0["complete"] as? Bool == true })

        let grouped = try cli(["notes", "history", Self.physics, "--sessions", "--json"] + args)
        let groups = try XCTUnwrap(grouped.json as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["type"] as? String }, ["session", "checkpoint", "checkpoint"])
        XCTAssertEqual(groups[0]["saves"] as? Int, 2)
        XCTAssertEqual(groups[0]["device"] as? String, "abcdef01")
        XCTAssertEqual((groups[0]["points"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(groups[1]["name"] as? String, "Before the exam")
        XCTAssertEqual(groups[1]["newest"] as? String, file)

        let text = try cli(["notes", "history", Self.physics] + args)
        XCTAssertTrue(text.out.contains("(checkpoint: Before the exam)"), text.out)
        let sessions = try cli(["notes", "history", Self.physics, "--sessions"] + args)
        XCTAssertTrue(sessions.out.hasPrefix("GROUP"), sessions.out)
        XCTAssertEqual(sessions.out.split(separator: "\n").count, 4, sessions.out)

        // A checkpoint is restorable like any point.
        let restore = try cli(["notes", "restore", Self.physics, "--to", file, "--dry-run"] + args)
        XCTAssertEqual(restore.status, 0, restore.err)
    }

    /// One note with two old editing sessions and a checkpoint between them,
    /// written a year ago (wall times), on one device.
    func writeOldSessions(_ vault: Vault, baseMs: Int64 = 1_760_000_000_000) throws -> (note: UUID, keep: [String], all: [String]) {
        let note = UUID(uuidString: "cccccccc-3333-4333-8333-000000000003")!
        let device = DeviceID("0badcafe")!
        let page = UUID()
        var seq = 0
        var names: [String] = []
        func write(_ minute: Int64, _ ops: [Op], session: String, checkpoint: Checkpoint? = nil) throws -> String {
            seq += 1
            let ms = baseMs + minute * 60_000
            let r = Revision(noteId: note, device: device, seq: seq, hlc: HLC(millis: ms, counter: 0)!,
                             wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "cli-test/1",
                             body: .delta(ops: ops), session: session, checkpoint: checkpoint)
            try vault.write(r)
            names.append(r.name.filename)
            return r.name.filename
        }
        func ink(_ n: Double) -> Op {
            .addStroke(page: page, stroke: Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                                                  points: [StrokePoint(x: n, y: n, w: 2, h: 2), StrokePoint(x: n + 9, y: n, w: 2, h: 2)]))
        }
        _ = try write(0, [.addPage(Page(id: page, order: "a0")), .setMeta(.title("Old lecture"))], session: "s1")
        for i in 1...4 { _ = try write(Int64(i), [ink(Double(i))], session: "s1") }
        let end1 = try write(5, [ink(5)], session: "s1")
        let cp = try write(6, [], session: "s1", checkpoint: Checkpoint(name: "Week 1"))
        for i in 7...9 { _ = try write(Int64(i), [ink(Double(i))], session: "s2") }
        let end2 = try write(10, [ink(10)], session: "s2")
        return (note, [end1, cp, end2], names)
    }

    func testThinDryRunThenRealRunKeepsVersions() throws {
        let (vault, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", keyPath]
        let (note, keep, all) = try writeOldSessions(vault)
        let id = note.uuidString.lowercased()
        let before = try cli(["export", id, "--format", "svg", "--out", path("before.svg")] + args)
        XCTAssertEqual(before.status, 0, before.err)

        let dry = try cli(["compact", "Old lecture", "--thin-older-than", "30d", "--dry-run", "--json"] + args)
        XCTAssertEqual(dry.status, 0, dry.err)
        let item = try XCTUnwrap((dry.json as? [[String: Any]])?.first)
        let doomed = try XCTUnwrap(item["files"] as? [String])
        XCTAssertEqual(Set(doomed), Set(all).subtracting(keep))
        let snaps = try XCTUnwrap(item["snapshots"] as? [[String: Any]])
        XCTAssertEqual(snaps.count, 2, "\(snaps)")   // as of each session's end
        XCTAssertTrue(snaps.allSatisfy { $0["file"] == nil && $0["asOf"] is String })
        XCTAssertGreaterThan(item["bytesDeleted"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(item["bytesAdded"] as? Int ?? 0, 0)
        XCTAssertEqual(try revisionFiles(v, id), all.sorted(), "a dry run touches nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("state/sempere/device.json").path),
                       "not even the device state file")

        let text = try cli(["compact", id, "--thin-older-than", "30", "--dry-run"] + args)
        XCTAssertTrue(text.out.contains("would snapshot \(id) (as of"), text.out)
        XCTAssertTrue(text.out.contains("Would delete \(doomed.count) file(s)"), text.out)

        let real = try cli(["compact", id, "--thin-older-than", "30d"] + args)
        XCTAssertEqual(real.status, 0, real.err)
        let left = try revisionFiles(v, id)
        XCTAssertEqual(left.filter { $0.hasSuffix(".delta.age") }, keep.sorted())
        XCTAssertEqual(left.filter { $0.hasSuffix(".snapshot.age") }.count, 2)

        // The kept versions are complete restore points; the note is unchanged.
        let history = try cli(["notes", "history", id, "--json"] + args)
        let points = try XCTUnwrap(history.json as? [[String: Any]])
        XCTAssertEqual(points.compactMap { $0["revision"] as? String }, keep.sorted())
        XCTAssertTrue(points.allSatisfy { $0["complete"] as? Bool == true })
        XCTAssertEqual(points.first { $0["checkpoint"] as? Bool == true }?["name"] as? String, "Week 1")
        let after = try cli(["export", id, "--format", "svg", "--out", path("after.svg")] + args)
        XCTAssertEqual(after.status, 0, after.err)
        func exported(_ dir: String) throws -> Data {
            let files = try FileManager.default.contentsOfDirectory(atPath: path(dir))
            XCTAssertEqual(files.count, 1)
            return try Data(contentsOf: URL(fileURLWithPath: path(dir)).appendingPathComponent(files[0]))
        }
        XCTAssertEqual(try exported("before.svg"), try exported("after.svg"))
        let atCheckpoint = try cli(["export", id, "--at", keep[1], "--format", "svg", "--out", path("cp.svg")] + args)
        XCTAssertEqual(atCheckpoint.status, 0, atCheckpoint.err)
        XCTAssertEqual(try cli(["vault", "verify"] + args).status, 0)

        // Again: nothing to do.
        let again = try cli(["compact", id, "--thin-older-than", "30d", "--dry-run"] + args)
        XCTAssertTrue(again.out.contains("Would delete 0 file(s)") && !again.out.contains("would snapshot"), again.out)
    }

    /// `--thin-older-than` applies the window; `--thin-all` ignores it and keeps
    /// checkpoints plus each session's newest save. Both say which rule they apply.
    func testThinAllIgnoresTheWindowAndKeepsCheckpoints() throws {
        let (vault, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", keyPath]
        // Sessions from an hour ago: inside any window.
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        let (note, keep, all) = try writeOldSessions(vault, baseMs: base)
        let id = note.uuidString.lowercased()
        let windowed = try cli(["compact", id, "--thin-older-than", "30d", "--dry-run"] + args)
        XCTAssertEqual(windowed.status, 0, windowed.err)
        XCTAssertTrue(windowed.out.contains("Thin versions older than 30 days (dry run). Removes autosaves older than 30 days."),
                      windowed.out)
        XCTAssertTrue(windowed.out.contains("Would delete 0 file(s)"), windowed.out)
        let dry = try cli(["compact", id, "--thin-all", "--dry-run"] + args)
        XCTAssertTrue(dry.out.contains("Thin everything except checkpoints (dry run)."), dry.out)
        XCTAssertTrue(dry.out.contains("Keeps every checkpoint"), dry.out)
        let json = try cli(["compact", id, "--thin-all", "--dry-run", "--json"] + args)
        let item = try XCTUnwrap((json.json as? [[String: Any]])?.first)
        XCTAssertEqual(Set(try XCTUnwrap(item["files"] as? [String])), Set(all).subtracting(keep))
        XCTAssertEqual(try revisionFiles(v, id), all.sorted())
        let real = try cli(["compact", id, "--thin-all"] + args)
        XCTAssertEqual(real.status, 0, real.err)
        XCTAssertEqual(try revisionFiles(v, id).filter { $0.hasSuffix(".delta.age") }, keep.sorted())
        let history = try cli(["notes", "history", id, "--json"] + args)
        let points = try XCTUnwrap(history.json as? [[String: Any]])
        XCTAssertTrue(points.allSatisfy { $0["complete"] as? Bool == true })
        XCTAssertEqual(points.first { $0["checkpoint"] as? Bool == true }?["name"] as? String, "Week 1")
        for bad in [["--thin-all", "--thin-older-than", "30d"], ["--thin-all", "--retention", "30"]] {
            XCTAssertNotEqual(try cli(["compact", "--all"] + bad + args).status, 0, "\(bad)")
        }
    }

    func testThinNeverAndBadArguments() throws {
        let (vault, _, keyPath) = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", keyPath]
        let (note, _, all) = try writeOldSessions(vault)
        let never = try cli(["compact", "--all", "--thin-older-than", "never", "--json"] + args)
        XCTAssertEqual(never.status, 0, never.err)
        XCTAssertEqual((never.json as? [Any])?.count, 0)
        XCTAssertEqual(try revisionFiles(v, note.uuidString.lowercased()), all.sorted())
        for bad in [["--thin-older-than", "soon"], ["--thin-older-than", "0d"], ["--thin-older-than", "-3"],
                    ["--thin-older-than", "30d", "--retention", "30"]] {
            let r = try cli(["compact", "--all"] + bad + args)
            XCTAssertNotEqual(r.status, 0, "\(bad)")
        }
    }

    func testRetentionCompactionKeepsCheckpoint() throws {
        _ = try makeVault()
        let v = path("mine.sempere")
        let args = ["--vault", v, "--identity", path("mine.sempere.key")]
        let saved = try cli(["notes", "checkpoint", Self.physics, "--name", "keep", "--json"] + args)
        let file = try XCTUnwrap((saved.json as? [String: Any])?["file"] as? String)
        let r = try cli(["compact", Self.physics, "--retention", "0", "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let item = try XCTUnwrap((r.json as? [[String: Any]])?.first)
        XCTAssertFalse((item["files"] as? [String] ?? []).contains(file))
        XCTAssertTrue(try revisionFiles(v, Self.physics).contains(file))
        let points = try XCTUnwrap(try cli(["notes", "history", Self.physics, "--json"] + args).json as? [[String: Any]])
        let cp = try XCTUnwrap(points.first { $0["revision"] as? String == file })
        XCTAssertEqual(cp["complete"] as? Bool, true)
        XCTAssertEqual(cp["name"] as? String, "keep")
    }
}
