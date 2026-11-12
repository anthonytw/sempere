import Age
import CLITestSupport
import Foundation
@testable import Sempere
import VaultTestSupport
import XCTest

/// `sempere inbox watch`: the Apple Watch's voice notes end to end through the binary (docs/design/1.1-watch.md §4):
/// provision a throwaway watch, seal as the watch, receive as the phone, adopt.
final class CLIWatchTests: CLITestCase {
    static let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/audio/tone-aac.m4a").path

    func json(_ r: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertEqual(r.status, 0, r.err, file: file, line: line)
        return try XCTUnwrap(r.json as? [String: Any], r.out + r.err, file: file, line: line)
    }

    /// `frames` ADTS frames (24 kHz mono AAC-LC headers; the muxer never decodes the payloads).
    func adts(frames: Int) -> Data {
        var d = Data()
        for i in 0..<frames {
            let length = 7 + 30 + (i % 7)
            d.append(contentsOf: [0xFF, 0xF1, 0x58, UInt8(0x40 | ((length >> 11) & 3)), UInt8((length >> 3) & 0xFF),
                                  UInt8(((length & 7) << 5) | 0x1F), 0xFC])
            d.append(contentsOf: (7..<length).map { UInt8(truncatingIfNeeded: i &+ $0 &* 5) })
        }
        return d
    }

    /// A watch (its identity and recipient) provisioned from `vault`: the payload's path.
    func provisioned(_ unlocked: [String], name: String = "watch") throws -> (identity: String, payload: String, recipient: String) {
        let key = path("\(name).key")
        let made = try json(try cli(["inbox", "watch", "keygen", "--out", key, "--json"]))
        let recipient = try XCTUnwrap(made["recipient"] as? String)
        XCTAssertTrue(recipient.hasPrefix("age1pq1"))
        let attrs = try FileManager.default.attributesOfItem(atPath: key)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let payload = path("\(name).payload")
        let provisioned = try json(try cli(["inbox", "watch", "provision", "--to", recipient, "--out", payload, "--seq", "7",
                                            "--json"] + unlocked))
        XCTAssertEqual(provisioned["seq"] as? Int, 7)
        return (key, payload, recipient)
    }

    func testProvisionSealReceiveTwiceImport() throws {
        let (vault, identity, keyPath) = try makeVault()
        let unlocked = ["--vault", vault.url.path, "--identity", keyPath]
        let locked = ["--vault", vault.url.path]
        let watch = try provisioned(unlocked)
        // The payload is ciphertext: the capture key is not in it.
        let payloadBytes = try Data(contentsOf: URL(fileURLWithPath: watch.payload))
        XCTAssertNil(payloadBytes.range(of: Data(vault.vaultId.uuidString.lowercased().utf8)))

        let notesBefore = try XCTUnwrap(try cli(["notes", "list", "--json"] + unlocked).json as? [[String: Any]]).count
        // The watch records ADTS; it seals into its outbox.
        let aac = path("note.aac")
        try adts(frames: 120).write(to: URL(fileURLWithPath: aac))
        let outbox = path("outbox")
        let sealed = try json(try cli(["inbox", "watch", "seal", aac, "--payload", watch.payload, "--identity", watch.identity,
                                       "--outbox", outbox, "--started", "2026-11-09T14:32:00Z", "--json"]))
        let capture = try XCTUnwrap(sealed["capture"] as? String)
        XCTAssertEqual(sealed["vault"] as? String, vault.vaultId.uuidString.lowercased())
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outbox)/\(capture).capture.age"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outbox)/\(capture).meta.json"))

        // The phone receives it, twice. No key is needed.
        let args = ["inbox", "watch", "receive", outbox, "--received", path("received.json"), "--queue", path("queue"),
                    "--store", path("store"), "--json"] + locked
        let first = try json(try cli(args))
        let files = try XCTUnwrap(first["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["outcome"] as? String, "placed")
        XCTAssertEqual(files[0]["placement"] as? String, "vault")
        XCTAssertEqual(first["acked"] as? [String], [capture])
        let ack = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(outbox)/ack.json"))) as? [String: Any])
        XCTAssertEqual(ack["acked"] as? [String], [capture])

        let second = try json(try cli(args))
        XCTAssertEqual((second["files"] as? [[String: Any]])?.first?["outcome"] as? String, "duplicate")
        XCTAssertEqual(second["acked"] as? [String], [capture], "a duplicate is acknowledged again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.url.appendingPathComponent("inbox").path)
            .filter { $0.hasSuffix(".capture.age") }, ["\(capture).capture.age"], "placed once")

        // It is an ordinary inbox capture now.
        let listed = try XCTUnwrap(try cli(["inbox", "list", "--json"] + unlocked).json as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["title"] as? String, "Watch voice note \(Self.localTitleSuffix("2026-11-09T14:32:00Z"))")
        let imported = try json(try cli(["inbox", "import", "--json"] + unlocked))
        let result = try XCTUnwrap((imported["captures"] as? [[String: Any]])?.first)
        XCTAssertNil(result["error"])
        XCTAssertEqual(result["created"] as? Bool, true)
        let note = try XCTUnwrap(result["note"] as? String)

        // Exactly one note, with one recording, and the audio is MPEG-4.
        let notesAfter = try XCTUnwrap(try cli(["notes", "list", "--json"] + unlocked).json as? [[String: Any]]).count
        XCTAssertEqual(notesAfter, notesBefore + 1)
        let reader = try Vault.open(at: vault.url, identities: [identity])
        let state = try reader.reconstruct(noteId: UUID(uuidString: note)!)
        XCTAssertEqual(state.recordings.count, 1)
        let rec = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(rec.blob.type, "audio/mp4")
        let audio = try reader.readBlob(note: UUID(uuidString: note)!, rec.blob, maxBytes: 1 << 24)
        let probed = try AudioProbe.probe(audio)
        XCTAssertEqual(probed.codec, "aac")
        XCTAssertEqual(probed.sampleRate, 24000)
        XCTAssertEqual(try XCTUnwrap(probed.duration), 120 * 1024 / 24000.0, accuracy: 0.001)
        XCTAssertEqual((try cli(["inbox", "list", "--json"] + locked).json as? [[String: Any]])?.count, 0)

        // A third receive, after the inbox is empty and adopted, still places nothing (the received set).
        let third = try json(try cli(args))
        XCTAssertEqual((third["files"] as? [[String: Any]])?.first?["outcome"] as? String, "duplicate")
        XCTAssertEqual((try cli(["inbox", "list", "--json"] + locked).json as? [[String: Any]])?.count, 0)
    }

    /// The default title is in the machine's time zone; the test names it the same way.
    static func localTitleSuffix(_ rfc3339: String) -> String {
        guard let t = RFC3339.parse(rfc3339) else { return "" }
        return String(CaptureWriter.defaultTitle(t).dropFirst("Voice note ".count))
    }

    func testAnM4AIsSealedAsItIs() throws {
        let (_, _, keyPath) = try makeVault()
        let vault = try makeVault(named: "m4a.sempere")
        let unlocked = ["--vault", vault.vault.url.path, "--identity", vault.keyPath]
        _ = keyPath
        let watch = try provisioned(unlocked)
        let outbox = path("outbox")
        let sealed = try json(try cli(["inbox", "watch", "seal", Self.tone, "--payload", watch.payload, "--identity", watch.identity,
                                       "--outbox", outbox, "--title", "Hello", "--json"]))
        let capture = try XCTUnwrap(sealed["capture"] as? String)
        let received = try json(try cli(["inbox", "watch", "receive", outbox, "--received", path("r.json"), "--queue", path("q"),
                                         "--store", path("store"), "--json", "--vault", vault.vault.url.path]))
        XCTAssertEqual((received["files"] as? [[String: Any]])?.first?["placement"] as? String, "vault")
        let imported = try json(try cli(["inbox", "import", capture, "--json"] + unlocked))
        let note = try XCTUnwrap(((imported["captures"] as? [[String: Any]])?.first)?["note"] as? String)
        let state = try vault.vault.reconstruct(noteId: UUID(uuidString: note)!)
        XCTAssertEqual(state.meta.title, "Hello")
        XCTAssertEqual(try vault.vault.readBlob(note: UUID(uuidString: note)!, try XCTUnwrap(state.recordings.first).blob, maxBytes: 1 << 24),
                       try Data(contentsOf: URL(fileURLWithPath: Self.tone)))
    }

    /// A sealed watch file of `vault` in `outbox` (as the watch would write it): its capture id.
    func sealedNote(_ vault: (vault: Vault, identity: NativeIdentity, keyPath: String), outbox: String, name: String = "watch") throws -> String {
        let watch = try provisioned(["--vault", vault.vault.url.path, "--identity", vault.keyPath], name: name)
        let aac = path("\(name).aac")
        try adts(frames: 10).write(to: URL(fileURLWithPath: aac))
        return try XCTUnwrap(try json(try cli(["inbox", "watch", "seal", aac, "--payload", watch.payload, "--identity",
                                               watch.identity, "--outbox", outbox, "--json"]))["capture"] as? String)
    }

    /// A file of a vault this machine does not hold is not admitted: it is acknowledged and held, never queued, recorded or
    /// placed in the current inbox, and only `held delete` takes it (`held add` refuses).
    func testAFileOfAnotherVaultIsHeldNotPlacedInTheCurrentInbox() throws {
        let a = try makeVault(named: "a.sempere")
        let b = try makeVault(named: "b.sempere")
        let outbox = path("outbox")
        let capture = try sealedNote(b, outbox: outbox)
        // The phone's stored profile is vault A's; the file is B's, and B is not in its store.
        let r = try json(try cli(["inbox", "watch", "receive", outbox, "--received", path("r.json"), "--queue", path("q"),
                                  "--held", path("held"), "--store", path("store"), "--json", "--vault", a.vault.url.path]))
        let file = try XCTUnwrap((r["files"] as? [[String: Any]])?.first)
        XCTAssertEqual(file["outcome"] as? String, "held")
        XCTAssertEqual(file["reason"] as? String, "unknownVault")
        XCTAssertEqual(r["acked"] as? [String], [capture])
        let inboxA = a.vault.url.appendingPathComponent("inbox").path
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: inboxA)) ?? []).filter { $0.hasSuffix(".capture.age") }, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("q")), "not queued")

        let listed = try XCTUnwrap(try cli(["inbox", "watch", "held", "list", "--held", path("held"), "--json"]).json as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["capture"] as? String, capture)
        XCTAssertEqual(listed.first?["reason"] as? String, "unknownVault")
        XCTAssertEqual(listed.first?["canAdd"] as? Bool, false)
        let add = try cli(["inbox", "watch", "held", "add", String(capture.prefix(8)), "--held", path("held"), "--queue", path("q"),
                           "--store", path("store"), "--vault", a.vault.url.path])
        XCTAssertNotEqual(add.status, 0, "delete only")
        XCTAssertEqual((try cli(["inbox", "watch", "held", "list", "--held", path("held"), "--json"]).json as? [[String: Any]])?.count, 1)
        let deleted = try json(try cli(["inbox", "watch", "held", "delete", String(capture.prefix(8)), "--held", path("held"), "--json"]))
        XCTAssertEqual(deleted["deleted"] as? [String], [capture])
        XCTAssertEqual((try cli(["inbox", "watch", "held", "list", "--held", path("held"), "--json"]).json as? [[String: Any]])?.count, 0)
        // A second receive finds it already received.
        let again = try json(try cli(["inbox", "watch", "receive", outbox, "--received", path("r.json"), "--queue", path("q"),
                                      "--held", path("held"), "--store", path("store"), "--json", "--vault", a.vault.url.path]))
        XCTAssertEqual((again["files"] as? [[String: Any]])?.first?["outcome"] as? String, "duplicate")
    }

    /// A held note whose epoch this machine never held cannot be added even if it was held while the link was off
    /// (its sidecar says `linkOff`): `held add` re-checks and fails, and `--all` skips it.
    func testHeldAddRefusesAnUnknownEpochWhateverTheStoredReason() throws {
        let a = try makeVault(named: "a.sempere")
        let b = try makeVault(named: "b.sempere")
        let outbox = path("outbox")
        let capture = try sealedNote(b, outbox: outbox)
        let held = path("held")
        let dir = "\(held)/\(b.vault.vaultId.uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "\(outbox)/\(capture).capture.age"))
        try bytes.write(to: URL(fileURLWithPath: "\(dir)/\(capture).capture.age"))
        let sidecar: [String: Any] = ["id": capture, "vault": b.vault.vaultId.uuidString.lowercased(), "epoch": 1,
                                      "epochId": String(repeating: "ab", count: 32), "receivedAt": "2026-11-10T12:00:00Z",
                                      "reason": "linkOff", "bytes": bytes.count]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: URL(fileURLWithPath: "\(dir)/\(capture).capture.age.held.json"))
        // B is not in the store: not addable now.
        let add = try cli(["inbox", "watch", "held", "add", capture, "--held", held, "--queue", path("q"), "--store", path("store"),
                           "--vault", a.vault.url.path])
        XCTAssertNotEqual(add.status, 0)
        XCTAssertEqual((try cli(["inbox", "watch", "held", "list", "--held", held, "--json"]).json as? [[String: Any]])?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("q")))
        // `--all` makes the same re-check, so it skips the note (nothing to add) rather than trying it and failing.
        let all = try cli(["inbox", "watch", "held", "add", "--all", "--held", held, "--queue", path("q"), "--store", path("store"),
                           "--vault", a.vault.url.path, "--json"])
        XCTAssertEqual(all.status, 0, "a stale-reason note is not addable, so --all does not try it")
        XCTAssertEqual((try XCTUnwrap(all.json as? [[String: Any]])).count, 0)
        XCTAssertEqual((try cli(["inbox", "watch", "held", "list", "--held", held, "--json"]).json as? [[String: Any]])?.count, 1)
    }

    /// The same id twice: the first adds, the second finds it gone: `notHeld`, not a failure, and one inbox file.
    func testHeldAddOfTheSameIdTwiceIsANoOpTheSecondTime() throws {
        let vault = try makeVault()
        let outbox = path("outbox")
        let capture = try sealedNote(vault, outbox: outbox)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(outbox)/\(capture).meta.json"))) as? [String: Any])
        let vaultId = vault.vault.vaultId.uuidString.lowercased()
        let held = path("held")
        let dir = "\(held)/\(vaultId)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "\(outbox)/\(capture).capture.age"))
        try bytes.write(to: URL(fileURLWithPath: "\(dir)/\(capture).capture.age"))
        let sidecar: [String: Any] = ["id": capture, "vault": vaultId, "epoch": try XCTUnwrap(meta["epoch"] as? Int),
                                      "epochId": try XCTUnwrap(meta["epochId"] as? String), "receivedAt": "2026-11-10T12:00:00Z",
                                      "reason": "oldEpoch", "bytes": bytes.count]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: URL(fileURLWithPath: "\(dir)/\(capture).capture.age.held.json"))
        let r = try cli(["inbox", "watch", "held", "add", capture, capture, "--held", held, "--queue", path("q"),
                         "--store", path("store"), "--json", "--vault", vault.vault.url.path])
        XCTAssertEqual(r.status, 0)
        let rows = try XCTUnwrap(r.json as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["outcome"] as? String }, ["added", "notHeld"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.vault.url.appendingPathComponent("inbox").path)
            .filter { $0.hasSuffix(".capture.age") }, ["\(capture).capture.age"])
    }

    /// `held add` takes an addable held note into the inbox (ledger first), and an id that is not held fails. The held entry is
    /// written as the phone's `receive` would for an epoch the machine kept the key of (`oldEpoch`): a note that needs a check
    /// (`needsCheck`), which `--all` skips (saying so) and an add by id takes.
    func testHeldAddPlacesTheNoteInTheInbox() throws {
        let vault = try makeVault()
        let outbox = path("outbox")
        let capture = try sealedNote(vault, outbox: outbox)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(outbox)/\(capture).meta.json"))) as? [String: Any])
        let vaultId = vault.vault.vaultId.uuidString.lowercased()
        let held = path("held")
        let dir = "\(held)/\(vaultId)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "\(outbox)/\(capture).capture.age"))
        try bytes.write(to: URL(fileURLWithPath: "\(dir)/\(capture).capture.age"))
        let sidecar: [String: Any] = ["id": capture, "vault": vaultId, "epoch": try XCTUnwrap(meta["epoch"] as? Int),
                                      "epochId": try XCTUnwrap(meta["epochId"] as? String), "receivedAt": "2026-11-10T12:00:00Z",
                                      "reason": "oldEpoch", "bytes": bytes.count]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: URL(fileURLWithPath: "\(dir)/\(capture).capture.age.held.json"))

        let listed = try XCTUnwrap(try cli(["inbox", "watch", "held", "list", "--held", held, "--json"]).json as? [[String: Any]])
        XCTAssertEqual(listed.first?["canAdd"] as? Bool, true)
        XCTAssertEqual(listed.first?["needsCheck"] as? Bool, true)
        let missing = try cli(["inbox", "watch", "held", "add", "ffffffff", "--held", held, "--queue", path("q"), "--store", path("store"),
                               "--vault", vault.vault.url.path])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertNotEqual(try cli(["inbox", "watch", "held", "add", "--held", held]).status, 0, "ids or --all")
        let all = try cli(["inbox", "watch", "held", "add", "--all", "--held", held, "--queue", path("q"),
                           "--store", path("store"), "--json", "--vault", vault.vault.url.path])
        XCTAssertEqual(all.status, 0)
        XCTAssertEqual((try XCTUnwrap(all.json as? [[String: Any]])).count, 0, "--all skips a note that needs a check")
        XCTAssertTrue(all.err.contains("add them by id"), all.err)
        let added = try XCTUnwrap(try cli(["inbox", "watch", "held", "add", capture, "--held", held, "--queue", path("q"),
                                           "--store", path("store"), "--json", "--vault", vault.vault.url.path]).json as? [[String: Any]])
        XCTAssertEqual(added.first?["outcome"] as? String, "added")
        XCTAssertEqual(added.first?["placement"] as? String, "vault")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.vault.url.appendingPathComponent("inbox").path)
            .filter { $0.hasSuffix(".capture.age") }, ["\(capture).capture.age"])
        XCTAssertEqual((try cli(["inbox", "watch", "held", "list", "--held", held, "--json"]).json as? [[String: Any]])?.count, 0)
    }

    func testAFileThatFailsTheChecksIsRefusedAndNotAcknowledged() throws {
        let vault = try makeVault()
        let unlocked = ["--vault", vault.vault.url.path, "--identity", vault.keyPath]
        let watch = try provisioned(unlocked)
        let aac = path("n.aac")
        try adts(frames: 10).write(to: URL(fileURLWithPath: aac))
        let outbox = path("outbox")
        let capture = try XCTUnwrap(try json(try cli(["inbox", "watch", "seal", aac, "--payload", watch.payload, "--identity",
                                                      watch.identity, "--outbox", outbox, "--json"]))["capture"] as? String)
        // The file changes on the way.
        let file = URL(fileURLWithPath: "\(outbox)/\(capture).capture.age")
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: file)
        let r = try cli(["inbox", "watch", "receive", outbox, "--received", path("r.json"), "--queue", path("q"), "--store", path("store"),
                         "--json", "--vault", vault.vault.url.path])
        XCTAssertNotEqual(r.status, 0)
        let out = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual((out["files"] as? [[String: Any]])?.first?["outcome"] as? String, "refused")
        XCTAssertEqual(out["acked"] as? [String], [])
        XCTAssertEqual((try cli(["inbox", "list", "--json", "--vault", vault.vault.url.path]).json as? [[String: Any]])?.count, 0)
    }

    func testSealRefusesWhatItCannotOpenOrMux() throws {
        let vault = try makeVault()
        let unlocked = ["--vault", vault.vault.url.path, "--identity", vault.keyPath]
        let watch = try provisioned(unlocked)
        let other = path("other.key")
        _ = try cli(["inbox", "watch", "keygen", "--out", other])
        let aac = path("n.aac")
        try adts(frames: 5).write(to: URL(fileURLWithPath: aac))
        // Another watch's key cannot open the payload.
        let wrong = try cli(["inbox", "watch", "seal", aac, "--payload", watch.payload, "--identity", other, "--outbox", path("o")])
        XCTAssertNotEqual(wrong.status, 0)
        XCTAssertTrue(wrong.err.contains("cannot be opened"), wrong.err)
        // A damaged segment is a typed error, not a crash.
        let junk = path("junk.aac")
        try Data([0xFF, 0xF1, 0x58, 0x40, 0x00, 0x1F, 0xFC] + [UInt8](repeating: 1, count: 50)).write(to: URL(fileURLWithPath: junk))
        let bad = try cli(["inbox", "watch", "seal", junk, "--payload", watch.payload, "--identity", watch.identity,
                           "--outbox", path("o")])
        XCTAssertNotEqual(bad.status, 0)
        // A clean exit code, no trap.
        XCTAssertLessThan(bad.status, 128)
        // Provisioning to something that is not a watch's recipient writes nothing.
        let noKey = try cli(["inbox", "watch", "provision", "--to", "age1xyz", "--out", path("p")] + unlocked)
        XCTAssertNotEqual(noKey.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("p")))
    }
}
