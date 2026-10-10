import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere inbox`: quick capture without the key (format.md §11,
/// docs/quick-capture.md), end to end through the binary.
final class CLIInboxTests: CLITestCase {
    static let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/audio/tone-aac.m4a").path

    func json(_ r: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertEqual(r.status, 0, r.err, file: file, line: line)
        return try XCTUnwrap(r.json as? [String: Any], r.out + r.err, file: file, line: line)
    }

    /// enable (with the key) → capture and transcript (no key at all) →
    /// import (with the key): a note in the inbox notebook, the audio and the
    /// transcript readable, the inbox empty.
    func testCaptureWithoutTheKeyThenImport() throws {
        let (vault, identity, keyPath) = try makeVault()
        let unlocked = ["--vault", vault.url.path, "--identity", keyPath]
        let locked = ["--vault", vault.url.path]
        let enabled = try json(try cli(["inbox", "enable", "--notebook", "Voice", "--json"] + unlocked))
        let profilePath = try XCTUnwrap(enabled["profile"] as? String)
        let attrs = try FileManager.default.attributesOfItem(atPath: profilePath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try String(contentsOfFile: profilePath, encoding: .utf8).contains("AGE-SECRET-KEY"))

        // No identity and no passphrase anywhere: capture still works.
        let captured = try json(try cli(["inbox", "capture", Self.tone, "--title", "Groceries",
                                         "--started", "2026-10-07T14:32:00Z", "--json"] + locked))
        let capture = try XCTUnwrap(captured["capture"] as? String)
        let note = try XCTUnwrap(captured["note"] as? String)
        let transcript = path("t.json")
        try Transcript(recording: UUID(), engine: "test", language: "en", created: Date(),
                       segments: [.init(start: 0, end: 1, text: "milk")]).encoded().write(to: URL(fileURLWithPath: transcript))
        XCTAssertNotEqual(try cli(["inbox", "transcript", capture, transcript] + locked).status, 0,
                          "a transcript is bound to the capture's audio")
        XCTAssertEqual(try cli(["inbox", "transcript", capture, transcript, "--audio", Self.tone] + locked).status, 0)

        let listedLocked = try XCTUnwrap(try cli(["inbox", "list", "--json"] + locked).json as? [[String: Any]])
        XCTAssertEqual(listedLocked.first?["kinds"] as? [String], ["capture", "transcript"])
        XCTAssertNil(listedLocked.first?["title"], "no key: nothing about the content")
        let listed = try XCTUnwrap(try cli(["inbox", "list", "--json"] + unlocked).json as? [[String: Any]])
        XCTAssertEqual(listed.first?["title"] as? String, "Groceries")

        XCTAssertNotEqual(try cli(["inbox", "import", "--json"] + locked).status, 0, "import needs the key")
        let dry = try json(try cli(["inbox", "import", "--dry-run", "--json"] + unlocked))
        XCTAssertEqual((dry["captures"] as? [[String: Any]])?.first?["created"] as? Bool, true)
        XCTAssertEqual((try cli(["inbox", "list", "--json"] + locked).json as? [[String: Any]])?.count, 1, "a dry run keeps it")

        let imported = try json(try cli(["inbox", "import", "--json"] + unlocked))
        let result = try XCTUnwrap((imported["captures"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["note"] as? String, note)
        XCTAssertEqual(result["transcript"] as? Bool, true)
        XCTAssertNil(result["error"])
        let reader = try Vault.open(at: vault.url, identities: [identity])
        let state = try reader.reconstruct(noteId: UUID(uuidString: note)!)
        XCTAssertEqual(state.meta.title, "Groceries")
        XCTAssertEqual(state.meta.notebook, "Voice")
        let rec = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(try reader.readBlob(note: UUID(uuidString: note)!, rec.blob, maxBytes: 1 << 24),
                       try Data(contentsOf: URL(fileURLWithPath: Self.tone)))
        XCTAssertNotNil(rec.transcript)
        XCTAssertEqual((try cli(["inbox", "list", "--json"] + locked).json as? [[String: Any]])?.count, 0)
        // The note is an ordinary note now.
        let shown = try cli(["notes", "show", note, "--json"] + unlocked)
        XCTAssertEqual(shown.status, 0, shown.err)
    }

    func testCaptureNeedsAProfileAndForgeriesAreRefused() throws {
        let (vault, _, keyPath) = try makeVault()
        let locked = ["--vault", vault.url.path]
        let none = try cli(["inbox", "capture", Self.tone] + locked)
        XCTAssertEqual(none.status, 1)
        XCTAssertTrue(none.err.contains("inbox enable"), none.err)

        // A profile with the right recipients but a made-up capture key.
        let profile = CaptureProfile(vaultId: vault.vaultId, recipients: vault.recipients.map(\.key),
                                     key: Data(repeating: 1, count: 32), device: "0badf00d", notebook: "Inbox")
        let forged = path("forged.json")
        try JSONEncoder().encode(profile).write(to: URL(fileURLWithPath: forged))
        XCTAssertEqual(try cli(["inbox", "capture", Self.tone, "--profile", forged] + locked).status, 0)
        let r = try cli(["inbox", "import", "--json", "--identity", keyPath] + locked)
        XCTAssertEqual(r.status, 1)
        let first = try XCTUnwrap(((r.json as? [String: Any])?["captures"] as? [[String: Any]])?.first)
        XCTAssertTrue((first["error"] as? String)?.contains("does not verify") == true, "\(first)")
        XCTAssertEqual((try cli(["inbox", "list", "--json"] + locked).json as? [[String: Any]])?.count, 1, "kept")

        // Security review 2026-10 (C5): it is not read again at the next
        // import (backed off, reported), but is with --retry or by its id.
        let again = try cli(["inbox", "import", "--json", "--identity", keyPath] + locked)
        XCTAssertEqual(again.status, 1)
        let second = try XCTUnwrap(((again.json as? [String: Any])?["captures"] as? [[String: Any]])?.first)
        XCTAssertTrue((second["error"] as? String)?.contains("failed 1 time(s)") == true, "\(second)")
        let retried = try cli(["inbox", "import", "--json", "--retry", "--identity", keyPath] + locked)
        let third = try XCTUnwrap(((retried.json as? [String: Any])?["captures"] as? [[String: Any]])?.first)
        XCTAssertTrue((third["error"] as? String)?.contains("does not verify") == true, "\(third)")
        let byID = try cli(["inbox", "import", try XCTUnwrap(first["capture"] as? String), "--json", "--identity", keyPath] + locked)
        let fourth = try XCTUnwrap(((byID.json as? [String: Any])?["captures"] as? [[String: Any]])?.first)
        XCTAssertTrue((fourth["error"] as? String)?.contains("does not verify") == true, "\(fourth)")
    }

    /// A capture waiting in the inbox survives `vault recipients remove`: the
    /// rewrap re-tags it under the new secret's capture key (format.md
    /// §3.3.1), so `inbox import` still adopts it afterwards.
    func testWaitingCapturesSurviveARecipientRemoval() throws {
        let (vault, _, keyPath) = try makeVault()
        let unlocked = ["--vault", vault.url.path, "--identity", keyPath]
        let locked = ["--vault", vault.url.path]
        XCTAssertEqual(try cli(["inbox", "enable"] + unlocked).status, 0)
        let other = try NativeIdentity.generate(.postQuantum).recipient.string
        let added = try cli(["vault", "recipients", "add", other, "--label", "old phone"] + unlocked)
        XCTAssertEqual(added.status, 0, added.err)
        let capture = try XCTUnwrap(try json(try cli(["inbox", "capture", Self.tone, "--json"] + locked))["capture"] as? String)

        let removed = try json(try cli(["vault", "recipients", "remove", other, "--json"] + unlocked))
        XCTAssertEqual(removed["complete"] as? Bool, true)
        XCTAssertEqual(removed["inboxSkipped"] as? [String], [])
        let imported = try json(try cli(["inbox", "import", "--json"] + unlocked))
        let result = try XCTUnwrap((imported["captures"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["capture"] as? String, capture)
        XCTAssertNil(result["error"])
        XCTAssertEqual(result["created"] as? Bool, true)
    }

    /// A capture from a device whose key has no label names it as the app
    /// and `vault info` show such a device: "Device".
    func testCaptureFromAnUnlabelledDeviceSaysDevice() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, _, keyPath) = try makeVault()
        let other = try NativeIdentity.generate(.postQuantum)
        let otherKey = path("other.key")
        try IdentityFile.render(other, created: Date()).write(toFile: otherKey, atomically: true, encoding: .utf8)
        let mine = ["--vault", vault.url.path, "--identity", keyPath]
        XCTAssertEqual(try cli(["vault", "recipients", "add", other.recipient.string] + mine).status, 0)
        let profile = path("other-profile.json")
        let enabled = try cli(["inbox", "enable", "--profile", profile, "--vault", vault.url.path, "--identity", otherKey])
        XCTAssertEqual(enabled.status, 0, enabled.err)
        XCTAssertTrue(enabled.out.contains("captures attributed to Device)"), enabled.out)
        XCTAssertEqual(try cli(["inbox", "capture", Self.tone, "--vault", vault.url.path, "--profile", profile]).status, 0)
        let listed = try cli(["inbox", "list"] + mine)
        XCTAssertTrue(listed.out.contains("from Device (device "), listed.out)
    }

    /// Captures name the device whose key made the profile (format.md §11.1,
    /// security review 2026-10, C2); a device removed since cannot add any
    /// (C3): its profile's key is revoked and it has no key under the new one.
    func testCapturesAreAttributedAndARemovedDevicesAreRefused() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let (vault, identity, keyPath) = try makeVault()
        let ipad = try NativeIdentity.generate(.postQuantum)
        let ipadKey = path("ipad.key")
        try IdentityFile.render(ipad, created: Date()).write(toFile: ipadKey, atomically: true, encoding: .utf8)
        let mine = ["--vault", vault.url.path, "--identity", keyPath]
        XCTAssertEqual(try cli(["vault", "recipients", "add", ipad.recipient.string, "--label", "iPad"] + mine).status, 0)
        let profile = path("ipad-profile.json")
        let enabled = try json(try cli(["inbox", "enable", "--profile", profile, "--json", "--vault", vault.url.path,
                                        "--identity", ipadKey]))
        XCTAssertEqual(enabled["recipient"] as? String, CaptureKey.fingerprint(of: ipad.recipient.string))
        let locked = ["--vault", vault.url.path, "--profile", profile]
        let first = try XCTUnwrap(try json(try cli(["inbox", "capture", Self.tone, "--json"] + locked))["capture"] as? String)

        let listed = try XCTUnwrap(try cli(["inbox", "list", "--json"] + mine).json as? [[String: Any]])
        XCTAssertEqual(listed.first?["recipient"] as? String, CaptureKey.fingerprint(of: ipad.recipient.string))
        XCTAssertEqual(listed.first?["capturedBy"] as? String, "iPad")
        XCTAssertTrue(try cli(["inbox", "list"] + mine).out.contains("from iPad (device "))
        let imported = try json(try cli(["inbox", "import", "--json"] + mine))
        let r = try XCTUnwrap((imported["captures"] as? [[String: Any]])?.first)
        XCTAssertEqual(r["capturedBy"] as? String, "iPad")
        let note = try XCTUnwrap(UUID(uuidString: r["note"] as? String ?? ""))
        let rec = try XCTUnwrap(try Vault.open(at: vault.url, identities: [identity]).reconstruct(noteId: note).recordings.first)
        XCTAssertEqual(rec.captured?.recipient, CaptureKey.fingerprint(of: ipad.recipient.string))
        _ = first

        // The iPad is removed; its profile keeps capturing.
        XCTAssertEqual(try cli(["vault", "recipients", "remove", ipad.recipient.string] + mine).status, 0)
        let late = try XCTUnwrap(try json(try cli(["inbox", "capture", Self.tone, "--json"] + locked))["capture"] as? String)
        let refused = try cli(["inbox", "import", late, "--json"] + mine)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(((refused.json as? [String: Any])?["captures"] as? [[String: Any]])?.first?["error"] as? String
                      == CaptureError.badTag.description)
        XCTAssertEqual((try cli(["inbox", "list", "--json"] + mine).json as? [[String: Any]])?.count, 1, "kept, not adopted")
    }
}
