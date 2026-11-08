import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// AppModel against the committed fixture vault (`Tests/SempereTests/Fixtures`,
/// copied into this bundle as a folder reference). See its README for contents.
@MainActor
struct AppModelTests {
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// A private copy of the fixture, so no test can touch the bundled one.
    static func fixtureVault() throws -> (vault: URL, key: URL) {
        let bundle = Bundle(for: BundleToken.self)
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Fixtures missing from test bundle"])
        }
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("sample.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("sample.sempere"), to: vault)
        return (vault, fixtures.appendingPathComponent("sample.key"))
    }

    /// The recovery key's passphrase copy (format.md §15.11) opens the vault
    /// read-only (design §4.3 step 4), checked against the root it carries.
    @Test func unlocksReadOnlyWithTheRecoveryPassphraseCopy() async throws {
        let (url, _) = try Self.fixtureVault()
        let model = AppModel(trust: MemoryEpochTrustStore())
        try await model.openVault(at: url)
        await #expect(throws: AppModel.ModelError.passphraseMatchesNoKey) {
            try await model.unlock(passphrase: "wrong")
        }
        #expect(model.phase == .locked)
        try await model.unlock(passphrase: "sempere-test")
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(model.isRecoveryOpen)
        #expect(model.isVaultReadOnly)
        #expect(model.listAlert == nil, "the copy's root confirms the list")
        #expect(model.readOnlyBanner == AppModel.recoveryReadOnlyText)
        #expect(throws: VaultError.recoveryKeyReadOnly) { try model.requireWritableVault() }
        await #expect(throws: (any Error).self) {
            try await model.createNote(title: "No", paper: Paper(kind: .ruled), notebook: nil)
        }
        #expect(model.notes.count == 2)
    }

    /// The recovery key itself, pasted: read-only too, and never offered to remember.
    @Test func thePastedRecoveryKeyOpensReadOnly() async throws {
        let (url, key) = try Self.fixtureVault()
        let recovery = key.deletingLastPathComponent().appendingPathComponent("sample-recovery.key")
        let model = AppModel()
        try await model.openVault(at: url)
        let device = try await model.unlock(identityText: try String(contentsOf: recovery, encoding: .utf8))
        #expect(device == nil)
        #expect(model.isRecoveryOpen)
        #expect(model.isVaultReadOnly)
        #expect(model.heldDeviceKey == nil)
    }

    /// The fixture's device key file unlocks with its signing keys: this device is listed (home).
    @Test func theDeviceKeyFileUnlocksAsAListedDevice() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        let device = try #require(try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8)))
        #expect(!model.isRecoveryOpen)
        #expect(!model.isVaultReadOnly)
        #expect(model.heldDeviceKey == device.key)
        #expect(model.unlockKeys.signing != nil)
        #expect(model.vaultDevices.contains { $0.isThisDevice && $0.deviceID == device.id })
        #expect(model.vaultDevices.filter(\.isRecovery).count == 1)
    }

    // MARK: - Late results after close (generation token)

}

private final class BundleToken {}
