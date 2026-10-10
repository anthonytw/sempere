import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere settings` (docs/settings-sync.md §7).
final class CLISettingsTests: CLITestCase {
    func base(_ v: (vault: Vault, identity: NativeIdentity, keyPath: String)) -> [String] {
        ["--vault", v.vault.url.path, "--identity", v.keyPath]
    }

    func testListGetSetResetWithJSON() throws {
        let v = try makeVault()
        let list = try cli(["settings", "list", "--json"] + base(v))
        XCTAssertEqual(list.status, 0, list.err)
        let listing = try XCTUnwrap(list.json as? [String: Any])
        XCTAssertEqual(listing["schemaVersion"] as? Int, 1)
        XCTAssertEqual(listing["minReaderVersion"] as? Int, 1)
        let rows = try XCTUnwrap(listing["settings"] as? [[String: Any]])
        XCTAssertEqual(rows.count, SharedSettingsCatalog.specs.count)
        XCTAssertTrue(rows.allSatisfy { $0["source"] as? String == "default" })
        XCTAssertFalse(list.out.contains("$meta"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.vault.sharedSettingsURL.path), "reading writes nothing")

        let set = try cli(["settings", "set", "photos.removeMetadata", "off", "--json"] + base(v))
        XCTAssertEqual(set.status, 0, set.err)
        XCTAssertEqual((set.json as? [String: Any])?["value"] as? Bool, false)
        let get = try cli(["settings", "get", "photos.removeMetadata"] + base(v))
        XCTAssertEqual(get.out.trimmingCharacters(in: .whitespacesAndNewlines), "false")
        let getJSON = try cli(["settings", "get", "photos.removeMetadata", "--json"] + base(v))
        XCTAssertEqual((getJSON.json as? [String: Any])?["source"] as? String, "top")

        // The CLI records no device type in $meta.
        let stored = try XCTUnwrap(try v.vault.readSharedSettings())
        XCTAssertNil(stored.slots[SettingSlotKey("photos.removeMetadata")]?.meta?.type)
        XCTAssertNotNil(stored.slots[SettingSlotKey("photos.removeMetadata")]?.meta)

        XCTAssertEqual(try cli(["settings", "reset", "photos.removeMetadata"] + base(v)).status, 0)
        let after = try cli(["settings", "get", "photos.removeMetadata", "--json"] + base(v))
        XCTAssertEqual((after.json as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual((after.json as? [String: Any])?["source"] as? String, "default")
        let reset = try XCTUnwrap(try v.vault.readSharedSettings()?.slots[SettingSlotKey("photos.removeMetadata")])
        XCTAssertNil(reset.value)
        XCTAssertNotNil(reset.meta, "a reset is recorded")
    }

    func testTypeBlocks() throws {
        let v = try makeVault()
        XCTAssertEqual(try cli(["settings", "set", "eraser.mode", "pixel", "--type", "mac"] + base(v)).status, 0)
        let mac = try cli(["settings", "get", "eraser.mode", "--type", "mac", "--json"] + base(v))
        XCTAssertEqual((mac.json as? [String: Any])?["value"] as? String, "pixel")
        XCTAssertEqual((mac.json as? [String: Any])?["source"] as? String, "block")
        XCTAssertEqual(try cli(["settings", "get", "eraser.mode", "--type", "ipad"] + base(v)).out
            .trimmingCharacters(in: .whitespacesAndNewlines), "\"object\"")
        // --type lists only what that kind of device uses.
        let ipad = try XCTUnwrap(try cli(["settings", "list", "--type", "ipad", "--json"] + base(v)).json as? [String: Any])
        let keys = (ipad["settings"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        XCTAssertFalse(keys.contains("mouse.smoothing"))
        XCTAssertTrue(keys.contains("quickCapture.notebook"))
        let all = try XCTUnwrap(try cli(["settings", "list", "--all", "--json"] + base(v)).json as? [String: Any])
        XCTAssertEqual((all["others"] as? [[String: Any]])?.first?["block"] as? String, "mac")
        // Reset in the block: the top level applies again.
        XCTAssertEqual(try cli(["settings", "reset", "eraser.mode", "--type", "mac"] + base(v)).status, 0)
        let back = try cli(["settings", "get", "eraser.mode", "--type", "mac", "--json"] + base(v))
        XCTAssertEqual((back.json as? [String: Any])?["source"] as? String, "default")
        XCTAssertEqual(try cli(["settings", "list", "--type", "watch"] + base(v)).status, 2)
    }

    func testValidationErrors() throws {
        let v = try makeVault()
        XCTAssertEqual(try cli(["settings", "set", "no.such.key", "1"] + base(v)).status, 2)
        let bad = try cli(["settings", "set", "eraser.objectRadius", "15"] + base(v))
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.err.contains("4, 8, 16, 32"), bad.err)
        XCTAssertEqual(try cli(["settings", "set", "newNote.titlePattern", "'open"] + base(v)).status, 2)
        XCTAssertEqual(try cli(["settings", "set", "editor.defaultPaper", #"{"kind":"grid","spacing":30}"#] + base(v)).status, 0)
        let paper = try cli(["settings", "get", "editor.defaultPaper", "--json"] + base(v))
        XCTAssertEqual(((paper.json as? [String: Any])?["value"] as? [String: Any])?["spacing"] as? Double, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("never")))
    }

    func testUnknownKeysAreKeptAndAnotherDevicesWritesMerged() throws {
        let v = try makeVault()
        var other = SharedSettings()
        try other.set(SettingSlotKey("future.key"), to: .string("kept"), type: .ipad, now: Date())
        try other.set(SettingSlotKey("eraser.mode", type: .ipad), to: .string("pixel"), type: .ipad, now: Date())
        other.extra["$note"] = .string("hand")
        try v.vault.writeSharedSettings(other)
        XCTAssertEqual(try cli(["settings", "set", "history.thinAfterDays", "90"] + base(v)).status, 0)
        let s = try XCTUnwrap(try v.vault.readSharedSettings())
        XCTAssertEqual(s.slots[SettingSlotKey("future.key")], other.slots[SettingSlotKey("future.key")])
        XCTAssertEqual(s.value(SettingSlotKey("eraser.mode", type: .ipad)), .string("pixel"))
        XCTAssertEqual(s.extra["$note"], .string("hand"))
        XCTAssertEqual(s.value(SettingSlotKey("history.thinAfterDays")), .number(90))
        let get = try cli(["settings", "get", "future.key"] + base(v))
        XCTAssertEqual(get.out.trimmingCharacters(in: .whitespacesAndNewlines), "\"kept\"")
        let all = try cli(["settings", "list", "--all"] + base(v))
        XCTAssertTrue(all.out.contains("future.key"), all.out)
        XCTAssertTrue(all.out.contains("unknown"), all.out)
    }

    /// An "editor" script that replaces the file with `content` (or fails).
    func editor(_ content: String?, name: String = "editor.sh") throws -> String {
        let script = path(name)
        let body: String
        if let content {
            let payload = path(name + ".json")
            try content.write(toFile: payload, atomically: true, encoding: .utf8)
            body = "#!/bin/sh\ncp \"$1\" \"\(path(name + ".seen"))\"\ncat \"\(payload)\" > \"$1\"\n"
        } else {
            body = "#!/bin/sh\nexit 3\n"
        }
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return script
    }

    func testEditValidatesAndRecordsChangedKeys() throws {
        let v = try makeVault()
        XCTAssertEqual(try cli(["settings", "set", "mouse.smoothing", "strong"] + base(v)).status, 0)
        let before = try XCTUnwrap(try v.vault.readSharedSettings())
        let edited = """
        { "$schemaVersion": 1, "$minReaderVersion": 1, "mouse.smoothing": "strong",
          "newNote.titleFormat": "weekday", "[ipad]": { "editor.keepScreenOn": true }, "my.own": 1 }
        """
        // A private temporary folder, so the leftover check below sees only this run's files.
        let tmpdir = tmp.appendingPathComponent("tmpdir", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        let r = try cli(["settings", "edit", "--json"] + base(v),
                        env: ["EDITOR": try editor(edited), "VISUAL": "", "TMPDIR": tmpdir.path + "/"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(Set((r.json as? [String: Any])?["changed"] as? [String] ?? []),
                       ["newNote.titleFormat", "[ipad] editor.keepScreenOn", "my.own"])
        // The editor saw the settings without $meta.
        let seen = try String(contentsOfFile: path("editor.sh.seen"), encoding: .utf8)
        XCTAssertTrue(seen.contains("mouse.smoothing"))
        XCTAssertFalse(seen.contains("$meta"))
        let s = try XCTUnwrap(try v.vault.readSharedSettings())
        XCTAssertEqual(s.value(SettingSlotKey("newNote.titleFormat")), .string("weekday"))
        XCTAssertNotNil(s.slots[SettingSlotKey("newNote.titleFormat")]?.meta)
        XCTAssertEqual(s.slots[SettingSlotKey("mouse.smoothing")], before.slots[SettingSlotKey("mouse.smoothing")], "unchanged key keeps its $meta")
        // No plaintext copy is left behind.
        let used = try FileManager.default.contentsOfDirectory(atPath: tmpdir.path)
        XCTAssertEqual(used.filter { $0.hasPrefix("sempere-settings-") }, [])
    }

    func testEditRefusesInvalidResultsAndWritesNothing() throws {
        let v = try makeVault()
        XCTAssertEqual(try cli(["settings", "set", "mouse.smoothing", "strong"] + base(v)).status, 0)
        let original = try Data(contentsOf: v.vault.sharedSettingsURL)
        for (i, bad) in [#"{ "$schemaVersion": 1, "$minReaderVersion": 1, "mouse.smoothing": "max" }"#,
                         "not json", #"{ "mouse.smoothing": "off" }"#,
                         #"{ "$schemaVersion": 1, "$minReaderVersion": 1, "$meta": { "a": { "modified": 1 } }, "a": 1 }"#].enumerated() {
            let r = try cli(["settings", "edit"] + base(v), env: ["EDITOR": try editor(bad, name: "e\(i).sh")])
            XCTAssertEqual(r.status, 1, "\(bad): \(r.err)")
            XCTAssertTrue(r.err.contains("nothing was written"), r.err)
        }
        let failing = try cli(["settings", "edit"] + base(v), env: ["EDITOR": try editor(nil, name: "fail.sh")])
        XCTAssertEqual(failing.status, 1)
        XCTAssertEqual(try Data(contentsOf: v.vault.sharedSettingsURL), original)
    }

    func testValidateAndSchema() throws {
        let v = try makeVault()
        let empty = try cli(["settings", "validate", "--json"] + base(v))
        XCTAssertEqual(empty.status, 0, empty.err)
        XCTAssertEqual((empty.json as? [String: Any])?["valid"] as? Bool, true)
        var s = SharedSettings()
        s.slots[SettingSlotKey("mouse.smoothing")] = SettingSlot(value: .string("max"), meta: nil)
        s.slots[SettingSlotKey("later.key")] = SettingSlot(value: .number(1), meta: nil)
        try v.vault.writeSharedSettings(s)
        let r = try cli(["settings", "validate", "--json"] + base(v))
        XCTAssertEqual(r.status, 3)
        let issues = (r.json as? [String: Any])?["issues"] as? [[String: Any]] ?? []
        XCTAssertEqual(issues.first { $0["path"] as? String == "mouse.smoothing" }?["severity"] as? String, "error")
        XCTAssertEqual(issues.first { $0["path"] as? String == "later.key" }?["severity"] as? String, "info")

        let schema = try cli(["settings", "schema"])
        XCTAssertEqual(schema.status, 0)
        XCTAssertEqual(schema.outData, try SharedSettingsSchema.json())
    }

    func testAFileNeedingANewerReaderIsRefusedAndNeverRewritten() throws {
        let v = try makeVault()
        var later = SharedSettings(schemaVersion: 5, minReaderVersion: 4)
        later.slots[SettingSlotKey("mouse.smoothing")] = SettingSlot(value: .string("off"), meta: nil)
        try v.vault.writeSharedSettings(later)   // as a later version would
        let before = try Data(contentsOf: v.vault.sharedSettingsURL)
        for args in [["settings", "list"], ["settings", "get", "mouse.smoothing"], ["settings", "set", "mouse.smoothing", "light"],
                     ["settings", "reset", "mouse.smoothing"]] {
            let r = try cli(args + base(v), env: ["EDITOR": "true"])
            XCTAssertEqual(r.status, 7, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("newer sempere"), r.err)
        }
        let validate = try cli(["settings", "validate"] + base(v))
        XCTAssertEqual(validate.status, 3)
        XCTAssertTrue(validate.out.contains("$minReaderVersion"), validate.out)
        XCTAssertEqual(try Data(contentsOf: v.vault.sharedSettingsURL), before)
    }

    func testReadOnlyAndLegacyVaults() throws {
        let newer = try copyFixture(named: "newer.sempere")
        let r = try cli(["settings", "set", "mouse.smoothing", "off", "--vault", newer, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 7, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: newer).appendingPathComponent("settings.age").path))
        let legacy = try copyLegacyVault()
        XCTAssertEqual(try cli(["settings", "list", "--vault", legacy, "--identity", Self.legacyKey]).status, 5)
    }

    // MARK: - Helpers

    func copyFixture(named name: String) throws -> String {
        let dest = tmp.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: dest)
        return dest.path
    }
}
