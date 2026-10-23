import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// `settings.age` over WebDAV (docs/settings-sync.md §8): merged per key when
/// both sides changed, never replaced by a copy that does not verify.
final class SettingsSyncTests: SyncTestCase {
    func write(_ vault: Vault, _ key: String, _ value: JSONValue, type: SettingsDeviceType, at ms: Int64) throws {
        var s = try vault.readSharedSettings() ?? SharedSettings()
        try s.set(SettingSlotKey(key), to: value, type: type, now: Date(timeIntervalSince1970: Double(baseMillis + ms) / 1000))
        try vault.writeSharedSettings(s)
    }

    func testBothSidesChangedMergePerKey() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        XCTAssertTrue(try sync("A", server).uploaded.contains("settings.age"))
        let pull = try sync("B", server)
        XCTAssertTrue(pull.downloaded.contains("settings.age"), "\(pull)")
        let b = try openVault("B")
        XCTAssertEqual(try b.readSharedSettings(), try a.readSharedSettings())

        // Different keys on each side.
        try write(a, "history.thinAfterDays", .number(90), type: .mac, at: 100)
        try write(b, "photos.removeMetadata", .bool(false), type: .ipad, at: 200)
        try sync("A", server)
        let merge = try sync("B", server)
        XCTAssertEqual(merge.merged, ["settings.age"])
        XCTAssertTrue(merge.uploaded.contains("settings.age"))
        XCTAssertTrue(merge.conflicts.isEmpty)
        try sync("A", server)
        let sa = try XCTUnwrap(try openVault("A").readSharedSettings())
        XCTAssertEqual(sa, try openVault("B").readSharedSettings())
        XCTAssertEqual(sa.value(SettingSlotKey("history.thinAfterDays")), .number(90))
        XCTAssertEqual(sa.value(SettingSlotKey("photos.removeMetadata")), .bool(false))
        XCTAssertEqual(sa.value(SettingSlotKey("eraser.mode")), .string("pixel"))
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    /// A merge is uploaded over a weak ETag too (never sent in `If-Match`).
    func testMergeUploadsOverAWeakETag() throws {
        let server = MockDAV()
        server.weakFileETags = true
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        try sync("A", server); try sync("B", server)
        let b = try openVault("B")
        try write(a, "history.thinAfterDays", .number(90), type: .mac, at: 100)
        try write(b, "photos.removeMetadata", .bool(false), type: .ipad, at: 200)
        try sync("A", server)
        let merge = try sync("B", server)
        XCTAssertEqual(merge.merged, ["settings.age"])
        XCTAssertTrue(merge.uploaded.contains("settings.age"), "\(merge)")
        XCTAssertEqual(server.file("settings.age"), try Data(contentsOf: dir("B").appendingPathComponent("settings.age")))
    }

    private func pushKeeping(_ name: String, _ server: MockDAV, locked: Bool = false) throws -> SyncReport {
        var o = SyncOptions(deviceLabel: name)
        o.pushOnly = true
        o.keepServerChanges = true
        let vault = locked ? try Vault.open(at: dir(name)) : try openVault(name)
        return try SyncEngine(directory: dir(name), vault: vault, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    /// Push-only with `keepServerChanges` (the app's local copy): a
    /// settings.age another device changed is merged with this device's
    /// and uploaded, never kept as a device-list conflict, and nothing is
    /// written locally.
    func testPushOnlyMergesASettingsFileChangedElsewhere() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        XCTAssertTrue(try pushKeeping("A", server).errors.isEmpty)
        try sync("B", server)
        try write(try openVault("B"), "photos.removeMetadata", .bool(false), type: .ipad, at: 100)
        XCTAssertTrue(try sync("B", server).uploaded.contains("settings.age"))

        try write(a, "history.thinAfterDays", .number(90), type: .mac, at: 200)
        let localBefore = try Data(contentsOf: a.sharedSettingsURL)
        let r = try pushKeeping("A", server)
        XCTAssertTrue(r.conflicts.isEmpty, "\(r)")
        XCTAssertEqual(WebDAVSyncProblem.from(report: r), [])
        XCTAssertTrue(r.uploaded.contains("settings.age"), "\(r)")
        XCTAssertEqual(try Data(contentsOf: a.sharedSettingsURL), localBefore, "nothing written locally")
        let onServer = try a.openSharedSettings(try XCTUnwrap(server.file("settings.age"))).settings
        XCTAssertEqual(onServer.value(SettingSlotKey("history.thinAfterDays")), .number(90))
        XCTAssertEqual(onServer.value(SettingSlotKey("photos.removeMetadata")), .bool(false))
        XCTAssertEqual(onServer.value(SettingSlotKey("eraser.mode")), .string("pixel"))
        XCTAssertTrue(try pushKeeping("A", server).isEmpty)

        // Locked, the local copy is uploaded as the docs say (it cannot be merged).
        try write(try openVault("B"), "eraser.mode", .string("object"), type: .ipad, at: 300)
        try sync("B", server)
        let locked = try pushKeeping("A", server, locked: true)
        XCTAssertTrue(locked.conflicts.isEmpty, "\(locked)")
        XCTAssertEqual(server.file("settings.age"), localBefore)
    }

    func testLockedFallsBackToAConflictCopy() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        try sync("A", server)
        try sync("B", server)
        try write(a, "eraser.mode", .string("object"), type: .mac, at: 100)
        try write(try openVault("B"), "photos.removeMetadata", .bool(false), type: .ipad, at: 200)
        try sync("A", server)
        let locked = try sync("B", server, vault: .some(nil))
        XCTAssertEqual(locked.conflicts.map(\.path), ["settings.age"])
        let copy = try XCTUnwrap(locked.conflicts.first?.remoteCopy)
        XCTAssertTrue(copy.hasPrefix("settings.conflict-") && copy.hasSuffix(".age"), copy)
    }

    func testACopyThatDoesNotVerifyNeverReplacesOneThatDoes() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        try sync("A", server)
        let good = try XCTUnwrap(server.file("settings.age"))
        // A server copy tagged under another secret (or junk): replaced by the local one.
        let junk = try BodyFraming.frame(json: Data("{}".utf8), noteId: "settings", filename: "settings.age", secret: .random())
        server.putDirect("settings.age", try Vault.encrypt(junk, to: [try a.vaultRecipient()]))
        let r = try sync("A", server)
        XCTAssertTrue(r.uploaded.contains("settings.age"), "\(r)")
        XCTAssertEqual(server.file("settings.age"), good)
        // A local copy that does not verify takes the server's.
        try Vault.encrypt(junk, to: [try a.vaultRecipient()]).write(to: a.sharedSettingsURL)
        let back = try sync("A", server)
        XCTAssertTrue(back.downloaded.contains("settings.age"), "\(back)")
        XCTAssertEqual(try openVault("A").readSharedSettings()?.value(SettingSlotKey("eraser.mode")), .string("pixel"))
    }

    func testAFileNeedingANewerReaderIsMirroredNeverMerged() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        try sync("A", server)
        try sync("B", server)
        // A newer app on B writes a file this version may not read.
        var later = SharedSettings(schemaVersion: 9, minReaderVersion: 9)
        later.slots[SettingSlotKey("eraser.mode")] = SettingSlot(value: .string("object"), meta: nil)
        try openVault("B").writeSharedSettings(later)
        let newer = try Data(contentsOf: dir("B").appendingPathComponent("settings.age"))
        XCTAssertTrue(try sync("B", server).uploaded.contains("settings.age"))
        XCTAssertEqual(server.file("settings.age"), newer, "byte for byte")
        // A (this version) has an edit of its own: the newer file is mirrored over it, not merged.
        try write(a, "photos.removeMetadata", .bool(false), type: .mac, at: 100)
        let r = try sync("A", server)
        XCTAssertTrue(r.downloaded.contains("settings.age"), "\(r)")
        XCTAssertTrue(r.merged.isEmpty)
        XCTAssertEqual(try Data(contentsOf: a.sharedSettingsURL), newer)
        XCTAssertEqual(server.file("settings.age"), newer)
        XCTAssertThrowsError(try openVault("A").readSharedSettings())
        // Both sides then hold different files that need a newer reader: the keep-both rule, run after run,
        // never an error (the server's copy is read before the write lock and handed to the fallback).
        var laterB = SharedSettings(schemaVersion: 9, minReaderVersion: 9)
        laterB.slots[SettingSlotKey("eraser.mode")] = SettingSlot(value: .string("tip"), meta: nil)
        try openVault("B").writeSharedSettings(laterB)
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        var laterA = SharedSettings(schemaVersion: 9, minReaderVersion: 9)
        laterA.slots[SettingSlotKey("eraser.mode")] = SettingSlot(value: .string("ink"), meta: nil)
        try openVault("A").writeSharedSettings(laterA)
        for _ in 0..<2 {
            let both = try sync("A", server)
            XCTAssertTrue(both.errors.isEmpty, "\(both)")
        }
    }

    func testDryRunChangesNothing() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        try sync("A", server)
        try sync("B", server)
        try write(a, "history.thinAfterDays", .number(90), type: .mac, at: 100)
        try write(try openVault("B"), "photos.removeMetadata", .bool(false), type: .ipad, at: 200)
        try sync("A", server)
        let before = try Data(contentsOf: dir("B").appendingPathComponent("settings.age"))
        let serverBefore = server.file("settings.age")
        let dry = try sync("B", server, dryRun: true)
        XCTAssertEqual(dry.merged, ["settings.age"])
        XCTAssertEqual(try Data(contentsOf: dir("B").appendingPathComponent("settings.age")), before)
        XCTAssertEqual(server.file("settings.age"), serverBefore)
    }
}
