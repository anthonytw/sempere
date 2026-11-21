import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere tools` (docs/design/1.3-custom-tools.md §3.6).
final class CLIToolsTests: CLITestCase {
    func base(_ v: (vault: Vault, identity: NativeIdentity, keyPath: String)) -> [String] {
        ["--vault", v.vault.url.path, "--identity", v.keyPath]
    }

    func list(_ v: (vault: Vault, identity: NativeIdentity, keyPath: String)) throws -> [[String: Any]] {
        let r = try cli(["tools", "list", "--json"] + base(v))
        XCTAssertEqual(r.status, 0, r.err)
        return (r.json as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    }

    @discardableResult
    func addTool(_ v: (vault: Vault, identity: NativeIdentity, keyPath: String), _ name: String, ink: String = "pen",
             color: String = "#D32F2F", width: String = "1.5", extra: [String] = []) throws -> String {
        let r = try cli(["tools", "add", name, "--ink", ink, "--color", color, "--width", width, "--json"] + extra + base(v))
        XCTAssertEqual(r.status, 0, r.err)
        return (r.json as? [String: Any])?["id"] as? String ?? ""
    }

    func testAddListEditRemoveWithJSON() throws {
        let v = try makeVault()
        XCTAssertEqual(try list(v).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.vault.sharedSettingsURL.path), "reading writes nothing")

        let id = try addTool(v, "Fine red pen")
        _ = try addTool(v, "Yellow marker", ink: "marker", color: "#FFCC00", width: "14", extra: ["--opacity", "0.4"])
        let rows = try list(v)
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["Fine red pen", "Yellow marker"])
        XCTAssertEqual(rows[1]["opacity"] as? Double, 0.4)
        XCTAssertEqual(rows[0]["color"] as? String, "#D32F2F")
        XCTAssertEqual(rows.map { $0["order"] as? Int }, [1, 2])
        let text = try cli(["tools", "list"] + base(v))
        XCTAssertTrue(text.out.contains("Yellow marker") && text.out.contains("marker"), text.out)

        // The CLI records no device type, and the file is the shared settings.
        let stored = try XCTUnwrap(try v.vault.readSharedSettings())
        let slot = try XCTUnwrap(stored.slots[SettingSlotKey("palette.tool.\(id)")])
        XCTAssertNil(slot.meta?.type)
        XCTAssertEqual(SavedToolList(settings: stored).tools.count, 2)

        // Edit one slot by prefix: only the options given change.
        let edit = try cli(["tools", "edit", String(id.prefix(6)), "--name", "Finer", "--width", "1"] + base(v))
        XCTAssertEqual(edit.status, 0, edit.err)
        let after = try list(v)
        XCTAssertEqual(after[0]["name"] as? String, "Finer")
        XCTAssertEqual(after[0]["width"] as? Double, 1)
        XCTAssertEqual(after[0]["color"] as? String, "#D32F2F")
        XCTAssertEqual(after[0]["id"] as? String, id)
        XCTAssertEqual(try cli(["tools", "edit", id] + base(v)).status, 2, "nothing to change")

        let rm = try cli(["tools", "remove", "Yellow marker", "--json"] + base(v))
        XCTAssertEqual(rm.status, 0, rm.err)
        XCTAssertEqual(try list(v).count, 1)
        let reset = try XCTUnwrap(try v.vault.readSharedSettings()?.slots.values.first { $0.value == nil })
        XCTAssertNotNil(reset.meta, "a delete is recorded as a reset")
    }

    func testValidationIsExit3AndNothingIsWritten() throws {
        let v = try makeVault()
        for args in [["x", "--ink", "pen", "--color", "#000000", "--width", "0.5"],     // below the pen's range
                     ["x", "--ink", "monoline", "--color", "#000000", "--width", "9"],
                     ["x", "--ink", "pen", "--color", "#000000", "--width", "2", "--opacity", "2"],
                     [String(repeating: "n", count: 41), "--ink", "pen", "--color", "#000000", "--width", "2"],
                     [" ", "--ink", "pen", "--color", "#000000", "--width", "2"]] {
            let r = try cli(["tools", "add"] + args + base(v))
            XCTAssertEqual(r.status, 3, "\(args): \(r.err)")
        }
        XCTAssertEqual(try cli(["tools", "add", "x", "--ink", "sumi", "--color", "#000000", "--width", "2"] + base(v)).status, 2)
        XCTAssertEqual(try cli(["tools", "add", "x", "--ink", "pen", "--color", "red", "--width", "2"] + base(v)).status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.vault.sharedSettingsURL.path))
        let id = try addTool(v, "ok")
        // Changing the ink without a width that fits is refused too.
        XCTAssertEqual(try cli(["tools", "edit", id, "--ink", "marker"] + base(v)).status, 3)
        XCTAssertEqual(try list(v)[0]["ink"] as? String, "pen")
    }

    func testTheCapOf64() throws {
        let v = try makeVault()
        var s = SharedSettings()
        for i in 0..<64 {
            try SavedToolList.add(SavedTool(name: "T\(i)", ink: .pen, color: .black, width: 1.5, at: Int64(i)), to: &s)
        }
        try v.vault.writeSharedSettings(s)
        let r = try cli(["tools", "add", "65th", "--ink", "pen", "--color", "#000000", "--width", "2"] + base(v))
        XCTAssertEqual(r.status, 3, r.err)
        XCTAssertTrue(r.err.contains("64"), r.err)
    }

    func testNamesIdsPrefixesAndAmbiguity() throws {
        let v = try makeVault()
        let a = try addTool(v, "Twin"), b = try addTool(v, "Twin"), c = try addTool(v, "Solo")
        let ambiguous = try cli(["tools", "remove", "Twin"] + base(v))
        XCTAssertEqual(ambiguous.status, 1)
        XCTAssertTrue(ambiguous.err.contains(a) && ambiguous.err.contains(b), ambiguous.err)
        XCTAssertEqual(try cli(["tools", "remove", "nothing"] + base(v)).status, 1)
        XCTAssertEqual(try cli(["tools", "remove", b] + base(v)).status, 0)
        XCTAssertEqual(try cli(["tools", "edit", "Solo", "--color", "#00FF00"] + base(v)).status, 0)
        XCTAssertEqual(try list(v).map { $0["id"] as? String }, [a, c])
    }

    func testMove() throws {
        let v = try makeVault()
        let a = try addTool(v, "A"), b = try addTool(v, "B"), c = try addTool(v, "C")
        func order() throws -> [String] { try list(v).compactMap { $0["name"] as? String } }
        XCTAssertEqual(try cli(["tools", "move", "C", "--to", "1"] + base(v)).status, 0)
        XCTAssertEqual(try order(), ["C", "A", "B"])
        XCTAssertEqual(try cli(["tools", "move", "C", "--after", b] + base(v)).status, 0)
        XCTAssertEqual(try order(), ["A", "B", "C"])
        XCTAssertEqual(try cli(["tools", "move", "B", "--before", a, "--json"] + base(v)).status, 0)
        XCTAssertEqual(try order(), ["B", "A", "C"])
        XCTAssertEqual(try cli(["tools", "move", c, "--to", "9"] + base(v)).status, 2)
        XCTAssertEqual(try cli(["tools", "move", c] + base(v)).status, 2, "a destination is needed")
        XCTAssertEqual(try cli(["tools", "move", c, "--to", "1", "--after", a] + base(v)).status, 2)
        // A write of the order never touches the presets' own slots.
        let s = try XCTUnwrap(try v.vault.readSharedSettings())
        XCTAssertNotNil(s.value(SettingSlotKey("palette.toolOrder")))
    }

    func testExportAndImport() throws {
        let v = try makeVault()
        try addTool(v, "One"); try addTool(v, "Two", ink: "marker", color: "#FFCC00", width: "14")
        let file = path("tools.json")
        let export = try cli(["tools", "export", "--out", file, "--json"] + base(v))
        XCTAssertEqual(export.status, 0, export.err)
        XCTAssertEqual(try cli(["tools", "export", "--out", file] + base(v)).status, 1, "never overwrites")
        let text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(text.contains("sempere-tools/1"))
        XCTAssertFalse(text.contains("palette.tool"), "no ids or keys")
        let stdout = try cli(["tools", "export"] + base(v))
        XCTAssertEqual(stdout.out, text)

        // Into a second vault: new ids; invalid entries skipped and reported.
        let w = try makeVault(named: "other.sempere")
        let imported = try cli(["tools", "import", file, "--json"] + base(w))
        XCTAssertEqual(imported.status, 0, imported.err)
        XCTAssertEqual((imported.json as? [String: Any])?["added"] as? Int, 2)
        XCTAssertEqual(try list(w).map { $0["name"] as? String }, ["One", "Two"])
        XCTAssertNotEqual(try list(w).map { $0["id"] as? String }, try list(v).map { $0["id"] as? String })
        // Importing again adds again; --replace needs --yes.
        XCTAssertEqual(try cli(["tools", "import", file] + base(w)).status, 0)
        XCTAssertEqual(try list(w).count, 4)
        XCTAssertEqual(try cli(["tools", "import", file, "--replace"] + base(w)).status, 1)
        XCTAssertEqual(try list(w).count, 4, "nothing removed without --yes")
        let replaced = try cli(["tools", "import", file, "--replace", "--yes", "--json"] + base(w))
        XCTAssertEqual(replaced.status, 0, replaced.err)
        XCTAssertEqual((replaced.json as? [String: Any])?["removed"] as? Int, 4)
        XCTAssertEqual(try list(w).map { $0["name"] as? String }, ["One", "Two"])

        let messy = path("messy.json")
        try """
        {"format":"sempere-tools/1","tools":[{"name":"Good","ink":"pen","color":"#000000","width":2,"opacity":1},
        {"name":"Bad","ink":"pen","color":"#000000","width":500,"opacity":1}]}
        """.write(toFile: messy, atomically: true, encoding: .utf8)
        let m = try cli(["tools", "import", messy, "--json"] + base(w))
        XCTAssertEqual(m.status, 0, m.err)
        XCTAssertEqual(((m.json as? [String: Any])?["skipped"] as? [String])?.count, 1)
        XCTAssertTrue(m.err.contains("skipped"), m.err)
        let junk = path("junk.json")
        try "nope".write(toFile: junk, atomically: true, encoding: .utf8)
        XCTAssertEqual(try cli(["tools", "import", junk] + base(w)).status, 3)
        XCTAssertEqual(try cli(["tools", "import", path("missing.json")] + base(w)).status, 1)
    }

    func testPresetsAreSettingsSoValidateAndKeepUnknownInks() throws {
        let v = try makeVault()
        try addTool(v, "Mine")
        var s = try XCTUnwrap(try v.vault.readSharedSettings())
        let id = "3f9c1a52-7e0b-4d9a-9a54-1d2c8b6e4f10"
        try s.set(SettingSlotKey("palette.tool.\(id)"), to: .object([
            "name": .string("Brush"), "ink": .string("sumi"), "color": .string("#000000"), "width": .number(3),
            "opacity": .number(1), "at": .number(1)]), type: .ipad, now: Date())
        try v.vault.writeSharedSettings(s)
        XCTAssertEqual(try cli(["settings", "validate"] + base(v)).status, 0, "an unknown ink is information, not an error")
        let l = try cli(["tools", "list", "--json"] + base(v))
        XCTAssertEqual((l.json as? [String: Any])?["hidden"] as? Int, 1)
        XCTAssertEqual(try list(v).count, 1)
        XCTAssertEqual(try cli(["tools", "add", "More", "--ink", "pen", "--color", "#000000", "--width", "2"] + base(v)).status, 0)
        let kept = try XCTUnwrap(try v.vault.readSharedSettings()).slots[SettingSlotKey("palette.tool.\(id)")]
        XCTAssertEqual(kept, s.slots[SettingSlotKey("palette.tool.\(id)")])
        let all = try cli(["settings", "list", "--all"] + base(v))
        XCTAssertFalse(all.out.contains("unknown"), "palette keys are known keys: " + all.out)
    }

    func testReadOnlyVaultsAndNewerSettings() throws {
        let newer = tmp.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("newer.sempere"), to: newer)
        let r = try cli(["tools", "add", "x", "--ink", "pen", "--color", "#000000", "--width", "2",
                         "--vault", newer.path, "--identity", Self.fixtureKey])
        XCTAssertEqual(r.status, 7, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newer.appendingPathComponent("settings.age").path))

        let v = try makeVault()
        var later = SharedSettings(schemaVersion: 5, minReaderVersion: 4)
        later.slots[SettingSlotKey("mouse.smoothing")] = SettingSlot(value: .string("off"), meta: nil)
        try v.vault.writeSharedSettings(later)
        let before = try Data(contentsOf: v.vault.sharedSettingsURL)
        for args in [["tools", "list"], ["tools", "add", "x", "--ink", "pen", "--color", "#000000", "--width", "2"],
                     ["tools", "remove", "x"]] {
            let result = try cli(args + base(v))
            XCTAssertEqual(result.status, 7, "\(args): \(result.err)")
        }
        XCTAssertEqual(try Data(contentsOf: v.vault.sharedSettingsURL), before)
    }
}
