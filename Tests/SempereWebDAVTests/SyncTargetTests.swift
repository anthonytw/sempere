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
}
