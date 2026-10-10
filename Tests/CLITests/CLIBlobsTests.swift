import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere blobs …`, `vault recipients … --rewrap`, `recover` on a blob
/// (docs/cli.md "Attachments"), end to end through the binary.
final class CLIBlobsTests: CLITestCase {
    let n1 = "aaaaaaaa-1111-4111-8111-000000000001"
    let n2 = "bbbbbbbb-2222-4222-8222-000000000002"

    func access(_ vault: Vault, _ key: String) -> [String] { ["--vault", vault.url.path, "--identity", key] }

    /// Adds a blob through the CLI and returns its reference.
    func add(_ vault: Vault, _ key: String, note: String, content: Data, type: String) throws -> BlobRef {
        let file = path("src-\(UUID().uuidString)")
        try content.write(to: URL(fileURLWithPath: file))
        let r = try cli(["blobs", "add", note, file, "--type", type, "--json"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let o = try XCTUnwrap(r.json as? [String: Any])
        let ref = BlobRef(sha256: try XCTUnwrap(o["sha256"] as? String), size: Int64(try XCTUnwrap(o["size"] as? Int)),
                          type: try XCTUnwrap(o["type"] as? String))
        XCTAssertEqual(ref, BlobRef(content: content, type: type))
        return ref
    }

    /// Writes a delta in `note` with an image item using `ref`.
    func reference(_ vault: Vault, note: String, _ ref: BlobRef, seq: Int) throws {
        let page = UUID()
        try vault.write(Revision(noteId: UUID(uuidString: note)!, device: DeviceID("cccccccc")!, seq: seq,
                                 hlc: HLC(millis: 1_760_000_100_000 + Int64(seq), counter: 0)!,
                                 wall: Date(timeIntervalSince1970: 1_760_000_100), app: "cli-test/1",
                                 body: .delta(ops: [.addPage(Page(id: page, order: "b\(seq)")),
                                                    .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 2, h: 2),
                                                                                      frame: Rect(x: 0, y: 0, w: 20, h: 20), z: "a"))])))
    }

    /// Without --json, `blobs add` prints the reference as JSON a script can
    /// paste into a revision, whatever the media type holds.
    func testAddPrintsValidJSONForAnyType() throws {
        let (vault, _, key) = try makeVault()
        let file = path("src-quote")
        try Data("synthetic".utf8).write(to: URL(fileURLWithPath: file))
        let type = "text/x-\"quoted\"\\back"
        let r = try cli(["blobs", "add", n1, file, "--type", type] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let line = try XCTUnwrap(r.out.split(separator: "\n").last)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], r.out)
        XCTAssertEqual(o["type"] as? String, type)
        XCTAssertEqual(o["sha256"] as? String, BlobRef(content: Data("synthetic".utf8), type: type).sha256)
    }

    func testBlobsWorkflow() throws {
        let (vault, _, key) = try makeVault()
        let photo = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let used = try add(vault, key, note: n1, content: photo, type: "image/jpeg")
        let spare = try add(vault, key, note: n1, content: Data("synthetic spare".utf8), type: "application/pdf")
        try reference(vault, note: n1, used, seq: 1)

        // list
        var r = try cli(["blobs", "list", "--json"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let notes = try XCTUnwrap(r.json as? [[String: Any]])
        XCTAssertEqual(notes.map { $0["note"] as? String }, [n1])
        let files = try XCTUnwrap(notes.first?["files"] as? [[String: Any]])
        XCTAssertEqual(Set(files.compactMap { ($0["referenced"] as? Bool).map { "\($0)" } }), ["true", "false"])
        r = try cli(["blobs", "list", n1] + access(vault, key))
        XCTAssertTrue(r.out.contains("referenced") && r.out.contains("unreferenced"), r.out)

        // extract: to a file (never over one), and to standard output
        let out = path("photo.jpg")
        r = try cli(["blobs", "extract", n1, String(used.sha256.prefix(10)), "--out", out] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), photo)
        r = try cli(["blobs", "extract", n1, used.sha256, "--out", out] + access(vault, key))
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("refusing to overwrite"), r.err)
        r = try cli(["blobs", "extract", n1, used.sha256] + access(vault, key))
        XCTAssertEqual(r.outData, photo)
        r = try cli(["blobs", "extract", n1, spare.sha256] + access(vault, key))
        XCTAssertEqual(r.status, 1, "an unreferenced blob is not reachable by reference")

        // verify, copy
        r = try cli(["blobs", "verify"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.out + r.err)
        for short in [String(used.sha256.prefix(7)), used.sha256.uppercased()] {
            r = try cli(["blobs", "copy", short, "--from", n1, "--to", n2] + access(vault, key))
            XCTAssertEqual(r.status, 2, "copy takes the same hash argument as extract: \(short)")
            XCTAssertTrue(r.err.contains("8 to 64 lowercase hex digits"), r.err)
        }
        r = try cli(["blobs", "copy", used.sha256, "--from", n1, "--to", n2] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let copied = vault.url.appendingPathComponent("notes/\(n2)/att/\(try vault.blobFileName(for: used))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))

        // unused, gc
        r = try cli(["blobs", "unused", "--json"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        let unused = try XCTUnwrap((r.json as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(unused.count, 2, "the spare blob in n1 and the copy in n2 (no reference there yet)")
        r = try cli(["blobs", "gc", "--dry-run", "--retention", "0", n1] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("would delete"), r.out)
        r = try cli(["blobs", "gc", n1] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("Deleted 0 blob(s); 1 unused blob(s) inside the retention window."), r.out)
        let stateFile = tmp.appendingPathComponent("state/sempere/blobs/\(vault.vaultId.uuidString.lowercased()).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path), "the device-local record")
        r = try cli(["blobs", "gc", "--retention", "0", n1] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("deleted \(n1)/att/\(try vault.blobFileName(for: spare))"), r.out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.url.appendingPathComponent("notes/\(n1)/att").path),
                       [try vault.blobFileName(for: used)])

        // a damaged blob: verify fails with 3, gc does not delete it
        let damaged = vault.url.appendingPathComponent("notes/\(n2)/att/\(try vault.blobFileName(for: used))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path), "before damage")
        var bytes = try Data(contentsOf: damaged)
        bytes[bytes.count - 3] ^= 1
        try bytes.write(to: damaged)
        r = try cli(["blobs", "verify", "-q"] + access(vault, key))
        XCTAssertEqual(r.status, 3, r.out + r.err)
        XCTAssertTrue(r.out.contains("invalid"), r.out)
        r = try cli(["blobs", "gc", "--retention", "0", n2] + access(vault, key))
        XCTAssertEqual(r.status, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
        r = try cli(["vault", "verify", "-q"] + access(vault, key))
        XCTAssertEqual(r.status, 3)
        try FileManager.default.removeItem(at: damaged)

        // repair: nothing to do
        r = try cli(["blobs", "repair"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
    }

    /// `blobs unused` reports what Settings → Storage shows: unused count and
    /// bytes, first seen and deletable-from dates, eligibility, and space
    /// held only by history; `gc --file` deletes one eligible blob.
    func testUnusedReportsTheStorageNumbers() throws {
        let (vault, _, key) = try makeVault()
        let shown = try add(vault, key, note: n1, content: Data("synthetic shown".utf8), type: "image/png")
        let old = try add(vault, key, note: n1, content: syntheticPicture(3000), type: "image/jpeg")
        let spareA = try add(vault, key, note: n1, content: Data("synthetic spare a".utf8), type: "application/pdf")
        let spareB = try add(vault, key, note: n2, content: Data("synthetic spare b".utf8), type: "audio/mp4")
        try reference(vault, note: n1, shown, seq: 1)
        // `old` is placed, then removed: only history (revision 2) still uses it.
        let page = UUID(), item = UUID()
        let note = UUID(uuidString: n1)!
        func rev(_ seq: Int, _ ops: [Op]) -> Revision {
            Revision(noteId: note, device: DeviceID("cccccccc")!, seq: seq,
                     hlc: HLC(millis: 1_760_000_100_000 + Int64(seq), counter: 0)!,
                     wall: Date(timeIntervalSince1970: 1_760_000_100 + Double(seq)), app: "cli-test/1", body: .delta(ops: ops))
        }
        let image = Item.image(id: item, blob: old, pixelSize: Size(w: 2, h: 2), frame: Rect(x: 0, y: 0, w: 20, h: 20), z: "b")
        try vault.write(rev(2, [.addPage(Page(id: page, order: "c")), .addItem(page: page, item: image)]))
        try vault.write(rev(3, [.removeItem(page: page, itemId: item)]))
        try reference(vault, note: n2, shown, seq: 1)
        _ = spareB

        var r = try cli(["blobs", "unused", "--json"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        var o = try XCTUnwrap(r.json as? [String: Any])
        let items = try XCTUnwrap(o["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual((o["unused"] as? [String: Any])?["count"] as? Int, 2)
        let bytes = items.compactMap { $0["bytes"] as? Int }.reduce(0, +)
        XCTAssertEqual((o["unused"] as? [String: Any])?["bytes"] as? Int, bytes)
        XCTAssertEqual((o["eligible"] as? [String: Any])?["count"] as? Int, 0, "30 days have not passed")
        XCTAssertEqual(o["retentionDays"] as? Double, 30)
        for i in items {
            XCTAssertEqual(i["eligible"] as? Bool, false)
            let first = try XCTUnwrap((i["firstSeen"] as? String).flatMap(RFC3339.parse))
            let from = try XCTUnwrap((i["deletableFrom"] as? String).flatMap(RFC3339.parse))
            XCTAssertEqual(from.timeIntervalSince(first), 30 * 86400, accuracy: 0.002)
        }
        let held = try XCTUnwrap(o["held"] as? [[String: Any]])
        XCTAssertEqual(held.map { $0["sha256"] as? String }, [old.sha256])
        XCTAssertEqual(held.first?["revisions"] as? [String], [rev(2, []).name.filename])
        XCTAssertEqual((o["heldByHistory"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertGreaterThan((o["heldByHistory"] as? [String: Any])?["bytes"] as? Int ?? 0, 0)
        r = try cli(["blobs", "unused", n1] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("Unused attachments: 1 item(s)") && r.out.contains("held by history: 1 item(s)"), r.out)

        // With no window both are eligible; `--file` deletes only the one named.
        r = try cli(["blobs", "unused", "--retention", "0", "--json"] + access(vault, key))
        o = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual((o["eligible"] as? [String: Any])?["count"] as? Int, 2)
        let a = try vault.blobFileName(for: spareA)
        r = try cli(["blobs", "gc", "--retention", "0", "--file", a, "--json"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        o = try XCTUnwrap(r.json as? [String: Any])
        let deleted = try XCTUnwrap(o["notes"] as? [[String: Any]]).flatMap { ($0["deleted"] as? [String]) ?? [] }
        XCTAssertEqual(deleted, [a])
        XCTAssertEqual(((o["storage"] as? [String: Any])?["unused"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("notes/\(n1)/att/\(a)").path))
        // A held blob is never collected.
        r = try cli(["blobs", "gc", "--retention", "0"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("notes/\(n1)/att/\(try vault.blobFileName(for: old))").path))
        XCTAssertTrue(r.out.contains("Unused attachments: 0 item(s)"), r.out)
    }

    func syntheticPicture(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 13) }) }

    func testRecipientsRewrapOptionAndRecover() throws {
        let (vault, _, key) = try makeVault()
        let content = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let ref = try add(vault, key, note: n1, content: content, type: "audio/mp4")
        try reference(vault, note: n1, ref, seq: 1)
        let other = try NativeIdentity.generate(.postQuantum)
        let otherKey = path("other.key")
        try IdentityFile.render(other, created: Date()).write(toFile: otherKey, atomically: true, encoding: .utf8)

        var r = try cli(["vault", "recipients", "add", other.recipient.string, "--json"] + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual((r.json as? [String: Any])?["blobs"] as? String, "header")
        r = try cli(["vault", "recipients", "remove", other.recipient.string, "--rewrap", "header", "--json"]
            + access(vault, key))
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual((r.json as? [String: Any])?["blobs"] as? String, "header")
        r = try cli(["vault", "recipients", "add", other.recipient.string, "--rewrap", "reencrypt", "--json"]
            + access(vault, key))
        XCTAssertEqual((r.json as? [String: Any])?["blobs"] as? String, "reencrypt")
        r = try cli(["vault", "recipients", "remove", other.recipient.string, "--json"] + access(vault, key))
        XCTAssertEqual((r.json as? [String: Any])?["blobs"] as? String, "reencrypt")
        r = try cli(["vault", "recipients", "add", other.recipient.string, "--rewrap", "sideways"] + access(vault, key))
        XCTAssertEqual(r.status, 2)

        // recover: the content, the name checked inside the vault
        let reopened = try Vault.open(at: vault.url, identities: [try IdentityFile.parse(String(contentsOfFile: key, encoding: .utf8))])
        let blob = vault.url.appendingPathComponent("notes/\(n1)/att/\(try reopened.blobFileName(for: ref))")
        r = try cli(["recover", blob.path, "--identity", key, "-v"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.outData, content)
        XCTAssertTrue(r.err.contains("name verified"), r.err)
        let outside = tmp.appendingPathComponent(blob.lastPathComponent)
        try FileManager.default.copyItem(at: blob, to: outside)
        r = try cli(["recover", outside.path, "--identity", key])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.outData, content)
        XCTAssertTrue(r.err.contains("UNVERIFIED NAME"), r.err)
        let renamed = blob.deletingLastPathComponent().appendingPathComponent(String(repeating: "f", count: 64) + ".audio.age")
        try FileManager.default.moveItem(at: blob, to: renamed)
        r = try cli(["recover", renamed.path, "--identity", key])
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.outData, Data(), "nothing printed for a name that does not verify")
    }
}
