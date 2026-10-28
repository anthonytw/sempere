import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// The engine over a vault folder a provider holds (docs/design/device-first-sync.md
/// §3.3 "Placed vaults", docs/io.md "Folder targets in providers"), through
/// `EvictingFolderProvider` on any file system: evicted files (dataless and
/// stand-ins) are arriving, never missing; folders listed before their files
/// and `att/`-only folders are never judged, but only for `unlistedTimeout`;
/// waits are bounded; download failures and stalls are reported; the
/// provider's conflict versions are merged or kept, then resolved. Ported from
/// the app's `ProgressiveLoadTests` / `CloudConflictTests` hazards.
final class FolderHazardTests: SyncTestCase {
    private var provider: EvictingFolderProvider!
    private var remote: FolderRemote!
    private var id: String { noteID.uuidString.lowercased() }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = tmp.appendingPathComponent("icloud/Notes.sempere")
        provider = EvictingFolderProvider(root: base, cloud: tmp.appendingPathComponent("cloud"))
        remote = FolderRemote(root: base, provider: provider)
    }

    @discardableResult
    private func run(_ name: String, vault: Vault?? = nil, _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        let v: Vault?
        if let vault { v = vault } else { v = exists ? try openVault(name) : nil }
        var o = SyncOptions(deviceLabel: name)
        o.firstPullIdentities = [identity]
        o.arrivalWait = 2
        edit(&o)
        return try SyncEngine(directory: dir(name), vault: v, remote: remote,
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    private func rel(_ r: Revision) -> String { "notes/\(r.noteId.uuidString.lowercased())/\(r.name.filename)" }

    /// A with a note (two revisions, one blob) pushed to the folder.
    private func pushed() throws -> (revisions: [Revision], blob: String, ref: BlobRef) {
        let a = try makeVault("A")
        let r1 = try delta(a, device: devA, t: 0, title: "one")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(30_000, seed: 2), type: "image/png")
        let page = UUID()
        let r2 = Revision(noteId: noteID, device: devA, seq: try a.nextSeq(noteId: noteID, device: devA),
                          hlc: HLC(millis: baseMillis + 10, counter: 0)!, wall: Date(timeIntervalSince1970: Double(baseMillis + 10) / 1000),
                          app: "test/0", body: .delta(ops: [.addPage(Page(id: page, order: "a")),
                                                            .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                                                              frame: Rect(x: 1, y: 1, w: 4, h: 3), z: "a"))]))
        try a.write(r2)
        let up = try run("A")
        XCTAssertTrue(up.errors.isEmpty, "\(up)")
        return ([r1, r2], try a.blobFileName(for: ref), ref)
    }

    private func names(_ name: String) throws -> Set<String> { Set(try fileNames(try openVault(name))) }

    // MARK: Evicted files

    /// Evicted files the run needs are asked for and arrive within the run's wait.
    func testEvictedFilesArriveWithinTheRun() throws {
        let (rs, blob, ref) = try pushed()
        provider.arrivalDelay = 3
        try provider.evict("vault.json", as: .dataless)
        try provider.evict(rel(rs[0]), as: .dataless)
        try provider.evict(rel(rs[1]), as: .standIn)
        try provider.evict("notes/\(id)/att/\(blob)", as: .standIn)
        let down = try run("B")
        XCTAssertTrue(down.errors.isEmpty && down.quarantined.isEmpty && down.arriving.isEmpty, "\(down)")
        XCTAssertEqual(try names("B"), Set(rs.map(\.name.filename)))
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(30_000, seed: 2), "never the zeros")
        XCTAssertTrue(Set(provider.requested).isSuperset(of: ["vault.json", rel(rs[0]), rel(rs[1]), "notes/\(id)/att/\(blob)"]),
                      "\(provider.requested)")
        XCTAssertTrue(try run("B").isEmpty)
    }

    /// What does not arrive in time is left for a later run: never quarantined (its zeros
    /// are never read), never taken as missing on the other side, and placed once it arrives.
    func testEvictedFilesThatDoNotArriveAreLeftForLater() throws {
        let (rs, blob, _) = try pushed()
        try run("B")
        let a = try openVault("A")
        let r3 = try delta(a, device: devA, t: 20, title: "three")
        try run("A")
        provider.arrivalDelay = 10_000
        try provider.evict(rel(r3), as: .dataless)
        // Evicted files both sides already have are nothing to read: A's run stays quiet.
        try provider.evict(rel(rs[0]), as: .standIn)
        try provider.evict("notes/\(id)/att/\(blob)", as: .dataless)
        XCTAssertTrue(try run("A").isEmpty, "nothing uploaded over an evicted file, nothing deleted for it")
        let start = Date()
        let b = try run("B") { $0.arrivalWait = 0.3 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the wait is bounded")
        XCTAssertEqual(b.arriving.map(\.path), [rel(r3)], "\(b)")
        XCTAssertTrue(b.errors.isEmpty && b.quarantined.isEmpty && b.downloaded.isEmpty && b.deleted.isEmpty, "\(b)")
        XCTAssertFalse(try names("B").contains(r3.name.filename))
        XCTAssertTrue(try run("A").isEmpty, "A's file is still there for B")
        provider.arrivalDelay = 0
        let later = try run("B")
        XCTAssertEqual(later.downloaded, [rel(r3)], "\(later)")
        XCTAssertTrue(later.arriving.isEmpty)
        XCTAssertEqual(try title(try openVault("B")), "three")
    }

    /// A file that stays away: reported as arriving, then (past `arrivalStall`) as an error; never deleted.
    func testDownloadFailuresAndStallsAreReported() throws {
        let (rs, _, _) = try pushed()
        try run("B")
        let r3 = try delta(try openVault("A"), device: devA, t: 30, title: "x")
        try run("A")
        try provider.evict(rel(r3))
        provider.fail(rel(r3), "the iCloud storage is full")
        let first = try run("B")
        XCTAssertEqual(first.arriving.map(\.path), [rel(r3)])
        XCTAssertTrue(first.arriving.first?.message.contains("storage is full") == true, "\(first)")
        // Runs every 10 minutes (no gap): past `arrivalStall`, a stall, shown but not a failure (offline audit P5).
        try run("B") { $0.now = Date().addingTimeInterval(600) }
        let stalled = try run("B") { $0.now = Date().addingTimeInterval(1200) }
        XCTAssertEqual(stalled.errors.map(\.path), [rel(r3)], "\(stalled)")
        XCTAssertEqual(stalled.errors.map(\.kind), [.arrivalStall])
        XCTAssertEqual(stalled.arriving.map(\.path), [rel(r3)], "still arriving")
        XCTAssertTrue(stalled.outcome.success, "a provider's late file is not a failed run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.root.appendingPathComponent(rel(r3)).path), "kept")
        XCTAssertEqual(try names("B"), Set(rs.map(\.name.filename)))
    }

    /// Offline audit P5: a stall counts only time this device could sync. Back after hours offline (a gap between
    /// runs) or just after its network came back, a file still arriving is not reported as stalled.
    func testAStallIsNotCountedWhileTheDeviceWasOffline() throws {
        _ = try pushed()
        try run("B")
        let r3 = try delta(try openVault("A"), device: devA, t: 30, title: "x")
        try run("A")
        try provider.evict(rel(r3))
        provider.fail(rel(r3), "the iCloud storage is full")
        XCTAssertEqual(try run("B").arriving.map(\.path), [rel(r3)])
        // Twelve hours later (the device was asleep, or offline): a gap, not a stall.
        let back = try run("B") { $0.now = Date().addingTimeInterval(12 * 3600) }
        XCTAssertTrue(back.errors.isEmpty, "\(back.errors)")
        XCTAssertEqual(back.arriving.map(\.path), [rel(r3)])
        // Runs close together, but the network came back only 5 minutes ago: not a stall either.
        let soon = try run("B") { $0.now = Date().addingTimeInterval(12 * 3600 + 20 * 60); $0.networkReturned = $0.now.addingTimeInterval(-300) }
        XCTAssertTrue(soon.errors.isEmpty, "\(soon.errors)")
        // Twenty minutes of runs with a network path: a stall.
        let late = try run("B") { $0.now = Date().addingTimeInterval(12 * 3600 + 25 * 60) }
        XCTAssertEqual(late.errors.map(\.kind), [.arrivalStall], "\(late.errors)")
    }

    /// The remote's `vault.json` is needed to know it is the same vault: still away, the run stops.
    func testAManifestThatDoesNotArriveStopsTheRun() throws {
        _ = try pushed()
        provider.arrivalDelay = 10_000
        try provider.evict("vault.json", as: .standIn)
        XCTAssertThrowsError(try run("B") { $0.arrivalWait = 0.2 }) {
            XCTAssertEqual($0 as? SyncError, .notDownloaded("vault.json"), "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("B").path), "nothing was synced")
        // The base itself not listed yet (a package not downloaded): arriving, and nothing is written this run.
        try provider.unlist("")
        let held = try run("A") { $0.arrivalWait = 0.2 }
        XCTAssertEqual(held.arriving.map(\.path), ["/"], "\(held)")
        XCTAssertTrue(held.uploaded.isEmpty && held.errors.isEmpty, "\(held)")
    }

    // MARK: Folders listed before their files

    /// A note folder listed before its files is arriving: nothing judged (no local deletion, no
    /// upload); past `unlistedTimeout` its listing is taken as it is (an emptied folder deletes
    /// nothing, the files are put back); when it arrives, the rest comes in.
    func testUnlistedNoteFolders() throws {
        let (rs, _, _) = try pushed()
        try run("B")
        let r3 = try delta(try openVault("A"), device: devA, t: 40, title: "while unlisted")
        try run("A")
        provider.arrivalDelay = 10_000
        try provider.unlist("notes/\(id)")
        let b = try run("B")
        XCTAssertEqual(b.arriving.map(\.path), ["notes/\(id)/"], "\(b)")
        XCTAssertTrue(b.deleted.isEmpty && b.uploaded.isEmpty && b.errors.isEmpty, "\(b)")
        XCTAssertEqual(try names("B"), Set(rs.map(\.name.filename)))
        XCTAssertTrue(provider.requested.contains("notes/\(id)"))
        // Past the timeout: taken as listed (empty): nothing deleted here, the files put back.
        let late = try run("B") { $0.now = Date().addingTimeInterval(300) }
        XCTAssertTrue(late.deleted.isEmpty && late.arriving.isEmpty && late.errors.isEmpty, "\(late)")
        XCTAssertEqual(Set(late.uploaded.filter { !$0.contains("/att/") }), Set(rs.map(rel)), "\(late)")
        // It arrives: A's revision comes in too.
        provider.arrivalDelay = 0
        try remote.requestDownload([["notes", id]])
        try run("B")
        XCTAssertEqual(try names("B"), Set((rs + [r3]).map(\.name.filename)))
        XCTAssertEqual(try title(try openVault("B")), "while unlisted")
        try run("A")
        XCTAssertTrue(try run("A").isEmpty && run("B").isEmpty)
    }

    /// A note's `att/` listed before its files: the note is left out (no blob deleted or re-sent).
    func testUnlistedAttachmentFolders() throws {
        let (_, blob, ref) = try pushed()
        try run("B")
        provider.arrivalDelay = 10_000
        try provider.unlist("notes/\(id)/att")
        let b = try run("B")
        XCTAssertEqual(b.arriving.map(\.path), ["notes/\(id)/att/"], "\(b)")
        XCTAssertTrue(b.deleted.isEmpty && b.uploaded.isEmpty, "\(b)")
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, ref), syntheticBlob(30_000, seed: 2))
        provider.arrivalDelay = 0
        let after = try run("B")
        XCTAssertTrue(after.isEmpty, "\(after)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.root.appendingPathComponent("notes/\(id)/att/\(blob)").path))
    }

    /// An `att/`-only folder (an import in progress elsewhere: blobs before their revision) is
    /// not a note: nothing is judged or reported for it, and it becomes one when its revision comes.
    func testAttachmentOnlyFolderIsNotANoteYet() throws {
        _ = try pushed()
        try run("B")
        let a = try openVault("A")
        let other = UUID()
        let ref = try a.writeBlob(note: other, syntheticBlob(5_000, seed: 9), type: "image/png")
        try run("A")
        let b = try run("B")
        XCTAssertTrue(b.errors.isEmpty && b.deleted.isEmpty && b.quarantined.isEmpty && b.arriving.isEmpty, "\(b)")
        let r = try delta(a, device: devA, t: 50, title: "imported", note: other)
        _ = ref
        try run("A")
        try run("B")
        XCTAssertEqual(try fileNames(try openVault("B"), other), [r.name.filename])
    }

    // MARK: Conflict versions

    func testConflictVersionsAreMergedOrKeptThenResolved() throws {
        _ = try pushed()
        try run("B")
        let current = try Data(contentsOf: remote.root.appendingPathComponent("vault.json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        json["label"] = "Renamed elsewhere"
        let relabeled = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        json["label"] = nil
        json["x-other"] = "a key change elsewhere"
        let differing = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        // Another device's settings, forked by the provider.
        var mine = SharedSettings()
        try mine.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date(timeIntervalSince1970: 1_800_000_000))
        try openVault("B").writeSharedSettings(mine)
        try run("B"); try run("A")
        var theirs = try XCTUnwrap(try openVault("A").readSharedSettings())
        try theirs.set(SettingSlotKey("history.thinAfterDays"), to: .number(30), type: .mac, now: Date(timeIntervalSince1970: 1_800_000_100))
        try provider.addConflict("settings.age", try openVault("A").sealSharedSettings(theirs))
        try remote.write(["sempere-summaries.sealed"], .data(Data("x".utf8)), condition: .unconditional)
        try provider.addConflict("sempere-summaries.sealed", Data("y".utf8))
        try provider.addConflict("vault.json", relabeled)
        try provider.addConflict("vault.json", differing)

        let b = try run("B")
        XCTAssertEqual(b.conflicts.map(\.path), ["vault.json"], "only the differing manifest: \(b)")
        let copy = try XCTUnwrap(b.conflicts.first?.remoteCopy)
        XCTAssertEqual(try Data(contentsOf: dir("B").appendingPathComponent(copy)), differing, "kept here")
        XCTAssertEqual(b.merged, ["settings.age"], "\(b)")
        for f in ["vault.json", "settings.age", "sempere-summaries.sealed"] {
            XCTAssertEqual(provider.versions(of: f), [], "\(f): resolved, no version picker")
        }
        try run("A")
        let merged = try XCTUnwrap(try openVault("A").readSharedSettings())
        XCTAssertEqual(merged.value(SettingSlotKey("history.thinAfterDays")), .number(30))
        XCTAssertEqual(merged.value(SettingSlotKey("eraser.mode")), .string("pixel"))
    }

    /// Locked, settings versions wait (unresolved) for an unlocked run.
    func testSettingsVersionsWaitForTheKey() throws {
        _ = try pushed()
        var s = SharedSettings()
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date())
        try openVault("A").writeSharedSettings(s)
        try run("A")
        try provider.addConflict("settings.age", try openVault("A").sealSharedSettings(s))
        let locked = try run("A", vault: .some(nil))
        XCTAssertTrue(locked.skipped.contains { $0.path == "settings.age" && $0.message.contains("unlocked") }, "\(locked)")
        XCTAssertEqual(provider.versions(of: "settings.age").count, 1)
        try run("A")
        XCTAssertEqual(provider.versions(of: "settings.age"), [])
    }

    // MARK: The evicted memory store

    /// `MemoryRemote` in evicted mode really evicts: with no time to wait, a pull is all arrivals.
    func testEvictedMemoryStoreNeedsArrivals() throws {
        let t = TransportUnderTest.evictedMemory()
        _ = try makeVault("A")
        _ = try delta(try openVault("A"), device: devA, t: 0, title: "one")
        var o = SyncOptions(deviceLabel: "A")
        _ = try SyncEngine(directory: dir("A"), vault: try openVault("A"), remote: t.remote,
                           stateURL: tmp.appendingPathComponent("m-A.json"), options: o).run()
        o = SyncOptions(deviceLabel: "B")
        o.firstPullIdentities = [identity]
        o.arrivalWait = 0
        let remote = t.remote as! MemoryRemote
        remote.store.arrivalDelay = 50
        XCTAssertThrowsError(try SyncEngine(directory: dir("B"), vault: nil, remote: remote,
                                            stateURL: tmp.appendingPathComponent("m-B.json"), options: o).run()) {
            XCTAssertEqual($0 as? SyncError, .notDownloaded("vault.json"))
        }
        remote.store.arrivalDelay = 0
        let b = try SyncEngine(directory: dir("B"), vault: nil, remote: remote,
                               stateURL: tmp.appendingPathComponent("m-B.json"), options: o).run()
        XCTAssertTrue(b.errors.isEmpty, "\(b)")
        XCTAssertEqual(try title(try openVault("B")), "one")
    }
}
