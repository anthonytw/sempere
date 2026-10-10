import Age
import Foundation
import XCTest
@testable import Sempere
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
        server.putDirect("settings.age", try Vault.encrypt(junk, to: [identity.recipient]))
        let r = try sync("A", server)
        XCTAssertTrue(r.uploaded.contains("settings.age"), "\(r)")
        XCTAssertEqual(server.file("settings.age"), good)
        // A local copy that does not verify takes the server's.
        try Vault.encrypt(junk, to: [identity.recipient]).write(to: a.sharedSettingsURL)
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
    }

    func testAKeyChangePulledInTheSameRunWaitsForTheNextRun() throws {
        let server = MockDAV()
        let extra = pqIdentity()
        var a = try makeVault("A")
        _ = try a.addRecipient(extra.recipient, label: "extra")
        try write(a, "eraser.mode", .string("pixel"), type: .mac, at: 0)
        try sync("A", server)
        try sync("B", server)
        // B removes the extra key: the secret rotates and settings.age is re-tagged.
        var b = try openVault("B")
        _ = try b.removeRecipient(extra.recipient)
        try sync("B", server)
        let serverCopy = try XCTUnwrap(server.file("settings.age"))
        // A pulls the new vault.json in this run, still holding the old secret: the server's
        // settings.age is not judged (or overwritten) until the next run.
        a = try openVault("A")
        let r = try sync("A", server, vault: .some(a))
        XCTAssertTrue(r.downloaded.contains("vault.json"), "\(r)")
        XCTAssertTrue(r.skipped.contains { $0.path == "settings.age" }, "\(r)")
        XCTAssertEqual(server.file("settings.age"), serverCopy)
        let next = try sync("A", server)
        XCTAssertTrue(next.downloaded.contains("settings.age"), "\(next)")
        XCTAssertEqual(try openVault("A").readSharedSettings()?.value(SettingSlotKey("eraser.mode")), .string("pixel"))
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
