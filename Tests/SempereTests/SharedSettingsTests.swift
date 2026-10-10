import Age
import Foundation
import XCTest
@testable import Sempere

/// The settings file (format.md §13): model, merge, resolution, schema,
/// migrations, and the vault's read, write and rewrap.
final class SharedSettingsTests: VaultTestCase {
    let t0 = wallAt(1_760_000_000_000)

    func json(_ s: String) throws -> SharedSettings.Decoded { try SharedSettings.decode(Data(s.utf8)) }

    // MARK: - Decoding

    func testDecodesTheDocumentedExample() throws {
        let d = try json("""
        { "$schemaVersion": 1, "$minReaderVersion": 1,
          "editor.defaultPaper": { "kind": "grid", "spacing": 20 },
          "newNote.titleFormat": "isoDateTime",
          "mouse.smoothing": "strong",
          "[ipad]": { "editor.keepScreenOn": true },
          "$meta": {
            "newNote.titleFormat": { "modified": 1760025600000, "type": "ipad" },
            "history.thinAfterDays": { "modified": 1760029200000, "type": "mac" },
            "[ipad]": { "editor.keepScreenOn": { "modified": 1760025600000, "type": "ipad" } } } }
        """)
        XCTAssertEqual(d.warnings, [])
        let s = d.settings
        XCTAssertEqual(s.schemaVersion, 1)
        XCTAssertEqual(s.value(SettingSlotKey("newNote.titleFormat")), .string("isoDateTime"))
        XCTAssertEqual(s.slots[SettingSlotKey("newNote.titleFormat")]?.meta, SettingSlotMeta(modified: 1_760_025_600_000, type: "ipad"))
        XCTAssertNil(s.slots[SettingSlotKey("mouse.smoothing")]?.meta, "hand-written: no $meta")
        XCTAssertEqual(s.value(SettingSlotKey("editor.keepScreenOn", type: .ipad)), .bool(true))
        // A $meta entry without a value is a reset.
        let reset = try XCTUnwrap(s.slots[SettingSlotKey("history.thinAfterDays")])
        XCTAssertNil(reset.value)
        XCTAssertEqual(reset.meta?.type, "mac")
    }

    func testRoundTripKeepsUnknownKeysBlocksAndMembers() throws {
        let text = """
        { "$schemaVersion": 1, "$comment": "hand note", "future.key": [1, 2, {"a": null}],
          "[watch]": { "face": "modular" }, "[mac]": { "mouse.smoothing": "off", "later.key": 3 },
          "[notablock]": 7,
          "$meta": { "future.key": { "modified": 5, "type": "ipad", "extraMember": true },
                     "[watch]": { "face": { "modified": 6 } } } }
        """
        let s = try json(text).settings
        let again = try SharedSettings.decode(try s.encoded()).settings
        XCTAssertEqual(again, s)
        XCTAssertEqual(again.extra["$comment"], .string("hand note"))
        XCTAssertEqual(again.extra["[notablock]"], .number(7), "a block that is not an object is kept as it is")
        XCTAssertEqual(again.value(SettingSlotKey("face", block: "watch")), .string("modular"))
        XCTAssertEqual(again.slots[SettingSlotKey("future.key")]?.meta?.extra, ["extraMember": .bool(true)])
        XCTAssertEqual(again.value(SettingSlotKey("later.key", type: .mac)), .number(3))
    }

    func testMalformedPartsAreWarningsNotErrors() throws {
        let d = try json("""
        { "$schemaVersion": "one", "a.b": 1,
          "$meta": { "a.b": { "modified": -1 }, "c.d": "x", "[mac]": 3, "e.f": { "modified": 1.5 },
                     "g.h": { "modified": 2, "type": "Not A Type" } } }
        """)
        XCTAssertEqual(d.settings.schemaVersion, 1)
        XCTAssertEqual(d.settings.value(SettingSlotKey("a.b")), .number(1))
        XCTAssertNil(d.settings.slots[SettingSlotKey("a.b")]?.meta)
        XCTAssertNil(d.settings.slots[SettingSlotKey("c.d")])
        XCTAssertEqual(d.warnings.count, 7, "\(d.warnings)")
    }

    func testHostileFilesFailWithTypedErrors() throws {
        for bad in ["", "[]", "\"x\"", "{", "null"] {
            XCTAssertThrowsError(try json(bad), bad) { XCTAssertTrue($0 is SharedSettingsError, "\($0)") }
        }
        let many = "{" + (0...SharedSettings.maxSlots).map { "\"k\($0)\": 1" }.joined(separator: ",") + "}"
        XCTAssertThrowsError(try json(many)) { XCTAssertEqual($0 as? SharedSettingsError, .tooLarge) }
        let blocks = "{" + (0...SharedSettings.maxBlocks).map { "\"[b\($0)]\": {}" }.joined(separator: ",") + "}"
        XCTAssertThrowsError(try json(blocks)) { XCTAssertEqual($0 as? SharedSettingsError, .tooLarge) }
        XCTAssertThrowsError(try SharedSettings.decode(Data(count: SharedSettings.maxJSONBytes + 1))) {
            XCTAssertEqual($0 as? SharedSettingsError, .tooLarge)
        }
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        XCTAssertThrowsError(try json("{\"a\": \(deep)}"))
    }

    // MARK: - Merge

    func randomSettings(_ g: inout SplitMix64) -> SharedSettings {
        var s = SharedSettings(schemaVersion: Int(g.next() % 3) + 1)
        let keys = ["a.x", "b.y", "c.z", "eraser.mode"]
        let blocks: [String?] = [nil, "mac", "ipad", "watch"]
        for _ in 0..<Int(g.next() % 8) {
            let slot = SettingSlotKey(keys[Int(g.next() % 4)], block: blocks[Int(g.next() % 4)])
            let value: JSONValue? = g.next() % 4 == 0 ? nil : [.bool(true), .number(Double(g.next() % 3)), .string("v")][Int(g.next() % 3)]
            let meta: SettingSlotMeta? = g.next() % 5 == 0 ? nil
                : SettingSlotMeta(modified: Int64(g.next() % 4), type: [nil, "mac", "ipad"][Int(g.next() % 3)])
            if value == nil && meta == nil { continue }
            s.slots[slot] = SettingSlot(value: value, meta: meta)
        }
        if g.next() % 3 == 0 { s.extra["$x\(g.next() % 2)"] = .number(Double(g.next() % 2)) }
        return s
    }

    func testMergeIsCommutativeAssociativeAndIdempotentForSlots() {
        var g = SplitMix64(seed: 13)
        for _ in 0..<2000 {
            let a = randomSettings(&g), b = randomSettings(&g), c = randomSettings(&g)
            XCTAssertEqual(a.merging(b).slots, b.merging(a).slots)
            XCTAssertEqual(a.merging(b).schemaVersion, b.merging(a).schemaVersion)
            XCTAssertEqual(a.merging(b).merging(c).slots, a.merging(b.merging(c)).slots)
            XCTAssertEqual(a.merging(a), a)
            XCTAssertEqual(Set(a.merging(b).extra.keys), Set(a.extra.keys).union(b.extra.keys))
            // The whole result, unknown members included (a clash must not depend on the order).
            XCTAssertEqual(a.merging(b), b.merging(a))
            XCTAssertEqual(a.merging(b).merging(c), a.merging(b.merging(c)))
        }
    }

    func testClashingUnknownMembersConverge() {
        let a = SharedSettings(extra: ["$future": .number(1), "[odd]": .string("x")])
        let b = SharedSettings(extra: ["$future": .number(2), "[odd]": .string("y")])
        XCTAssertEqual(a.merging(b), b.merging(a), "the same result whichever copy merges")
        XCTAssertEqual(a.merging(b).extra["$future"], .number(2), "the greater canonical JSON wins")
        XCTAssertEqual(a.merging(b).extra["[odd]"], .string("y"))
        // A device holding a different unknown value does not keep writing its own back.
        var state = SettingsSyncState()
        state.enabled = true
        state.known = a
        let pass = try? state.reconcile(local: [:], file: b, type: .mac, now: Date(timeIntervalSince1970: 100))
        XCTAssertNotNil(pass)
        XCTAssertNil(pass?.write, "the file's greater value is taken, not overwritten with this device's")
        XCTAssertEqual(state.known.extra["$future"], .number(2))
    }

    func testOrderingOfSlots() {
        let k = SettingSlotKey("a.b")
        func merged(_ x: SettingSlot, _ y: SettingSlot) -> SettingSlot? {
            SharedSettings(slots: [k: x]).merging(SharedSettings(slots: [k: y])).slots[k]
        }
        let hand = SettingSlot(value: .number(9), meta: nil)
        let old = SettingSlot(value: .number(1), meta: SettingSlotMeta(modified: 0))
        XCTAssertEqual(merged(hand, old), old, "a slot with $meta beats a hand-written one")
        let mac = SettingSlot(value: .number(1), meta: SettingSlotMeta(modified: 5, type: "mac"))
        let ipad = SettingSlot(value: .number(2), meta: SettingSlotMeta(modified: 5, type: "ipad"))
        XCTAssertEqual(merged(mac, ipad), mac, "same time: the greater type wins")
        let reset = SettingSlot(value: nil, meta: SettingSlotMeta(modified: 5, type: "mac"))
        XCTAssertEqual(merged(reset, mac), mac, "same time and type: a reset is lowest")
        let later = SettingSlot(value: nil, meta: SettingSlotMeta(modified: 6))
        XCTAssertEqual(merged(mac, later), later, "a later reset wins")
    }

    func testWriteBeatsWhatTheWriterSawWhateverTheClock() throws {
        var s = SharedSettings()
        let k = SettingSlotKey("eraser.mode")
        s.slots[k] = SettingSlot(value: .string("pixel"), meta: SettingSlotMeta(modified: 2_000_000_000_000, type: "mac"))
        try s.set(k, to: .string("object"), type: .ipad, now: t0)   // this clock is behind
        XCTAssertEqual(s.slots[k]?.meta?.modified, 2_000_000_000_001)
        let other = SharedSettings(slots: [k: SettingSlot(value: .string("pixel"), meta: SettingSlotMeta(modified: 2_000_000_000_000, type: "mac"))])
        XCTAssertEqual(other.merging(s).value(k), .string("object"))
        XCTAssertEqual(s.merging(other).value(k), .string("object"))
        try s.set(k, to: .string("pixel"), type: nil, now: wallAt(3_000_000_000_000))
        XCTAssertEqual(s.slots[k]?.meta, SettingSlotMeta(modified: 3_000_000_000_000, type: nil))
        s.slots[k]?.meta?.modified = SharedSettings.maxModified
        XCTAssertThrowsError(try s.set(k, to: nil, type: .mac, now: t0)) {
            guard case .clockExhausted = $0 as? SharedSettingsError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Resolution

    func testResolutionOrderBlockThenTopThenDefault() throws {
        let spec = try XCTUnwrap(SharedSettingsCatalog.spec(named: "eraser.mode"))
        var s = SharedSettings()
        XCTAssertEqual(s.resolve(spec, for: .mac), .init(value: .string("object"), source: .default))
        try s.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .ipad, now: t0)
        XCTAssertEqual(s.resolve(spec, for: .mac).source, .top)
        try s.set(SettingSlotKey("eraser.mode", type: .mac), to: .string("object"), type: .mac, now: t0)
        XCTAssertEqual(s.resolve(spec, for: .mac), .init(value: .string("object"), source: .block))
        XCTAssertEqual(s.resolve(spec, for: .ipad), .init(value: .string("pixel"), source: .top))
        // A reset in the block falls back to the top level.
        try s.set(SettingSlotKey("eraser.mode", type: .mac), to: nil, type: .mac, now: t0)
        XCTAssertEqual(s.resolve(spec, for: .mac).source, .top)
    }

    func testInvalidValuesFallBackWithAWarning() throws {
        let spec = try XCTUnwrap(SharedSettingsCatalog.spec(named: "history.thinAfterDays"))
        let s = try json("""
        { "$schemaVersion": 1, "history.thinAfterDays": "lots", "[mac]": { "history.thinAfterDays": 12 } }
        """).settings
        let mac = s.resolve(spec, for: .mac)
        XCTAssertEqual(mac.value, .number(30))
        XCTAssertEqual(mac.source, .default)
        XCTAssertEqual(mac.warnings.count, 2)
        let s2 = try json(#"{"$schemaVersion": 1, "history.thinAfterDays": 90, "[mac]": {"history.thinAfterDays": true}}"#).settings
        XCTAssertEqual(s2.resolve(spec, for: .mac).value, .number(90), "an invalid block value falls back to the top level")
    }

    // MARK: - Registry and schema

    func testRegistryValidatesEachKind() throws {
        func v(_ name: String, _ value: JSONValue) -> JSONValue? { SharedSettingsCatalog.spec(named: name)?.validated(value) }
        XCTAssertEqual(v("handwriting.recognize", .bool(false)), .bool(false))
        XCTAssertNil(v("handwriting.recognize", .number(0)))
        XCTAssertNil(v("newNote.titleFormat", .string("nope")))
        XCTAssertEqual(v("recording.bitRate", .number(48_000)), .number(48_000))
        XCTAssertNil(v("recording.bitRate", .number(48_000.5)))
        XCTAssertNil(v("recording.bitRate", .number(1e300)))
        XCTAssertEqual(v("quickCapture.notebook", .string(" Work // Meetings ")), .string("Work/Meetings"))
        XCTAssertNil(v("quickCapture.notebook", .string(" / ")))
        XCTAssertNil(v("newNote.titlePattern", .string("   ")))
        XCTAssertNil(v("newNote.titlePattern", .string("'open")))
        XCTAssertEqual(v("newNote.titlePattern", .string("'Lecture' d MMM")), .string("'Lecture' d MMM"))
        XCTAssertEqual(v("transcription.language", .null), .null)
        XCTAssertEqual(v("transcription.language", .string("es_ES")), .string("es_ES"))
        XCTAssertNil(v("transcription.language", .string("es ES")))
        let paper = try XCTUnwrap(v("editor.defaultPaper", .object(["kind": .string("grid"), "spacing": .number(1000)])))
        XCTAssertEqual(try paper.decode(Paper.self).spacing, Paper.Limits.spacing.upperBound, "clamped")
        XCTAssertNil(v("editor.defaultPaper", .string("grid")))
    }

    func testCommandLineParsing() throws {
        func p(_ name: String, _ text: String) -> JSONValue? { SharedSettingsCatalog.spec(named: name)?.parse(text) }
        XCTAssertEqual(p("photos.removeMetadata", "off"), .bool(false))
        XCTAssertNil(p("photos.removeMetadata", "maybe"))
        XCTAssertEqual(p("eraser.objectRadius", "16"), .number(16))
        XCTAssertNil(p("eraser.objectRadius", "15"))
        XCTAssertEqual(p("transcription.language", "device"), .null)
        XCTAssertEqual(try p("editor.defaultPaper", "dot")?.decode(Paper.self).kind, .dot)
        XCTAssertNil(p("editor.defaultPaper", "dots"))
        XCTAssertEqual(try p("editor.defaultPaper", #"{"kind":"grid","spacing":30}"#)?.decode(Paper.self).spacing, 30)
    }

    func testEveryDefaultIsValidAndNamesAreUnique() {
        let names = SharedSettingsCatalog.specs.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for spec in SharedSettingsCatalog.specs {
            XCTAssertEqual(spec.validated(spec.defaultValue), spec.defaultValue, spec.name)
            XCTAssertFalse(spec.name.hasPrefix("$") || spec.name.hasPrefix("["), spec.name)
        }
        XCTAssertTrue(SharedSettingsCatalog.specs(for: .mac).contains { $0.name == "mouse.smoothing" })
        XCTAssertFalse(SharedSettingsCatalog.specs(for: .ipad).contains { $0.name == "mouse.smoothing" })
        XCTAssertFalse(SharedSettingsCatalog.specs(for: .mac).contains { $0.name == "quickCapture.notebook" })
    }

    /// docs/settings.schema.json is generated from the registry; regenerate
    /// with `swift run sempere settings schema > docs/settings.schema.json`.
    func testCommittedSchemaMatchesTheRegistry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let committed = try Data(contentsOf: root.appendingPathComponent("docs/settings.schema.json"))
        XCTAssertEqual(String(decoding: committed, as: UTF8.self), String(decoding: try SharedSettingsSchema.json(), as: UTF8.self),
                       "docs/settings.schema.json is stale: swift run sempere settings schema > docs/settings.schema.json")
    }

    func testIssuesSeparateErrorsFromInformation() throws {
        let d = try json("""
        { "$schemaVersion": 3, "$minReaderVersion": 1, "$note": 1, "mouse.smoothing": "max", "future.key": 1,
          "[watch]": { "x": 1 }, "[mac]": { "eraser.mode": "pixel" }, "$meta": { "a": 1 } }
        """)
        let issues = SharedSettingsCatalog.issues(in: d)
        XCTAssertEqual(issues.filter { $0.severity == .error }.map(\.path).sorted(), ["file", "mouse.smoothing"])
        XCTAssertEqual(Set(issues.filter { $0.severity == .info }.map(\.path)),
                       ["$schemaVersion", "$note", "future.key", "[watch] x"])
    }

    // MARK: - Migrations

    let testMigrations: [SharedSettingsMigrations.Migration] = [
        .init(from: 1, [.copy(from: "pen.width", to: "ink.width"),
                        .copy(from: "pen.style", to: "pen.kind", map: { $0 == .string("bitmap") ? .string("pixel") : $0 })]),
        // `@Sendable` spelled out: in a tuple literal the macOS compiler does not infer it.
        .init(from: 2, [.split(key: "ink.width", into: [
            (key: "ink.penWidth", map: { @Sendable v in v }),
            (key: "ink.markerWidth", map: { @Sendable v in if case .number(let n) = v { return .number(n * 4) } else { return nil } }),
        ])]),
    ]

    func testMigrationsCopyAndSplitKeepingOldKeysAndMeta() throws {
        let v1 = try fixture("v1.json")
        let migrated = SharedSettingsMigrations.migrated(v1, using: testMigrations, to: 3)
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.minReaderVersion, 1)
        XCTAssertEqual(migrated.slots[SettingSlotKey("pen.width")], v1.slots[SettingSlotKey("pen.width")], "older readers still read it")
        XCTAssertEqual(migrated.value(SettingSlotKey("ink.width")), .number(2))
        XCTAssertEqual(migrated.value(SettingSlotKey("ink.penWidth")), .number(2))
        XCTAssertEqual(migrated.value(SettingSlotKey("ink.markerWidth")), .number(8))
        XCTAssertEqual(migrated.slots[SettingSlotKey("ink.markerWidth")]?.meta, v1.slots[SettingSlotKey("pen.width")]?.meta)
        XCTAssertEqual(migrated.value(SettingSlotKey("ink.penWidth", type: .mac)), .number(3), "blocks migrate too")
        XCTAssertEqual(migrated.value(SettingSlotKey("pen.kind", type: .ipad)), .string("pixel"))
        XCTAssertEqual(migrated.value(SettingSlotKey("pen.style", type: .ipad)), .string("bitmap"))
        XCTAssertEqual(migrated, SharedSettingsMigrations.migrated(v1, using: testMigrations, to: 3), "deterministic")
        var v2 = v1
        v2.schemaVersion = 2
        XCTAssertNil(SharedSettingsMigrations.migrated(v2, using: testMigrations, to: 3).slots[SettingSlotKey("ink.width")],
                     "starting from v2 runs only the later migration")
        // A copy never overwrites a newer write of the new key.
        var newer = v1
        try newer.set(SettingSlotKey("ink.width"), to: .number(5), type: .mac, now: wallAt(1_800_000_000_000))
        XCTAssertEqual(SharedSettingsMigrations.migrated(newer, using: testMigrations, to: 2).value(SettingSlotKey("ink.width")), .number(5))
    }

    func testARemovalMustRaiseMinReader() throws {
        let sloppy = SharedSettingsMigrations.Migration(from: 1, [.remove(key: "pen.width")])
        XCTAssertFalse(sloppy.isAdditiveOrBreakingOnPurpose)
        let deliberate = SharedSettingsMigrations.Migration(from: 1, [.remove(key: "pen.width")], raisesMinReaderTo: 2)
        XCTAssertTrue(deliberate.isAdditiveOrBreakingOnPurpose)
        let out = SharedSettingsMigrations.migrated(try fixture("v1.json"), using: [deliberate], to: 2)
        XCTAssertFalse(out.slots.keys.contains { $0.key == "pen.width" })
        XCTAssertEqual(out.minReaderVersion, 2)
        for m in SharedSettingsMigrations.all { XCTAssertTrue(m.isAdditiveOrBreakingOnPurpose, "migration from \(m.version)") }
    }

    func testNewerVersionIsNotMigratedAndKeptVerbatim() throws {
        var newer = try fixture("v1.json")
        newer.schemaVersion = 7
        XCTAssertEqual(SharedSettingsMigrations.migrated(newer, using: testMigrations, to: 3), newer)
        XCTAssertEqual(SharedSettingsMigrations.migrated(newer), newer)
        // A device writing one key keeps the rest, and the version, as it was.
        var written = newer
        try written.set(SettingSlotKey("eraser.mode"), to: .string("pixel"), type: .mac, now: t0)
        XCTAssertEqual(written.minReaderVersion, newer.minReaderVersion)
        XCTAssertEqual(written.schemaVersion, 7)
        var expected = newer.slots
        expected[SettingSlotKey("eraser.mode")] = written.slots[SettingSlotKey("eraser.mode")]
        XCTAssertEqual(written.slots, expected)
    }

    func testTheV1FixtureReadsCleanWithTheShippedMigrations() throws {
        let decoded = try SharedSettings.decode(Data(contentsOf: fixtureURL("v1.json")))
        XCTAssertEqual(decoded.warnings, [])
        XCTAssertEqual(decoded.settings.schemaVersion, 1)
        XCTAssertEqual(SharedSettingsMigrations.current, 1)
        XCTAssertEqual(SharedSettingsMigrations.migrated(decoded.settings), decoded.settings)
    }

    func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/settings/\(name)")
    }

    func fixture(_ name: String) throws -> SharedSettings {
        try SharedSettings.decode(Data(contentsOf: fixtureURL(name))).settings
    }

    // MARK: - The vault's file

    func testWriteReadAndStockToolLayout() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        XCTAssertNil(try vault.readSharedSettings())
        var s = SharedSettings()
        try s.set(SettingSlotKey("photos.removeMetadata"), to: .bool(false), type: .ipad, now: t0)
        try vault.writeSharedSettings(s)
        XCTAssertEqual(try vault.readSharedSettings(), s)
        // The body is the revision framing (format.md §4): `tail -c +38 | gunzip` reads it.
        let plain = try AgeFile.decrypt(Data(contentsOf: vault.sharedSettingsURL), with: [id])
        XCTAssertEqual(Array(plain.prefix(4)), Array("SMPR".utf8))
        let json = try Gzip.decompress(Data(plain.dropFirst(BodyFraming.headerSize)))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"photos.removeMetadata\" : false"))
    }

    func testTagBindsTheFileToTheVault() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let other = try makeVault(id, name: "Other")
        try other.writeSharedSettings(SharedSettings())
        // Another vault's file (another secret), encrypted to this vault's key: refused.
        try FileManager.default.copyItem(at: other.sharedSettingsURL, to: vault.sharedSettingsURL)
        XCTAssertThrowsError(try vault.readSharedSettings()) {
            XCTAssertEqual($0 as? SharedSettingsError, .framing(.tagMismatch))
        }
        // A file anyone could make from the public keys alone: refused.
        let forged = try BodyFraming.frame(json: Data("{}".utf8), noteId: "settings", filename: "settings.age",
                                           secret: VaultSecret.random())
        try Vault.encrypt(forged, to: [id.recipient]).write(to: vault.sharedSettingsURL)
        XCTAssertThrowsError(try vault.readSharedSettings())
        // updateSharedSettings refuses to replace it unless asked.
        XCTAssertThrowsError(try vault.updateSharedSettings { _ in })
        try vault.updateSharedSettings(replacingUnreadable: true) { try $0.set(SettingSlotKey("a.b"), to: .number(1), type: nil, now: self.t0) }
        XCTAssertEqual(try vault.readSharedSettings()?.value(SettingSlotKey("a.b")), .number(1))
    }

    func testUpdateMergesWhatAnotherWriterWroteMeanwhile() throws {
        let vault = try makeVault(pqIdentity())
        try vault.updateSharedSettings { s in
            try s.set(SettingSlotKey("a.b"), to: .number(1), type: .mac, now: self.t0)
            // Another process writes while this change is being made.
            var other = SharedSettings()
            try other.set(SettingSlotKey("c.d"), to: .number(2), type: .ipad, now: self.t0)
            try vault.writeSharedSettings(other)
        }
        let s = try XCTUnwrap(try vault.readSharedSettings())
        XCTAssertEqual(s.value(SettingSlotKey("a.b")), .number(1))
        XCTAssertEqual(s.value(SettingSlotKey("c.d")), .number(2))
    }

    func testRecipientChangesRewrapTheFile() throws {
        let id = pqIdentity(), second = pqIdentity()
        var vault = try makeVault(id)
        var s = SharedSettings()
        try s.set(SettingSlotKey("mouse.smoothing"), to: .string("off"), type: .mac, now: t0)
        try vault.writeSharedSettings(s)

        let added = try vault.addRecipient(second.recipient, label: "second")
        XCTAssertTrue(added.rewrapped.contains("settings.age"))
        let asSecond = try Vault.open(at: vault.url, identities: [second])
        XCTAssertEqual(try asSecond.readSharedSettings(), s, "readable by the added key")

        let removed = try vault.removeRecipient(second.recipient)
        XCTAssertTrue(removed.rewrapped.contains("settings.age"))
        XCTAssertEqual(try vault.readSharedSettings(), s, "re-tagged under the rotated secret")
        XCTAssertThrowsError(try AgeFile.decrypt(Data(contentsOf: vault.sharedSettingsURL), with: [second]))
    }

    /// A device that stayed open while another one changed the keys sees the rotated file as
    /// unverifiable; it must notice its keys are stale before replacing the file (the app's pass).
    func testAStaleVaultValueKnowsItsKeysChangedOnDisk() throws {
        let id = pqIdentity(), second = pqIdentity()
        var vault = try makeVault(id)
        let stale = vault   // the other device's open vault: in-memory secret and recipients
        XCTAssertTrue(stale.keysMatchManifestOnDisk())
        var s = SharedSettings()
        try s.set(SettingSlotKey("mouse.smoothing"), to: .string("off"), type: .mac, now: t0)
        try vault.writeSharedSettings(s)
        _ = try vault.addRecipient(second.recipient, label: "second")
        _ = try vault.removeRecipient(second.recipient)   // rotates the secret
        XCTAssertTrue(vault.keysMatchManifestOnDisk(), "the device that changed the keys is current")
        XCTAssertFalse(stale.keysMatchManifestOnDisk(), "the stale value must not replace the file")
        XCTAssertThrowsError(try stale.readSharedSettings(), "the rotated file does not verify under the stale secret")
        XCTAssertEqual(try vault.readSharedSettings(), s)
        // Adding a device alone also makes an open value stale (its recipients lack the new key).
        let before = vault
        _ = try vault.addRecipient(second.recipient, label: "second")
        XCTAssertFalse(before.keysMatchManifestOnDisk())
    }

    func testAFileThatDoesNotVerifyIsSkippedAndDoesNotKeepTheJournal() throws {
        let id = pqIdentity(), second = pqIdentity()
        var vault = try makeVault(id)
        let junk = try BodyFraming.frame(json: Data("{}".utf8), noteId: "settings", filename: "settings.age", secret: .random())
        try Vault.encrypt(junk, to: [id.recipient]).write(to: vault.sharedSettingsURL)
        let report = try vault.addRecipient(second.recipient, label: "second")
        XCTAssertEqual(report.settingsSkipped, ["settings.age"])
        XCTAssertTrue(report.isComplete)
        XCTAssertFalse(vault.pendingRewrap)
    }

    func testReadOnlyAndLegacyVaultsRefuseWrites() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        // An unknown feature makes the vault read-only (format.md §7.3).
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.url.appendingPathComponent("vault.json"))) as! [String: Any]
        manifest["features"] = ((manifest["features"] as? [String]) ?? []) + ["from-the-future"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: vault.url.appendingPathComponent("vault.json"))
        let readOnly = try Vault.open(at: vault.url, identities: [id])
        XCTAssertThrowsError(try readOnly.writeSharedSettings(SharedSettings())) {
            guard case .readOnly = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: readOnly.sharedSettingsURL.path))

        let legacy = try makeLegacyVault(X25519Identity(), name: "Legacy")
        XCTAssertThrowsError(try legacy.writeSharedSettings(SharedSettings())) {
            guard case .legacyVault = $0 as? VaultError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try legacy.readSharedSettings()) {
            guard case .legacyVault = $0 as? VaultError else { return XCTFail("\($0)") }
        }
    }

    func testOversizedFileIsRefusedBeforeReading() throws {
        let vault = try makeVault(pqIdentity())
        try Data(count: SharedSettings.maxFileBytes + 1).write(to: vault.sharedSettingsURL)
        XCTAssertThrowsError(try vault.readSharedSettings()) { XCTAssertEqual($0 as? SharedSettingsError, .tooLarge) }
    }

    func testCodableCopyRoundTrips() throws {
        let s = try fixture("v1.json")
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SharedSettings.self, from: data), s)
    }
}
