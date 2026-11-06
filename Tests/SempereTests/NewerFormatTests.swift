import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

final class NewerFormatTests: VaultTestCase {
    static func sampleIdentity() throws -> NativeIdentity {
        try SampleFixture.bundledKeys().device.nativeIdentity
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
        refused("approve device") { try TestVaults.approve(pqIdentity(), into: &vault) }
        refused("rename device") { try vault.renameDevice(id: vault.devices[0].id ?? "", to: "x") }
        refused("label") { try vault.setLabel("x") }
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

    /// A version-1 vault whose tag was broken (format.md §15.3) and whose newer revision was read is
    /// read-only (§7.3): no write touches `vault.json`.
    func testReadOnlyVaultIsNeverTagged() throws {
        let id = pqIdentity()
        let created = try makeVault(id)
        let note = UUID()
        let device = tmp.appendingPathComponent("device.json")
        try created.apply(NoteOps.newNote(title: "Plain"), to: note, deviceState: device, app: "t")
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, Self.future, "delta")
        d["ops"] = [["op": "teleport"]]
        try NewerFixture.writeRaw(created, d, note: note, name: NewerFixture.name(NewerFixture.devN, 1, Self.future, .delta))
        // Its list tag broken as well: refused for writing.
        let manifestURL = created.url.appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        obj["listTag"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: obj).write(to: manifestURL)
        let untagged = try Data(contentsOf: manifestURL)

        var vault = try Vault.open(at: created.url, identities: [id])
        XCTAssertEqual(vault.listStatus.problem?.reason, .listTag)
        _ = try vault.reconstruct(noteId: note)   // reads the newer revision
        XCTAssertTrue(vault.isReadOnly)
        XCTAssertThrowsError(try vault.apply([.setMeta(.title("x"))], to: note, deviceState: device, app: "t")) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try vault.setLabel("x")) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), untagged, "vault.json is never rewritten")
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
        // An empty features list in a revision is not newer.
        let k = UUID()
        var e = NewerFixture.envelope(k, NewerFixture.devN, 1, 9000, "delta", newer: false)
        e["features"] = [String]()
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

        // A key type this version does not know: still opens (read-only).
        try rewrite {
            var r = $0["keys"] as! [[String: Any]]
            var future = r[0]
            future["key"] = "age1future1qqqq"
            future["id"] = "ffffffff"
            r.append(future)
            $0["keys"] = r
        }
        v = try Vault.open(at: url, identities: [id])
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
        try rewrite { $0["format"] = "sempere/3"; $0["keys"] = nil }
        XCTAssertThrowsError(try Vault.open(at: url, identities: [id])) {
            XCTAssertEqual($0 as? VaultError, .unsupportedFormat("sempere/3"))
        }
    }

    func testListChangeRefusesANewerManifestSyncedInAfterOpen() throws {
        let id = pqIdentity()
        var vault = try TestVaults.create(at: vaultURL(), identities: [id])
        let m = vault.url.appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: m)) as? [String: Any])
        obj["format"] = "sempere/2"
        try JSONSerialization.data(withJSONObject: obj).write(to: m)
        XCTAssertFalse(vault.isReadOnly, "the open value has the old manifest")
        XCTAssertThrowsError(try TestVaults.approve(pqIdentity(), into: &vault)) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Vault.readManifest(Data(contentsOf: m)).devices.count, 1)
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
