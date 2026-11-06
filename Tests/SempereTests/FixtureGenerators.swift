import Age
import Foundation
import VaultTestSupport
@testable import Sempere

/// Where the committed fixtures are in the source tree (resolved through symlinks: `SempereBenchmarks` compiles this
/// file too, to regenerate them: `Tests/SempereBenchmarks/FixtureRegeneration.swift`).
enum FixtureFiles {
    static var source: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("Fixtures")
    }
}

/// The committed sample vault under `Fixtures/sample.sempere` (see
/// `Fixtures/README.md`). Everything except the age randomness is fixed, so
/// regenerating changes ciphertext bytes but never content.
///
/// Regenerate with:
///
///     SEMPERE_REGENERATE_FIXTURE=1 swift test --filter FixtureRegeneration/testRegenerateFixture
enum SampleFixture {
    static let passphrase = "sempere-test"
    static let vaultId = UUID(uuidString: "5a3b1e00-1000-4000-8000-000000000001")!
    static let baseMillis: Int64 = 1_791_130_800_000            // 2026-10-04T16:20:00Z
    static let devA = DeviceID("a1b2c3d4")!
    static let devB = DeviceID("99ee00ff")!
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let app = "sempere-fixture/1"
    /// One attachment blob in the lecture's `att/`, unreferenced until the attachments merge (task A1) gives the
    /// fixture a note with items.
    static let attachment = Data("Sempere fixture attachment: synthetic, test-only.\n".utf8)
    static let attachmentType = "text/plain"

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "f1c70000-0000-4000-8000-%012ld", n))! }

    /// The committed test-only keys in `dir`: `sample.key`, the fixture device's key file (its age identity
    /// and signing seeds, `DeviceKeys`), and `sample-recovery.key`, the fixtures' recovery key. The device
    /// keys are registered with `TestVaults`, so vaults made for the sample identity use its signing pair.
    static func keys(in dir: URL) throws -> (device: DeviceKeys, recovery: MLKEM768X25519Identity) {
        let device = try DeviceKeys.parse(String(contentsOf: dir.appendingPathComponent("sample.key"), encoding: .utf8))
        TestVaults.register(device)
        guard case .mlkem768x25519(let recovery) = try IdentityFile.parse(
            String(contentsOf: dir.appendingPathComponent("sample-recovery.key"), encoding: .utf8)) else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "sample-recovery.key is not post-quantum"])
        }
        return (device, recovery)
    }

    /// `keys(in:)` of the bundled fixtures.
    static func bundledKeys() throws -> (device: DeviceKeys, recovery: MLKEM768X25519Identity) {
        try keys(in: FixtureFiles.source)
    }
    static func at(_ offset: Int64) -> Date { Date(timeIntervalSince1970: Double(baseMillis + offset) / 1000) }

    static func stroke(_ n: Int, tool: InkTool = .pen, color: Color = Color(r: 0x1A, g: 0x1A, b: 0x1A)) -> Stroke {
        let pts = (0..<4).map { (i: Int) -> StrokePoint in
            let x = Double(50 + 20 * n + 10 * i)
            let y = Double(100 + 15 * i)
            return StrokePoint(x: x, y: y, t: Double(i) * 0.016, w: 2.5, h: 2.5, o: 1, f: 0.5, az: 0.25, al: 1.25)
        }
        return Stroke(id: id(100 + n), ink: Ink(tool: tool, color: color, width: 2.5), points: pts)
    }

    static func delta(_ note: UUID, _ dev: DeviceID, _ seq: Int, _ offset: Int64, _ ops: [Op]) -> Revision {
        Revision(noteId: note, device: dev, seq: seq, hlc: HLC(millis: baseMillis + offset, counter: 0)!,
                 wall: at(offset), app: app, body: .delta(ops: ops))
    }

    /// Writes the fixture vault (`sample.sempere`) at `url`, which must not exist yet: the fixture device
    /// (`identity`, registered with `TestVaults`) as its home, the fixture recovery key (bundled unless
    /// given), and the passphrase copy under `passphrase` (scrypt work factor 15: test-only).
    static func generate(at url: URL, identity: NativeIdentity, recovery: MLKEM768X25519Identity? = nil) throws {
        let vault = try TestVaults.create(at: url, identities: [identity], names: ["Sempere test fixture (throwaway, test-only key)"],
                                          recovery: try recovery ?? bundledKeys().recovery, recoveryPassphrase: passphrase,
                                          workFactor: 15, vaultId: vaultId, created: at(0))
        let p1 = id(1), p2 = id(2), q1 = id(3)
        // Lecture: devices A and B, a snapshot by A, then one uncovered delta.
        try vault.write(delta(lecture, devA, 1, 1000, [
            .addPage(Page(id: p1, order: "a0")), .setMeta(.title("Fixture lecture")), .setMeta(.paper(.ruled)),
            .addStroke(page: p1, stroke: stroke(1)), .addStroke(page: p1, stroke: stroke(2)),
        ]))
        try vault.write(delta(lecture, devB, 1, 2000, [
            .addStroke(page: p1, stroke: stroke(3, tool: .marker, color: Color(r: 0xFF, g: 0xD6, b: 0x0A, a: 0x80))),
            .addTag("fixture"),
        ]))
        try vault.write(delta(lecture, devB, 2, 3000, [
            .removeStroke(page: p1, strokeId: id(101)), .addPage(Page(id: p2, order: "a1")),
            .addStroke(page: p2, stroke: stroke(4)),
        ]))
        var clock = HybridClock()
        try vault.snapshot(noteId: lecture, device: devA, clock: &clock, wall: at(4000), app: app)
        try vault.write(delta(lecture, devA, 3, 5000, [.addStroke(page: p2, stroke: stroke(5))]))
        // Deleted note.
        try vault.write(delta(deleted, devA, 1, 6000, [
            .addPage(Page(id: q1, order: "a0")), .setMeta(.title("Fixture deleted")),
            .addStroke(page: q1, stroke: stroke(6)),
        ]))
        try vault.write(delta(deleted, devB, 1, 7000, [.deleteNote]))
        try vault.writeBlob(note: lecture, attachment, type: attachmentType)
    }
}

/// `Fixtures/items.sempere` (gap audit GA-63): one note with a text box, an image (with its blob) and
/// an equation, written with the same post-quantum key as `sample.sempere` but its own vault id, so the
/// sample's note and revision counts, and the web goldens, stay as they are.
enum ItemsFixture {
    static let vaultId = UUID(uuidString: "5a3b1e00-1000-4000-8000-000000000002")!
    static let note = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let page = SampleFixture.id(201)
    static let textItem = SampleFixture.id(301)
    static let imageItem = SampleFixture.id(302)
    static let mathItem = SampleFixture.id(303)
    /// A 1 x 1 PNG, synthetic.
    static let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    static func generate(at url: URL, identity: NativeIdentity, recovery: MLKEM768X25519Identity? = nil) throws {
        let vault = try TestVaults.create(at: url, identities: [identity], names: ["Sempere test fixture (throwaway, test-only key)"],
                                          recovery: try recovery ?? SampleFixture.bundledKeys().recovery,
                                          recoveryPassphrase: SampleFixture.passphrase, workFactor: 15, vaultId: vaultId,
                                          created: SampleFixture.at(0))
        let blob = try vault.writeBlob(note: note, picture, type: "image/png")
        let text = try NoteOps.text("Fixture text box")
        let math = try NoteOps.math("e^{i\\pi}+1=0")
        try vault.write(SampleFixture.delta(note, SampleFixture.devA, 1, 1000, [
            .addPage(Page(id: page, order: "a0")), .setMeta(.title("Fixture items")),
            .addItem(page: page, item: .text(id: textItem, text, frame: Rect(x: 36, y: 36, w: 300, h: 24), z: "a0")),
            .addItem(page: page, item: .image(id: imageItem, blob: blob, pixelSize: Size(w: 1, h: 1),
                                              frame: Rect(x: 36, y: 100, w: 120, h: 120), z: "a1")),
            .addItem(page: page, item: .math(id: mathItem, math, frame: Rect(x: 36, y: 260, w: 160, h: 32), z: "a2")),
            .addStroke(page: page, stroke: SampleFixture.stroke(7)),
        ]))
    }
}

/// `Fixtures/epochs.sempere` (key hierarchy KH3, format.md §15.14): a vault at epoch 3, shared with the web
/// viewer's tests. Home is the sample device (`sample.key`); a second device ("Old laptop") was approved at
/// epoch 1 and removed, which started epoch 2; a third ("Tablet") was approved at epoch 2 and removed (epoch 3).
/// It holds
///
/// - "Before the change" (`44444444-…`), written at epoch 1 with an attachment: sealed by epoch 2's record, read;
/// - "After the change" (`55555555-…`), written at epoch 2: read;
/// - "Written after the change under the old key" (`66666666-…`): a revision under epoch 1's key written after the
///   removal (by a vault value that had not seen it), not sealed: set aside, never read.
enum EpochsFixture {
    static let vaultId = UUID(uuidString: "5a3b1e00-1000-4000-8000-000000000003")!
    static let before = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let after = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let planted = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let attachment = Data("Sempere epochs fixture attachment: synthetic, test-only.\n".utf8)

    static func generate(at url: URL, device: DeviceKeys, recovery: MLKEM768X25519Identity) throws {
        let laptop = try DeviceKeys.generate()
        var home = try TestVaults.create(at: url, identities: [device.nativeIdentity],
                                         names: ["Sempere test fixture (throwaway, test-only key)"], recovery: recovery,
                                         workFactor: 15, vaultId: vaultId, created: SampleFixture.at(0))
        try home.approveDevice(laptop.joinRequest(vaultId: vaultId, name: "Old laptop", kind: "cli", created: SampleFixture.at(0)),
                               added: SampleFixture.at(0))
        let stale = try TestVaults.open(at: url, identity: device.nativeIdentity)
        let page = SampleFixture.id(401)
        try stale.writeBlob(note: before, attachment, type: "text/plain")
        try stale.write(SampleFixture.delta(before, SampleFixture.devA, 1, 1000, [
            .addPage(Page(id: page, order: "a0")), .setMeta(.title("Before the change")), .addStroke(page: page, stroke: SampleFixture.stroke(1)),
        ]))
        var current = try TestVaults.open(at: url, identity: device.nativeIdentity)
        try current.removeDevices([laptop.id], now: SampleFixture.at(2000))
        try current.write(SampleFixture.delta(after, SampleFixture.devA, 1, 3000, [
            .addPage(Page(id: SampleFixture.id(402), order: "a0")), .setMeta(.title("After the change")),
        ]))
        // Under epoch 1's key after the change: never sealed.
        try stale.write(SampleFixture.delta(planted, SampleFixture.devB, 1, 4000, [
            .addPage(Page(id: SampleFixture.id(403), order: "a0")), .setMeta(.title("Written after the change under the old key")),
        ]))
        // A second removal (epoch 3), so a reader walks two records to reach epoch 1's key.
        let tablet = try DeviceKeys.generate()
        try current.approveDevice(tablet.joinRequest(vaultId: vaultId, name: "Tablet", kind: "cli", created: SampleFixture.at(5000)),
                                  added: SampleFixture.at(5000))
        try current.removeDevices([tablet.id], now: SampleFixture.at(6000))
    }
}

/// The committed fixture `Fixtures/newer.sempere`: a synthetic vault of a
/// later major (`sempere/2`, format.md §7) holding newer revisions with ops,
/// fields, meta registers, snapshot elements and a body version this
/// version does not know. Encrypted to `sample.key`. Only the age randomness
/// differs between generations.
///
/// Regenerate with:
///
///     SEMPERE_REGENERATE_FIXTURE=1 swift test --filter FixtureRegeneration/testRegenerateNewerFixture
enum NewerFixture {
    static let vaultId = UUID(uuidString: "5a3b1e00-1000-4000-8000-000000000002")!
    static let devA = DeviceID("a1b2c3d4")!
    static let devN = DeviceID("0e0e0e0e")!
    /// A version-1 delta, then a newer delta with unknown and invalid ops.
    static let mixed = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    /// One newer snapshot with elements that do not decode.
    static let snapshot = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    /// A version-1 delta, then a file with body version 2.
    static let body2 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let format = "sempere/2"
    static let feature = "tables"
    static let app = "sempere-fixture/2"

    static func id(_ n: Int) -> String { String(format: "f1c70000-0000-4000-8000-%012ld", n) }
    static func hlc(_ offset: Int64) -> String { String(SampleFixture.baseMillis + offset) + "0000" }
    static func wall(_ offset: Int64) -> String { RFC3339.string(from: SampleFixture.at(offset))! }

    static func stroke(_ n: Int) -> [String: Any] {
        var pts: [[Double]] = []
        for i in 0..<4 {
            let x = Double(50 + 20 * n + 10 * i)
            let y = Double(100 + 15 * i)
            let t = Double(i) * 0.016
            let rest: [Double] = [2.5, 2.5, 1, 0.5, 0.25, 1.25]
            pts.append([x, y, t] + rest)
        }
        return ["id": id(100 + n), "ink": ["tool": "pen", "color": "#1A1A1AFF", "width": 2.5], "points": pts]
    }

    static func envelope(_ note: UUID, _ dev: DeviceID, _ seq: Int, _ offset: Int64, _ type: String,
                         newer: Bool = true) -> [String: Any] {
        var e: [String: Any] = ["type": type, "noteId": note.uuidString.lowercased(), "device": dev.rawValue,
                                "seq": seq, "hlc": hlc(offset), "wall": wall(offset), "app": app]
        if newer { e["format"] = format }
        return e
    }

    static func name(_ dev: DeviceID, _ seq: Int, _ offset: Int64, _ kind: RevisionName.Kind) -> RevisionName {
        RevisionName(hlc: HLC(String(hlc(offset)))!, device: dev, seq: seq, kind: kind)
    }

    /// Writes revision JSON as a newer writer would: framed (with `bodyVersion`
    /// in the header), tagged and encrypted like any revision.
    static func writeRaw(_ vault: Vault, _ json: [String: Any], note: UUID, name: RevisionName,
                         bodyVersion: UInt8 = 1) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        var body = try BodyFraming.frame(json: data, noteId: note.uuidString.lowercased(), filename: name.filename,
                                         secret: try vault.requireSecret())
        body[body.startIndex + 4] = bodyVersion
        let dir = vault.noteURL(note)
        try FileIO.createDirectory(dir)
        try FileIO.writeAtomically(try Vault.encrypt(body, to: vault.ageRecipients()),
                                   to: dir.appendingPathComponent(name.filename), replacing: false)
    }

    static func generate(at url: URL, identity: NativeIdentity) throws {
        let vault = try TestVaults.create(at: url, identities: [identity], names: ["Sempere test fixture (throwaway, test-only key)"], vaultId: vaultId, created: SampleFixture.at(0))
        let p1 = UUID(uuidString: id(1))!, p2 = UUID(uuidString: id(2))!, p3 = UUID(uuidString: id(3))!
        func v1Stroke(_ n: Int) -> Stroke { SampleFixture.stroke(n) }

        // Mixed: a version-1 delta, then a newer one.
        try vault.write(SampleFixture.delta(mixed, devA, 1, 1000, [
            .addPage(Page(id: p1, order: "a0")), .setMeta(.title("Newer fixture")), .setMeta(.paper(.ruled)),
            .addStroke(page: p1, stroke: v1Stroke(1)),
        ]))
        var d = envelope(mixed, devN, 1, 2000, "delta")
        d["ops"] = [
            ["op": "addStroke", "page": id(1), "stroke": stroke(2)],
            ["op": "moveStroke", "page": id(1), "strokeId": id(101), "dx": 10],
            ["op": "setMeta", "field": "color", "value": "#FF0000FF"],
            ["op": "setMeta", "field": "title", "value": "Newer fixture, edited by v2"],
            ["op": "addStroke", "page": id(1), "stroke": ["id": id(109), "ink": "laser", "points": 7]],
            ["op": "addItem", "page": id(1), "item": ["id": id(201), "kind": "hologram", "layer": 100,
                                                      "frame": [72, 300, 144, 72], "z": "a0", "depth": 3]],
            ["op": "addTag", "tag": "v2"],
        ] as [Any]
        d["sync"] = ["vector": [1, 2, 3]]   // an unknown envelope field
        try writeRaw(vault, d, note: mixed, name: name(devN, 1, 2000, .delta))

        // A newer snapshot alone, with elements that do not decode.
        var s = envelope(snapshot, devN, 1, 3000, "snapshot")
        s["features"] = [feature]
        s["included"] = [devN.rawValue: ["upTo": 0, "extra": []]]
        s["state"] = [
            "deleted": false,
            "meta": ["title": "Newer snapshot", "tags": [], "notebook": NSNull(), "favorite": false,
                     "created": wall(3000), "paper": ["kind": "grid", "spacing": 18],
                     "pageSize": ["width": 612, "height": 792, "infinite": false], "color": "#00FF00FF"],
            "pages": [
                ["id": id(2), "order": "a0", "origin": "\(hlc(3000))-\(devN.rawValue)-1-0",
                 "strokes": [stroke(3).merging(["origin": "\(hlc(3000))-\(devN.rawValue)-1-1"]) { $1 },
                             ["id": "not-a-uuid", "ink": ["tool": "pen", "color": "#000000FF", "width": 1], "points": []]],
                 "tables": [["rows": 2]]],
                ["order": "a1", "strokes": []],   // no id: skipped
            ],
            "tables": [["id": id(301)]],
            "tagSet": ["instances": [], "removed": []],
        ] as [String: Any]
        try writeRaw(vault, s, note: snapshot, name: name(devN, 1, 3000, .snapshot))

        // Body version 2: unreadable here.
        try vault.write(SampleFixture.delta(body2, devA, 1, 4000, [
            .addPage(Page(id: p3, order: "a0")), .setMeta(.title("Newer body")),
            .addStroke(page: p3, stroke: v1Stroke(4)),
        ]))
        var b = envelope(body2, devN, 1, 5000, "delta")
        b["ops"] = [["op": "addStroke", "page": id(3), "stroke": stroke(5)]]
        try writeRaw(vault, b, note: body2, name: name(devN, 1, 5000, .delta), bodyVersion: 2)
        _ = p2

        // Last, the manifest: a later major using an unknown extension.
        var m = vault.manifest
        m.format = format
        m.features = [feature]
        // As its home would write it: tagged and signed (format.md §15.3).
        try Vault.seal(&m, key: try vault.requireSecret(), signing: TestVaults.signing(identity), author: m.author)
        _ = try Vault.writeManifest(m, to: vault.manifestURL, replacing: true)
    }
}
