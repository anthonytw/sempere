import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The palette's saved tools through the model (`AppModel+SavedTools`, docs/design/1.3-custom-tools.md §3.3): this
    /// device's own list with Sync Settings with This Vault off, the open vault's with it on, seeding on turning it on.
    /// The rules themselves are `SavedToolsTests` (SempereTests).
    @MainActor
    struct SavedToolsModelTests {
        let settings = MemoryKeyValueStore()

        func model() async throws -> (AppModel, Vault) {
            let (url, key) = try await ModelFixture.vault()
            var services = AppModelServices.headless(settings: settings)
            services.platform = HeadlessPlatform()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), services: services)
            model.settingsDeviceTypeOverride = .ipad
            model.settingsSyncDebounce = .milliseconds(10)
            try await model.openVault(at: url)
            let text = try await ModelFixture.keyText(key)
            try await model.unlock(identityText: text)
            let vault = try await SettingsSyncTests.open(url, try IdentityFile.parse(text))
            return (model, vault)
        }

        func tool(_ name: String, ink: InkTool = .pen, at: Int64 = 1) -> SavedTool {
            SavedTool(name: name, ink: ink, color: Color(r: 211, g: 47, b: 47),
                      width: ink == .pen ? 1.5 : DrawingToolState.widthPresets(for: ink)[2], at: at)
        }

        @Test func withSyncOffTheDevicesOwnListIsUsed() async throws {
            let (model, vault) = try await model()
            #expect(model.savedTools.isEmpty)
            let a = tool("A", at: 1), b = tool("B", at: 2)
            #expect(await model.changeSavedTools(.add(a)) == .done)
            #expect(await model.changeSavedTools(.add(b)) == .done)
            #expect(model.savedTools.tools.map(\.name) == ["A", "B"])
            #expect(await model.changeSavedTools(.move(b.id, .position(1))) == .done)
            var renamed = a; renamed.name = "A2"
            #expect(await model.changeSavedTools(.update(renamed)) == .done)
            #expect(model.savedTools.tools.map(\.name) == ["B", "A2"])
            #expect(model.localSavedTools.tools.map(\.name) == ["B", "A2"], "kept in the device's store")
            #expect(try vault.readSharedSettings() == nil, "nothing reaches the vault")
            #expect(await model.changeSavedTools(.remove(b.id)) == .done)
            #expect(model.savedTools.tools.map(\.name) == ["A2"])
            // A tool that is not valid is refused and changes nothing.
            var bad = tool("Bad"); bad.width = 99
            guard case .refused = await model.changeSavedTools(.add(bad)) else { Issue.record("not refused"); return }
            #expect(model.savedTools.tools.count == 1)
        }

        @Test func turningSyncOnSeedsAVaultThatHasNoSavedToolsFromTheDevicesList() async throws {
            let (model, vault) = try await model()
            await model.changeSavedTools(.add(tool("Mine", at: 1)))
            await model.changeSavedTools(.add(tool("Marker", ink: .marker, at: 2)))
            await model.setSettingsSync(true)
            #expect(model.settingsSync.enabled)
            let file = try #require(try vault.readSharedSettings())
            #expect(SavedToolList(settings: file).tools.map(\.name) == ["Mine", "Marker"])
            #expect(file.slots[SettingSlotKey(SavedTool.key(for: model.savedTools.tools[0].id))]?.meta?.type == "ipad")
            #expect(model.savedTools.tools.map(\.name) == ["Mine", "Marker"])
        }

        @Test func withSyncOnTheOpenVaultsToolsAreUsedAndSavesGoToTheVault() async throws {
            let (model, vault) = try await model()
            // Another device's tool is already in the vault.
            let theirs = tool("Theirs", at: 5)
            try vault.updateSharedSettings { s in try SavedToolList.add(theirs, to: &s, type: .mac, now: Date()) }
            await model.changeSavedTools(.add(tool("Local only")))   // the device's list, before sync
            await model.setSettingsSync(true)
            #expect(model.savedTools.tools.map(\.name) == ["Theirs"], "the vault's, the device's list stays on the device")
            #expect(model.localSavedTools.tools.map(\.name) == ["Local only"])

            let mine = tool("Mine", at: 9)
            #expect(await model.changeSavedTools(.add(mine)) == .done)
            #expect(model.savedTools.tools.map(\.name) == ["Theirs", "Mine"])
            #expect(SavedToolList(settings: try #require(try vault.readSharedSettings())).tools.map(\.name) == ["Theirs", "Mine"])
            #expect(model.localSavedTools.tools.map(\.name) == ["Local only"], "the device's own list is not touched")

            // A later pass (a remote change) shows another device's new tool.
            let later = tool("Later", at: 20)
            try vault.updateSharedSettings { s in try SavedToolList.add(later, to: &s, type: .mac, now: Date().addingTimeInterval(5)) }
            await model.syncSettingsNow()
            #expect(model.savedTools.tools.map(\.name) == ["Theirs", "Mine", "Later"])

            // Delete is a reset of the slot; reordering writes the order slot.
            #expect(await model.changeSavedTools(.remove(theirs.id)) == .done)
            #expect(await model.changeSavedTools(.move(later.id, .position(1))) == .done)
            #expect(model.savedTools.tools.map(\.name) == ["Later", "Mine"])
            let file = try #require(try vault.readSharedSettings())
            #expect(file.slots[SettingSlotKey(SavedTool.key(for: theirs.id))]?.value == nil)
            #expect(file.slots[SettingSlotKey(SavedTool.key(for: theirs.id))]?.meta != nil)
            #expect(file.value(SettingSlotKey(SavedTool.orderKey)) != nil)
        }

        @Test func replacingTheVaultsToolsWithTheDevicesOwn() async throws {
            let (model, vault) = try await model()
            try vault.updateSharedSettings { s in try SavedToolList.add(tool("Theirs"), to: &s, type: .mac, now: Date()) }
            await model.changeSavedTools(.add(tool("Mine")))
            await model.setSettingsSync(true)
            #expect(model.savedTools.tools.map(\.name) == ["Theirs"])
            #expect(await model.replaceVaultSavedToolsWithLocal() == .done)
            #expect(model.savedTools.tools.map(\.name) == ["Mine"])
            #expect(SavedToolList(settings: try #require(try vault.readSharedSettings())).tools.map(\.name) == ["Mine"])
        }

        @Test func seedingIsDecidedUnderTheLockSoAToolThatLandedFirstIsKept() async throws {
            let (model, vault) = try await model()
            await model.setSettingsSync(true)   // nothing local, nothing in the vault
            // The tools another device synced land after the seed was decided on, before it is applied.
            try vault.updateSharedSettings { s in try SavedToolList.add(tool("Theirs"), to: &s, type: .mac, now: Date()) }
            var mine = SavedToolList()
            try mine.add(tool("Mine"))
            #expect(await model.changeSavedTools(.seedIfEmpty(mine)) == .done)
            #expect(SavedToolList(settings: try #require(try vault.readSharedSettings())).tools.map(\.name) == ["Theirs"])
            // Replacing is the explicit action and still resets them.
            #expect(await model.changeSavedTools(.replaceAll(mine)) == .done)
            #expect(SavedToolList(settings: try #require(try vault.readSharedSettings())).tools.map(\.name) == ["Mine"])
        }

        @Test func turningSyncOffShowsTheDevicesListAgain() async throws {
            let (model, vault) = try await model()
            await model.changeSavedTools(.add(tool("Mine")))
            await model.setSettingsSync(true)
            try vault.updateSharedSettings { s in try SavedToolList.add(tool("Theirs", at: 9), to: &s, type: .mac, now: Date().addingTimeInterval(5)) }
            await model.syncSettingsNow()
            #expect(model.savedTools.tools.count == 2)
            await model.setSettingsSync(false)
            #expect(model.savedTools.tools.map(\.name) == ["Mine"])
        }

        @Test func theCapOf64IsEnforcedInTheVault() async throws {
            let (model, vault) = try await model()
            await model.setSettingsSync(true)
            for i in 0..<64 { #expect(await model.changeSavedTools(.add(tool("T\(i)", at: Int64(i)))) == .done) }
            #expect(await model.changeSavedTools(.add(tool("65th"))) == .refused(.tooMany))
            #expect(SavedToolList(settings: try #require(try vault.readSharedSettings())).tools.count == 64)
        }
    }
}
