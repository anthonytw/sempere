import TempDirSupport
import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The committed sample vault under `Fixtures/sample.sempere` (see
/// `Fixtures/README.md`). Everything except the age randomness is fixed, so
/// regenerating changes ciphertext bytes but never content.
///
/// Regenerate with:
///
///     SEMPERE_REGENERATE_FIXTURE=1 swift test --filter FixtureTests/testRegenerateFixture
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
        try keys(in: FixtureTests.bundled("sample.key").deletingLastPathComponent())
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

final class FixtureTests: XCTestCase {
    static var sourceFixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func bundled(_ name: String) throws -> URL {
        let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return url
    }

    func testFixtureOpensAndReconstructs() throws {
        let (device, recovery) = try SampleFixture.bundledKeys()
        let identity = device.nativeIdentity
        let vault = try Vault.open(at: Self.bundled("sample.sempere"), identities: [identity], signing: device.signing)
        XCTAssertEqual(vault.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(vault.devices.map(\.key), [identity.recipient.string])
        XCTAssertEqual(vault.manifest.recoveryEntry?.key, recovery.recipient.string)
        XCTAssertTrue(vault.isHome, "the fixture device created the vault")
        XCTAssertEqual(try vault.noteIDs(), [SampleFixture.lecture, SampleFixture.deleted])
        XCTAssertEqual(try vault.revisionNames(of: SampleFixture.lecture).map(\.kind),
                       [.delta, .delta, .delta, .snapshot, .delta])

        let lecture = try vault.reconstruct(noteId: SampleFixture.lecture)
        XCTAssertEqual(lecture.meta.title, "Fixture lecture")
        XCTAssertEqual(lecture.meta.tags, ["fixture"])
        XCTAssertEqual(lecture.meta.paper.kind, .ruled)
        XCTAssertFalse(lecture.deleted)
        XCTAssertEqual(lecture.pages.map { $0.strokes.count }, [2, 2])
        XCTAssertEqual(lecture.pages.flatMap { $0.strokes.map(\.id) },
                       [102, 103, 104, 105].map(SampleFixture.id))

        let gone = try vault.reconstruct(noteId: SampleFixture.deleted)
        XCTAssertEqual(gone.meta.title, "Fixture deleted")
        XCTAssertTrue(gone.deleted)
        XCTAssertEqual(gone.pages.map { $0.strokes.count }, [1])

        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.counts[.ok], 9)   // 7 revisions, the passphrase copy, the epoch record
        XCTAssertEqual(report.counts[.unreferenced], 1)   // the attachment blob
        XCTAssertEqual(vault.manifest.features, [], "this version writes no features (format.md §2)")
        XCTAssertEqual(vault.listStatus, .verified(.firstUse), "the committed vault.json checks (format.md §15.3)")
        let blob = BlobRef(content: SampleFixture.attachment, type: SampleFixture.attachmentType)
        XCTAssertEqual(try vault.readBlob(note: SampleFixture.lecture, blob), SampleFixture.attachment)
        XCTAssertEqual(try vault.blobInventory(note: SampleFixture.lecture).unreferenced.map(\.fileName),
                       [try vault.blobFileName(for: blob)])

        // Same content as a fresh generation (only ciphertext is random).
        let tmp = TestTemp.root.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("sample.sempere")
        try SampleFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        for note in try vault.noteIDs() {
            XCTAssertEqual(try regenerated.revisionNames(of: note), try vault.revisionNames(of: note))
            for name in try vault.revisionNames(of: note) {
                XCTAssertEqual(try regenerated.readRevision(noteId: note, name: name),
                               try vault.readRevision(noteId: note, name: name), "\(name)")
            }
        }
    }

    /// GA-63: a committed vault whose note has items. It reads back as generated, its blob verifies and
    /// is referenced, and a fresh generation has the same content.
    func testItemsFixtureHoldsTextImageAndEquation() throws {
        let identity = try SampleFixture.bundledKeys().device.nativeIdentity
        let vault = try Vault.open(at: Self.bundled("items.sempere"), identities: [identity])
        XCTAssertEqual(vault.vaultId, ItemsFixture.vaultId)
        XCTAssertEqual(try vault.noteIDs(), [ItemsFixture.note])
        let state = try vault.reconstruct(noteId: ItemsFixture.note)
        XCTAssertEqual(state.meta.title, "Fixture items")
        let items = try XCTUnwrap(state.pages.first).items
        XCTAssertEqual(items.map(\.id), [ItemsFixture.textItem, ItemsFixture.imageItem, ItemsFixture.mathItem])
        XCTAssertEqual(items.map(\.kind), [.text, .image, .math])
        XCTAssertEqual(items[0].text?.runs.map(\.t), ["Fixture text box"])
        XCTAssertEqual(items[2].math?.latex, "e^{i\\pi}+1=0")
        let blob = try XCTUnwrap(items[1].blob)
        XCTAssertEqual(try vault.readBlob(note: ItemsFixture.note, blob), ItemsFixture.picture)
        XCTAssertEqual(try XCTUnwrap(state.pages.first).strokes.count, 1, "ink and items share the page")
        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertNil(report.counts[.unreferenced], "the image blob is referenced")
        XCTAssertEqual(try vault.blobInventory(note: ItemsFixture.note).unreferenced.count, 0)

        let tmp = TestTemp.root.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("items.sempere")
        try ItemsFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        XCTAssertEqual(try regenerated.revisionNames(of: ItemsFixture.note), try vault.revisionNames(of: ItemsFixture.note))
        XCTAssertEqual(try regenerated.reconstruct(noteId: ItemsFixture.note).pages, state.pages)
    }

    /// The passphrase copy opens to the fixture recovery key, with the vault's id and root; the recovery
    /// key opens the vault read-only, checked against that root.
    func testFixturePassphraseCopyOpensToTheRecoveryKey() throws {
        let (_, recovery) = try SampleFixture.bundledKeys()
        let locked = try Vault.open(at: Self.bundled("sample.sempere"))
        XCTAssertEqual(locked.passphraseCopyNames().count, 1)
        let copy = try locked.openPassphraseCopy(passphrase: SampleFixture.passphrase)
        XCTAssertEqual(copy.identity.string, recovery.string)
        XCTAssertEqual(copy.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(copy.root, locked.root)
        XCTAssertThrowsError(try locked.openPassphraseCopy(passphrase: "wrong")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        let read = try Vault.open(at: Self.bundled("sample.sempere"), identities: [NativeIdentity.mlkem768x25519(recovery)],
                                  root: copy.root)
        XCTAssertTrue(read.isRecoveryOpen)
        XCTAssertEqual(read.listStatus, .verified(.firstUse))
        XCTAssertEqual(try read.reconstruct(noteId: SampleFixture.lecture).meta.title, "Fixture lecture")
        XCTAssertThrowsError(try read.requireWritable()) { XCTAssertEqual($0 as? VaultError, .recoveryKeyReadOnly) }
    }

    /// Rewrites Fixtures/sample.sempere in the source tree, reusing sample.key (the fixture device's key
    /// file) and sample-recovery.key, or creating them when they are missing or not of the key hierarchy.
    func testRegenerateFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_FIXTURE=1 to rewrite the fixture vault")
        }
        let dir = Self.sourceFixtures
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("sample.key"), recoveryURL = dir.appendingPathComponent("sample-recovery.key")
        if (try? DeviceKeys.parse(String(contentsOf: keyURL, encoding: .utf8))) == nil {
            // Keeps the age identity of an older sample.key, so stock-age commands in docs keep working.
            let old = (try? String(contentsOf: keyURL, encoding: .utf8)).flatMap { try? IdentityFile.parse($0) }
            let identity: MLKEM768X25519Identity
            if case .mlkem768x25519(let pq)? = old { identity = pq } else { identity = try MLKEM768X25519Identity() }
            let device = try DeviceKeys(identity: identity, signing: DeviceSigningKeys.generate())
            try ("# TEST-ONLY throwaway device key for Tests/SempereTests/Fixtures. Never use it for real notes.\n"
                + (try device.fileText(created: SampleFixture.at(0)))).write(to: keyURL, atomically: true, encoding: .utf8)
        }
        if (try? IdentityFile.parse(String(contentsOf: recoveryURL, encoding: .utf8))) == nil {
            try ("# TEST-ONLY throwaway recovery key for Tests/SempereTests/Fixtures. Never use it for real notes.\n"
                + IdentityFile.render(.mlkem768x25519(try MLKEM768X25519Identity()), created: SampleFixture.at(0)))
                .write(to: recoveryURL, atomically: true, encoding: .utf8)
        }
        let (device, recovery) = try SampleFixture.keys(in: dir)
        let vaultURL = dir.appendingPathComponent("sample.sempere")
        try? FileManager.default.removeItem(at: vaultURL)
        try SampleFixture.generate(at: vaultURL, identity: device.nativeIdentity, recovery: recovery)
    }

    /// Rewrites Fixtures/items.sempere only (the sample vault keeps its tagged manifest).
    func testRegenerateItemsFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_ITEMS_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_ITEMS_FIXTURE=1 to rewrite Fixtures/items.sempere")
        }
        let dir = Self.sourceFixtures
        let (device, recovery) = try SampleFixture.keys(in: dir)
        let url = dir.appendingPathComponent("items.sempere")
        try? FileManager.default.removeItem(at: url)
        try ItemsFixture.generate(at: url, identity: device.nativeIdentity, recovery: recovery)
    }
}
