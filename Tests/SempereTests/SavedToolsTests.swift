import Foundation
import XCTest
@testable import Sempere

/// Saved tools (docs/design/1.3-custom-tools.md): the preset, its slots in the shared settings, ordering, the
/// caps, unknown inks, merges, `DrawingToolState.apply` and `isActive`, and the `sempere-tools/1` file.
final class SavedToolsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_764_727_900)
    let uuidA = "3f9c1a52-7e0b-4d9a-9a54-1d2c8b6e4f10"

    func tool(_ name: String, ink: InkTool = .pen, at: Int64 = 1, id: String = SavedTool.newID()) -> SavedTool {
        SavedTool(id: id, name: name, ink: ink, color: Color(r: 211, g: 47, b: 47),
                  width: ink == .pen ? 1.5 : DrawingToolState.widthPresets(for: ink)[2], opacity: 1, at: at)
    }

    func names(_ s: SharedSettings) -> [String] { SavedToolList(settings: s).tools.map(\.name) }

    func decoded(_ s: SharedSettings) -> SharedSettings.Decoded { SharedSettings.Decoded(settings: s, warnings: []) }

    func testRemoveEveryLiveSlotResetsHiddenToolsToo() throws {
        var s = SharedSettings()
        try SavedToolList.add(tool("A", at: 1), to: &s, now: now)
        try SavedToolList.add(tool("B", at: 2), to: &s, now: now)
        // A slot this version cannot show (an ink of a newer version) is live too.
        try s.set(SettingSlotKey(SavedTool.key(for: "9f9c1a52-7e0b-4d9a-9a54-1d2c8b6e4f99")),
                  to: .object(["name": .string("Future"), "ink": .string("laser"), "color": .string("#000000"),
                               "width": .number(2), "at": .number(3)]), type: nil, now: now)
        XCTAssertEqual(try SavedToolList.removeEveryLiveSlot(from: &s, now: now), 3)
        XCTAssertTrue(SavedToolList(settings: s).isEmpty)
        XCTAssertEqual(try SavedToolList.removeEveryLiveSlot(from: &s, now: now), 0, "nothing live is left")
        XCTAssertTrue(SavedToolList.hasSlots(in: s), "the resets stay, so another device does not bring them back")
    }

    // MARK: The preset

    func testTheDocumentedPresetParsesAndRoundTrips() throws {
        let d = try SharedSettings.decode(Data("""
        {"$schemaVersion":1,"$minReaderVersion":1,
         "palette.tool.\(uuidA)":{"name":"Fine red pen","ink":"pen","color":"#D32F2F","width":1.5,"opacity":1,"at":1764727900000,"future":[1]}}
        """.utf8))
        XCTAssertEqual(SharedSettingsCatalog.issues(in: d), [])
        let list = SavedToolList(settings: d.settings)
        let t = try XCTUnwrap(list.tools.first)
        XCTAssertEqual(t.name, "Fine red pen")
        XCTAssertEqual(t.color, Color(r: 211, g: 47, b: 47))
        XCTAssertEqual(t.extra["future"], .array([.number(1)]), "unknown members are kept")
        XCTAssertEqual(SavedTool.parse(id: t.id, t.jsonValue), .success(t))
    }

    func testNamesAreTrimmedNFCAndBounded() {
        XCTAssertEqual(SavedTool.cleanName("  Fine \u{65}\u{301}  "), "Fine \u{e9}")
        XCTAssertNil(SavedTool.cleanName("   "))
        XCTAssertNil(SavedTool.cleanName(String(repeating: "a", count: 41)))
        XCTAssertNotNil(SavedTool.cleanName(String(repeating: "a", count: 40)))
        XCTAssertNil(SavedTool.cleanName("a\nb"))
        XCTAssertNotNil(tool(" padded ").problem(), "a name that is not clean is a problem")
    }

    func testFieldRules() {
        var t = tool("x")
        XCTAssertNil(t.problem())
        t.width = 0.5   // below the pen's 0.88
        XCTAssertNotNil(t.problem())
        t.width = 25.7
        XCTAssertNotNil(t.problem())
        t.width = .nan
        XCTAssertNotNil(t.problem())
        t = tool("x"); t.opacity = 0.04
        XCTAssertNotNil(t.problem())
        t.opacity = 1.01
        XCTAssertNotNil(t.problem())
        t = tool("x"); t.color = Color(r: 1, g: 2, b: 3, a: 200)
        XCTAssertNotNil(t.problem())
        XCTAssertNil(SavedTool.color(fromHex: "D32F2F"))
        XCTAssertNil(SavedTool.color(fromHex: "#D32F2FAA"))
        XCTAssertEqual(SavedTool.color(fromHex: "#d32f2f"), Color(r: 211, g: 47, b: 47))
        XCTAssertFalse(SavedTool.isValidID("3F9C1A52-7E0B-4D9A-9A54-1D2C8B6E4F10"), "lowercase only")
        XCTAssertFalse(SavedTool.isValidID("nope"))
    }

    func testAnOutOfRangeWidthIsSkippedNotClamped() throws {
        var s = SharedSettings()
        s.slots[SettingSlotKey("palette.tool.\(uuidA)")] = SettingSlot(value: .object([
            "name": .string("Wide"), "ink": .string("monoline"), "color": .string("#000000"), "width": .number(9),
            "opacity": .number(1), "at": .number(1)]), meta: nil)
        let list = SavedToolList(settings: s)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.warnings.count, 1)
        XCTAssertTrue(list.warnings[0].contains("width"), list.warnings[0])
        XCTAssertEqual(SharedSettingsCatalog.issues(in: decoded(s)).filter { $0.severity == .error }.count, 1)
    }

    func testAnUnknownInkIsHiddenKeptAndNeverReadAsThePen() throws {
        var s = SharedSettings()
        let slot = SettingSlotKey("palette.tool.\(uuidA)")
        s.slots[slot] = SettingSlot(value: .object([
            "name": .string("Brush"), "ink": .string("sumi"), "color": .string("#000000"), "width": .number(3),
            "opacity": .number(1), "at": .number(1)]), meta: nil)
        XCTAssertEqual(SavedTool.parse(id: uuidA, s.slots[slot]!.value!), .failure(.unknownInk("sumi")))
        let list = SavedToolList(settings: s)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.hiddenCount, 1)
        XCTAssertEqual(list.warnings, [], "not a problem: a newer app's ink")
        XCTAssertEqual(SharedSettingsCatalog.issues(in: decoded(s)).map(\.severity), [.info])
        // Saving something else keeps it, byte for byte.
        var saved = s
        try SavedToolList.add(tool("Pen"), to: &saved, now: now)
        XCTAssertEqual(saved.slots[slot], s.slots[slot])
        // It still counts toward the 64.
        XCTAssertEqual(SavedToolList(settings: saved).liveCount, 2)
    }

    func testPresetsInTypeBlocksAreKeptAndNotShown() throws {
        var s = SharedSettings()
        let slot = SettingSlotKey("palette.tool.\(uuidA)", type: .mac)
        try s.set(slot, to: tool("Blocked", id: uuidA).jsonValue, type: nil, now: now)
        XCTAssertTrue(SavedToolList(settings: s).isEmpty)
        XCTAssertEqual(SharedSettingsCatalog.issues(in: decoded(s)).map(\.severity), [.info])
        let back = try SharedSettings.decode(try s.encoded()).settings
        XCTAssertEqual(back.slots[slot]?.value, s.slots[slot]?.value)
    }

    func testABadKeyAndAMalformedOrderAreErrors() throws {
        let d = try SharedSettings.decode(Data("""
        {"$schemaVersion":1,"$minReaderVersion":1,"palette.tool.NOPE":{"name":"x"},"palette.toolOrder":"a"}
        """.utf8))
        XCTAssertEqual(SharedSettingsCatalog.issues(in: d).filter { $0.severity == .error }.map(\.path).sorted(),
                       ["palette.tool.NOPE", "palette.toolOrder"])
        XCTAssertNotNil(SavedTool.orderProblem(.array([.string("x")])))
        XCTAssertNotNil(SavedTool.orderProblem(.array(Array(repeating: .string(uuidA), count: 65))))
        XCTAssertNil(SavedTool.orderProblem(.array([.string(uuidA)])))
    }

    // MARK: Order, caps

    func testOrderListedFirstThenByAtAndTheRestReconciled() throws {
        var s = SharedSettings()
        let a = tool("A", at: 30), b = tool("B", at: 10), c = tool("C", at: 20), d = tool("D", at: 5)
        for t in [a, b, c, d] { try SavedToolList.add(t, to: &s, now: now) }
        XCTAssertEqual(names(s), ["D", "B", "C", "A"], "by creation time without an order")
        // The order lists C, a missing id, A and C again; B and D follow by `at`.
        try SavedToolList.writeOrder([c.id, uuidA, a.id, c.id], to: &s, now: now)
        XCTAssertEqual(names(s), ["C", "A", "D", "B"])
    }

    func testEqualTimesBreakTiesById() throws {
        var s = SharedSettings()
        let x = tool("X", at: 1, id: "00000000-0000-4000-8000-000000000002")
        let y = tool("Y", at: 1, id: "00000000-0000-4000-8000-000000000001")
        for t in [x, y] { try SavedToolList.add(t, to: &s, now: now) }
        XCTAssertEqual(names(s), ["Y", "X"])
    }

    func testTheCapOf64() throws {
        var s = SharedSettings()
        for i in 0..<64 { try SavedToolList.add(tool("T\(i)", at: Int64(i)), to: &s, now: now) }
        XCTAssertThrowsError(try SavedToolList.add(tool("65th"), to: &s, now: now)) { XCTAssertEqual($0 as? SavedToolError, .tooMany) }
        // Deleting one frees a place: the cap counts live presets only.
        let first = SavedToolList(settings: s).tools[0]
        try SavedToolList.remove(id: first.id, from: &s, now: now)
        try SavedToolList.add(tool("65th", at: 99), to: &s, now: now)
        XCTAssertEqual(SavedToolList(settings: s).tools.count, 64)
        // A file with more shows the first 64 by order and keeps the rest.
        var big = s
        for i in 0..<3 {
            let id = "00000000-0000-4000-8000-00000000000\(i)"
            big.slots[SettingSlotKey("palette.tool.\(id)")] = SettingSlot(value: tool("Extra\(i)", at: 1000 + Int64(i), id: id).jsonValue, meta: nil)
        }
        let list = SavedToolList(settings: big)
        XCTAssertEqual(list.tools.count, 64)
        XCTAssertEqual(list.liveCount, 67)
        XCTAssertEqual(list.hiddenCount, 3)
        XCTAssertTrue(SharedSettingsCatalog.issues(in: decoded(big)).contains { $0.path == "palette.tool.*" })
    }

    func testMoveDestinations() throws {
        var s = SharedSettings()
        let t = ["A", "B", "C", "D"].enumerated().map { tool($1, at: Int64($0)) }
        for x in t { try SavedToolList.add(x, to: &s, now: now) }
        try SavedToolList.move(id: t[3].id, to: .position(1), in: &s, now: now)
        XCTAssertEqual(names(s), ["D", "A", "B", "C"])
        try SavedToolList.move(id: t[0].id, to: .after(t[2].id), in: &s, now: now)
        XCTAssertEqual(names(s), ["D", "B", "C", "A"])
        try SavedToolList.move(id: t[1].id, to: .before(t[3].id), in: &s, now: now)
        XCTAssertEqual(names(s), ["B", "D", "C", "A"])
        let list = SavedToolList(settings: s)
        XCTAssertThrowsError(try list.order(moving: t[0].id, to: .position(5)))
        XCTAssertThrowsError(try list.order(moving: t[0].id, to: .before(t[0].id)))
        XCTAssertThrowsError(try list.order(moving: uuidA, to: .position(1)))
    }

    func testResolveByIdPrefixAndName() throws {
        var s = SharedSettings()
        let a = tool("Same", id: "aaaa0000-0000-4000-8000-000000000001"), b = tool("Same", id: "aaaa1111-0000-4000-8000-000000000002")
        let c = tool("Solo", id: "bbbb0000-0000-4000-8000-000000000003")
        for x in [a, b, c] { try SavedToolList.add(x, to: &s, now: now) }
        let list = SavedToolList(settings: s)
        XCTAssertEqual(try list.resolve(a.id), a)
        XCTAssertEqual(try list.resolve("bbbb"), c)
        XCTAssertEqual(try list.resolve("Solo"), c)
        XCTAssertThrowsError(try list.resolve("Same")) { XCTAssertEqual($0 as? SavedToolError, .ambiguous("Same", [a.id, b.id])) }
        XCTAssertThrowsError(try list.resolve("aaaa"))
        XCTAssertThrowsError(try list.resolve("nothing")) { XCTAssertEqual($0 as? SavedToolError, .notFound("nothing")) }
    }

    // MARK: Merge

    func testTwoDevicesThatEachAddAPresetBothKeepIt() throws {
        var a = SharedSettings(), b = SharedSettings()
        try SavedToolList.add(tool("From A", at: 1), to: &a, type: .ipad, now: now)
        try SavedToolList.add(tool("From B", at: 2), to: &b, type: .mac, now: now)
        XCTAssertEqual(names(a.merging(b)), ["From A", "From B"])
        XCTAssertEqual(names(a.merging(b)), names(b.merging(a)))
    }

    func testEditVersusDeleteLaterWriteWinsAndADeletionIsNotResurrected() throws {
        var base = SharedSettings()
        let t = tool("Original", at: 1)
        try SavedToolList.add(t, to: &base, now: now)
        var editor = base, deleter = base
        var edited = t; edited.name = "Edited"
        try SavedToolList.update(edited, in: &editor, type: .ipad, now: now.addingTimeInterval(10))
        try SavedToolList.remove(id: t.id, from: &deleter, type: .mac, now: now.addingTimeInterval(5))
        XCTAssertEqual(names(editor.merging(deleter)), ["Edited"], "the later write wins for that preset")
        // A device that still holds the preset (the older write) does not bring a deletion back.
        XCTAssertEqual(names(base.merging(deleter)), [])
        var late = deleter
        try SavedToolList.remove(id: t.id, from: &late, type: .mac, now: now.addingTimeInterval(20))
        XCTAssertEqual(names(editor.merging(late)), [])
    }

    func testAnOrderRaceLosesOnlyTheOrder() throws {
        var base = SharedSettings()
        let t = ["A", "B", "C"].enumerated().map { tool($1, at: Int64($0)) }
        for x in t { try SavedToolList.add(x, to: &base, now: now) }
        var one = base, two = base
        try SavedToolList.move(id: t[2].id, to: .position(1), in: &one, type: .ipad, now: now.addingTimeInterval(1))
        try SavedToolList.add(tool("New", at: 9), to: &two, type: .mac, now: now.addingTimeInterval(2))
        try SavedToolList.move(id: t[1].id, to: .position(1), in: &two, type: .mac, now: now.addingTimeInterval(3))
        XCTAssertEqual(Set(names(one.merging(two))), ["A", "B", "C", "New"], "no preset is lost")
    }

    func testAnOlderRegistryReaderKeepsTheKeysThroughASave() throws {
        var s = SharedSettings()
        try SavedToolList.add(tool("Kept", at: 1), to: &s, now: now)
        try SavedToolList.writeOrder(SavedToolList(settings: s).tools.map(\.id), to: &s, now: now)
        // A reader that does not know the family decodes, writes one known setting and re-encodes.
        var older = try SharedSettings.decode(try s.encoded()).settings
        let spec = try XCTUnwrap(SharedSettingsCatalog.spec(named: "eraser.objectRadius"))
        try older.write(spec, .number(32), block: nil, type: .ipad, now: now)
        let reread = try SharedSettings.decode(try older.encoded()).settings
        for (k, slot) in s.slots { XCTAssertEqual(reread.slots[k], slot, "\(k)") }
    }

    // MARK: Seeding and the local list

    func testSeedingAVaultFromTheLocalListAndTheLocalListsStorage() throws {
        var local = SavedToolList()
        try local.add(tool("One", at: 5)); try local.add(tool("Two", ink: .marker, at: 1))
        var s = SharedSettings()
        XCTAssertFalse(SavedToolList.hasSlots(in: s))
        try local.seed(into: &s, now: now)
        XCTAssertTrue(SavedToolList.hasSlots(in: s))
        XCTAssertEqual(names(s), ["One", "Two"], "the local order is kept, not the creation order")
        let back = SavedToolList(decoding: local.encoded())
        XCTAssertEqual(back.tools, local.tools)
        XCTAssertTrue(SavedToolList(decoding: Data("[1,{\"id\":\"x\"}]".utf8)).isEmpty)
        XCTAssertTrue(SavedToolList(decoding: Data("junk".utf8)).isEmpty)
        XCTAssertTrue(SavedToolList(decoding: nil).isEmpty)
        // A deleted vault slot still counts as "has slots": the vault's choice stands.
        for t in local.tools { try SavedToolList.remove(id: t.id, from: &s, now: now) }
        XCTAssertTrue(SavedToolList.hasSlots(in: s))
    }

    func testLocalListEdits() throws {
        var l = SavedToolList()
        let a = tool("A"), b = tool("B")
        try l.add(a); try l.add(b)
        try l.move(id: b.id, to: .position(1))
        XCTAssertEqual(l.tools.map(\.name), ["B", "A"])
        var e = a; e.name = "A2"
        try l.update(e)
        XCTAssertEqual(l.tools.map(\.name), ["B", "A2"])
        l.remove(id: b.id)
        XCTAssertEqual(l.tools.map(\.name), ["A2"])
        XCTAssertThrowsError(try l.add(tool(" ")))
    }

    // MARK: The palette

    func testApplyMakesTheToolAShortcutToAState() {
        var state = DrawingToolState()
        let saved = SavedTool(name: "Yellow marker", ink: .marker, color: Color(r: 255, g: 204, b: 0), width: 14, opacity: 0.4, at: 1)
        XCTAssertFalse(state.isActive(saved))
        state.apply(saved)
        XCTAssertEqual(state.tool, .marker)
        XCTAssertEqual(state.settings(for: .marker), InkSettings(color: saved.color, width: 14, opacity: 0.4))
        XCTAssertTrue(state.isActive(saved))
        // Adjusting the width deselects it: there is no hidden preset mode.
        state.setWidth(20, for: .marker)
        XCTAssertFalse(state.isActive(saved))
        state.setWidth(14.002, for: .marker)
        XCTAssertTrue(state.isActive(saved), "within the tolerance")
        state.select(.pen)
        XCTAssertFalse(state.isActive(saved), "another tool")
    }

    func testApplyReturnsToThePreviousToolLikeAnyToolChange() {
        var state = DrawingToolState()
        state.select(.pencil)
        state.apply(tool("Pen preset"))
        XCTAssertEqual(state.previousTool, .pencil)
        XCTAssertEqual(state.pencil(.switchPrevious), .switchedTool)
        XCTAssertEqual(state.tool, .pencil)
    }

    func testSavingTheCurrentToolRefusesEraserAndLasso() {
        var state = DrawingToolState()
        state.setColor(Color(r: 211, g: 47, b: 47), for: .pen)
        state.setWidth(1.5, for: .pen)
        let saved = state.saving(name: "  Fine red pen ", now: now)
        XCTAssertEqual(saved?.name, "Fine red pen")
        XCTAssertEqual(saved?.ink, .pen)
        XCTAssertEqual(saved.map(state.isActive), true)
        XCTAssertNil(state.saving(name: ""))
        state.select(.eraser)
        XCTAssertNil(state.saving(name: "Eraser"))
        state.select(.lasso)
        XCTAssertNil(state.saving(name: "Lasso"))
    }

    // MARK: sempere-tools/1

    func testExportImportRoundTripWithInvalidEntries() throws {
        var l = SavedToolList()
        try l.add(tool("One", at: 5)); try l.add(tool("Two", ink: .marker, at: 1))
        let data = try SavedToolFile.encode(l)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(l.tools[0].id), "no ids")
        let parsed = try SavedToolFile.parse(data, now: now)
        XCTAssertEqual(parsed.tools.map(\.name), ["One", "Two"])
        XCTAssertEqual(parsed.skipped, [])
        XCTAssertTrue(Set(parsed.tools.map(\.id)).isDisjoint(with: l.tools.map(\.id)), "fresh ids")
        XCTAssertTrue(parsed.tools.allSatisfy { $0.problem() == nil })

        let messy = Data("""
        {"format":"sempere-tools/1","tools":[
          {"name":"Good","ink":"pen","color":"#000000","width":2,"opacity":1},
          {"name":"","ink":"pen","color":"#000000","width":2,"opacity":1},
          {"name":"Far","ink":"pen","color":"#000000","width":99,"opacity":1},
          {"name":"Odd","ink":"sumi","color":"#000000","width":2,"opacity":1},
          7]}
        """.utf8)
        let p = try SavedToolFile.parse(messy, now: now)
        XCTAssertEqual(p.tools.map(\.name), ["Good"])
        XCTAssertEqual(p.skipped.count, 4)
        XCTAssertThrowsError(try SavedToolFile.parse(Data("{\"format\":\"other\",\"tools\":[]}".utf8)))
        XCTAssertThrowsError(try SavedToolFile.parse(Data("nope".utf8)))
    }

    func testTheSchemaCoversTheFamily() throws {
        let text = String(decoding: try SharedSettingsSchema.json(), as: UTF8.self)
        XCTAssertTrue(text.contains("palette.toolOrder"))
        XCTAssertTrue(text.contains("^palette\\\\.tool\\\\.[0-9a-f-]{36}$"), text)
    }
}
