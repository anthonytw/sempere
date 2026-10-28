import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Sync stress at package level (docs/ci.md "Sync stress"): devices with their
/// own keys, clocks and sync state on one in-memory server, each through its
/// own `FaultyTransport`, interleaving writes and runs (some at the same
/// time). Seeded, so a failing seed replays. The same scenarios against
/// wsgidav behind `scripts/dav-fault-proxy.py` are `SyncFaultProxyTests`
/// (fast, in `scripts/test-webdav.sh`) and `SyncStressTests` (640 notes,
/// `scripts/sync-stress.sh`).
final class TwoDeviceStressTests: SyncTestCase {
    private func devices(_ server: MockDAV, count: Int = 2, seed: UInt64, rates: FaultyTransport.Rates = .none)
        throws -> (SyncDevices, [String: FaultyTransport]) {
        var transports: [String: FaultyTransport] = [:]
        let set = try SyncDevices.make(root: tmp.appendingPathComponent("devices-\(seed)"), count: count, client: { name in
            let t = FaultyTransport(server, seed: seed &* 31 &+ UInt64(name.unicodeScalars.first!.value), rates: rates)
            transports[name] = t
            return try self.client(t)
        }, inspector: try client(server))
        return (set, transports)
    }

    private func client(_ transport: any WebDAVTransport) throws -> WebDAVClient {
        try WebDAVClient(baseURL: URL(string: "https://dav.example.com\(MockDAV.base)/")!, transport: transport)
    }

    /// Paths of a revision written by a device, as `noteFiles` lists them.
    private func path(_ r: Revision) -> String { "notes/\(r.noteId.uuidString.lowercased())/\(r.name.filename)" }

    // MARK: - Random interleavings

    /// Two or three devices write notes, renames, tags, blobs and shared
    /// settings and run two-way syncs and pushes in random order, sometimes
    /// two runs at once, through requests that fail at random (dropped,
    /// answered 503, applied with the answer lost, cut mid-download). Once the
    /// faults stop, a few rounds converge: no revision or blob ever written is
    /// lost, every device and the server hold the same files, nothing is
    /// left in flight, every device reads the same notes and settings, and
    /// no conflict copy was ever made (no mutable file changed on two sides
    /// in a way the rules do not merge).
    func testRandomInterleavingsWithFaultsLoseNothing() throws {
        let seeds = ProcessInfo.processInfo.environment["SEMPERE_STRESS_SEEDS"].flatMap(Int.init) ?? 6
        for seed in 1...seeds { try interleave(seed: UInt64(seed)) }
    }

    private func interleave(seed: UInt64) throws {
        var rng = SeededRNG(seed)
        let server = MockDAV()
        let (set, transports) = try devices(server, count: seed % 3 == 0 ? 3 : 2, seed: seed)
        for t in transports.values { t.rates = .all(0.04) }
        // Device clocks disagree: up to an hour either way.
        for d in set.devices { d.skew = Double(Int(rng.next() % 7200) - 3600) }
        var written = Set<String>()
        var notes: [UUID] = []
        let settingKeys = ["history.thinAfterDays", "photos.removeMetadata", "eraser.mode"]
        for step in 0..<40 {
            let d = set.devices[Int(rng.next() % UInt64(set.devices.count))]
            let known = notes.filter { (try? d.vault().revisionNames(of: $0).isEmpty) == false }
            switch rng.next() % 10 {
            case 0, 1:
                let id = try d.newNote("note \(step) by \(d.name)")
                notes.append(id)
                written.formUnion(d.noteFiles().filter { $0.contains(id.uuidString.lowercased()) })
            case 2:
                guard let id = known.randomElement(using: &rng) else { continue }
                written.insert(path(try d.rename(id, "renamed \(step) by \(d.name)")))
            case 3:
                guard let id = known.randomElement(using: &rng) else { continue }
                written.insert(path(try d.tag(id, "t\(step % 4)")))
            case 4:
                guard let id = known.randomElement(using: &rng) else { continue }
                var bytes = Data(count: 3000 + Int(rng.next() % 5000))
                for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: rng.next()) }
                let blob = try d.attach(id, bytes)
                written.insert("notes/\(id.uuidString.lowercased())/att/\(blob)")
                written.formUnion(d.noteFiles().filter { $0.hasPrefix("notes/\(id.uuidString.lowercased())/") && !$0.contains("/att/") })
            case 5:
                var s = try d.vault().readSharedSettings() ?? SharedSettings()
                let key = settingKeys[Int(rng.next() % 3)]
                try s.set(SettingSlotKey(key), to: .string("\(d.name)\(step)"), type: .mac, now: d.now)
                try d.vault().writeSharedSettings(s)
            case 6:
                _ = try? d.push()
            case 7:
                // Two devices' runs at the same time on the one server.
                let other = set.devices[(set.devices.firstIndex { $0 === d }! + 1) % set.devices.count]
                let group = DispatchGroup()
                for x in [d, other] { DispatchQueue.global().async(group: group) { _ = try? x.sync() } }
                XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "seed \(seed): concurrent runs hung")
            default:
                _ = try? d.sync()
            }
        }
        for t in transports.values { t.rates = .none }
        try set.converge()
        try set.assertConverged(written: written)
        let settings = try set.a.vault().readSharedSettings()
        for d in set.devices {
            XCTAssertEqual(try d.vault().readSharedSettings(), settings, "seed \(seed): \(d.name)'s settings")
            let copies = (try? FileManager.default.contentsOfDirectory(atPath: d.folder.path))?.filter { $0.contains(".conflict-") } ?? []
            XCTAssertEqual(copies, [], "seed \(seed): \(d.name)")
        }
        XCTAssertGreaterThan(transports.values.map { $0.faults.values.reduce(0, +) }.reduce(0, +), 0, "seed \(seed): no fault was injected")
    }

    /// Device clocks two hours apart: an edit made after a sync still wins
    /// over what that sync brought (the hybrid clock observes every revision
    /// of the note first), on every device, whichever clock is ahead.
    func testSkewedClocksKeepEditsInSyncOrder() throws {
        let server = MockDAV()
        let (set, _) = try devices(server, seed: 8)
        set.a.skew = 3600
        set.b.skew = -3600
        let id = try set.a.newNote("from A, an hour ahead")
        try set.converge()
        try set.b.rename(id, "from B, an hour behind, after seeing A's")
        try set.converge()
        let seen = try set.a.notes()[id]
        XCTAssertTrue(seen?.hasPrefix("from B") == true, "\(String(describing: seen))")
        try set.a.rename(id, "A again")
        try set.b.rename(id, "B at the same time")   // concurrent: either may win, but the same everywhere
        try set.converge()
        try set.assertConverged()
        XCTAssertEqual(try set.a.notes()[id], try set.b.notes()[id])
    }

    // MARK: - Request counts

    /// After convergence an idle run costs a bounded number of requests (no
    /// GET of any note file), another device's one new revision costs one
    /// GET under `notes/`, and with `skipUnchangedNotes` on a server whose
    /// folder ETags follow their children the idle run lists no note folder.
    func testRequestCountsStaySane() throws {
        let server = MockDAV()
        server.collectionETags = .direct
        let (set, transports) = try devices(server, seed: 99)
        var ids: [UUID] = []
        for i in 0..<30 { ids.append(try set.a.newNote("note \(i)")) }
        _ = try set.a.attach(ids[3], Data(repeating: 7, count: 5000))
        try set.converge()
        let ta = transports["A"]!

        ta.resetCounts()
        XCTAssertTrue(try set.a.sync().isEmpty)
        let idle = ta.requests
        XCTAssertEqual(idle["GET", default: 0], 1, "only vault.json: \(ta.log.filter { $0.method == "GET" }.map(\.path))")
        XCTAssertEqual(idle["PUT", default: 0] + idle["MOVE", default: 0] + idle["DELETE", default: 0], 0, "\(idle)")
        XCTAssertLessThanOrEqual(idle["PROPFIND", default: 0], ids.count + 4, "\(idle)")

        let r = try set.b.rename(ids[7], "renamed on B")
        let tb = transports["B"]!
        tb.resetCounts()
        try set.b.sync()
        XCTAssertEqual(tb.requests["MKCOL"], nil, "the note folder was listed: no MKCOL before the upload \(tb.log.map(\.path))")
        XCTAssertEqual(tb.requests["PUT"], 1)
        ta.resetCounts()
        let pulled = try set.a.sync()
        XCTAssertEqual(pulled.downloaded, [path(r)])
        XCTAssertEqual(ta.log.filter { $0.method == "GET" && $0.path.contains("/notes/") }.count, 1, "\(ta.log.map(\.path))")

        set.a.tune = { $0.skipUnchangedNotes = true }
        try set.a.sync(); try set.a.sync()
        _ = try set.a.rename(ids[1], "renamed on A")
        try set.a.sync(); try set.a.sync()
        ta.resetCounts()
        XCTAssertTrue(try set.a.sync().isEmpty)
        let skipping = ta.requests
        XCTAssertLessThanOrEqual(skipping["PROPFIND", default: 0], 3 + 1, "the root, notes/, and the one att/: \(ta.log.map(\.path))")
        XCTAssertEqual(skipping["GET", default: 0], 1, "\(skipping)")
    }

    /// A device that misses many runs catches up with one download per new
    /// file, however its earlier runs ended, and re-downloads nothing when a
    /// run is repeated (no storm after a cut run).
    func testCatchingUpDownloadsEachFileOnce() throws {
        let server = MockDAV()
        let (set, transports) = try devices(server, seed: 7)
        var expected = Set<String>()
        for i in 0..<20 {
            let id = try set.a.newNote("note \(i)")
            if i % 5 == 0 { expected.insert("notes/\(id.uuidString.lowercased())/att/" + (try set.a.attach(id, Data(repeating: UInt8(i), count: 300_000)))) }
        }
        try set.a.sync()
        let tb = transports["B"]!
        tb.rates = FaultyTransport.Rates(cutBody: 0.3)
        tb.eligible = { $0.url.path.contains("/att/") }
        for _ in 0..<4 { _ = try? set.b.sync() }
        tb.rates = .none
        try set.b.syncUntilQuiet()
        let gets = tb.log.filter { $0.method == "GET" && $0.path.contains("/notes/") && !$0.path.contains("/att/") }
        XCTAssertEqual(gets.count, Set(gets.map(\.path)).count, "a revision downloaded twice: \(gets.map(\.path))")
        tb.resetCounts()
        XCTAssertTrue(try set.b.sync().isEmpty)
        XCTAssertFalse(tb.log.contains { $0.method == "GET" && $0.path.contains("/notes/") })
        try set.assertConverged(written: expected)
    }

    // MARK: - Mutable files (format.md §1.3)

    /// The vault's label changed on both devices: `vault.json` versions that
    /// differ only in `label` are the same vault (format.md §1.3), so no
    /// conflict copy is made and every device ends with one label.
    func testLabelChangedOnBothDevicesIsNotAConflict() throws {
        let server = MockDAV()
        let (set, _) = try devices(server, seed: 3)
        var va = try set.a.vault()
        try va.setLabel("Named on A")
        var vb = try set.b.vault()
        try vb.setLabel("Named on B")
        let ra = try set.a.sync()
        XCTAssertTrue(ra.conflicts.isEmpty && ra.errors.isEmpty, "\(ra)")
        let rb = try set.b.sync()
        XCTAssertTrue(rb.conflicts.isEmpty && rb.errors.isEmpty, "\(rb)")
        try set.converge()
        let labels = try set.devices.map { try $0.vault().manifest.label }
        XCTAssertEqual(Set(labels).count, 1, "\(labels)")
        for d in set.devices {
            let copies = try FileManager.default.contentsOfDirectory(atPath: d.folder.path).filter { $0.contains(".conflict-") }
            XCTAssertEqual(copies, [], d.name)
        }

        // The app's push (push-only, keeping the server's changes) after another device renamed the vault.
        va = try set.a.vault()
        try va.setLabel("Renamed again on A")
        try set.a.sync()
        vb = try set.b.vault()
        try vb.setLabel("Renamed again on B")
        let push = try set.b.push()
        XCTAssertTrue(push.conflicts.isEmpty && push.overwritten.isEmpty, "\(push)")
        XCTAssertTrue(push.skipped.contains { $0.path == "vault.json" }, "\(push)")
        XCTAssertEqual(try set.a.vault().manifest.label, "Renamed again on A")
        // Any other difference is still a conflict (both sides changed the keys, format.md §1.3).
        let manifest = set.b.folder.appendingPathComponent("vault.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["x-test"] = "changed on B"
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        XCTAssertEqual(try set.b.push().conflicts.map(\.path), ["vault.json"])
        XCTAssertEqual(try set.b.sync().conflicts.map(\.path), ["vault.json"])
    }

    /// Per-device published summaries (`summaries/<device>.sealed`, format.md
    /// §12.5) are never another device's to write: each device uploads its own,
    /// and a received one that is not a sealed file of the vault is not placed
    /// (these hold junk); merge-copy leaves the vault's own.
    func testDeviceSummariesStayWithTheirDevice() throws {
        let server = MockDAV()
        let (set, _) = try devices(server, seed: 4)
        for d in set.devices {
            let dir = d.folder.appendingPathComponent(PublishedSummaries.deviceFolderName)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("\(d.name)".utf8).write(to: dir.appendingPathComponent("\(d.vaultDevice.rawValue).sealed"))
        }
        try set.converge()
        for d in set.devices {
            let names = try FileManager.default.contentsOfDirectory(atPath: d.folder.appendingPathComponent("summaries").path)
            XCTAssertEqual(names, ["\(d.vaultDevice.rawValue).sealed"], d.name)
        }
        XCTAssertEqual(Set((try set.inspector.list(["summaries"]) ?? []).map(\.name)),
                       Set(set.devices.map { "\($0.vaultDevice.rawValue).sealed" }))
        let merged = try set.a.vault().mergeCopy(from: set.b.folder)
        XCTAssertTrue(merged.added.isEmpty, "\(merged)")
    }

    // MARK: - merge-copy round trips

    /// A device's folder is lost after it wrote offline, but a copy survives
    /// (a backup, another disk). It pulls the vault again, merges the copy in
    /// (`sempere vault merge-copy`) and syncs: every note it wrote reaches
    /// the other device, nothing is uploaded twice or reported as a
    /// conflict, and merging again (either way) changes nothing.
    func testMergeCopyRoundTrip() throws {
        let server = MockDAV()
        let (set, transports) = try devices(server, seed: 5)
        let shared = try set.a.newNote("shared")
        try set.converge()
        // B writes offline: a new note, an edit, a blob.
        let offline = try set.b.newNote("written offline on B")
        let edit = try set.b.rename(shared, "renamed offline on B")
        let blob = try set.b.attach(offline, Data(repeating: 9, count: 40_000))
        let a1 = try set.a.tag(shared, "from-a")
        try set.a.sync()
        let backup = tmp.appendingPathComponent("backup.sempere")
        try FileManager.default.copyItem(at: set.b.folder, to: backup)
        // B's folder and sync state are gone; it pulls the vault again.
        try FileManager.default.removeItem(at: set.b.folder)
        try FileManager.default.removeItem(at: set.b.stateURL)
        try set.b.syncUntilQuiet()
        XCTAssertNil(try? set.b.vault().revisionNames(of: offline).first, "not on the server yet")

        let merged = try set.b.vault().mergeCopy(from: backup)
        XCTAssertTrue(merged.refused.isEmpty && merged.differing.isEmpty && !merged.manifestDiffers, "\(merged)")
        XCTAssertEqual(Set(merged.added), Set([path(edit), "notes/\(offline.uuidString.lowercased())/att/\(blob)"])
            .union(SyncDevice.noteFiles(in: backup).filter { $0.contains(offline.uuidString.lowercased()) }))
        XCTAssertTrue(try set.b.vault().mergeCopy(from: backup).isEmpty, "merging twice adds nothing")

        transports["B"]!.resetCounts()
        let up = try set.b.sync()
        XCTAssertEqual(Set(up.uploaded), Set(merged.added), "\(up)")
        XCTAssertTrue(up.conflicts.isEmpty && up.errors.isEmpty && up.downloaded.isEmpty, "\(up)")
        try set.converge()
        try set.assertConverged(written: Set(merged.added).union([path(a1)]))
        XCTAssertEqual(try set.a.notes()[shared], try set.b.notes()[shared])
        XCTAssertTrue(try set.a.vault().mergeCopy(from: set.b.folder).isEmpty, "the two copies are one now")
        XCTAssertTrue(try set.b.vault().mergeCopy(from: backup).isEmpty)
    }
}
