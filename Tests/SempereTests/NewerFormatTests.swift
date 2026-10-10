import Age
import Foundation
import XCTest
@testable import Sempere

/// The committed fixture `Fixtures/newer.sempere`: a synthetic vault of a
/// later major (`sempere/2`, format.md §7) holding newer revisions with ops,
/// fields, meta registers, snapshot elements and a body version this
/// version does not know. Encrypted to `sample.key`. Only the age randomness
/// differs between generations.
///
/// Regenerate with:
///
///     SEMPERE_REGENERATE_FIXTURE=1 swift test --filter NewerFormatTests/testRegenerateNewerFixture
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
        let vault = try Vault.create(at: url, recipients: [identity.recipient],
                                     labels: ["Sempere test fixture (throwaway, test-only key)"],
                                     identities: [identity], vaultId: vaultId, created: SampleFixture.at(0))
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
        _ = try Vault.writeManifest(m, to: vault.manifestURL, replacing: true, secret: try vault.requireSecret())
    }
}

final class NewerFormatTests: VaultTestCase {
    static func sampleIdentity() throws -> NativeIdentity {
        try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
    }

    /// A private copy of the committed fixture.
    func newerFixture() throws -> (URL, NativeIdentity) {
        let copy = tmp.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: FixtureTests.bundled("newer.sempere"), to: copy)
        return (copy, try Self.sampleIdentity())
    }

    // MARK: - Identifiers

    func testFormatIdentifiers() {
        XCTAssertEqual(SempereFormat.major(of: "sempere/1"), 1)
        XCTAssertEqual(SempereFormat.major(of: "sempere/2"), 2)
        XCTAssertEqual(SempereFormat.major(of: "sempere/999999999"), 999_999_999)
        for bad in ["sempere/0", "sempere/01", "sempere/", "sempere/1.1", "sempere/-2", "Sempere/2", "inkvault/1",
                    "sempere/1000000000", "sempere/２", " sempere/2", ""] {
            XCTAssertNil(SempereFormat.major(of: bad), bad)
        }
        XCTAssertTrue(SempereFormat.isNewer("sempere/2"))
        XCTAssertFalse(SempereFormat.isNewer("sempere/1"))
        XCTAssertFalse(SempereFormat.isNewer("garbage"))
    }

    // MARK: - The committed fixture

    func testFixtureOpensReadOnlyAndShowsWhatItKnows() throws {
        let (url, identity) = try newerFixture()
        let vault = try Vault.open(at: url, identities: [identity])
        XCTAssertTrue(vault.isReadOnly)
        XCTAssertEqual(vault.readOnlyReasons.vaultFormat, "sempere/2")
        XCTAssertEqual(vault.readOnlyReasons.unknownFeatures, ["tables"])
        XCTAssertEqual(try vault.noteIDs(), [NewerFixture.mixed, NewerFixture.snapshot, NewerFixture.body2])

        // Mixed: the known ops of the newer delta apply, the rest is reported.
        let mixed = try vault.loadNote(NewerFixture.mixed)
        XCTAssertTrue(mixed.failures.isEmpty)
        let newer = try XCTUnwrap(mixed.newer)
        XCTAssertEqual(newer.revisions, 1)
        XCTAssertEqual(newer.formats, ["sempere/2": 1])
        XCTAssertEqual(newer.skippedOps, ["moveStroke": 1, "setMeta.color": 1, "addStroke": 1])
        let state = try vault.reconstruct(mixed)
        XCTAssertEqual(state.meta.title, "Newer fixture, edited by v2")
        XCTAssertEqual(state.meta.tags, ["v2"])
        XCTAssertEqual(state.pages.count, 1)
        XCTAssertEqual(state.pages[0].strokes.map(\.id.uuidString).map { $0.lowercased() },
                       [NewerFixture.id(101), NewerFixture.id(102)])
        XCTAssertEqual(state.pages[0].items.map(\.kind), [ItemKind(rawValue: "hologram")])

        // Snapshot: undecodable elements skipped, unknown members ignored.
        let snap = try vault.loadNote(NewerFixture.snapshot)
        let sn = try XCTUnwrap(snap.newer)
        XCTAssertEqual(sn.features, ["tables": 1])
        XCTAssertEqual(sn.skippedElements, 2)
        let sstate = try vault.reconstruct(snap)
        XCTAssertEqual(sstate.meta.title, "Newer snapshot")
        XCTAssertEqual(sstate.pages.map { $0.strokes.count }, [1])

        // Body version 2: unreadable, reported as newer; the rest still shows.
        let b2 = try vault.loadNote(NewerFixture.body2)
        XCTAssertEqual(b2.failures.count, 1)
        guard case .newer(let why)? = b2.failures.values.first else { return XCTFail("\(b2.failures)") }
        XCTAssertTrue(why.contains("body version 2"), why)
        XCTAssertEqual(b2.newer?.unreadable, 1)
        XCTAssertEqual(try NoteReducer.reconstruct(b2.revisions).pages.map { $0.strokes.count }, [1])

        XCTAssertEqual(Set(vault.readOnlyReasons.newerNotes),
                       [NewerFixture.mixed, NewerFixture.snapshot, NewerFixture.body2])

        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.counts[.newer], 3)

        let summaries = try vault.summaries()
        XCTAssertEqual(summaries.first { $0.id == NewerFixture.mixed }?.newer?.skippedOpCount, 3)
        XCTAssertNotNil(summaries.first { $0.id == NewerFixture.body2 }?.newer)
    }

    func testFixtureRefusesEveryWrite() throws {
        let (url, identity) = try newerFixture()
        var vault = try Vault.open(at: url, identities: [identity])
        let before = try snapshotOfFiles(url)
        let device = tmp.appendingPathComponent("device.json")
        func refused(_ what: String, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), what) { e in
                guard case .readOnly = e as? VaultError else { return XCTFail("\(what): \(e)") }
            }
        }
        refused("delta") { try vault.apply([.setMeta(.title("x"))], to: NewerFixture.mixed, deviceState: device, app: "t") }
        refused("new note") { try vault.apply(NoteOps.newNote(title: "x"), to: UUID(), deviceState: device, app: "t") }
        refused("snapshot") {
            var clock = HybridClock()
            try vault.snapshot(noteId: NewerFixture.mixed, device: DeviceID("0f0f0f0f")!, clock: &clock, wall: Date(), app: "t")
        }
        refused("compact") { try vault.compact(noteId: NewerFixture.mixed, retention: 0, now: Date.distantFuture) }
        refused("thin") {
            let loaded = try vault.loadNote(NewerFixture.mixed)
            var clock = HybridClock()
            let plan = try vault.planCompaction(NewerFixture.mixed, loaded: loaded, mode: .thin(olderThan: 0),
                                                now: .distantFuture, device: DeviceID("0f0f0f0f")!, clock: &clock, app: "t")
            try vault.execute(plan)
        }
        refused("blob") { _ = try vault.writeBlob(note: NewerFixture.mixed, Data("x".utf8), type: "text/plain") }
        refused("blob gc") {
            var state = BlobCollectorState(vaultId: vault.vaultId)
            _ = try vault.collectBlobs(note: NewerFixture.mixed, state: &state, now: .distantFuture, retention: 0)
        }
        refused("blob repair") { _ = try vault.repairBlobs(note: NewerFixture.mixed) }
        refused("add recipient") { try vault.addRecipient(pqIdentity().recipient, label: "x") }
        refused("rewrap resume") { try vault.resumeRewrap() }
        refused("identity file") { try vault.writeIdentityFile(identity, passphrase: "p", workFactor: 15, replace: true) }
        refused("capture profile") { _ = try vault.captureProfile(device: DeviceID("0f0f0f0f")!) }
        XCTAssertEqual(try snapshotOfFiles(url), before, "nothing in the vault changed")
    }

    // MARK: - Revision-level markers in a version-1 vault

    func testNewerRevisionMakesTheVaultReadOnlyOnceRead() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        let device = tmp.appendingPathComponent("device.json")
        try vault.apply(NoteOps.newNote(title: "Plain"), to: note, deviceState: device, app: "t")
        XCTAssertFalse(vault.isReadOnly)
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, Self.future, "delta")
        d["ops"] = [["op": "teleport"], ["op": "setMeta", "field": "title", "value": "From v2"]]
        try NewerFixture.writeRaw(vault, d, note: note, name: NewerFixture.name(NewerFixture.devN, 1, Self.future, .delta))
        let copy = vault   // copies share what they saw
        XCTAssertFalse(vault.isReadOnly, "not seen yet")
        XCTAssertEqual(try vault.reconstruct(noteId: note).meta.title, "From v2")
        XCTAssertEqual(copy.readOnlyReasons.newerNotes, [note])
        XCTAssertNil(copy.readOnlyReasons.vaultFormat)
        XCTAssertThrowsError(try copy.apply([.setMeta(.title("x"))], to: note, deviceState: device, app: "t"))
        XCTAssertThrowsError(try copy.apply(NoteOps.newNote(title: "other"), to: UUID(), deviceState: device, app: "t"))
        // A fresh open has not read it: the note itself still refuses, since
        // writing it reads it first.
        let fresh = try Vault.open(at: vault.url, identities: [id])
        XCTAssertFalse(fresh.isReadOnly)
        XCTAssertThrowsError(try fresh.apply([.setMeta(.title("x"))], to: note, deviceState: device, app: "t")) {
            guard case .readOnly(let r) = $0 as? VaultError else { return XCTFail("\($0)") }
            XCTAssertEqual(r.newerNotes, [note])
        }
    }

    /// An untagged version-1 vault (format.md §2.1) whose newer revision was
    /// read is read-only (§7.3): no write tags `vault.json` on the way to
    /// being refused, and neither does an explicit tag upgrade.
    func testReadOnlyVaultIsNeverTagged() throws {
        let id = pqIdentity()
        let created = try makeVault(id)
        let note = UUID()
        let device = tmp.appendingPathComponent("device.json")
        try created.apply(NoteOps.newNote(title: "Plain"), to: note, deviceState: device, app: "t")
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, Self.future, "delta")
        d["ops"] = [["op": "teleport"]]
        try NewerFixture.writeRaw(created, d, note: note, name: NewerFixture.name(NewerFixture.devN, 1, Self.future, .delta))
        // The vault as a version before §2.1 wrote it: no tag.
        let manifestURL = created.url.appendingPathComponent("vault.json")
        var m = try VaultManifest.decode(Data(contentsOf: manifestURL))
        m.recipientsTag = nil
        m.secretLink = nil
        m.features.removeAll { $0 == VaultManifest.recipientsTagFeature }
        m.markersTag = nil; m.features.removeAll { $0 == VaultManifest.markersTagFeature }   // older than version markers
        try m.encoded().write(to: manifestURL)
        let untagged = try Data(contentsOf: manifestURL)

        var vault = try Vault.open(at: created.url, identities: [id])
        guard case .untagged = vault.recipientsStatus else { return XCTFail("\(vault.recipientsStatus)") }
        _ = try vault.reconstruct(noteId: note)   // reads the newer revision
        XCTAssertTrue(vault.isReadOnly)
        XCTAssertThrowsError(try vault.apply([.setMeta(.title("x"))], to: note, deviceState: device, app: "t")) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try vault.upgradeRecipientsTag()) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), untagged, "vault.json is never tagged")
    }

    func testUnmarkedRevisionWithUnknownOpStillFailsClosed() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, 9000, "delta", newer: false)
        d["ops"] = [["op": "teleport"], ["op": "setMeta", "field": "title", "value": "x"]]
        let name = NewerFixture.name(NewerFixture.devN, 1, 9000, .delta)
        try NewerFixture.writeRaw(vault, d, note: note, name: name)
        let loaded = try vault.loadNote(note)
        guard case .undecodable? = loaded.failures[name] else { return XCTFail("\(loaded.failures)") }
        XCTAssertNil(loaded.newer)
        XCTAssertFalse(vault.isReadOnly)

        // `format: sempere/1` is the same as absent; a malformed marker rejects.
        for (marker, value) in [("format", "sempere/1" as Any), ("format", "2"), ("format", "sempere/0"), ("features", "x")] {
            let n = UUID()
            var e = NewerFixture.envelope(n, NewerFixture.devN, 1, 9000, "delta", newer: false)
            e[marker] = value
            e["ops"] = [["op": "teleport"]]
            try NewerFixture.writeRaw(vault, e, note: n, name: name)
            guard case .undecodable? = try vault.loadNote(n).failures[name] else { return XCTFail("\(marker) \(value)") }
        }
        // Known features in a revision are not newer.
        let k = UUID()
        var e = NewerFixture.envelope(k, NewerFixture.devN, 1, 9000, "delta", newer: false)
        e["features"] = ["attachments"]
        e["ops"] = [["op": "setMeta", "field": "title", "value": "fine"]]
        try NewerFixture.writeRaw(vault, e, note: k, name: name)
        XCTAssertEqual(try vault.reconstruct(noteId: k).meta.title, "fine")
        XCTAssertFalse(vault.isReadOnly)
    }

    func testNewerRevisionIsStillAuthenticated() throws {
        let vault = try makeVault(pqIdentity())
        let note = UUID()
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, 9000, "delta")
        d["ops"] = [["op": "teleport"]]
        let name = NewerFixture.name(NewerFixture.devN, 1, 9000, .delta)
        try NewerFixture.writeRaw(vault, d, note: note, name: name)
        try flipByte(vault.noteURL(note).appendingPathComponent(name.filename), at: 1)
        XCTAssertNotNil(try vault.loadNote(note).failures[name])
        XCTAssertFalse(vault.isReadOnly, "an unverified file never counts as newer")

        // Named for another note: rejected, not newer.
        let other = UUID()
        var o = NewerFixture.envelope(note, NewerFixture.devN, 1, 9000, "delta")
        o["ops"] = []
        let dir = vault.noteURL(other)
        let json = try JSONSerialization.data(withJSONObject: o)
        let body = try BodyFraming.frame(json: json, noteId: other.uuidString.lowercased(), filename: name.filename,
                                         secret: try vault.requireSecret())
        try FileIO.createDirectory(dir)
        try FileIO.writeAtomically(try Vault.encrypt(body, to: vault.ageRecipients()),
                                   to: dir.appendingPathComponent(name.filename), replacing: false)
        guard case .undecodable? = try vault.loadNote(other).failures[name] else { return XCTFail() }
    }

    func testRevisionReadLenientlyIsNeverWritten() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, 9000, "delta")
        d["ops"] = [["op": "setMeta", "field": "title", "value": "v2"]]
        let name = NewerFixture.name(NewerFixture.devN, 1, 9000, .delta)
        try NewerFixture.writeRaw(vault, d, note: note, name: name)
        var rev = try Vault.open(at: vault.url, identities: [id]).readRevision(noteId: note, name: name)
        XCTAssertNotNil(rev.newer)
        rev.noteId = UUID()   // somewhere fresh, through a vault that has not read anything
        rev.seq = 1
        let fresh = try Vault.open(at: vault.url, identities: [id])
        XCTAssertThrowsError(try fresh.write(rev)) { XCTAssertNotNil($0 as? VaultError) }
    }

    // MARK: - Manifests

    func testManifestOfALaterMajor() throws {
        let id = pqIdentity()
        _ = try makeVault(id)
        let url = vaultURL()
        func rewrite(_ change: (inout [String: Any]) -> Void) throws {
            let m = url.appendingPathComponent("vault.json")
            var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: m)) as? [String: Any])
            change(&obj)
            try JSONSerialization.data(withJSONObject: obj).write(to: m)
        }
        try rewrite { $0["format"] = "sempere/7" }
        var v = try Vault.open(at: url, identities: [id])
        XCTAssertEqual(v.readOnlyReasons.vaultFormat, "sempere/7")
        XCTAssertThrowsError(try v.writeBlob(note: UUID(), Data(), type: "text/plain"))

        // A recipient type this version does not know: still opens (read-only).
        try rewrite {
            var r = $0["recipients"] as! [[String: Any]]
            r.append(["key": "age1future1qqqq", "label": "", "added": "2026-10-04T16:20:00Z"])
            $0["recipients"] = r
        }
        v = try Vault.open(at: url, identities: [id])
        XCTAssertFalse(v.isLegacy)
        XCTAssertTrue(v.isReadOnly)
        XCTAssertNoThrow(try v.noteIDs())

        // …but not in a version-1 manifest.
        try rewrite { $0["format"] = "sempere/1" }
        XCTAssertThrowsError(try Vault.open(at: url, identities: [id])) {
            guard case .manifestCorrupt = $0 as? VaultError else { return XCTFail("\($0)") }
        }

        // Not a format identifier, or a newer manifest without the §2 fields: refused.
        for format in ["sempere/0", "sempere/x", "other/2"] {
            try rewrite { $0["format"] = format }
            XCTAssertThrowsError(try Vault.open(at: url, identities: [id])) {
                XCTAssertEqual($0 as? VaultError, .unsupportedFormat(format))
            }
        }
        try rewrite { $0["format"] = "sempere/3"; $0["vaultSecret"] = nil }
        XCTAssertThrowsError(try Vault.open(at: url, identities: [id])) {
            XCTAssertEqual($0 as? VaultError, .unsupportedFormat("sempere/3"))
        }
    }

    func testRecipientChangeRefusesANewerManifestSyncedInAfterOpen() throws {
        let id = pqIdentity()
        var vault = try makeVault(id)
        let m = vault.url.appendingPathComponent("vault.json")
        var manifest = try VaultManifest.decode(Data(contentsOf: m))
        manifest.format = "sempere/2"
        try manifest.encoded().write(to: m)
        XCTAssertFalse(vault.isReadOnly, "the open value has the old manifest")
        XCTAssertThrowsError(try vault.addRecipient(pqIdentity().recipient, label: "x")) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try VaultManifest.decode(Data(contentsOf: m)).recipients.count, 1)
        XCTAssertFalse(vault.pendingRewrap)
    }

    // MARK: - Bounds (format.md §9)

    func testSkippedNamesAreBounded() throws {
        let vault = try makeVault(pqIdentity())
        let note = UUID()
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, 9000, "delta")
        var ops: [Any] = (0..<200).map { ["op": "op\($0)" + String(repeating: "x", count: 100)] }
        ops += [42, "string", NSNull(), ["no": "op"], ["op": 7]]
        d["ops"] = ops
        try NewerFixture.writeRaw(vault, d, note: note, name: NewerFixture.name(NewerFixture.devN, 1, 9000, .delta))
        let newer = try XCTUnwrap(try vault.loadNote(note).newer)
        XCTAssertLessThanOrEqual(newer.skippedOps.count, NewerContent.maxNames + 1)
        XCTAssertNotNil(newer.skippedOps[NewerContent.otherName])
        XCTAssertTrue(newer.skippedOps.keys.allSatisfy { $0.count <= NewerContent.maxNameLength })
        XCTAssertEqual(newer.skippedOpCount, 205)
        XCTAssertFalse(newer.summary.isEmpty)
        var big = NewerContent()
        big.revisions = .max
        big.merge(big)
        XCTAssertEqual(big.revisions, .max, "counts saturate")
    }

    /// Rewrites `Fixtures/newer.sempere` in the source tree from `sample.key`.
    func testRegenerateNewerFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_FIXTURE=1 to rewrite the fixture vault")
        }
        let target = FixtureTests.sourceFixtures.appendingPathComponent("newer.sempere")
        try? FileManager.default.removeItem(at: target)
        try NewerFixture.generate(at: target, identity: try Self.sampleIdentity())
    }

    func testFixtureMatchesAFreshGeneration() throws {
        let identity = try Self.sampleIdentity()
        let fresh = tmp.appendingPathComponent("fresh.sempere")
        try NewerFixture.generate(at: fresh, identity: identity)
        let a = try Vault.open(at: FixtureTests.bundled("newer.sempere"), identities: [identity])
        let b = try Vault.open(at: fresh, identities: [identity])
        XCTAssertEqual(a.manifest.format, b.manifest.format)
        XCTAssertEqual(a.manifest.features, b.manifest.features)
        for note in try a.noteIDs() {
            let la = try a.loadNote(note), lb = try b.loadNote(note)
            XCTAssertEqual(la.revisions, lb.revisions)
            XCTAssertEqual(Set(la.failures.keys), Set(lb.failures.keys))
        }
    }

    // MARK: - Helpers

    /// An hlc offset after any test's wall clock (100 years past the fixture base).
    static let future: Int64 = 100 * 365 * 86_400_000

    /// Every file under `url` with its bytes.
    func snapshotOfFiles(_ url: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            guard (try f.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            out[String(f.path.dropFirst(url.path.count))] = try Data(contentsOf: f)
        }
        return out
    }
}
