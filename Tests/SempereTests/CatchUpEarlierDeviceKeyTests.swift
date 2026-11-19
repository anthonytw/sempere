import Age
import Foundation
import VaultTestSupport
import XCTest
@testable import Sempere

/// Catch-up of this device's own inbox files sealed under a device key it had before it was removed and joined again, and
/// the end of retries for files no key it held opens.
final class CatchUpEarlierDeviceKeyTests: VaultTestCase {
    let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26")
    }

    /// This device (P) with a new key after A removed it, keeping P's write ledger (the app's ledger outlives a device key).
    private func rejoin(_ w: EpochWorld, as name: String) throws -> (EpochDevice, Vault) {
        let p2 = EpochDevice(name, root: tmp)
        var a = try w.open("A")
        try a.approveDevice(p2.keys.joinRequest(vaultId: a.vaultId, name: name, kind: "cli"))
        var v = try Vault.open(at: w.url, identities: [p2.identity], signing: TestVaults.signing(p2.identity), trust: p2.trust,
                               root: w.root, ledger: w["P"].ledger, setAside: p2.setAside)
        try v.confirmJoin(words: try XCTUnwrap(v.expectedReplyWords()))
        return (p2, v)
    }

    private func open(_ w: EpochWorld, _ p2: EpochDevice) throws -> Vault {
        try Vault.open(at: w.url, identities: [p2.identity], signing: TestVaults.signing(p2.identity), trust: p2.trust,
                       root: w.root, ledger: w["P"].ledger, setAside: p2.setAside)
    }

    /// The captures sealed under the OLD key (Lock Screen notes of the phone) are re-sealed under the new one, whose line names
    /// the new device, and adoption reads them; the next catch-up has nothing left to retry.
    func testCapturesOfAnEarlierDeviceKeyAreResealed() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P"])
        let opened = try w.open("P")
        let profile = try opened.captureProfile(device: try XCTUnwrap(opened.writerDevice))
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        let note = try writer.seal(audio: audio, started: Date(), id: id)
        var a = try w.open("A")
        try a.removeDevices([w["P"].id])
        // Written after the removal (the device did not know yet): no record seals it, so only catch-up can save it.
        try writer.record(note, in: w["P"].ledger)
        try CaptureWriter.store(note, in: w.url.appendingPathComponent("inbox", isDirectory: true))
        let (p2, joined) = try rejoin(w, as: "P2")
        XCTAssertNotEqual(joined.deviceFingerprint, w["P"].fingerprint)
        let path = "inbox/\(note.name)"
        XCTAssertFalse(try w["P"].ledger.entries().filter { $0.path == path }.isEmpty)

        let report = try open(w, p2).catchUp()
        XCTAssertEqual(report.reencrypted, [path], "\(report)")
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertTrue(report.unreadable.isEmpty)
        let read = try w.open("A").readCapture(id)
        XCTAssertEqual(read.audio, audio)
        XCTAssertEqual(read.recipient, CaptureKey.fingerprint(of: try XCTUnwrap(joined.deviceEntry).key),
                       "attributed to the device that holds it now")
        // Nothing left to retry.
        let again = try open(w, p2).catchUp()
        XCTAssertTrue(again.reencrypted.isEmpty && again.unreadable.isEmpty && again.problems.isEmpty, "\(again)")
        XCTAssertEqual(try w["P"].ledger.caughtUp(), try open(w, p2).requireSecret().epochId)
    }

    /// A file of this device's ledger that opens under no key it ever held (another listed device's capture) is reported
    /// once, its entry dropped, and catch-up completes: it was retried at every write before. It stays in the inbox.
    func testAFileNoKeyOpensIsGivenUpOnOnce() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X", "Y"])
        // X's capture key, recorded in P's ledger (it cannot be P's own: only a stray entry or a wrong file gets here).
        let profile = try w.open("X").captureProfile(device: DeviceID("0d0d0d0d")!)
        let writer = try CaptureWriter(profile: profile)
        let id = UUID()
        let note = try writer.seal(audio: audio, started: Date(), id: id)
        var a = try w.open("A")
        try a.removeDevices([w["Y"].id])   // a new epoch; X stays listed, so it is no earlier key of P's
        try writer.record(note, in: w["P"].ledger)   // written after the epoch closed: no record seals it
        try CaptureWriter.store(note, in: w.url.appendingPathComponent("inbox", isDirectory: true))

        let path = "inbox/\(note.name)"
        let first = try w.open("P").catchUp()
        XCTAssertEqual(first.unreadable, [path], "\(first)")
        XCTAssertTrue(first.problems.isEmpty, "\(first.problems)")
        XCTAssertTrue(try w["P"].ledger.entries().filter { $0.path == path }.isEmpty, "no longer retried")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try w.open("P").inboxURL.appendingPathComponent(note.name).path))
        XCTAssertEqual(try w["P"].ledger.caughtUp(), try w.open("P").requireSecret().epochId)
        let second = try w.open("P").catchUp()
        XCTAssertTrue(second.unreadable.isEmpty && second.problems.isEmpty, "\(second)")
    }

    /// The app builds its capture profile with its state file's random device id, not the manifest's: such a capture under
    /// an earlier key is still re-sealed after the device rejoins.
    func testAnAppProfileWithAStateFileDeviceIdIsResealed() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P"])
        let stateId = DeviceID.random()
        XCTAssertNotEqual(stateId, try XCTUnwrap(w.open("P").writerDevice))
        let writer = try CaptureWriter(profile: try w.open("P").captureProfile(device: stateId))
        let note = try writer.seal(audio: audio, started: Date(), id: UUID())
        var a = try w.open("A")
        try a.removeDevices([w["P"].id])
        try writer.record(note, in: w["P"].ledger)
        try CaptureWriter.store(note, in: w.url.appendingPathComponent("inbox", isDirectory: true))
        let (p2, _) = try rejoin(w, as: "P2")
        let report = try open(w, p2).catchUp()
        XCTAssertEqual(report.reencrypted, ["inbox/\(note.name)"], "\(report)")
        XCTAssertTrue(report.unreadable.isEmpty)
    }

    /// A capture sealed under a removed OTHER device's key sits in this device's ledger (a Watch capture of another phone's
    /// profile): it is not this device's, so it is never re-sealed as the current key's; it is reported unreadable and kept.
    func testAFileSealedUnderAnotherRemovedDevicesKeyIsNotResealed() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X"])
        let xv = try w.open("X")
        let writer = try CaptureWriter(profile: try xv.captureProfile(device: try XCTUnwrap(xv.writerDevice)))
        let id = UUID()
        let note = try writer.seal(audio: audio, started: Date(), id: id)
        _ = try w.open("P")   // P is opened (and remembers its own key) while listed
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        try writer.record(note, in: w["P"].ledger)
        try CaptureWriter.store(note, in: w.url.appendingPathComponent("inbox", isDirectory: true))
        let path = "inbox/\(note.name)"
        let report = try w.open("P").catchUp()
        XCTAssertEqual(report.reencrypted.filter { $0 == path }, [], "\(report)")
        XCTAssertEqual(report.unreadable, [path], "\(report)")
        let bytes = try Data(contentsOf: w.url.appendingPathComponent(path))
        XCTAssertEqual(bytes, note.data, "left as it is")
    }

    /// A file sealed under this device's earlier key whose line names a device id this device never had is not re-sealed.
    func testAnEarlierKeyCaptureNamingAnotherDeviceIsNotResealed() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P"])
        var profile = try w.open("P").captureProfile(device: DeviceID("0e0e0e0e")!)
        profile.device = "0c0c0c0c"   // a device id this device never recorded (a forged or foreign line)
        let writer = try CaptureWriter(profile: profile)
        let note = try writer.seal(audio: audio, started: Date(), id: UUID())
        var a = try w.open("A")
        try a.removeDevices([w["P"].id])
        try writer.record(note, in: w["P"].ledger)
        try CaptureWriter.store(note, in: w.url.appendingPathComponent("inbox", isDirectory: true))
        let (p2, _) = try rejoin(w, as: "P2")
        let report = try open(w, p2).catchUp()
        XCTAssertEqual(report.unreadable, ["inbox/\(note.name)"], "\(report)")
        XCTAssertTrue(report.reencrypted.isEmpty)
    }

    /// Without the device-local record (a reinstall lost it) an earlier key's files are not caught up: they stay in the inbox.
    func testWithoutTheLocalRecordAnEarlierKeysFilesStayUnreadable() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P"])
        let opened = try w.open("P")
        let writer = try CaptureWriter(profile: try opened.captureProfile(device: try XCTUnwrap(opened.writerDevice)))
        let note = try writer.seal(audio: audio, started: Date(), id: UUID())
        var a = try w.open("A")
        try a.removeDevices([w["P"].id])
        // The ledger of a fresh install: the entry is known (kept) but no device key was recorded.
        let fresh = MemoryWriteLedger()
        try writer.record(note, in: fresh)
        try CaptureWriter.store(note, in: w.url.appendingPathComponent("inbox", isDirectory: true))
        let p2 = EpochDevice("P2", root: tmp)
        try a.approveDevice(p2.keys.joinRequest(vaultId: a.vaultId, name: "P2", kind: "cli"))
        var v = try Vault.open(at: w.url, identities: [p2.identity], signing: TestVaults.signing(p2.identity), trust: p2.trust,
                               root: w.root, ledger: fresh, setAside: p2.setAside)
        try v.confirmJoin(words: try XCTUnwrap(v.expectedReplyWords()))
        let report = try Vault.open(at: w.url, identities: [p2.identity], signing: TestVaults.signing(p2.identity), trust: p2.trust,
                                    root: w.root, ledger: fresh, setAside: p2.setAside).catchUp()
        XCTAssertEqual(report.unreadable, ["inbox/\(note.name)"], "\(report)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.url.appendingPathComponent("inbox/\(note.name)").path))
    }

    /// The retag that renames a recipient needs the old one exactly once in the line, and leaves the payload alone.
    func testRetagRenamesTheRecipientOnceOrNotAtAll() throws {
        let key = try CaptureKey(bytes: Data(repeating: 1, count: 32))
        let other = try CaptureKey(bytes: Data(repeating: 2, count: 32))
        let old = String(repeating: "ab", count: 32), new = String(repeating: "cd", count: 32)
        let line = Data("{\"recipient\":\"\(old)\"}".utf8)
        let payload = Data("payload \(old)".utf8)
        let framed = try CaptureFile.frame(line: line, payload: payload, filename: "n", key: key)
        let out = try XCTUnwrap(CaptureFile.retag(framed, filename: "n", verifiedBy: key, to: other, recipient: (old, new)))
        let parts = try CaptureFile.unframe(out, filename: "n", key: other)
        XCTAssertEqual(String(decoding: parts.line, as: UTF8.self), "{\"recipient\":\"\(new)\"}")
        XCTAssertEqual(parts.payload, payload, "the payload is never touched")
        // Absent, or twice, in the line: refused.
        XCTAssertNil(CaptureFile.retag(framed, filename: "n", verifiedBy: key, to: other, recipient: (new, old)))
        let twice = try CaptureFile.frame(line: Data("{\"a\":\"\(old)\",\"recipient\":\"\(old)\"}".utf8), payload: payload,
                                          filename: "n", key: key)
        XCTAssertNil(CaptureFile.retag(twice, filename: "n", verifiedBy: key, to: other, recipient: (old, new)))
        XCTAssertNil(CaptureFile.retag(framed, filename: "n", verifiedBy: other, to: key, recipient: (old, new)), "wrong old key")
    }
}
