import Age
import Foundation
import XCTest
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
    /// One attachment blob in the lecture's `att/` (post-quantum sample
    /// only), unreferenced until the attachments merge (task A1) gives the
    /// fixture a note with items.
    static let attachment = Data("Sempere fixture attachment: synthetic, test-only.\n".utf8)
    static let attachmentType = "text/plain"

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "f1c70000-0000-4000-8000-%012ld", n))! }
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

    /// Writes the fixture vault at `url` (which must not exist yet). With a
    /// post-quantum identity this is `sample.sempere`; with an X25519 one
    /// `legacy.sempere`, a legacy vault (format.md §3.3.2) that only the
    /// migration tests open (its notes are written through the test seam).
    static func generate(at url: URL, identity: NativeIdentity) throws {
        let vault = try Vault.createUnchecked(at: url, recipients: [identity.recipient],
                                              labels: ["Sempere test fixture (throwaway, test-only key)"],
                                              identities: [identity], vaultId: vaultId, created: at(0))
            .allowingLegacyContent()
        let p1 = id(1), p2 = id(2), q1 = id(3)
        // Lecture: devices A and B, a snapshot by A, then one uncovered delta.
        try vault.write(delta(lecture, devA, 1, 1000, [
            .addPage(Page(id: p1, order: "a0")), .setMeta(.title("Fixture lecture")), .setMeta(.paper(.ruled)),
            .addStroke(page: p1, stroke: stroke(1)), .addStroke(page: p1, stroke: stroke(2)),
        ]))
        try vault.write(delta(lecture, devB, 1, 2000, [
            .addStroke(page: p1, stroke: stroke(3, tool: .marker, color: Color(r: 0xFF, g: 0xD6, b: 0x0A, a: 0x80))),
            .setMeta(.tags(["fixture"])),
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
        if identity.isPostQuantum { try vault.writeBlob(note: lecture, attachment, type: attachmentType) }
        try vault.writeIdentityFile(identity, passphrase: passphrase, workFactor: 15, created: at(0))
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

    static func generate(at url: URL, identity: NativeIdentity) throws {
        let vault = try Vault.createUnchecked(at: url, recipients: [identity.recipient],
                                              labels: ["Sempere test fixture (throwaway, test-only key)"],
                                              identities: [identity], vaultId: vaultId, created: SampleFixture.at(0))
            .allowingLegacyContent()
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
        try vault.writeIdentityFile(identity, passphrase: SampleFixture.passphrase, workFactor: 15, created: SampleFixture.at(0))
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
        let keyText = try String(contentsOf: Self.bundled("sample.key"), encoding: .utf8)
        let identity = try IdentityFile.parse(keyText)
        let vault = try Vault.open(at: Self.bundled("sample.sempere"), identities: [identity])
        XCTAssertEqual(vault.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(vault.recipients.map(\.key), [identity.recipient.string])
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
        XCTAssertEqual(report.counts[.ok], 8)   // 7 revisions + 1 identity file
        XCTAssertEqual(report.counts[.unreferenced], 1)   // the attachment blob
        XCTAssertEqual(Set(vault.manifest.features), ["attachments", "recipients-tag", "signed-secret-link", "markers-tag"])
        XCTAssertEqual(vault.recipientsStatus, .verified(.firstUse), "the committed list is tagged (format.md §2.1)")
        let blob = BlobRef(content: SampleFixture.attachment, type: SampleFixture.attachmentType)
        XCTAssertEqual(try vault.readBlob(note: SampleFixture.lecture, blob), SampleFixture.attachment)
        XCTAssertEqual(try vault.blobInventory(note: SampleFixture.lecture).unreferenced.map(\.fileName),
                       [try vault.blobFileName(for: blob)])

        // Same content as a fresh generation (only ciphertext is random).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("sample.sempere")
        try SampleFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        for note in try vault.noteIDs() {
            XCTAssertEqual(try regenerated.revisionNames(of: note), try vault.revisionNames(of: note))
            for name in try vault.revisionNames(of: note) {
                XCTAssertEqual(try Self.asWrittenBeforeTagSets(regenerated.readRevision(noteId: note, name: name)),
                               try vault.readRevision(noteId: note, name: name), "\(name)")
            }
        }
    }

    /// The committed fixture predates per-tag merging (format.md §5.4.1): its
    /// lecture snapshot has no `tagSet` and keeps the legacy `tags` register in
    /// `meta.tags` and `clocks.tags`, so it doubles as a legacy-vault test. A
    /// fresh snapshot differs only there; this maps it back.
    static func asWrittenBeforeTagSets(_ r: Revision) -> Revision {
        guard case .snapshot(let included, var state) = r.body, let set = state.tagSet else { return r }
        state.tagSet = nil
        state.meta.tags = set.legacy?.tags ?? []
        state.clocks?["tags"] = set.legacy?.clock
        var out = r
        out.body = .snapshot(included: included, state: state)
        return out
    }

    /// The legacy fixture reads with per-tag semantics: its `setMeta(tags)` is
    /// a baseline that a current writer's `removeTag` and `addTag` build on.
    func testLegacyFixtureTagsMergeWithPerTagOps() throws {
        let identity = try IdentityFile.parse(String(contentsOf: Self.bundled("sample.key"), encoding: .utf8))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let copy = tmp.appendingPathComponent("sample.sempere")
        try FileManager.default.copyItem(at: Self.bundled("sample.sempere"), to: copy)
        let vault = try Vault.open(at: copy, identities: [identity])
        let device = tmp.appendingPathComponent("device.json")
        let lecture = SampleFixture.lecture
        guard case .snapshot(_, let old)? = try vault.revisionNames(of: lecture).filter({ $0.kind == .snapshot })
            .first.map({ try vault.readRevision(noteId: lecture, name: $0).body }) else { return XCTFail("no snapshot") }
        XCTAssertNil(old.tagSet)
        var state = try vault.reconstruct(noteId: lecture)
        XCTAssertEqual(state.tagSet?.legacy?.tags, ["fixture"])
        try vault.apply([try XCTUnwrap(NoteOps.addTag("exam", to: state))], to: lecture, deviceState: device, app: "t")
        state = try vault.reconstruct(noteId: lecture)
        XCTAssertEqual(state.meta.tags, ["fixture", "exam"])
        try vault.apply([try XCTUnwrap(NoteOps.removeTag("Fixture", from: state))], to: lecture,
                        deviceState: device, app: "t")
        XCTAssertEqual(try vault.summary(of: lecture).tags, ["exam"])
        var clock = HybridClock()
        try vault.snapshot(noteId: lecture, device: DeviceID("0f0f0f0f")!, clock: &clock, wall: Date(), app: "t")
        XCTAssertEqual(try vault.summary(of: lecture).tags, ["exam"])
    }

    /// GA-63: a committed vault whose note has items. It reads back as generated, its blob verifies and
    /// is referenced, and a fresh generation has the same content.
    func testItemsFixtureHoldsTextImageAndEquation() throws {
        let identity = try IdentityFile.parse(String(contentsOf: Self.bundled("sample.key"), encoding: .utf8))
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

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = tmp.appendingPathComponent("items.sempere")
        try ItemsFixture.generate(at: fresh, identity: identity)
        let regenerated = try Vault.open(at: fresh, identities: [identity])
        XCTAssertEqual(try regenerated.revisionNames(of: ItemsFixture.note), try vault.revisionNames(of: ItemsFixture.note))
        XCTAssertEqual(try regenerated.reconstruct(noteId: ItemsFixture.note).pages, state.pages)
    }

    func testFixtureIdentityFileOpensWithPassphrase() throws {
        let identity = try IdentityFile.parse(String(contentsOf: Self.bundled("sample.key"), encoding: .utf8))
        let locked = try Vault.open(at: Self.bundled("sample.sempere"))
        XCTAssertEqual(try locked.identityFiles(), [identity.recipient])
        let read = try locked.readIdentityFile(recipient: identity.recipient, passphrase: SampleFixture.passphrase)
        XCTAssertEqual(read.string, identity.string)
    }

    /// Rewrites Fixtures/sample.sempere (post-quantum) and
    /// Fixtures/legacy.sempere (X25519) in the source tree, reusing
    /// sample.key / legacy.key (or creating them on first run).
    func testRegenerateFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_FIXTURE=1 to rewrite the fixture vault")
        }
        let dir = Self.sourceFixtures
        for (name, kind) in [("sample", NativeIdentity.Kind.postQuantum), ("legacy", .x25519)] {
            let keyURL = dir.appendingPathComponent("\(name).key")
            let identity: NativeIdentity
            if let text = try? String(contentsOf: keyURL, encoding: .utf8) {
                identity = try IdentityFile.parse(text)
            } else {
                identity = try NativeIdentity.generate(kind)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try ("# TEST-ONLY throwaway identity for Tests/SempereTests/Fixtures. Never use it for real notes.\n"
                    + IdentityFile.render(identity, created: SampleFixture.at(0)))
                    .write(to: keyURL, atomically: true, encoding: .utf8)
            }
            let vaultURL = dir.appendingPathComponent("\(name).sempere")
            try? FileManager.default.removeItem(at: vaultURL)
            try SampleFixture.generate(at: vaultURL, identity: identity)
            try Self.rewriteSnapshotsBeforeTagSets(vaultURL, identity: identity)
        }
    }

    /// Rewrites Fixtures/items.sempere only (the sample and legacy vaults keep their tagged manifests).
    func testRegenerateItemsFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_ITEMS_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_ITEMS_FIXTURE=1 to rewrite Fixtures/items.sempere")
        }
        let dir = Self.sourceFixtures
        let identity = try IdentityFile.parse(String(contentsOf: dir.appendingPathComponent("sample.key"), encoding: .utf8))
        let url = dir.appendingPathComponent("items.sempere")
        try? FileManager.default.removeItem(at: url)
        try ItemsFixture.generate(at: url, identity: identity)
    }

    /// The committed fixtures keep the lecture snapshot in its pre-tag-set
    /// form (`asWrittenBeforeTagSets`), so they double as legacy-snapshot
    /// tests; a regeneration rewrites the fresh snapshot back into that form.
    static func rewriteSnapshotsBeforeTagSets(_ url: URL, identity: NativeIdentity) throws {
        let vault = try Vault.open(at: url, identities: [identity]).allowingLegacyContent()
        let note = SampleFixture.lecture
        for name in try vault.revisionNames(of: note) where name.kind == .snapshot {
            let old = try vault.readRevision(noteId: note, name: name)
            try FileManager.default.removeItem(at: url.appendingPathComponent("notes/\(note.uuidString.lowercased())/\(name)"))
            try vault.write(asWrittenBeforeTagSets(old))
        }
    }

    /// The legacy fixture: an X25519 vault whose notes the library refuses
    /// until it is migrated, while the stock recovery path still reads them.
    func testLegacyFixtureIsMigrateOnly() throws {
        let identity = try IdentityFile.parse(String(contentsOf: Self.bundled("legacy.key"), encoding: .utf8))
        XCTAssertFalse(identity.isPostQuantum)
        let vault = try Vault.open(at: Self.bundled("legacy.sempere"), identities: [identity])
        XCTAssertTrue(vault.isLegacy)
        XCTAssertEqual(vault.classicRecipients, [identity.recipient.string])
        XCTAssertThrowsError(try vault.summaries()) {
            XCTAssertEqual($0 as? VaultError, .legacyVault(recipients: [identity.recipient.string]))
        }
        // Same content as the post-quantum sample, readable through the test seam.
        let lecture = try vault.allowingLegacyContent().reconstruct(noteId: SampleFixture.lecture)
        XCTAssertEqual(lecture.meta.title, "Fixture lecture")
        XCTAssertEqual(try vault.identityFiles(), [identity.recipient])
    }
}
