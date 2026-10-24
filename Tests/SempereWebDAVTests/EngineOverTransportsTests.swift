import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The engine's core two-way rules over every transport
/// (docs/design/device-first-sync.md §9 "Engine over every transport"): the
/// same scenarios, taken from `SyncTests`, `BlobSyncTests`,
/// `IncomingCheckSyncTests`, `SettingsSyncTests` and `IntegrationTests`, written
/// against `SyncRemote` alone (tampering goes through the transport's
/// inspector, another writer), run by the subclasses below over
/// `MemoryRemote`, `WebDAVSyncRemote` on `MockDAV`, and on wsgidav
/// (`scripts/test-webdav.sh`). The WebDAV-specific suites keep testing what
/// only WebDAV has (headers, ETag kinds, servers that refuse deep listings).
class EngineScenarioCase: SyncTestCase {
    /// The transport under test, on a fresh base. Subclasses override it.
    func transport() throws -> TransportUnderTest { throw XCTSkip("abstract") }

    /// Applied to the options of every run (a transport's own needs).
    func tune(_ options: inout SyncOptions) {}

    private(set) var t: TransportUnderTest!
    private var label: String { t.kind }
    private var id: String { noteID.uuidString.lowercased() }

    override func setUpWithError() throws {
        try super.setUpWithError()
        t = try transport()
    }

    /// A two-way run of device `name` (its folder `dir(name)`, state next to it).
    @discardableResult
    func run(_ name: String, via remote: (any SyncRemote)? = nil, vault: Vault?? = nil,
             _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        let v: Vault?
        if let vault { v = vault } else { v = exists ? try openVault(name) : nil }
        var o = SyncOptions(deviceLabel: name)
        o.firstPullIdentities = [identity]
        tune(&o)
        edit(&o)
        return try SyncEngine(directory: dir(name), vault: v, remote: remote ?? t.remote,
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    private func rel(_ r: Revision) -> String { "notes/\(id)/\(r.name.filename)" }
    private func comps(_ rel: String) -> [String] { rel.split(separator: "/").map(String.init) }
    private func remoteNames(_ path: [String]) throws -> [String] { (try t.inspector.list(path) ?? []).map(\.name).sorted() }

    /// A delta adding one image item per reference, on a new page of `note`.
    @discardableResult
    private func referencingNote(_ vault: Vault, note: UUID, device: DeviceID, t ms: Int64, _ refs: [BlobRef]) throws -> Revision {
        let page = UUID()
        var ops: [Op] = [.addPage(Page(id: page, order: "a\(ms)"))]
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: page, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                         frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        let r = Revision(noteId: note, device: device, seq: try vault.nextSeq(noteId: note, device: device),
                         hlc: HLC(millis: baseMillis + ms, counter: 0)!,
                         wall: Date(timeIntervalSince1970: Double(baseMillis + ms) / 1000), app: "test/0", body: .delta(ops: ops))
        try vault.write(r)
        return r
    }

    /// A delta adding one image item per reference, on a new page.
    @discardableResult
    private func referencing(_ vault: Vault, device: DeviceID, t ms: Int64, _ refs: [BlobRef]) throws -> Revision {
        let page = UUID()
        var ops: [Op] = [.addPage(Page(id: page, order: "a\(ms)"))]
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: page, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                         frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        let r = Revision(noteId: noteID, device: device, seq: try vault.nextSeq(noteId: noteID, device: device),
                         hlc: HLC(millis: baseMillis + ms, counter: 0)!,
                         wall: Date(timeIntervalSince1970: Double(baseMillis + ms) / 1000), app: "test/0", body: .delta(ops: ops))
        try vault.write(r)
        return r
    }

    private func assertSameNotes(_ x: String, _ y: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try openVault(x), b = try openVault(y)
        XCTAssertEqual(try a.noteIDs().sorted(), try b.noteIDs().sorted(), label, file: file, line: line)
        for n in try a.noteIDs() {
            XCTAssertEqual(try fileNames(a, n), try fileNames(b, n), label, file: file, line: line)
            XCTAssertEqual(try a.reconstruct(noteId: n), try b.reconstruct(noteId: n), label, file: file, line: line)
        }
    }

    // MARK: Scenarios

    /// A first upload with a blob, a first pull, then idle runs that change nothing.
    func scenarioFirstUploadPullAndIdle() throws {
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        _ = try delta(a, device: devA, t: 5, title: "other", note: UUID())
        let ref = try a.writeBlob(note: noteID, syntheticBlob(70_000), type: "image/png")
        try referencing(a, device: devA, t: 10, [ref])
        let blob = try a.blobFileName(for: ref)
        let up = try run("A")
        XCTAssertTrue(up.errors.isEmpty && up.conflicts.isEmpty, "\(label): \(up)")
        XCTAssertTrue(up.uploaded.contains("notes/\(id)/att/\(blob)"), "\(label): \(up)")
        XCTAssertEqual(try remoteNames(["notes", id, "att"]), [blob], "\(label): no temporary name left")
        let down = try run("B")
        XCTAssertTrue(down.errors.isEmpty && down.quarantined.isEmpty, "\(label): \(down)")
        try assertSameNotes("A", "B")
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(70_000), label)
        XCTAssertEqual(SyncDevices.hiddenFiles(in: dir("B")), [], "\(label): nothing left in progress")
        XCTAssertTrue(try openVault("B").verify().isHealthy, label)
        let idleA = try run("A"), idleB = try run("B")
        XCTAssertTrue(idleA.isEmpty, "\(label): \(idleA)")
        XCTAssertTrue(idleB.isEmpty, "\(label): \(idleB)")
    }

    func scenarioConcurrentDeltasConverge() throws {
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try run("A"); try run("B")
        let b = try openVault("B")
        _ = try delta(a, device: devA, t: 100, title: "from A")
        _ = try delta(b, device: devB, t: 200, title: "from B")
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        _ = try delta(b, device: devB, t: 210, title: "second", note: other)
        try run("A"); try run("B"); try run("A")
        try assertSameNotes("A", "B")
        XCTAssertEqual(try title(try openVault("A")), "from B", "\(label): the later clock wins")
        XCTAssertTrue(try run("A").isEmpty, label)
        XCTAssertTrue(try run("B").isEmpty, label)
    }

    /// Write-once files are never replaced on either side, whatever the copies hold.
    func scenarioNeverOverwritesExistingFiles() throws {
        let a = try makeVault("A")
        let r = try delta(a, device: devA, t: 0, title: "one")
        try run("A")
        let localFile = dir("A").appendingPathComponent(rel(r))
        try Data("age-encryption.org/v1\nlocal".utf8).write(to: localFile)
        try t.inspector.write(comps(rel(r)), .data(Data("age-encryption.org/v1\nremote".utf8)), condition: .unconditional)
        let report = try run("A")
        XCTAssertTrue(report.isEmpty, "\(label): \(report)")
        XCTAssertEqual(try Data(contentsOf: localFile), Data("age-encryption.org/v1\nlocal".utf8), label)
        XCTAssertEqual(try t.inspector.read(comps(rel(r)), maxBytes: 1 << 20).data, Data("age-encryption.org/v1\nremote".utf8), label)
    }

    /// A file that fails the checks is quarantined (kept outside the vault), never placed, not fetched again
    /// while unchanged, and checked again when asked.
    func scenarioHostileFileIsQuarantined() throws {
        let a = try makeVault("A")
        let r = try delta(a, device: devA, t: 0, title: "one")
        try run("A")
        let html = Data("<html>login required</html>".utf8)
        try t.inspector.write(comps(rel(r)), .data(html), condition: .unconditional)
        let report = try run("B")
        XCTAssertEqual(report.quarantined.map(\.path), [rel(r)], "\(label): \(report)")
        let noteDir = dir("B").appendingPathComponent("notes/\(id)")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: noteDir.path)) ?? [], [], label)
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("state-B.quarantine/\(rel(r))")), html, "\(label): kept")
        let again = try run("B")
        XCTAssertTrue(again.quarantined.isEmpty && again.skipped.contains { $0.path == rel(r) }, "\(label): \(again)")
        XCTAssertEqual(try run("B") { $0.retryQuarantined = true }.quarantined.map(\.path), [rel(r)], label)
    }

    private func compactionSetup() throws -> (Vault, [Revision], Revision) {
        let a = try makeVault("A")
        let ds = [try delta(a, device: devA, t: 0, title: "1"), try delta(a, device: devA, t: 10, title: "2"),
                  try delta(a, device: devA, t: 20, title: "3")]
        var clock = HybridClock()
        let snap = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                                  wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        try run("A"); try run("B")
        return (a, ds, snap)
    }

    func scenarioCompactionDeletesPropagate() throws {
        let (a, ds, snap) = try compactionSetup()
        let before = try title(a)
        XCTAssertEqual(Set(try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))),
                       Set(ds.map(\.name)))
        let up = try run("A")
        XCTAssertEqual(Set(up.deleted.map(\.path)), Set(ds.map(rel)), "\(label): \(up)")
        XCTAssertEqual(try remoteNames(["notes", id]), [snap.name.filename], label)
        let down = try run("B")
        XCTAssertEqual(Set(down.deleted.map(\.path)), Set(ds.map(rel)), "\(label): \(down)")
        XCTAssertEqual(try fileNames(try openVault("B")), [snap.name.filename], label)
        XCTAssertEqual(try title(try openVault("B")), before, label)
        XCTAssertTrue(try run("A").isEmpty, label)
        XCTAssertTrue(try run("B").isEmpty, label)
    }

    /// A file the remote lost that no compaction explains is put back.
    func scenarioUnexplainedRemoteDeletionIsRestored() throws {
        let a = try makeVault("A")
        let d1 = try delta(a, device: devA, t: 0, title: "1")
        try run("A")
        try t.inspector.delete(comps(rel(d1)))
        let report = try run("A")
        XCTAssertTrue(report.deleted.isEmpty, "\(label): \(report)")
        XCTAssertEqual(report.uploaded, [rel(d1)], label)
        XCTAssertEqual(try remoteNames(["notes", id]), [d1.name.filename], label)
    }

    /// An emptied note folder on the remote is not a compaction: nothing is deleted locally.
    func scenarioWipedRemoteNeverDeletesHistory() throws {
        let (_, ds, snap) = try compactionSetup()
        for n in try remoteNames(["notes", id]) { try t.inspector.delete(["notes", id, n]) }
        let report = try run("B")
        XCTAssertTrue(report.deleted.isEmpty, "\(label): \(report)")
        let all = Set(ds.map(\.name.filename) + [snap.name.filename])
        XCTAssertEqual(Set(try fileNames(try openVault("B"))), all, label)
        XCTAssertEqual(Set(try remoteNames(["notes", id])), all, "\(label): put back")
    }

    func scenarioRefusesAnotherVault() throws {
        _ = try makeVault("A")
        try run("A")
        _ = try makeVault("B")
        _ = try delta(try openVault("B"), device: devB, t: 0, title: "x")
        XCTAssertThrowsError(try run("B")) {
            guard case SyncError.vaultMismatch = $0 else { return XCTFail("\(self.label): \($0)") }
        }
        XCTAssertEqual(try remoteNames(["notes"]), [], label)
    }

    /// `vault.json` changed on both sides in a way the rules do not merge:
    /// a conflict copy here, and neither copy replaced.
    func scenarioManifestConflictKeepsBothCopies() throws {
        _ = try makeVault("A")
        try run("A"); try run("B")
        func edit(_ name: String, _ value: String) throws {
            let url = dir(name).appendingPathComponent("vault.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["x-test"] = value
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        }
        try edit("A", "A's idea")
        try edit("B", "B's idea")
        // Another writer puts A's version on the server (a keyless run never uploads vault.json, review of #88 M1).
        try t.inspector.write(["vault.json"], .data(try vaultJSON("A")), condition: .unconditional)
        let before = try vaultJSON("B")
        let report = try run("B", vault: .some(nil))
        XCTAssertEqual(report.conflicts.map(\.path), ["vault.json"], "\(label): \(report)")
        XCTAssertEqual(try vaultJSON("B"), before, "\(label): the local file is never replaced")
        let copy = try XCTUnwrap(report.conflicts.first?.remoteCopy)
        let remote = try t.inspector.read(["vault.json"], maxBytes: 1 << 20).data
        XCTAssertEqual(try Data(contentsOf: dir("B").appendingPathComponent(copy)), remote, label)
        XCTAssertEqual(remote, try vaultJSON("A"), "\(label): the remote was not touched")
    }

    /// The server's version token of a mutable file moves between the listing and the upload over the same bytes
    /// (a server that stamps again, another writer putting the same file back): the local change is uploaded, and
    /// no conflict copy (identical to the server's copy) is made. (`settings.age`: a keyless run never uploads
    /// `vault.json`, review of #88 M1.)
    func scenarioManifestStampChangeIsNoConflict() throws {
        _ = try makeVault("A")
        try run("A"); try run("B")
        let url = dir("B").appendingPathComponent("settings.age")
        try Data("age-encryption.org/v1\nsettings one".utf8).write(to: url)
        try run("B", vault: .some(nil))
        try Data("age-encryption.org/v1\nsettings two".utf8).write(to: url)
        let inspector = t.inspector
        let done = Locked(false)
        let restamping = BeforeWriteRemote(t.remote) { path in
            guard path == ["settings.age"], !done.value else { return }
            done.value = true
            let same = try inspector.read(path, maxBytes: 1 << 20).data
            try inspector.write(path, .data(same), condition: .unconditional)
        }
        let report = try run("B", via: restamping, vault: .some(nil))
        XCTAssertTrue(report.conflicts.isEmpty, "\(label): \(report)")
        XCTAssertEqual(report.uploaded, ["settings.age"], "\(label): \(report)")
        XCTAssertEqual(try t.inspector.read(["settings.age"], maxBytes: 1 << 20).data, try Data(contentsOf: url), label)
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir("B").path).filter { $0.contains(".conflict-") }
        XCTAssertEqual(copies, [], label)
        XCTAssertTrue(try run("B", vault: .some(nil)).isEmpty, label)
    }

    /// Quarantining the same path again keeps every distinct copy (design §6, I6: nothing leaves
    /// the quarantine without Adopt or Export), the same bytes once, and at most
    /// `SyncEngine.maxQuarantinedCopies` copies of one path.
    func scenarioQuarantineKeepsEveryCopy() throws {
        let a = try makeVault("A")
        let r = try delta(a, device: devA, t: 0, title: "one")
        try run("A")
        let q = tmp.appendingPathComponent("state-B.quarantine")
        func serve(_ text: String) throws -> Data {
            let data = Data(text.utf8)
            try t.inspector.write(comps(rel(r)), .data(data), condition: .unconditional)
            return data
        }
        func kept() throws -> [Data] {
            let dir = q.appendingPathComponent("notes/\(id)")
            return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                .map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        }
        let first = try serve("<html>login required</html>")
        XCTAssertEqual(try run("B").quarantined.map(\.path), [rel(r)], label)
        let second = try serve("<html>try again later</html>")
        let again = try run("B") { $0.retryQuarantined = true }
        XCTAssertEqual(again.quarantined.map(\.path), [rel(r)], "\(label): \(again)")
        XCTAssertEqual(try Data(contentsOf: q.appendingPathComponent(rel(r))), first, "\(label): the first copy stays")
        XCTAssertEqual(Set(try kept()), [first, second], label)
        _ = try serve("<html>login required</html>")
        try run("B") { $0.retryQuarantined = true }
        XCTAssertEqual(try kept().count, 2, "\(label): the same bytes are kept once")
        let limit = SyncEngine.maxQuarantinedCopies
        for i in 0..<limit {
            _ = try serve("<html>page \(i)</html>")
            let rep = try run("B") { $0.retryQuarantined = true }
            XCTAssertEqual(rep.quarantined.count, 1, label)
            if i == limit - 2 {
                XCTAssertTrue(rep.quarantined[0].message.contains("not kept"), "\(label): \(rep.quarantined)")
            }
        }
        XCTAssertEqual(try kept().count, limit, "\(label): bounded")
        XCTAssertEqual(try Data(contentsOf: q.appendingPathComponent(rel(r))), first, label)
        XCTAssertTrue(Set(try kept()).isSuperset(of: [first, second]), label)
    }

    func scenarioSettingsMergePerKey() throws {
        func write(_ vault: Vault, _ key: String, _ value: JSONValue, at ms: Int64) throws {
            var s = try vault.readSharedSettings() ?? SharedSettings()
            try s.set(SettingSlotKey(key), to: value, type: .mac, now: Date(timeIntervalSince1970: Double(baseMillis + ms) / 1000))
            try vault.writeSharedSettings(s)
        }
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), at: 0)
        try run("A"); try run("B")
        try write(a, "history.thinAfterDays", .number(90), at: 100)
        try write(try openVault("B"), "photos.removeMetadata", .bool(false), at: 200)
        try run("A")
        let merge = try run("B")
        XCTAssertEqual(merge.merged, ["settings.age"], "\(label): \(merge)")
        XCTAssertTrue(merge.conflicts.isEmpty, label)
        try run("A")
        let sa = try XCTUnwrap(try openVault("A").readSharedSettings())
        XCTAssertEqual(sa, try openVault("B").readSharedSettings(), label)
        XCTAssertEqual(sa.value(SettingSlotKey("history.thinAfterDays")), .number(90), label)
        XCTAssertEqual(sa.value(SettingSlotKey("photos.removeMetadata")), .bool(false), label)
        XCTAssertTrue(try run("A").isEmpty, label)
        XCTAssertTrue(try run("B").isEmpty, label)
    }

    /// A blob download cut midway keeps its part for the next run, which
    /// finishes it; nothing partial is ever placed.
    func scenarioCutBlobDownloadFinishesNextRun() throws {
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(400_000, seed: 3), type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        let blob = try a.blobFileName(for: ref)
        try run("A")
        let cutting = t.faulty(5, TransportFaults(cutBody: 1, only: { $0.count == 4 && $0[2] == "att" }))
        let cut = try run("B", via: cutting) { $0.blobSegmentBytes = 64 << 10 }
        XCTAssertFalse(cut.errors.isEmpty, "\(label): \(cut)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("B").appendingPathComponent("notes/\(id)/att/\(blob)").path),
                       "\(label): never placed partial")
        let done = try run("B")
        XCTAssertTrue(done.errors.isEmpty, "\(label): \(done)")
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(400_000, seed: 3), label)
        XCTAssertEqual(SyncDevices.hiddenFiles(in: dir("B")), [], label)
        try assertSameNotes("A", "B")
    }

    /// A blob whose upload fails holds back every revision that references it in that run (format.md
    /// §8.1.4 step 4): a revision never reaches the server without its attachment, which a device that
    /// then stops syncing (or is removed) would leave missing for every other device. The next clean
    /// run uploads both. Over both upload paths: the concurrent pre-upload and the note loop.
    func scenarioRevisionWaitsForItsBlobs() throws {
        let a = try makeVault("A")
        for width in [TransferPool.defaultWidth, 1] {
            let note = UUID()
            let ref = try a.writeBlob(note: note, syntheticBlob(30_000, seed: 11), type: "image/png")
            let r = try referencingNote(a, note: note, device: devA, t: 0, [ref])
            let failing = t.faulty(31, TransportFaults(serverError: 1, only: { $0.count == 4 && $0[2] == "att" }))
            let cut = try run("A", via: failing, vault: try openVault("A")) { $0.concurrency = width }
            XCTAssertFalse(cut.errors.isEmpty, "\(label) width \(width): the blob upload failed: \(cut)")
            let folder = [Vault.notesName, note.uuidString.lowercased()]
            XCTAssertFalse(try remoteNames(folder).contains(r.name.filename),
                           "\(label) width \(width): the revision went up without its blob")
            let done = try run("A") { $0.concurrency = width }
            XCTAssertTrue(done.errors.isEmpty, "\(label) width \(width): \(done)")
            XCTAssertTrue(try remoteNames(folder).contains(r.name.filename), "\(label) width \(width)")
            XCTAssertTrue(try remoteNames(folder + [Vault.attachmentsName]).contains(try a.blobFileName(for: ref)), label)
        }
    }

    /// Runs through requests that fail at random (dropped, refused, applied
    /// with the answer lost, cut) lose nothing, and clean runs converge.
    func scenarioTransientFaultsConverge() throws {
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "start")
        try run("A"); try run("B")
        let fa = t.faulty(21, .all(0.08)), fb = t.faulty(22, .all(0.08))
        var written = Set<String>()
        for i in 0..<6 {
            let ra = try delta(try openVault("A"), device: devA, t: Int64(1000 + i * 10), title: "a\(i)",
                               note: i % 2 == 0 ? noteID : nil)
            let rb = try delta(try openVault("B"), device: devB, t: Int64(1005 + i * 10), title: "b\(i)")
            written.formUnion(["notes/\(ra.noteId.uuidString.lowercased())/\(ra.name.filename)", rel(rb)])
            if i % 3 == 1 {
                let ref = try openVault("A").writeBlob(note: noteID, syntheticBlob(50_000 + i, seed: UInt8(i)), type: "image/png")
                written.insert("notes/\(id)/att/\(try openVault("A").blobFileName(for: ref))")
                try referencing(try openVault("A"), device: devA, t: Int64(1001 + i * 10), [ref])
            }
            _ = try? run("A", via: fa)
            _ = try? run("B", via: fb)
        }
        for _ in 0..<4 { _ = try run("A"); _ = try run("B") }
        let ra = try run("A"), rb = try run("B")
        XCTAssertTrue(ra.isEmpty && rb.isEmpty, "\(label): not quiet: \(ra) \(rb)")
        try assertSameNotes("A", "B")
        let remote = try SyncDevices.remoteFiles(t.inspector)
        XCTAssertTrue(remote.isSuperset(of: written), "\(label): lost \(written.subtracting(remote).sorted())")
        let visible = remote.filter { !($0.split(separator: "/").last ?? "").hasPrefix(".") }
        XCTAssertEqual(SyncDevice.noteFiles(in: dir("A")), visible, label)
        XCTAssertEqual(SyncDevices.hiddenFiles(in: dir("A")) + SyncDevices.hiddenFiles(in: dir("B")), [], label)
    }

    /// `skipUnchangedNotes`: whatever the remote's folder tokens do, another
    /// device's revision and a new local one are still seen.
    func scenarioSkipUnchangedNotesSeesEveryChange() throws {
        let a = try makeVault("A")
        let other = UUID()
        _ = try delta(a, device: devA, t: 0, title: "one")
        _ = try delta(a, device: devA, t: 1, title: "two", note: other)
        func runA() throws -> SyncReport {
            let r = try run("A") { $0.skipUnchangedNotes = true }
            XCTAssertTrue(r.errors.isEmpty, "\(label): \(r)")
            return r
        }
        _ = try runA()
        _ = try delta(a, device: devA, t: 2, title: "three")
        _ = try runA(); _ = try runA(); _ = try runA()
        try run("B")
        let fromB = try delta(try openVault("B"), device: devB, t: 5, title: "from B")
        try run("B")
        XCTAssertEqual(try runA().downloaded, [rel(fromB)], label)
        XCTAssertEqual(try title(try openVault("A")), "from B", label)
        let mine = try delta(a, device: devA, t: 9, title: "later", note: other)
        XCTAssertEqual(try runA().uploaded, ["notes/\(other.uuidString.lowercased())/\(mine.name.filename)"], label)
        XCTAssertTrue(try runA().isEmpty, label)
    }
}

// MARK: - Each transport


final class EngineOverMemoryTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest { .memory() }
    func testFirstUploadPullAndIdle() throws { try scenarioFirstUploadPullAndIdle() }
    func testConcurrentDeltasConverge() throws { try scenarioConcurrentDeltasConverge() }
    func testNeverOverwritesExistingFiles() throws { try scenarioNeverOverwritesExistingFiles() }
    func testHostileFileIsQuarantined() throws { try scenarioHostileFileIsQuarantined() }
    func testCompactionDeletesPropagate() throws { try scenarioCompactionDeletesPropagate() }
    func testUnexplainedRemoteDeletionIsRestored() throws { try scenarioUnexplainedRemoteDeletionIsRestored() }
    func testWipedRemoteNeverDeletesHistory() throws { try scenarioWipedRemoteNeverDeletesHistory() }
    func testRefusesAnotherVault() throws { try scenarioRefusesAnotherVault() }
    func testManifestConflictKeepsBothCopies() throws { try scenarioManifestConflictKeepsBothCopies() }
    func testSettingsMergePerKey() throws { try scenarioSettingsMergePerKey() }
    func testCutBlobDownloadFinishesNextRun() throws { try scenarioCutBlobDownloadFinishesNextRun() }
    func testRevisionWaitsForItsBlobs() throws { try scenarioRevisionWaitsForItsBlobs() }
    func testTransientFaultsConverge() throws { try scenarioTransientFaultsConverge() }
    func testSkipUnchangedNotesSeesEveryChange() throws { try scenarioSkipUnchangedNotesSeesEveryChange() }
    func testManifestStampChangeIsNoConflict() throws { try scenarioManifestStampChangeIsNoConflict() }
    func testQuarantineKeepsEveryCopy() throws { try scenarioQuarantineKeepsEveryCopy() }
}

final class EngineOverWebDAVMockTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest { try .mockDAV() }
    func testFirstUploadPullAndIdle() throws { try scenarioFirstUploadPullAndIdle() }
    func testConcurrentDeltasConverge() throws { try scenarioConcurrentDeltasConverge() }
    func testNeverOverwritesExistingFiles() throws { try scenarioNeverOverwritesExistingFiles() }
    func testHostileFileIsQuarantined() throws { try scenarioHostileFileIsQuarantined() }
    func testCompactionDeletesPropagate() throws { try scenarioCompactionDeletesPropagate() }
    func testUnexplainedRemoteDeletionIsRestored() throws { try scenarioUnexplainedRemoteDeletionIsRestored() }
    func testWipedRemoteNeverDeletesHistory() throws { try scenarioWipedRemoteNeverDeletesHistory() }
    func testRefusesAnotherVault() throws { try scenarioRefusesAnotherVault() }
    func testManifestConflictKeepsBothCopies() throws { try scenarioManifestConflictKeepsBothCopies() }
    func testSettingsMergePerKey() throws { try scenarioSettingsMergePerKey() }
    func testCutBlobDownloadFinishesNextRun() throws { try scenarioCutBlobDownloadFinishesNextRun() }
    func testRevisionWaitsForItsBlobs() throws { try scenarioRevisionWaitsForItsBlobs() }
    func testTransientFaultsConverge() throws { try scenarioTransientFaultsConverge() }
    func testSkipUnchangedNotesSeesEveryChange() throws { try scenarioSkipUnchangedNotesSeesEveryChange() }
    func testManifestStampChangeIsNoConflict() throws { try scenarioManifestStampChangeIsNoConflict() }
    func testQuarantineKeepsEveryCopy() throws { try scenarioQuarantineKeepsEveryCopy() }
}

/// `FolderRemote` on a plain folder.
final class EngineOverFolderTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest { .folder(tmp.appendingPathComponent("remote")) }

    func testFirstUploadPullAndIdle() throws { try scenarioFirstUploadPullAndIdle() }
    func testConcurrentDeltasConverge() throws { try scenarioConcurrentDeltasConverge() }
    func testNeverOverwritesExistingFiles() throws { try scenarioNeverOverwritesExistingFiles() }
    func testHostileFileIsQuarantined() throws { try scenarioHostileFileIsQuarantined() }
    func testCompactionDeletesPropagate() throws { try scenarioCompactionDeletesPropagate() }
    func testUnexplainedRemoteDeletionIsRestored() throws { try scenarioUnexplainedRemoteDeletionIsRestored() }
    func testWipedRemoteNeverDeletesHistory() throws { try scenarioWipedRemoteNeverDeletesHistory() }
    func testRefusesAnotherVault() throws { try scenarioRefusesAnotherVault() }
    func testManifestConflictKeepsBothCopies() throws { try scenarioManifestConflictKeepsBothCopies() }
    func testSettingsMergePerKey() throws { try scenarioSettingsMergePerKey() }
    func testCutBlobDownloadFinishesNextRun() throws { try scenarioCutBlobDownloadFinishesNextRun() }
    func testRevisionWaitsForItsBlobs() throws { try scenarioRevisionWaitsForItsBlobs() }
    func testTransientFaultsConverge() throws { try scenarioTransientFaultsConverge() }
    func testSkipUnchangedNotesSeesEveryChange() throws { try scenarioSkipUnchangedNotesSeesEveryChange() }
}

/// `FolderRemote` on a folder a simulated provider holds (nothing evicted: the provider paths with the
/// scenarios' own expectations). A folder emptied by a test is taken as listed at once (`unlistedTimeout` 0),
/// as the scenarios expect of a store with no arrivals; `FolderHazardTests` test the timeout.
final class EngineOverEvictingFolderTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest { TransportUnderTest.evictingFolder(tmp.appendingPathComponent("remote")).0 }
    override func tune(_ options: inout SyncOptions) { options.unlistedTimeout = 0 }

    func testFirstUploadPullAndIdle() throws { try scenarioFirstUploadPullAndIdle() }
    func testConcurrentDeltasConverge() throws { try scenarioConcurrentDeltasConverge() }
    func testNeverOverwritesExistingFiles() throws { try scenarioNeverOverwritesExistingFiles() }
    func testHostileFileIsQuarantined() throws { try scenarioHostileFileIsQuarantined() }
    func testCompactionDeletesPropagate() throws { try scenarioCompactionDeletesPropagate() }
    func testUnexplainedRemoteDeletionIsRestored() throws { try scenarioUnexplainedRemoteDeletionIsRestored() }
    func testWipedRemoteNeverDeletesHistory() throws { try scenarioWipedRemoteNeverDeletesHistory() }
    func testRefusesAnotherVault() throws { try scenarioRefusesAnotherVault() }
    func testManifestConflictKeepsBothCopies() throws { try scenarioManifestConflictKeepsBothCopies() }
    func testSettingsMergePerKey() throws { try scenarioSettingsMergePerKey() }
    func testCutBlobDownloadFinishesNextRun() throws { try scenarioCutBlobDownloadFinishesNextRun() }
    func testRevisionWaitsForItsBlobs() throws { try scenarioRevisionWaitsForItsBlobs() }
    func testTransientFaultsConverge() throws { try scenarioTransientFaultsConverge() }
    func testSkipUnchangedNotesSeesEveryChange() throws { try scenarioSkipUnchangedNotesSeesEveryChange() }
}

/// `MemoryRemote` in evicted mode: every file read is first asked for and waited for (`Arrivals.swift`).
final class EngineOverEvictedMemoryTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest { .evictedMemory() }

    func testFirstUploadPullAndIdle() throws { try scenarioFirstUploadPullAndIdle() }
    func testConcurrentDeltasConverge() throws { try scenarioConcurrentDeltasConverge() }
    func testNeverOverwritesExistingFiles() throws { try scenarioNeverOverwritesExistingFiles() }
    func testHostileFileIsQuarantined() throws { try scenarioHostileFileIsQuarantined() }
    func testCompactionDeletesPropagate() throws { try scenarioCompactionDeletesPropagate() }
    func testUnexplainedRemoteDeletionIsRestored() throws { try scenarioUnexplainedRemoteDeletionIsRestored() }
    func testWipedRemoteNeverDeletesHistory() throws { try scenarioWipedRemoteNeverDeletesHistory() }
    func testRefusesAnotherVault() throws { try scenarioRefusesAnotherVault() }
    func testManifestConflictKeepsBothCopies() throws { try scenarioManifestConflictKeepsBothCopies() }
    func testSettingsMergePerKey() throws { try scenarioSettingsMergePerKey() }
    func testCutBlobDownloadFinishesNextRun() throws { try scenarioCutBlobDownloadFinishesNextRun() }
    func testRevisionWaitsForItsBlobs() throws { try scenarioRevisionWaitsForItsBlobs() }
    func testTransientFaultsConverge() throws { try scenarioTransientFaultsConverge() }
    func testSkipUnchangedNotesSeesEveryChange() throws { try scenarioSkipUnchangedNotesSeesEveryChange() }
}

/// Against wsgidav (`scripts/test-webdav.sh`, CI's `webdav` job); skipped without it.
final class EngineOverWsgidavTests: EngineScenarioCase {
    override func transport() throws -> TransportUnderTest { try .wsgidav() }
    func testFirstUploadPullAndIdle() throws { try scenarioFirstUploadPullAndIdle() }
    func testConcurrentDeltasConverge() throws { try scenarioConcurrentDeltasConverge() }
    func testNeverOverwritesExistingFiles() throws { try scenarioNeverOverwritesExistingFiles() }
    func testHostileFileIsQuarantined() throws { try scenarioHostileFileIsQuarantined() }
    func testCompactionDeletesPropagate() throws { try scenarioCompactionDeletesPropagate() }
    func testUnexplainedRemoteDeletionIsRestored() throws { try scenarioUnexplainedRemoteDeletionIsRestored() }
    func testWipedRemoteNeverDeletesHistory() throws { try scenarioWipedRemoteNeverDeletesHistory() }
    func testRefusesAnotherVault() throws { try scenarioRefusesAnotherVault() }
    func testManifestConflictKeepsBothCopies() throws { try scenarioManifestConflictKeepsBothCopies() }
    func testSettingsMergePerKey() throws { try scenarioSettingsMergePerKey() }
    func testCutBlobDownloadFinishesNextRun() throws { try scenarioCutBlobDownloadFinishesNextRun() }
    func testRevisionWaitsForItsBlobs() throws { try scenarioRevisionWaitsForItsBlobs() }
    func testTransientFaultsConverge() throws { try scenarioTransientFaultsConverge() }
    func testSkipUnchangedNotesSeesEveryChange() throws { try scenarioSkipUnchangedNotesSeesEveryChange() }
    func testManifestStampChangeIsNoConflict() throws { try scenarioManifestStampChangeIsNoConflict() }
    func testQuarantineKeepsEveryCopy() throws { try scenarioQuarantineKeepsEveryCopy() }
}

/// A remote that runs `before` ahead of each write (another writer acting between the engine's
/// listing and its upload), and otherwise is `inner`.
final class BeforeWriteRemote: SyncRemote, @unchecked Sendable {
    private var inner: any SyncRemote
    private let before: ([String]) throws -> Void

    init(_ inner: any SyncRemote, before: @escaping ([String]) throws -> Void) {
        self.inner = inner
        self.before = before
    }

    var location: String { inner.location }
    var capabilities: RemoteCapabilities { inner.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { inner.interrupt }
        set { inner.interrupt = newValue }
    }
    func list(_ path: [String]) throws -> [RemoteEntry]? { try inner.list(path) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { try inner.listTree(path, maxBytes: maxBytes) }
    func stat(_ path: [String]) throws -> RemoteEntry? { try inner.stat(path) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) { try inner.read(path, maxBytes: maxBytes) }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                  segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try inner.download(path, to: file, resumeFrom: resumeFrom, ifETag: ifETag, maxBytes: maxBytes,
                           segmentBytes: segmentBytes, progress: progress)
    }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try before(path)
        return try inner.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try inner.moveNoOverwrite(path, to: destination)
    }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try inner.makeCollection(path) }
    func createBase() throws { try inner.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try inner.delete(path, ifETag: ifETag) }
    func missingCollectionError(_ path: [String]) -> any Error { inner.missingCollectionError(path) }
}
