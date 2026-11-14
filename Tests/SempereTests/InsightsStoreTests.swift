import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The insights codec and store (format.md §16; docs/design/1.2-note-insights.md §3.3, §9 "Codec and store"): round
/// trip, wrong key, wrong tag, renamed file, oversize, bad JSON, unknown `format`, unknown members, `written` order and
/// the future window, tombstones, the best-file pick, re-sealing after a removal, files of removed devices, deletion
/// below a finished re-encryption, purge and the read-only rule.
final class InsightsStoreTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    let note = UUID(uuidString: "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func gen(_ hash: String = String(repeating: "a", count: 32), summary: String = "Free vibration of a damped system.") -> InsightsNoteFile.Gen {
        .init(hash: hash, identity: GenerationIdentity(model: "afm-ondevice", os: "27.2", prompt: 1), summary: summary,
              keywords: [.init(t: "damping ratio", w: 0.82)], concepts: ["critical damping"], dropped: 0)
    }

    func makeOne() throws -> (Vault, NativeIdentity) {
        let id = pqIdentity()
        let v = try TestVaults.create(at: vaultURL(), identities: [id], names: ["mac"])
        return (try TestVaults.open(at: v.url, identity: id), id)
    }

    // MARK: Names and codec

    func testFileNames() throws {
        let d = try XCTUnwrap(DeviceID("a1b2c3d4"))
        XCTAssertEqual(InsightsFileName(note: note, device: d).fileName, "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10.a1b2c3d4.insights.age")
        XCTAssertEqual(InsightsFileName(.map, device: d).fileName, "map.a1b2c3d4.insights.age")
        for name in ["map.a1b2c3d4.insights.age", "device.a1b2c3d4.insights.age", "topics.a1b2c3d4.insights.age",
                     "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10.a1b2c3d4.insights.age"] {
            XCTAssertEqual(InsightsFileName(name)?.fileName, name)
        }
        for bad in ["map.A1B2C3D4.insights.age", "6F1C2B9E-0A43-4F6E-9A51-2C8D7E3B4A10.a1b2c3d4.insights.age", "map.a1b2c3d.insights.age",
                    "other.a1b2c3d4.insights.age", "map.a1b2c3d4.insights", ".map.a1b2c3d4.insights.age", "map.a1b2c3d4.x.insights.age"] {
            XCTAssertNil(InsightsFileName(bad), bad)
        }
    }

    func testRoundTripAndUnknownMembers() throws {
        let (v, _) = try makeOne()
        let store = InsightsStore(vault: v)
        let e = InsightsNoteFile.Emb(hash: String(repeating: "b", count: 32), key: EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1),
                                     vector: [0.5, -0.25, 0.125, 1])
        let name = try store.write(.note(InsightsNoteFile(noteId: note, device: try store.writer(), written: 0, lang: "en", gen: gen(), emb: e)), now: now)
        guard case .note(let f)? = try store.read(name) else { return XCTFail("not read") }
        XCTAssertEqual(f.gen, gen())
        XCTAssertEqual(f.emb?.vector, [0.5, -0.25, 0.125, 1])
        XCTAssertEqual(f.written, 1_790_000_000_000)
        XCTAssertEqual(f.hashBasis, "text/1")
        // Unknown members are ignored (a later writer's additions).
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: InsightsCodec.encode(.note(f))) as? [String: Any])
        json["future"] = ["x": 1]
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNoThrow(try InsightsCodec.decode(data, name: name))
    }

    func testOnlyTheCurrentKeyAndTheRightNameOpen() throws {
        let (v, _) = try makeOne()
        let store = InsightsStore(vault: v)
        let name = try store.write(.note(InsightsNoteFile(noteId: note, device: try store.writer(), written: 0, gen: gen())), now: now)
        let bytes = try Data(contentsOf: v.insightsURL.appendingPathComponent(name.fileName))
        // Renamed onto another note or device: the tag binds the name.
        let other = InsightsFileName(note: UUID(), device: name.device)
        XCTAssertThrowsError(try v.openInsights(bytes, name: other)) { XCTAssertEqual($0 as? InsightsFileError, .framing) }
        // Another vault's key: does not decrypt.
        let (w, _) = try { () throws -> (Vault, NativeIdentity) in
            let id = pqIdentity()
            let x = try TestVaults.create(at: vaultURL("Other"), identities: [id], names: ["x"])
            return (try TestVaults.open(at: x.url, identity: id), id)
        }()
        XCTAssertThrowsError(try w.openInsights(bytes, name: name)) { XCTAssertEqual($0 as? InsightsFileError, .undecryptable) }
        // A wrong tag (one byte of the body flipped before encryption).
        var body = try BodyFraming.frame(json: InsightsCodec.encode(.note(InsightsNoteFile(noteId: note, device: name.device, written: 5))),
                                         noteId: "insights", filename: name.fileName, secret: v.requireSecret())
        body[10] ^= 1
        XCTAssertThrowsError(try v.openInsights(try v.encrypt(body), name: name)) { XCTAssertEqual($0 as? InsightsFileError, .framing) }
        // Oversize, bad JSON, unknown format, a writer other than the file name's.
        XCTAssertThrowsError(try v.openInsights(Data(count: InsightsFileKind.note.maxBytes + 5000), name: name))
        for (json, want) in [("{", InsightsFileError.invalid("not a JSON object")),
                             (#"{"format":"sempere-insights/2","device":"\#(name.device)","written":1}"#, .unknownFormat("sempere-insights/2")),
                             (#"{"format":"sempere-insights/1","device":"00000000","written":1}"#, .nameMismatch)] {
            XCTAssertThrowsError(try InsightsCodec.decode(Data(json.utf8), name: name)) { XCTAssertEqual($0 as? InsightsFileError, want, json) }
        }
    }

    func testWrittenOrderAndFutureWindow() {
        XCTAssertEqual(InsightsCodec.nextWritten(after: nil, now: now), 1_790_000_000_000)
        XCTAssertEqual(InsightsCodec.nextWritten(after: 1_890_000_000_000, now: now), 1_890_000_000_001)
        let a = (written: Int64?(1_790_000_000_000), sha256: "aa"), b = (written: Int64?(1_790_000_000_001), sha256: "00")
        XCTAssertTrue(InsightsCodec.isLater(b, than: a, now: now))
        XCTAssertFalse(InsightsCodec.isLater(a, than: b, now: now))
        // Equal `written`: the greater SHA-256.
        XCTAssertTrue(InsightsCodec.isLater((1, "bb"), than: (1, "aa"), now: now))
        // More than 7 days ahead of the reader's clock: not ordered, never wins.
        let ahead = (written: Int64?(1_790_000_000_000 + 8 * 24 * 3600 * 1000), sha256: "ff")
        XCTAssertFalse(InsightsCodec.isLater(ahead, than: a, now: now))
        XCTAssertTrue(InsightsCodec.isLater(a, than: ahead, now: now))
        XCTAssertFalse(InsightsCodec.isLater((nil, "ff"), than: (nil, "00"), now: now))
    }

    func testFloat16RoundTrip() {
        let v: [Float] = (0..<512).map { sin(Float($0) * 0.37) * 0.9 }
        let back = Float16Codec.decode(Float16Codec.encode(v), count: v.count)
        XCTAssertEqual(back?.count, 512)
        for (x, y) in zip(v, back ?? []) { XCTAssertEqual(x, y, accuracy: 1e-3) }
        XCTAssertEqual(Float16Codec.float(Float16Codec.half(65504)), 65504)
        XCTAssertEqual(Float16Codec.float(Float16Codec.half(1e-7)), 1.1920929e-07, accuracy: 1e-7)
        XCTAssertNil(Float16Codec.decode("AAAA", count: 3), "wrong length")
        XCTAssertNil(Float16Codec.decode(Data([0, 0x7c]).base64EncodedString(), count: 1), "infinity is refused")
    }

    // MARK: Store

    func testTombstoneAndBestFile() throws {
        let (v, _) = try makeOne()
        let store = InsightsStore(vault: v)
        let me = try store.writer()
        try store.write(.note(InsightsNoteFile(noteId: note, device: me, written: 0, gen: gen())), now: now)
        XCTAssertTrue(try store.tombstone(note: note, now: now))
        XCTAssertFalse(try store.tombstone(note: note, now: now), "already a tombstone")
        let s = store.snapshot()
        XCTAssertEqual(s.notes[note]?[me]?.isTombstone, true)
        XCTAssertGreaterThan(s.notes[note]?[me]?.written ?? 0, 1_790_000_000_000, "a later written")
        XCTAssertNil(s.bestGen(for: note, hash: nil))
        // Best pick: the hash first, then the later written.
        var snap = InsightsSnapshot()
        let d1 = DeviceID("11111111")!, d2 = DeviceID("22222222")!
        snap.notes[note] = [d1: InsightsNoteFile(noteId: note, device: d1, written: 10, gen: gen(String(repeating: "c", count: 32))),
                            d2: InsightsNoteFile(noteId: note, device: d2, written: 5, gen: gen())]
        XCTAssertEqual(snap.bestGen(for: note, hash: String(repeating: "a", count: 32))?.device, d2)
        XCTAssertEqual(snap.bestGen(for: note, hash: String(repeating: "a", count: 32))?.current, true)
        XCTAssertEqual(snap.bestGen(for: note, hash: String(repeating: "f", count: 32))?.device, d1, "stale: the later one")
        XCTAssertEqual(snap.bestGen(for: note, hash: String(repeating: "f", count: 32))?.current, false)
        // `emb` only from the named device.
        snap.notes[note]?[d1]?.emb = .init(hash: String(repeating: "c", count: 32), key: .init(model: "m", lang: "en", rev: 1, input: 1), vector: [1])
        XCTAssertNotNil(snap.emb(for: note, from: d1))
        XCTAssertNil(snap.emb(for: note, from: d2))
    }

    func testReadOnlyAndRecoveryRefuseWrites() throws {
        let (v, _) = try makeOne()
        let byKit = try Vault.open(at: v.url, identities: [])
        XCTAssertThrowsError(try InsightsStore(vault: byKit).write(.note(InsightsNoteFile(noteId: note, device: DeviceID("11111111")!, written: 0))))
        XCTAssertThrowsError(try InsightsStore(vault: byKit).purge())
    }

    func testPurgeDeletesOnlyInsightsFiles() throws {
        let (v, _) = try makeOne()
        let store = InsightsStore(vault: v)
        try store.write(.note(InsightsNoteFile(noteId: note, device: try store.writer(), written: 0, gen: gen())), now: now)
        try Data("keep".utf8).write(to: v.insightsURL.appendingPathComponent("README.txt"))
        XCTAssertEqual(try store.purge().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: v.insightsURL.path), ["README.txt"], "unknown files are never deleted")
    }

    /// Review of #50, M2: copy-merge never replaces this device's own file with a copy, even a later one that opens.
    func testCopyMergeNeverReplacesTheOwnFile() throws {
        let (v, _) = try makeOne()
        try v.updateSharedSettings { s in
            try s.write(SharedSettingsCatalog.spec(named: "insights.enabled")!, .bool(true), block: nil, type: nil, now: now)
        }
        let store = InsightsStore(vault: v)
        let name = try store.write(.note(InsightsNoteFile(noteId: note, device: try store.writer(), written: 0, gen: gen())), now: now)
        let mine = try Data(contentsOf: v.insightsURL.appendingPathComponent(name.fileName))
        let copy = tmp.appendingPathComponent("Copy.sempere")
        try FileManager.default.copyItem(at: v.url, to: copy)
        let planted = try v.sealInsights(.note(InsightsNoteFile(noteId: note, device: name.device, written: 1_890_000_000_000,
                                                               gen: gen(summary: "Planted."))), name: name)
        try planted.write(to: copy.appendingPathComponent("insights/\(name.fileName)"))
        let r = try v.mergeCopy(from: copy)
        XCTAssertFalse(r.added.contains("insights/\(name.fileName)"))
        XCTAssertEqual(try Data(contentsOf: v.insightsURL.appendingPathComponent(name.fileName)), mine)
    }

    // MARK: Epochs

    /// A removal starts a new epoch: B's files stop opening; B re-seals its own under the new key (no model work);
    /// files named for the removed device X are ignored and deleted by any device.
    func testResealAfterARemovalAndRemovedDevicesFiles() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"])
        let a0 = try w.open("A"), b0 = try w.open("B"), x0 = try w.open("X")
        let bName = try InsightsStore(vault: b0).write(.note(InsightsNoteFile(noteId: note, device: try InsightsStore(vault: b0).writer(),
                                                                                written: 0, gen: gen())), now: now)
        try InsightsStore(vault: x0).write(.device(InsightsDeviceRecord(device: DeviceID(w["X"].id)!, written: 0, os: "macOS 27.2", platform: "mac",
                                                                         model: .init(available: false, reason: "disabled", identity: nil),
                                                                         supported: ["en": [1]], canaries: [], compatibility: nil, against: nil)), now: now)
        XCTAssertEqual(InsightsStore(vault: a0).snapshot().files.count, 2)
        var a = a0
        try a.removeDevices([w["X"].id])
        let b = try w.open("B")
        XCTAssertNil(try? InsightsStore(vault: b).read(bName), "under the old key: not read")
        XCTAssertEqual(InsightsStore(vault: b).snapshot().notes[note], nil)
        XCTAssertEqual(try InsightsStore(vault: b).resealOwn(now: now), ["insights/\(bName.fileName)"])
        guard case .note(let f)? = try InsightsStore(vault: b).read(bName) else { return XCTFail("not re-sealed") }
        XCTAssertEqual(f.gen, gen())
        // X's record: never shown, deleted.
        let a2 = try w.open("A")
        XCTAssertTrue(a2.removedInsightsDevices().contains(DeviceID(w["X"].id)!))
        XCTAssertEqual(try InsightsStore(vault: a2).removeRemovedDevices(), ["insights/device.\(w["X"].id).insights.age"])
    }

    /// A device on an older list never deletes a just-joined device's file (it has not heard of it).
    func testAnOlderListKeepsAJustJoinedDevicesFile() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let stale = try w.open("B")
        var a = try w.open("A")
        let c = pqIdentity()
        try TestVaults.approve(c, into: &a, name: "C")
        let cId = TestVaults.device(c).id
        XCTAssertFalse(stale.removedInsightsDevices().contains(DeviceID(cId)!))
        XCTAssertFalse(try w.open("B").removedInsightsDevices().contains(DeviceID(cId)!))
    }

    /// After a finished re-encryption a file under a key from before it goes (even one an old app left).
    func testBelowAFinishedReencryptionInsightsGo() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let b = try w.open("B")
        let name = try InsightsStore(vault: b).write(.note(InsightsNoteFile(noteId: note, device: try InsightsStore(vault: b).writer(),
                                                                             written: 0, gen: gen())), now: now)
        var a = try w.open("A")
        let prep = try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id], remove: [])
        try a.beginReencryption(prep)
        _ = try a.reencryptPass()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.insightsURL.appendingPathComponent(name.fileName).path),
                      "the pass leaves insights alone (hints)")
        try a.finishReencryption()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.insightsURL.appendingPathComponent(name.fileName).path))
    }
}
