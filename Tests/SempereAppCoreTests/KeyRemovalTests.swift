import Age
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// What deleting this device's keys for a vault costs (`KeyRemoval.check`): the words are the app's
/// (`JoinTakeoverAppTests`).
struct KeyRemovalTests {
    /// Review of #88, M4, and its re-check (R2, SHOULD): the one check behind every removal of this device's keys
    /// tells home alone from home with others.
    @Test func deletingTheHomesCopyIsRecognized() async throws {
        let homeStore = MemoryDeviceKeyStore()
        let (url, id, home) = try await Self.vault(device: try homeStore.generate())
        try await homeStore.save(home, for: id, vaultName: "Mine")
        let alone = await KeyRemoval.check(vaultID: id, at: url, store: homeStore)
        #expect(alone.home == .alone)
        #expect(!alone.offersMakeHome)
        let phoneStore = MemoryDeviceKeyStore()
        let phone = try phoneStore.generate()
        try await phoneStore.save(phone, for: id, vaultName: "Mine")
        try await Self.approve(phone, in: url, home: home)
        let withOthers = await KeyRemoval.check(vaultID: id, at: url, store: homeStore)
        #expect(withOthers.home == .withOthers)
        #expect(withOthers.offersMakeHome)
        let member = await KeyRemoval.check(vaultID: id, at: url, store: phoneStore)
        #expect(member.home == .no)
        // No folder to look in: home is not looked up.
        #expect(await KeyRemoval.check(vaultID: id, at: nil, store: homeStore).home == .no)
    }

    /// "Mine", created by `device` (its home), off the main actor: its folder, id and keys.
    static func vault(device: DeviceKeys) async throws -> (url: URL, id: UUID, home: DeviceKeys) {
        let parent = TestTemp.root.appendingPathComponent("Join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var request = NewVaultRequest(name: "Mine", keySource: .generate, passphrase: nil)
        request.deviceName = "Home iPad"
        request.workFactor = 10
        request.device = device
        let created = try VaultLibrary.createVault(request, folder: "Mine.sempere", in: parent)
        return (created.url, created.vaultID, created.device)
    }

    /// Home approves `device` (its list grows), off the main actor.
    static func approve(_ device: DeviceKeys, in url: URL, home: DeviceKeys) async throws {
        var vault = try Vault.open(at: url, identities: [home.nativeIdentity], signing: home.signing)
        _ = try vault.approveDevice(device.joinRequest(vaultId: vault.vaultId, name: "Phone", kind: "iphone"))
    }
}
