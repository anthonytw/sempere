import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// Store vaults' sync targets (docs/design/device-first-sync.md §2, §8.1; docs/io.md "Sync targets in the
/// app"): the registry the app and `sempere store target` share, and `FolderTargetRun` over a provider's
/// folder (`EvictingFolderProvider`): eviction, conflict versions, a folder that went away, upload-only runs.
final class SyncTargetTests: SyncTestCase {
    private var registry: SyncTargetRegistry { SyncTargetRegistry(root: tmp.appendingPathComponent("store/.sync")) }
    private let vaultA = UUID(), vaultB = UUID()

    // MARK: Registry

    func testRegistryKeepsTargetsPerVault() throws {
        let folder = SyncTarget.folder(tmp.appendingPathComponent("Drive/Notes.sempere"))
        try registry.add(folder, to: vaultA)
        var dav = SyncTarget.webdav("https://nas.example/dav/Notes/", user: "me", name: "nas")
        try registry.add(dav, to: vaultA)
        // The same place twice: refused, by path or by collection (a trailing slash and the host's case aside).
        XCTAssertThrowsError(try registry.add(.folder(tmp.appendingPathComponent("Drive/Notes.sempere/")), to: vaultA)) {
            XCTAssertEqual($0 as? SyncTargetError, .duplicate(folder.id))
        }
        XCTAssertThrowsError(try registry.add(.webdav("https://NAS.example/dav/Notes", user: "me", name: "x"), to: vaultA))
        // Another user is another place; another vault is separate.
        try registry.add(.webdav("https://nas.example/dav/Notes", user: "you", name: "x"), to: vaultA)
        try registry.add(.folder(tmp.appendingPathComponent("Drive/Notes.sempere")), to: vaultB)
        XCTAssertEqual(registry.targets(of: vaultA).count, 3)
        XCTAssertEqual(registry.targets(of: vaultB).count, 1)
        XCTAssertEqual(Set(registry.all().keys), [vaultA, vaultB])

        XCTAssertEqual(try registry.resolve(String(dav.id.uuidString.prefix(8)), of: vaultA).id, dav.id)
        XCTAssertEqual(try registry.resolve("https://nas.example/dav/Notes/", of: vaultA).id, dav.id)
        XCTAssertThrowsError(try registry.resolve("nothing", of: vaultA))

        dav.lastSuccess = Date(timeIntervalSince1970: 1_800_000_000)
        try registry.save(dav, to: vaultA)
        try registry.update(folder.id, of: vaultA) { $0.joined = true }
        XCTAssertEqual(registry.targets(of: vaultA).first { $0.id == dav.id }?.lastSuccess, dav.lastSuccess)
        XCTAssertEqual(registry.targets(of: vaultA).first?.joined, true)

        let state = registry.stateURL(folder.id, of: vaultA)
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state)
        try registry.remove(folder.id, of: vaultA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.deletingLastPathComponent().path))
        XCTAssertEqual(registry.targets(of: vaultA).count, 2)
    }

    /// "Choose Again" starts a target over: its state file and transfers go, its quarantine stays.
    func testResetStateKeepsTheQuarantine() throws {
        let target = try registry.add(.folder(tmp.appendingPathComponent("F")), to: vaultA)
        let state = registry.stateURL(target.id, of: vaultA)
        let quarantine = registry.quarantineDirectory(target.id, of: vaultA)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state)
        try Data("{}".utf8).write(to: SyncState.transfersURL(state))
        try Data("x".utf8).write(to: quarantine.appendingPathComponent("x.age"))
        registry.resetState(target.id, of: vaultA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncState.transfersURL(state).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("x.age").path))
        XCTAssertEqual(registry.targets(of: vaultA).count, 1)
    }

    /// A kind this version does not know (a later transport) is kept, never dropped on a write.
    func testUnknownKindsAreKept() throws {
        try registry.add(SyncTarget(kind: SyncTargetKind(rawValue: "s3"), name: "bucket"), to: vaultA)
        try registry.add(.folder(tmp.appendingPathComponent("F")), to: vaultA)
        XCTAssertEqual(registry.targets(of: vaultA).map(\.kind.rawValue), ["s3", "folder"])
    }

    func testFolderTargetsMustNotOverlapTheStore() throws {
        let store = VaultStore(root: tmp.appendingPathComponent("store"))
        XCTAssertThrowsError(try store.checkFolderTarget(store.root.appendingPathComponent("x")))
        XCTAssertThrowsError(try store.checkFolderTarget(tmp))
        try Data().write(to: tmp.appendingPathComponent("file"))
        XCTAssertThrowsError(try store.checkFolderTarget(tmp.appendingPathComponent("file")))
        XCTAssertNoThrow(try store.checkFolderTarget(tmp.appendingPathComponent("elsewhere/Notes.sempere")))
    }

    /// Review of #108: a backup (`backup.json`, downloaded or an iCloud stand-in) is never a folder target, and a
    /// run refuses one a target was added for before: a sync would write into it and pass deletions on.
    func testABackupIsNeverAFolderTarget() throws {
        let store = VaultStore(root: tmp.appendingPathComponent("store"))
        let backup = tmp.appendingPathComponent("Drive/Notes.sempere")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: backup.appendingPathComponent("backup.json"))
        XCTAssertThrowsError(try store.checkFolderTarget(backup)) { error in
            XCTAssertEqual(error as? SyncTargetError, .isBackup(backup.standardizedFileURL.path))
            XCTAssertTrue("\(error)".contains("restore"), "\(error)")
        }
        XCTAssertThrowsError(try FolderTargetRun.check(backup, stateURL: tmp.appendingPathComponent("state.json"))) { error in
            XCTAssertEqual(error as? FolderTargetError, .isBackup(backup.path))
        }
        let evicted = tmp.appendingPathComponent("Cloud/Notes.sempere")
        try FileManager.default.createDirectory(at: evicted, withIntermediateDirectories: true)
        try Data().write(to: evicted.appendingPathComponent(".backup.json.icloud"))
        XCTAssertThrowsError(try store.checkFolderTarget(evicted))
    }

    /// Review of #109: a folder inside a vault or a backup is never added as a folder target. A backup's `versions/<time>/` holds a `vault.json` of the same vault, which the engine's
    /// same-vault check takes; inside another vault, the copy would land in its write-once folders.
    func testAFolderInsideAVaultOrABackupIsNeverAFolderTarget() throws {
        let store = VaultStore(root: tmp.appendingPathComponent("store"))
        let backup = tmp.appendingPathComponent("Drive/Notes.sempere-backup")
        let version = backup.appendingPathComponent("versions/20261020T101010Z")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: backup.appendingPathComponent("backup.json"))
        try Data("{}".utf8).write(to: version.appendingPathComponent("vault.json"))
        XCTAssertThrowsError(try store.checkFolderTarget(version)) { error in
            XCTAssertEqual(error as? SyncTargetError, .insideVault(version.standardizedFileURL.path, backup.standardizedFileURL.path))
        }
        // Runs look at the folder itself only (review of #113): a target added before keeps working.
        XCTAssertNoThrow(try FolderTargetRun.check(version, stateURL: tmp.appendingPathComponent("state.json")))
        // Inside another vault (its notes/), and below an iCloud stand-in of a vault.json: refused too, not yet made.
        let vault = tmp.appendingPathComponent("Drive/Other.sempere")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data().write(to: vault.appendingPathComponent(".vault.json.icloud"))
        let inside = vault.appendingPathComponent("notes/Mine.sempere")
        XCTAssertThrowsError(try store.checkFolderTarget(inside)) { error in
            XCTAssertEqual(error as? SyncTargetError, .insideVault(inside.standardizedFileURL.path, vault.standardizedFileURL.path))
        }
        XCTAssertEqual(BackupDestination.enclosingHolders(of: inside).map(\.standardizedFileURL.path), [vault.standardizedFileURL.path])
        // Next to them: fine.
        XCTAssertNoThrow(try store.checkFolderTarget(tmp.appendingPathComponent("Drive/Mine.sempere")))
    }

    /// Review of #113: the refusal of a folder inside a vault or a backup is for new targets only, and never counts
    /// this vault's own copy above (a bare copy build 10 synced there from an iPad). A target that worked before, under
    /// an earlier build's backup written straight into a plain folder, keeps syncing.
    func testExistingTargetsUnderAnOldBackupOrTheVaultsOwnCopyKeepSyncing() throws {
        let store = VaultStore(root: tmp.appendingPathComponent("store"))
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "mine", note: UUID())
        // The vault's own bare copy in `junk`, its correct target in `junk/A.sempere`: allowed; another vault's is not.
        let junk = tmp.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        _ = try FolderTargetRun.run(vaultFolder: dir("A"), folder: junk, vault: nil,
                                    stateURL: tmp.appendingPathComponent("bare.json"), twoWay: false)
        XCTAssertNoThrow(try store.checkFolderTarget(junk.appendingPathComponent("A.sempere"), vaultId: a.vaultId))
        XCTAssertThrowsError(try store.checkFolderTarget(junk.appendingPathComponent("A.sempere"), vaultId: UUID()))
        XCTAssertThrowsError(try store.checkFolderTarget(junk.appendingPathComponent("A.sempere")))
        // The iPad's old backup straight in a plain folder, with a target next to it inside: runs go on.
        let pad = tmp.appendingPathComponent("Pad")
        _ = try Backup.run(source: a, to: pad)
        let target = pad.appendingPathComponent("A.sempere")
        for (i, folder) in [target, junk.appendingPathComponent("A.sempere")].enumerated() {
            let report = try FolderTargetRun.run(vaultFolder: dir("A"), folder: folder, vault: try openVault("A"),
                                                 stateURL: tmp.appendingPathComponent("t\(i).json"), twoWay: true)
            XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vault.json").path))
        }
    }

    /// Re-check of #113: the path helpers compare `/private/var/…` and `/var/…` alike, and a target whose stored path
    /// is below the folder its bookmark recorded, with no subfolder, is held (`isMisrecorded`).
    func testMisrecordedTargetsAreToldFromTheirRecord() throws {
        XCTAssertEqual(SyncTarget.subfolder(of: URL(fileURLWithPath: "/private/var/mobile/junk/W.sempere"),
                                            in: URL(fileURLWithPath: "/var/mobile/junk")), "W.sempere")
        XCTAssertNil(SyncTarget.subfolder(of: URL(fileURLWithPath: "/var/mobile/junkyard/x"), in: URL(fileURLWithPath: "/var/mobile/junk")))
        #if canImport(Darwin)
        let junk = tmp.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        let bookmark = try junk.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        XCTAssertTrue(SyncTarget.folder(junk.appendingPathComponent("W.sempere"), bookmark: bookmark).isMisrecorded)
        XCTAssertFalse(SyncTarget.folder(junk.appendingPathComponent("W.sempere"), bookmark: bookmark, subfolder: "W.sempere").isMisrecorded)
        XCTAssertFalse(SyncTarget.folder(junk, bookmark: bookmark).isMisrecorded)
        #endif
        XCTAssertFalse(SyncTarget.folder(tmp.appendingPathComponent("x")).isMisrecorded, "no bookmark: the CLI's own")
    }

    /// TestFlight 1.0.0 (9): a folder target that holds ANOTHER vault (an earlier test vault left in iCloud Drive)
    /// is never written. The engine's `checkSameVault` refuses it (`SyncError.vaultMismatch`) before any write,
    /// two-way and upload-only; a `vault.json` iCloud has evicted is waited for, and one that does not arrive
    /// stops the run (`notDownloaded`) before anything is written too.
    func testAFolderHoldingAnotherVaultIsNeverWritten() throws {
        let other = try makeVault("Other")
        _ = try delta(other, device: devB, t: 0, title: "theirs")
        let folder = tmp.appendingPathComponent("Drive/Other.sempere")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir("Other"), to: folder)
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "mine", note: UUID())
        func listing() throws -> [String] {
            let e = FileManager.default.enumerator(atPath: folder.path)
            return (e?.allObjects as? [String] ?? []).sorted()
        }
        let before = try listing()
        let manifest = try Data(contentsOf: folder.appendingPathComponent("vault.json"))
        for twoWay in [true, false] {
            var o = SyncOptions(deviceLabel: "A")
            o.arrivalWait = 1
            XCTAssertThrowsError(try FolderTargetRun.run(vaultFolder: dir("A"), folder: folder, vault: try openVault("A"),
                                                         stateURL: tmp.appendingPathComponent("st-\(twoWay).json"),
                                                         twoWay: twoWay, options: o)) { error in
                guard case SyncError.vaultMismatch = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try listing(), before, "nothing written (two-way: \(twoWay))")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("vault.json")), manifest)
        }
        // The engine alone (no FolderTargetRun around it) refuses it the same way.
        let engine = SyncEngine(directory: dir("A"), vault: try openVault("A"), remote: FolderRemote(root: folder),
                                stateURL: tmp.appendingPathComponent("st-engine.json"), options: SyncOptions(deviceLabel: "A"))
        XCTAssertThrowsError(try engine.run()) { error in
            guard case SyncError.vaultMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try listing(), before)
        // Evicted in iCloud Drive (only `.vault.json.icloud`): refused all the same, by the engine once it arrives.
        let p = EvictingFolderProvider(root: folder, cloud: tmp.appendingPathComponent("cloud-other"))
        try p.evict("vault.json", as: .standIn)
        p.arrivalDelay = 10_000
        var o = SyncOptions(deviceLabel: "A")
        o.arrivalWait = 0.5
        XCTAssertThrowsError(try FolderTargetRun.run(vaultFolder: dir("A"), folder: folder, provider: p, vault: try openVault("A"),
                                                     stateURL: tmp.appendingPathComponent("st-evicted.json"), twoWay: true,
                                                     options: o)) { error in
            guard case SyncError.notDownloaded = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(try listing().contains { $0.hasPrefix("notes/") && !before.contains($0) }, "no note of A written")
    }

    // MARK: Runs over a provider's folder

    private var base: URL { tmp.appendingPathComponent("icloud/Notes.sempere") }

    private func provider() -> EvictingFolderProvider {
        EvictingFolderProvider(root: base, cloud: tmp.appendingPathComponent("cloud"))
    }

    @discardableResult
    private func run(_ name: String, _ p: EvictingFolderProvider, twoWay: Bool = true,
                     _ edit: (inout SyncOptions) -> Void = { _ in }) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        var o = SyncOptions(deviceLabel: name)
        o.firstPullIdentities = [identity]
        o.arrivalWait = 2
        edit(&o)
        return try FolderTargetRun.run(vaultFolder: dir(name), folder: base, provider: p, vault: exists ? try openVault(name) : nil,
                                       stateURL: registry.stateURL(name == "A" ? vaultA : vaultB, of: vaultA),
                                       twoWay: twoWay, options: o)
    }

    private func rel(_ r: Revision) -> String { "notes/\(r.noteId.uuidString.lowercased())/\(r.name.filename)" }

    /// Files a provider evicted while another device's run was going are arriving, never missing: asked for,
    /// left for a later run when they do not come in time (no quarantine, nothing deleted), then taken.
    func testEvictionDuringRunsIsArrivingNeverMissing() throws {
        let p = provider()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try run("A", p).errors.isEmpty)
        XCTAssertTrue(try run("B", p).errors.isEmpty)
        let r2 = try delta(a, device: devA, t: 10, title: "two")
        try run("A", p)
        p.arrivalDelay = 10_000
        try p.evict(rel(r2), as: .dataless)
        let b = try run("B", p) { $0.arrivalWait = 0.3 }
        XCTAssertEqual(b.arriving.map(\.path), [rel(r2)], "\(b)")
        XCTAssertTrue(b.quarantined.isEmpty && b.deleted.isEmpty && b.errors.isEmpty, "\(b)")
        XCTAssertTrue(try run("A", p).deleted.isEmpty, "A's file stays in the folder")
        p.arrivalDelay = 0
        XCTAssertEqual(try run("B", p).downloaded, [rel(r2)])
        XCTAssertEqual(try title(try openVault("B")), "two")
    }

    /// A provider's conflict copy of a mutable file (iCloud keeps both) is merged or kept and resolved: no
    /// version picker ever reaches the user, and the store copy gets the merge.
    func testConflictCopyInTheTargetIsMergedAndResolved() throws {
        let p = provider()
        _ = try makeVault("A")
        try run("A", p)
        try run("B", p)
        var theirs = try XCTUnwrap(try openVault("B").readSharedSettings() ?? SharedSettings())
        try theirs.set(SettingSlotKey("history.thinAfterDays"), to: .number(30), type: .mac, now: Date(timeIntervalSince1970: 1_800_000_100))
        var mine = SharedSettings()
        try mine.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: Date(timeIntervalSince1970: 1_800_000_000))
        try openVault("A").writeSharedSettings(mine)
        try run("A", p)
        _ = try p.addConflict("settings.age", try openVault("B").sealSharedSettings(theirs))
        let a = try run("A", p)
        XCTAssertEqual(a.merged, ["settings.age"], "\(a)")
        XCTAssertEqual(p.versions(of: "settings.age"), [])
        let merged = try XCTUnwrap(try openVault("A").readSharedSettings())
        XCTAssertEqual(merged.value(SettingSlotKey("history.thinAfterDays")), .number(30))
        XCTAssertEqual(merged.value(SettingSlotKey("eraser.mode")), .string("pixel"))
    }

    /// Upload-only (a closed or locked vault in the app): the folder gets what the vault has; nothing from
    /// the folder is written into the vault.
    func testUploadOnlyNeverWritesTheVault() throws {
        let p = provider()
        let a = try makeVault("A")
        try run("A", p)
        try run("B", p)
        _ = try delta(try openVault("B"), device: devB, t: 5, title: "from B")
        try run("B", p)
        let mine = try delta(a, device: devA, t: 6, title: "from A", note: UUID())
        let before = try fileNames(try openVault("A"))
        let up = try run("A", p, twoWay: false)
        XCTAssertTrue(up.downloaded.isEmpty, "\(up)")
        XCTAssertTrue(up.uploaded.contains(rel(mine)), "\(up)")
        XCTAssertEqual(try fileNames(try openVault("A")), before)
    }

    /// A folder synced before that is gone is not recreated; one whose parent is gone cannot be reached now.
    func testAFolderThatWentAway() throws {
        let p = provider()
        _ = try makeVault("A")
        try run("A", p)
        try FileManager.default.removeItem(at: base)
        XCTAssertThrowsError(try run("A", p)) { XCTAssertEqual($0 as? FolderTargetError, .missing(self.base.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        try FileManager.default.removeItem(at: base.deletingLastPathComponent())
        XCTAssertThrowsError(try run("A", p)) { XCTAssertEqual($0 as? FolderTargetError, .unavailable(self.base.path)) }
        XCTAssertNoThrow(try openVault("A"))
    }

    // MARK: A target iCloud holds as a package, evicted whole (review of #115, F1)

    /// The vault folder earlier builds made a package, which iCloud Drive evicts whole (Files ▸ "Remove Download"):
    /// only `.Notes.sempere.icloud` is left. A run asks for it, reports it arriving and writes nothing (never an empty
    /// folder beside the package, which iCloud would keep as a second copy); a later run, once it is back, syncs.
    func testATargetEvictedWholeIsArrivingAndNeverSplit() throws {
        let p = provider()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        XCTAssertTrue(try run("A", p).errors.isEmpty)
        p.arrivalDelay = 100_000
        try p.evictFolder("", as: .standIn)
        let later = try delta(a, device: devA, t: 10, title: "two", note: UUID())
        let r = try run("A", p) { $0.arrivalWait = 0.2 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "no folder made beside the package")
        XCTAssertEqual(r.arriving.map(\.path), ["/"], "\(r)")
        XCTAssertTrue(r.uploaded.isEmpty && r.downloaded.isEmpty && r.deleted.isEmpty && r.errors.isEmpty, "\(r)")
        XCTAssertTrue(p.requested.contains(""), "the package was asked for")
        // Upload-only runs (the vault closed here) keep the rule too.
        XCTAssertTrue(try run("A", p, twoWay: false).uploaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        // Back: the next run syncs into it, and there is one copy.
        p.arrivalDelay = 0
        let healed = try run("A", p)
        XCTAssertTrue(healed.uploaded.contains(rel(later)), "\(healed)")
        XCTAssertTrue(healed.arriving.isEmpty && healed.errors.isEmpty, "\(healed)")
        XCTAssertNil(p.splitCopy(of: ""))
        XCTAssertTrue(try run("B", p).errors.isEmpty)
        XCTAssertEqual(try fileNames(try openVault("B")), try fileNames(try openVault("A")))
    }

    /// The same package not downloaded yet when a device adds it as a target (no sync state here): still never made
    /// again beside it. Before the fix this run made `Notes.sempere` and uploaded the vault, and iCloud kept the
    /// package as `Notes 2.sempere`.
    func testANewTargetEvictedWholeIsNeverSplit() throws {
        let p = provider()
        _ = try makeVault("A")
        try run("A", p)
        p.arrivalDelay = 100_000
        try p.evictFolder("", as: .standIn)
        let fresh = tmp.appendingPathComponent("fresh-state/state.json")
        let r = try FolderTargetRun.run(vaultFolder: dir("A"), folder: base, provider: p, vault: try openVault("A"),
                                        stateURL: fresh, twoWay: true, options: { var o = SyncOptions(deviceLabel: "A"); o.arrivalWait = 0.2; return o }())
        XCTAssertFalse(r.arriving.isEmpty, "\(r)")
        XCTAssertTrue(r.uploaded.isEmpty, "\(r)")
        p.arrivalDelay = 0
        XCTAssertTrue(p.isAway(""))
        _ = try FolderTargetRun.run(vaultFolder: dir("A"), folder: base, provider: p, vault: try openVault("A"),
                                    stateURL: fresh, twoWay: true, options: SyncOptions(deviceLabel: "A"))
        XCTAssertFalse(p.isAway(""))
        XCTAssertNil(p.splitCopy(of: ""), "one copy of the vault")
    }

    /// A package kept under its own name but not downloaded (a dataless folder): arriving too, then synced.
    func testATargetHeldAsADatalessPackageIsArriving() throws {
        let p = provider()
        let a = try makeVault("A")
        try run("A", p)
        p.arrivalDelay = 100_000
        try p.evictFolder("", as: .dataless)
        let later = try delta(a, device: devA, t: 10, title: "two", note: UUID())
        let r = try run("A", p) { $0.arrivalWait = 0.2 }
        XCTAssertEqual(r.arriving.map(\.path), ["/"], "\(r)")
        XCTAssertTrue(r.uploaded.isEmpty && r.errors.isEmpty, "\(r)")
        p.arrivalDelay = 0
        XCTAssertTrue(try run("A", p).uploaded.contains(rel(later)))
    }

    /// The rule for a folder that is not there is one (`FolderRemote.absentBase`): the pre-check and the engine agree.
    func testTheAbsentBaseRule() throws {
        XCTAssertNil(FolderRemote.absentBase(base, syncedBefore: false), "never synced: the first run makes it")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(FolderRemote.absentBase(base, syncedBefore: true), .refused(.missing(base.path)))
        let standIn = base.deletingLastPathComponent().appendingPathComponent(".Notes.sempere.icloud")
        try Data("x".utf8).write(to: standIn)
        XCTAssertEqual(FolderRemote.absentBase(base, syncedBefore: true), .arriving)
        XCTAssertEqual(FolderRemote.absentBase(base, syncedBefore: false), .arriving)
        XCTAssertThrowsError(try FolderRemote(root: base, provider: PlainFolder()).createBase()) {
            XCTAssertEqual($0 as? FolderRemoteError, .unavailable(FolderRemote(root: base).root.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertNil(FolderRemote.absentBase(base, syncedBefore: true))
    }

    /// The engine's rule holds on any transport whose base a provider evicts whole (`MemoryStore.evictPackage`).
    func testABaseEvictedWholeIsArrivingOnAnyTransport() throws {
        let store = MemoryStore(name: "pkg")
        let remote = MemoryRemote(store: store, base: ["Notes.sempere"])
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        func go() throws -> SyncReport {
            var o = SyncOptions(deviceLabel: "A")
            o.arrivalWait = 0.2
            return try SyncEngine(directory: dir("A"), vault: try openVault("A"), remote: remote,
                                  stateURL: tmp.appendingPathComponent("state-memory.json"), options: o).run()
        }
        XCTAssertTrue(try go().errors.isEmpty)
        store.arrivalDelay = 100_000
        store.evictPackage(["Notes.sempere"])
        let later = try delta(a, device: devA, t: 10, title: "two", note: UUID())
        let r = try go()
        XCTAssertEqual(r.arriving.map(\.path), ["/"], "\(r)")
        XCTAssertTrue(r.uploaded.isEmpty && r.errors.isEmpty, "\(r)")
        XCTAssertTrue(store.filePaths(under: ["Notes.sempere"]).isEmpty, "nothing made beside the package")
        store.arrivalDelay = 0
        let healed = try go()
        XCTAssertTrue(healed.uploaded.contains(rel(later)), "\(healed)")
        XCTAssertNil(store.splitCopy(of: ["Notes.sempere"]))
    }

    /// Review of #119 (1): a re-encryption's claim makes a target's base only by the same rule as a run. A folder
    /// synced before and deleted is not made again by the claim (nor one present only as its stand-in).
    func testAReencryptionClaimNeverMakesAGoneTargetAgain() throws {
        let p = provider()
        _ = try makeVault("A")
        try run("A", p)
        let state = registry.stateURL(vaultA, of: vaultA)
        XCTAssertTrue(FolderTargetRun.syncedBefore(stateURL: state))
        try FileManager.default.removeItem(at: base)
        let target = ReencryptCoordinator.Target(name: "folder", remote: FolderRemote(root: base, provider: p),
                                                 syncedBefore: FolderTargetRun.syncedBefore(stateURL: state))
        var seen = ReencryptCoordinator.ClaimSightings()
        let out = ReencryptCoordinator.claim(Data("journal".utf8), vault: try openVault("A"), on: [target], seen: &seen)
        XCTAssertNotEqual(out["folder"], .claimed, "\(out)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "the claim made the folder again")
        // Only its stand-in there: not made either, whatever the state says.
        try Data("x".utf8).write(to: base.deletingLastPathComponent().appendingPathComponent(".Notes.sempere.icloud"))
        let fresh = ReencryptCoordinator.Target(name: "folder", remote: FolderRemote(root: base, provider: p))
        let again = ReencryptCoordinator.claim(Data("journal".utf8), vault: try openVault("A"), on: [fresh], seen: &seen)
        XCTAssertNotEqual(again["folder"], .claimed, "\(again)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    /// Review of #119 (2): "synced before" is what the state holds (`vault.json` recorded), never a state file alone.
    /// A target that never synced and found only a stand-in saves no state; when the stand-in goes (the package
    /// deleted elsewhere), the next run is a first run (it makes the folder), never "the folder is gone".
    func testAStandInSeenBeforeAnySyncDoesNotCountAsSyncedBefore() throws {
        let p = provider()
        _ = try makeVault("A")
        let standIn = base.deletingLastPathComponent().appendingPathComponent(".Notes.sempere.icloud")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: standIn)
        let state = registry.stateURL(vaultA, of: vaultA)
        let r = try run("A", p) { $0.arrivalWait = 0.1 }
        XCTAssertEqual(r.arriving.map(\.path), ["/"], "\(r)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "no state saved for a target that never synced")
        XCTAssertFalse(FolderTargetRun.syncedBefore(stateURL: state))
        try FileManager.default.removeItem(at: standIn)
        let first = try run("A", p)
        XCTAssertTrue(first.uploaded.contains("vault.json"), "\(first)")
        XCTAssertTrue(FolderTargetRun.syncedBefore(stateURL: state))
        // A state file that records no sync (an early failure) is not "synced before" either.
        let empty = tmp.appendingPathComponent("empty-state.json")
        try SyncState().save(empty)
        XCTAssertFalse(FolderTargetRun.syncedBefore(stateURL: empty))
    }

    /// Review of #119 re-check: a state that records files or notes but no `vault.json` is synced before.
    func testAStateWithFilesButNoManifestIsSyncedBefore() throws {
        let url = tmp.appendingPathComponent("files-state.json")
        var s = SyncState()
        s.files["7e57c0de-0000-4000-8000-000000000001/x.d.age"] = .init()
        try s.save(url)
        XCTAssertTrue(FolderTargetRun.syncedBefore(stateURL: url))
    }

    /// Review of #119 re-check: a state file that cannot be read (corrupt here) counts as synced before, so a deleted
    /// target folder is refused, never made again, by the pre-check and by the engine alike.
    func testACorruptStateAndADeletedFolderAreRefused() throws {
        let p = provider()
        _ = try makeVault("A")
        try run("A", p)
        let state = registry.stateURL(vaultA, of: vaultA)
        try Data("{ not json".utf8).write(to: state)
        XCTAssertTrue(FolderTargetRun.syncedBefore(stateURL: state))
        try FileManager.default.removeItem(at: base)
        XCTAssertThrowsError(try run("A", p)) { XCTAssertEqual($0 as? FolderTargetError, .missing(self.base.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        // The engine on its own (`sempere sync folder`): the same.
        let engine = SyncEngine(directory: dir("A"), vault: try openVault("A"), remote: FolderRemote(root: base, provider: p),
                                stateURL: state, options: SyncOptions(deviceLabel: "A"))
        XCTAssertThrowsError(try engine.run()) {
            XCTAssertEqual($0 as? FolderTargetError, .missing(FolderRemote(root: self.base).root.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }
}
