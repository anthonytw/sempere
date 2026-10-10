import Foundation
import XCTest
@testable import Sempere

/// One device's settings sync (docs/settings-sync.md §4): first enable, passes,
/// local overrides and type blocks.
final class SettingsSyncStateTests: XCTestCase {
    var clock = 1_760_000_000_000.0
    func now() -> Date { clock += 1000; return Date(timeIntervalSince1970: clock / 1000) }

    /// A device's effective values: every setting it uses at its default, then `changes`.
    func local(_ type: SettingsDeviceType, _ changes: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for spec in SharedSettingsCatalog.specs(for: type) { out[spec.name] = spec.defaultValue }
        return out.merging(changes) { $1 }
    }

    /// Applies a pass to a device's values, as the app would.
    func applying(_ pass: SettingsSyncState.Pass, to values: inout [String: JSONValue]) {
        values.merge(pass.apply) { $1 }
    }

    // MARK: - First enable

    func testFirstEnableOnAVaultWithoutSettingsSeedsFromThisDevice() throws {
        let mine = local(.ipad, ["eraser.mode": .string("pixel")])
        XCTAssertEqual(SettingsSyncState.discover(local: mine, file: nil, type: .ipad), .empty)
        var state = SettingsSyncState()
        let pass = try state.enable(.useVault, local: mine, file: nil, type: .ipad, now: now())
        XCTAssertEqual(pass.apply, [:])
        let written = try XCTUnwrap(pass.write)
        XCTAssertEqual(written.value(SettingSlotKey("eraser.mode")), .string("pixel"))
        XCTAssertEqual(Set(written.slots.keys.map(\.key)), Set(SharedSettingsCatalog.specs(for: .ipad).map(\.name)))
        XCTAssertTrue(written.slots.keys.allSatisfy { $0.block == nil }, "seeded at the top level")
        XCTAssertEqual(written.slots[SettingSlotKey("eraser.mode")]?.meta?.type, "ipad")
        XCTAssertNil(try state.reconcile(local: mine, file: written, type: .ipad, now: now()).write, "nothing more to write")
    }

    func testFirstEnableWhenTheVaultAgrees() throws {
        let file = try seeded(.ipad, ["photos.removeMetadata": .bool(false)])
        let mine = local(.mac, ["photos.removeMetadata": .bool(false)])
        XCTAssertEqual(SettingsSyncState.discover(local: mine, file: file, type: .mac), .agrees)
        var state = SettingsSyncState()
        let pass = try state.enable(.useVault, local: mine, file: file, type: .mac, now: now())
        XCTAssertEqual(pass.apply, [:])
        // Only what the Mac adds (mouse smoothing, which the iPad does not use) is written.
        let added = try XCTUnwrap(pass.write).slots.filter { file.slots[$0.key] == nil }.map(\.key.key)
        XCTAssertEqual(added, ["mouse.smoothing"])
    }

    func testFirstEnableUseTheVaultsSettings() throws {
        let file = try seeded(.ipad, ["eraser.objectRadius": .number(16), "history.thinAfterDays": .number(90)])
        var mine = local(.mac, ["history.thinAfterDays": .number(7)])
        guard case .differs(let diffs) = SettingsSyncState.discover(local: mine, file: file, type: .mac) else {
            return XCTFail("expected differences")
        }
        XCTAssertEqual(Set(diffs.map(\.key)), ["eraser.objectRadius", "history.thinAfterDays"])
        XCTAssertEqual(diffs.first { $0.key == "history.thinAfterDays" }?.vault, .number(90))
        XCTAssertEqual(diffs.first { $0.key == "history.thinAfterDays" }?.device, .number(7))
        var state = SettingsSyncState()
        let pass = try state.enable(.useVault, local: mine, file: file, type: .mac, now: now())
        XCTAssertEqual(pass.apply, ["eraser.objectRadius": .number(16), "history.thinAfterDays": .number(90)])
        applying(pass, to: &mine)
        XCTAssertEqual(try XCTUnwrap(pass.write).value(SettingSlotKey("history.thinAfterDays")), .number(90))
        XCTAssertNil(try state.reconcile(local: mine, file: pass.write, type: .mac, now: now()).write)
    }

    func testFirstEnableReplaceTheVaultsSettings() throws {
        var file = try seeded(.ipad, ["history.thinAfterDays": .number(90)])
        try file.set(SettingSlotKey("eraser.mode", type: .mac), to: .string("pixel"), type: .mac, now: now())
        let mine = local(.mac, ["history.thinAfterDays": .number(7), "eraser.mode": .string("object")])
        var state = SettingsSyncState()
        let pass = try state.enable(.replaceVault, local: mine, file: file, type: .mac, now: now())
        XCTAssertEqual(pass.apply, [:])
        let w = try XCTUnwrap(pass.write)
        XCTAssertEqual(w.value(SettingSlotKey("history.thinAfterDays")), .number(7))
        XCTAssertEqual(w.value(SettingSlotKey("eraser.mode", type: .mac)), .string("object"), "written where it resolves from")
        XCTAssertEqual(w.value(SettingSlotKey("eraser.mode")), .string("object"), "the top level was the iPad's default all along")
        // On the iPad, the replaced values arrive.
        var ipad = SettingsSyncState()
        var ipadValues = local(.ipad, ["history.thinAfterDays": .number(90)])
        _ = try ipad.enable(.useVault, local: ipadValues, file: file, type: .ipad, now: now())
        applying(try ipad.reconcile(local: ipadValues, file: w, type: .ipad, now: now()), to: &ipadValues)
        XCTAssertEqual(ipadValues["history.thinAfterDays"], .number(7))
    }

    func testDisableForgetsEverything() throws {
        var state = SettingsSyncState()
        _ = try state.enable(.useVault, local: local(.mac), file: nil, type: .mac, now: now())
        state.override("eraser.mode")
        state.disable()
        XCTAssertEqual(state, SettingsSyncState())
        XCTAssertEqual(try state.reconcile(local: local(.mac), file: nil, type: .mac, now: now()), .init())
    }

    // MARK: - Passes

    func testLocalEditsGoToTheFileAndArriveOnTheOtherDevice() throws {
        var (mac, macValues, ipad, ipadValues, file) = try twoDevices()
        macValues["newNote.titleFormat"] = .string("weekday")
        let p1 = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(p1.apply, [:])
        file = try XCTUnwrap(p1.write)
        let p2 = try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now())
        XCTAssertEqual(p2.apply, ["newNote.titleFormat": .string("weekday")])
        XCTAssertNil(p2.write)
        applying(p2, to: &ipadValues)
        // The value it received is not taken for an edit on the next pass.
        XCTAssertEqual(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()), .init())
    }

    func testAFileThatLostAWriteIsWrittenBack() throws {
        var (mac, macValues, ipad, ipadValues, file) = try twoDevices()
        let base = file
        macValues["recording.codec"] = .string("alac")
        _ = try mac.reconcile(local: macValues, file: base, type: .mac, now: now())   // the Mac's write...
        ipadValues["photos.removeMetadata"] = .bool(false)
        file = try XCTUnwrap(try ipad.reconcile(local: ipadValues, file: base, type: .ipad, now: now()).write)   // ...lost to the iPad's
        XCTAssertEqual(file.value(SettingSlotKey("recording.codec")), .string("aac"))
        let again = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(again.apply, ["photos.removeMetadata": .bool(false)])
        let healed = try XCTUnwrap(again.write, "the Mac puts its change back")
        XCTAssertEqual(healed.value(SettingSlotKey("recording.codec")), .string("alac"))
        XCTAssertEqual(healed.value(SettingSlotKey("photos.removeMetadata")), .bool(false))
    }

    func testSettingsAddedLaterAreSeededAndUnknownOnesKept() throws {
        var (mac, macValues, _, _, file) = try twoDevices()
        file.slots.removeValue(forKey: SettingSlotKey("mouse.smoothing"))
        try file.set(SettingSlotKey("future.setting"), to: .string("x"), type: .ipad, now: now())
        mac.known = SharedSettings()   // as if the Mac had never seen mouse.smoothing
        macValues["mouse.smoothing"] = .string("strong")
        let pass = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        let w = try XCTUnwrap(pass.write)
        XCTAssertEqual(w.value(SettingSlotKey("mouse.smoothing")), .string("strong"))
        XCTAssertEqual(w.value(SettingSlotKey("future.setting")), .string("x"))
    }

    func testInvalidValuesAreNotAppliedAndWarn() throws {
        var (mac, macValues, _, _, file) = try twoDevices()
        file.slots[SettingSlotKey("eraser.objectRadius")] = SettingSlot(value: .number(5), meta: SettingSlotMeta(modified: 9_000_000_000_000))
        macValues["eraser.objectRadius"] = .number(16)
        mac.applied["eraser.objectRadius"] = .number(16)
        let pass = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(pass.apply["eraser.objectRadius"], .number(8), "falls back to the default")
        XCTAssertEqual(pass.warnings.count, 1)
        XCTAssertNil(pass.write, "the invalid value stays in the file untouched")
    }

    func testAMigratedFileIsNotWrittenByItself() throws {
        var (mac, macValues, _, _, file) = try twoDevices()
        file.schemaVersion = 1
        XCTAssertNil(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).write)
        macValues["eraser.mode"] = .string("pixel")
        XCTAssertNotNil(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).write)
    }

    // MARK: - Local overrides

    func testOverrideLifecycle() throws {
        var (mac, macValues, ipad, ipadValues, file) = try twoDevices()
        // Only on this device: keeps its value, ignores shared changes, edits stay local.
        mac.override("history.thinAfterDays")
        XCTAssertEqual(mac.rowState("history.thinAfterDays", type: .mac), .overridden)
        ipadValues["history.thinAfterDays"] = .number(90)
        file = try XCTUnwrap(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()).write)
        XCTAssertNil(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).apply["history.thinAfterDays"])
        macValues["history.thinAfterDays"] = .number(7)
        let edit = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        XCTAssertNil(edit.write, "an overridden edit is never written")
        // Setting it to the shared value does not relink it.
        macValues["history.thinAfterDays"] = .number(90)
        _ = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        XCTAssertTrue(mac.isOverridden("history.thinAfterDays"))
        macValues["history.thinAfterDays"] = .number(14)
        ipadValues["history.thinAfterDays"] = .number(365)
        file = try XCTUnwrap(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()).write)
        XCTAssertNil(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).apply["history.thinAfterDays"])
        // Use Synced Value: takes the shared value; the local one is not an edit.
        let back = try mac.useSynced("history.thinAfterDays", local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(back.apply["history.thinAfterDays"], .number(365))
        XCTAssertNil(back.write)
        XCTAssertEqual(mac.rowState("history.thinAfterDays", type: .mac), .synced)
        applying(back, to: &macValues)
        // From now on edits sync again.
        macValues["history.thinAfterDays"] = .number(30)
        let synced = try mac.reconcile(local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(try XCTUnwrap(synced.write).value(SettingSlotKey("history.thinAfterDays")), .number(30))
    }

    func testUseSyncedValueSeedsWhenTheVaultHasNone() throws {
        var (mac, macValues, _, _, file) = try twoDevices()
        mac.override("mouse.smoothing")
        file.slots.removeValue(forKey: SettingSlotKey("mouse.smoothing"))
        mac.known.slots.removeValue(forKey: SettingSlotKey("mouse.smoothing"))
        macValues["mouse.smoothing"] = .string("off")
        let pass = try mac.useSynced("mouse.smoothing", local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(pass.apply, [:])
        XCTAssertEqual(try XCTUnwrap(pass.write).value(SettingSlotKey("mouse.smoothing")), .string("off"))
    }

    // MARK: - Type blocks

    func testOnlyOnThisTypeAndUseOnAllDevices() throws {
        var (mac, macValues, ipad, ipadValues, file) = try twoDevices()
        macValues["eraser.mode"] = .string("pixel")
        mac.applied["eraser.mode"] = .string("pixel")   // changed while overridden, say
        let only = try mac.onlyOnThisType("eraser.mode", local: macValues, file: file, type: .mac, now: now())
        file = try XCTUnwrap(only.write)
        XCTAssertEqual(file.value(SettingSlotKey("eraser.mode", type: .mac)), .string("pixel"))
        XCTAssertEqual(file.value(SettingSlotKey("eraser.mode")), .string("object"))
        XCTAssertEqual(mac.rowState("eraser.mode", type: .mac), .typeSpecific)
        // The iPad keeps the top level; a later Mac edit stays in the block.
        XCTAssertNil(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()).apply["eraser.mode"])
        macValues["eraser.mode"] = .string("object")
        file = try XCTUnwrap(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).write)
        XCTAssertEqual(file.value(SettingSlotKey("eraser.mode", type: .mac)), .string("object"))
        macValues["eraser.mode"] = .string("pixel")
        file = try XCTUnwrap(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).write)
        // An iPad edit goes to the top level and does not reach the Mac.
        ipadValues["eraser.mode"] = .string("pixel")
        file = try XCTUnwrap(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()).write)
        ipadValues["eraser.mode"] = .string("object")
        file = try XCTUnwrap(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()).write)
        XCTAssertNil(try mac.reconcile(local: macValues, file: file, type: .mac, now: now()).apply["eraser.mode"])
        // Use on All Devices: the block's slot is reset and the top level applies.
        let all = try mac.useOnAllDevices("eraser.mode", local: macValues, file: file, type: .mac, now: now())
        XCTAssertEqual(all.apply["eraser.mode"], .string("object"))
        let w = try XCTUnwrap(all.write)
        XCTAssertNil(w.value(SettingSlotKey("eraser.mode", type: .mac)))
        XCTAssertNotNil(w.slots[SettingSlotKey("eraser.mode", type: .mac)]?.meta, "a reset, kept for the merge")
        XCTAssertEqual(mac.rowState("eraser.mode", type: .mac), .synced)
    }

    func testTwoMacsShareTheirBlock() throws {
        var (mac, macValues, _, _, file) = try twoDevices()
        var mac2 = SettingsSyncState()
        var mac2Values = local(.mac)
        applying(try mac2.enable(.useVault, local: mac2Values, file: file, type: .mac, now: now()), to: &mac2Values)
        macValues["eraser.mode"] = .string("pixel")
        file = try XCTUnwrap(try mac.onlyOnThisType("eraser.mode", local: macValues, file: file, type: .mac, now: now()).write)
        XCTAssertEqual(try mac2.reconcile(local: mac2Values, file: file, type: .mac, now: now()).apply["eraser.mode"], .string("pixel"))
    }

    func testStateRoundTripsThroughCodable() throws {
        var (mac, _, _, _, _) = try twoDevices()
        mac.override("eraser.mode")
        let data = try JSONEncoder().encode(mac)
        XCTAssertEqual(try JSONDecoder().decode(SettingsSyncState.self, from: data), mac)
    }

    // MARK: - Helpers

    /// The file a device of `type` writes when it turns sync on first.
    func seeded(_ type: SettingsDeviceType, _ changes: [String: JSONValue]) throws -> SharedSettings {
        var s = SettingsSyncState()
        return try XCTUnwrap(try s.enable(.useVault, local: local(type, changes), file: nil, type: type, now: now()).write)
    }

    /// An iPad that turned sync on first and a Mac that joined.
    func twoDevices() throws -> (SettingsSyncState, [String: JSONValue], SettingsSyncState, [String: JSONValue], SharedSettings) {
        var ipad = SettingsSyncState(), mac = SettingsSyncState()
        let ipadValues = local(.ipad)
        var macValues = local(.mac)
        var file = try XCTUnwrap(try ipad.enable(.useVault, local: ipadValues, file: nil, type: .ipad, now: now()).write)
        let pass = try mac.enable(.useVault, local: macValues, file: file, type: .mac, now: now())
        applying(pass, to: &macValues)
        file = pass.write ?? file
        XCTAssertNil(try ipad.reconcile(local: ipadValues, file: file, type: .ipad, now: now()).write)
        return (mac, macValues, ipad, ipadValues, file)
    }
}
