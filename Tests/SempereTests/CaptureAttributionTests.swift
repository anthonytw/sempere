import Age
import Foundation
import XCTest
@testable import Sempere

/// Capture attribution (format.md §8.3.1, §11.1–§11.3; security review
/// 2026-10, C2 and C3): each profile holds its device's capture key, the key
/// that verifies attributes the capture, and a device no longer listed has
/// no key, also while the rewrap of its removal is unfinished.
final class CaptureAttributionTests: VaultTestCase {
    let a = pqIdentity(), b = pqIdentity(), c = pqIdentity()
    let audio = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    var audioRef: BlobRef { BlobRef(content: audio, type: "audio/mp4") }

    func deviceState() -> URL { tmp.appendingPathComponent("device-\(UUID().uuidString).json") }

    /// A vault of A ("Mac"), B ("iPad") and C ("Phone") with one note, so a
    /// rewrap has a file to stop at.
    func setUpVault() throws -> Vault {
        try XCTSkipUnless(postQuantumAvailable)
        let v = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient, c.recipient],
                                 labels: ["Mac", "iPad", "Phone"], identities: [a])
        _ = try v.apply(NoteOps.newNote(title: "Plain"), to: UUID(), deviceState: deviceState(), app: "t")
        return v
    }

    func profile(_ vault: Vault, as identity: NativeIdentity, device: String = "1badf00d") throws -> CaptureProfile {
        try Vault.open(at: vault.url, identities: [identity]).captureProfile(device: DeviceID(device)!)
    }

    func store(_ profile: CaptureProfile, id: UUID = UUID(), transcript: Bool = false, in vault: Vault) throws -> UUID {
        let w = try CaptureWriter(profile: profile)
        try CaptureWriter.store(try w.seal(audio: audio, started: started, id: id), in: vault.inboxURL)
        if transcript { try storeTranscript(profile, id: id, in: vault) }
        return id
    }

    func storeTranscript(_ profile: CaptureProfile, id: UUID, in vault: Vault) throws {
        let t = TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: id).recording, engine: "e", language: "en-US",
                                             created: started, segments: [.init(start: 0, end: 1, text: "Hello.")])
        try CaptureWriter.store(try CaptureWriter(profile: profile).seal(transcript: t, capture: id, audio: audioRef),
                                in: vault.inboxURL)
    }

    func recording(_ vault: Vault, _ id: UUID) throws -> Recording {
        try XCTUnwrap(try vault.reconstruct(noteId: CaptureAdoption.ids(for: id).note).recordings.first)
    }

    // MARK: - C2: attribution

    /// A profile is made for the key the device unlocked with; the capture
    /// names it, verifies under that device's key alone, and the adopted
    /// recording carries `captured` (the adopter writes the delta).
    func testCapturesAreAttributedToTheDeviceThatSealedThem() throws {
        let vault = try setUpVault()
        let p = try profile(vault, as: b, device: "0b0b0b0b")
        XCTAssertEqual(p.recipient, CaptureKey.fingerprint(of: b.recipient.string))
        XCTAssertEqual(p.key, CaptureKey.derive(from: try vault.requireSecret(), device: p.recipient!).bytes)
        XCTAssertNotEqual(p.key, try vault.captureKey().bytes, "not the vault capture key")
        let id = try store(p, transcript: true, in: vault)

        let pending = try vault.readCapture(id)
        XCTAssertEqual(pending.recipient, p.recipient)
        XCTAssertEqual(pending.manifest?.recipient, p.recipient)
        XCTAssertEqual(pending.transcriptRecipient, p.recipient)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.transcript)
        let rec = try recording(vault, id)
        XCTAssertEqual(rec.captured, CaptureAttribution(device: "0b0b0b0b", recipient: p.recipient))
        XCTAssertEqual(rec.captured?.label(in: vault.recipients), "iPad")
        // Round trip through a snapshot keeps it.
        let json = try InkJSON.encoder().encode(rec)
        XCTAssertEqual(try InkJSON.decoder().decode(Recording.self, from: json).captured, rec.captured)
    }

    /// Attack: the holder of B's profile claims to be A. The manifest's
    /// `recipient` must be the one whose key verified the file.
    func testAProfileCannotImpersonateAnotherDevice() throws {
        let vault = try setUpVault()
        var p = try profile(vault, as: b)
        p.recipient = CaptureKey.fingerprint(of: a.recipient.string)   // the claim; the key stays B's
        let claimed = try store(p, in: vault)
        // The claim picks A's key, under which B's tag does not verify.
        XCTAssertThrowsError(try vault.readCapture(claimed)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        // Nor can it pass as unattributed with its device key.
        p.recipient = nil
        let unattributed = try store(p, in: vault)
        XCTAssertThrowsError(try vault.readCapture(unattributed)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        XCTAssertNotNil(vault.adoptCapture(claimed, deviceState: deviceState(), app: "t").error)
        XCTAssertEqual(try vault.inboxEntries().count, 2, "refused captures are kept")
    }

    /// A profile made before attribution (the vault capture key, no
    /// recipient) still delivers, as an unattributed capture.
    func testCapturesOfProfilesMadeBeforeAttributionAreUnattributed() throws {
        let vault = try setUpVault()
        let legacy = CaptureProfile(vaultId: vault.vaultId, recipients: vault.recipients.map(\.key),
                                    key: try vault.captureKey().bytes, device: "0ddba11a", notebook: "Inbox")
        XCTAssertFalse(legacy.isAttributed)
        let id = try store(legacy, transcript: true, in: vault)
        let r = vault.adoptCapture(id, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertTrue(r.transcript)
        let rec = try recording(vault, id)
        XCTAssertEqual(rec.captured, CaptureAttribution(device: "0ddba11a", recipient: nil))
        XCTAssertNil(rec.captured?.label(in: vault.recipients))
    }

    /// Attack: the holder of A's profile adds a transcript (bound to the
    /// right audio, which it learned) to B's voice note. It is attributed
    /// to A, so it is never adopted, at adoption or later.
    func testATranscriptFromAnotherDeviceIsNeverAdopted() throws {
        let vault = try setUpVault()
        let pb = try profile(vault, as: b), pa = try profile(vault, as: a)
        let together = try store(pb, in: vault)
        try storeTranscript(pa, id: together, in: vault)
        var r = vault.adoptCapture(together, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertFalse(r.transcript)
        XCTAssertNil(try recording(vault, together).transcript)
        XCTAssertEqual(try vault.inboxEntries().count, 0, "the foreign transcript is deleted once the note exists")

        let later = try store(pb, in: vault)
        XCTAssertNil(vault.adoptCapture(later, deviceState: deviceState(), app: "t").error)
        try storeTranscript(pa, id: later, in: vault)
        r = vault.adoptCapture(later, deviceState: deviceState(), app: "t")
        XCTAssertNil(r.error)
        XCTAssertNil(r.file, "nothing written")
        XCTAssertNil(try recording(vault, later).transcript)
        XCTAssertEqual(try vault.inboxEntries().count, 0)

        // B's own transcript, sealed later, is added.
        let own = try store(pb, in: vault)
        XCTAssertNil(vault.adoptCapture(own, deviceState: deviceState(), app: "t").error)
        try storeTranscript(pb, id: own, in: vault)
        XCTAssertTrue(vault.adoptCapture(own, deviceState: deviceState(), app: "t").transcript)
    }

    /// A malformed `captured` reads as absent; the revision is not rejected.
    func testMalformedAttributionReadsAsAbsent() throws {
        let ref = audioRef
        for bad in [#"{"device": "XYZ"}"#, #"{"device": "0badf00d", "recipient": "ABC"}"#, #""a string""#, "7"] {
            let json = #"{"id": "11111111-1111-4111-8111-111111111111", "blob": "# + String(decoding: try InkJSON.encoder().encode(ref), as: UTF8.self)
                + #", "started": "2026-10-04T16:20:00.000Z", "captured": "# + bad + "}"
            let rec = try InkJSON.decoder().decode(Recording.self, from: Data(json.utf8))
            XCTAssertNil(rec.captured, bad)
        }
        XCTAssertThrowsError(try RecordingChange(field: "captured", value: .string("x")), "immutable")
    }

    // MARK: - C3: removed devices

    /// Attack: B is removed (it was lost) and its rewrap is unfinished, so
    /// the outgoing secret is still accepted for files not yet rewrapped.
    /// B's profile (outgoing secret, B's key) and a profile of the vault
    /// capture key keep sealing: both are refused. A kept device's capture
    /// sealed with its old profile meanwhile is still taken.
    func testARemovedDevicesCapturesAreRefusedWhileItsRewrapIsUnfinished() throws {
        var vault = try setUpVault()
        let pb = try profile(vault, as: b), pc = try profile(vault, as: c)
        let legacy = CaptureProfile(vaultId: vault.vaultId, recipients: vault.recipients.map(\.key),
                                    key: try vault.captureKey().bytes, device: "0ddba11a", notebook: "Inbox")
        XCTAssertThrowsError(try vault.removeRecipient(b.recipient, policy: RewrapPolicy(), stopAfter: 0))
        XCTAssertTrue(vault.pendingRewrap)
        let fromB = try store(pb, in: vault), fromLegacy = try store(legacy, in: vault), fromC = try store(pc, in: vault)

        let reader = try Vault.open(at: vault.url, identities: [a])
        XCTAssertNotNil(reader.previousSecret, "the journal is accepted")
        XCTAssertThrowsError(try reader.readCapture(fromB)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        XCTAssertThrowsError(try reader.readCapture(fromLegacy)) { XCTAssertEqual($0 as? CaptureError, .badTag) }
        XCTAssertEqual(try reader.readCapture(fromC).recipient, pc.recipient)

        // The resumed rewrap re-tags C's, and leaves the others as they are.
        var resuming = reader
        let report = try resuming.resumeRewrap()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(Set(report.inboxSkipped), ["inbox/\(CaptureFile.name(fromB, .capture))",
                                                  "inbox/\(CaptureFile.name(fromLegacy, .capture))"])
        XCTAssertTrue(report.rewrapped.contains("inbox/\(CaptureFile.name(fromC, .capture))"))
        let after = try Vault.open(at: vault.url, identities: [a])
        XCTAssertNil(after.adoptCapture(fromC, deviceState: deviceState(), app: "t").error)
        XCTAssertEqual(try recording(after, fromC).captured?.label(in: after.recipients), "Phone")
        XCTAssertNotNil(after.adoptCapture(fromB, deviceState: deviceState(), app: "t").error)
        XCTAssertNotNil(after.adoptCapture(fromLegacy, deviceState: deviceState(), app: "t").error)
    }

    /// The captures a device sealed before it was removed are refused too:
    /// the rotation re-tags only those of devices still listed, and those
    /// of the vault capture key (which it found waiting).
    func testTheRotationKeepsOnlyCapturesOfListedDevicesAndWaitingUnattributedOnes() throws {
        var vault = try setUpVault()
        let pb = try profile(vault, as: b), pc = try profile(vault, as: c)
        let legacy = CaptureProfile(vaultId: vault.vaultId, recipients: vault.recipients.map(\.key),
                                    key: try vault.captureKey().bytes, device: "0ddba11a", notebook: "Inbox")
        let fromB = try store(pb, in: vault), fromC = try store(pc, in: vault), fromLegacy = try store(legacy, in: vault)
        let report = try vault.removeRecipient(b.recipient)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.inboxSkipped, ["inbox/\(CaptureFile.name(fromB, .capture))"])
        let after = try Vault.open(at: vault.url, identities: [a])
        XCTAssertEqual(after.adoptCapture(fromB, deviceState: deviceState(), app: "t").error, CaptureError.badTag.description)
        XCTAssertNil(after.adoptCapture(fromC, deviceState: deviceState(), app: "t").error)
        XCTAssertNil(after.adoptCapture(fromLegacy, deviceState: deviceState(), app: "t").error)
        XCTAssertNil(try recording(after, fromLegacy).captured?.recipient)
    }

    /// A profile can only be made for a listed key, and never against a
    /// list that does not check (captures are attributed against it).
    func testProfilesAndReadsNeedTheAuthenticatedList() throws {
        let vault = try setUpVault()
        XCTAssertThrowsError(try vault.captureProfile(device: DeviceID("1badf00d")!, recipient: pqIdentity().recipient.string)) {
            XCTAssertEqual($0 as? CaptureError, .notARecipient)
        }
        let id = try store(try profile(vault, as: c), in: vault)
        // An attacker inserts a key into vault.json.
        let url = vault.url.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: url))
        m.recipients.append(.init(key: pqIdentity().recipient.string, label: "x", added: Date()))
        try m.encoded().write(to: url)
        let tampered = try Vault.open(at: vault.url, identities: [a])
        XCTAssertThrowsError(try tampered.readCapture(id)) {
            guard case .untrustedRecipients? = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    /// The work of verifying a capture is bounded (review of #125): its
    /// manifest's device claim picks the keys tried, so a long device list
    /// costs nothing more. A capture still verifies with 20 devices listed.
    func testTheClaimBoundsTheKeysTried() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let many = (0..<20).map { _ in pqIdentity() }
        let v = try Vault.create(at: vaultURL("Many"), recipients: [a.recipient] + many.map(\.recipient),
                                 labels: ["Mac"] + many.indices.map { "D\($0)" }, identities: [a])
        let p = try profile(v, as: many[13])
        let id = try store(p, in: v)
        XCTAssertEqual(try v.readCapture(id).recipient, p.recipient)
        // The scan finds the claim the writer wrote, and only well-formed ones.
        let fp = try XCTUnwrap(p.recipient)
        XCTAssertEqual(CaptureFile.claimedDevices(in: Data(#"{"notebook":"x","recipient":"\#(fp)","title":"y"}"#.utf8)), [fp])
        XCTAssertEqual(CaptureFile.claimedDevices(in: Data(#"{"recipient" : "\#(fp)"}"#.utf8)), [fp])
        XCTAssertEqual(CaptureFile.claimedDevices(in: Data(#"{"title":"\"recipient\":\"\#(fp)\""}"#.utf8)), [], "inside a string")
        XCTAssertEqual(CaptureFile.claimedDevices(in: Data(#"{"recipient":"\#(fp.uppercased())"}"#.utf8)), [])
        XCTAssertEqual(CaptureFile.claimedDevices(in: Data("{}\n{\"recipient\":\"\(fp)\"}".utf8)), [], "after the line")
        XCTAssertEqual(CaptureFile.claimedDevices(in: Data(repeating: 0x22, count: 1 << 20)), [])
        // A long notebook is bounded by the writer, so the claim stays in the window.
        var long = p
        long.notebook = String(repeating: "\"", count: 100_000)
        let far = try store(long, in: v)
        XCTAssertEqual(try v.readCapture(far).recipient, p.recipient)
    }
}
