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

    func testAFileOfAnotherVaultIsQueuedNotPlacedInTheCurrentInbox() throws {
        let a = try makeVault(named: "a.sempere")
        let b = try makeVault(named: "b.sempere")
        let watch = try provisioned(["--vault", b.vault.url.path, "--identity", b.keyPath])
        let aac = path("n.aac")
        try adts(frames: 10).write(to: URL(fileURLWithPath: aac))
        let outbox = path("outbox")
        let capture = try XCTUnwrap(try json(try cli(["inbox", "watch", "seal", aac, "--payload", watch.payload, "--identity",
                                                      watch.identity, "--outbox", outbox, "--json"]))["capture"] as? String)
        // The phone's stored profile is vault A's; the file is B's, and B is not in its store.
        let r = try json(try cli(["inbox", "watch", "receive", outbox, "--received", path("r.json"), "--queue", path("q"),
                                  "--store", path("store"), "--json", "--vault", a.vault.url.path]))
        XCTAssertEqual((r["files"] as? [[String: Any]])?.first?["placement"] as? String, "otherVaultQueued")
        XCTAssertEqual(r["acked"] as? [String], [capture])
        let inboxA = a.vault.url.appendingPathComponent("inbox").path
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: inboxA)) ?? []).filter { $0.hasSuffix(".capture.age") }, [])
        let queued = try FileManager.default.contentsOfDirectory(atPath: "\(path("q"))/\(b.vault.vaultId.uuidString.lowercased())").sorted()
        XCTAssertEqual(queued, ["\(capture).capture.age", "\(capture).capture.age.epoch"])
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
