import Age
import Foundation
import Sempere
import SempereWebDAV
import Testing
@testable import SempereApp

/// Audit check c30, automated: a vault created by the app on each kind of
/// storage, a second device's key added, both devices editing, locking and
/// unlocking, and no warning about the device list (`recipientsAlert`) on
/// either. Each "device" is its own `AppModel` with its own device state,
/// trust record store and remembered-key store (`FakeKeyStore`).
@Suite(.serialized, .timeLimit(.minutes(10)))
@MainActor
struct TwoDeviceVaultTests {
    /// One device: a model and what it keeps for itself.
    @MainActor
    struct Device {
        let name: String
        let model: AppModel
        let trust: MemoryRecipientsTrustStore
        let keys = FakeKeyStore()
        var identity: NativeIdentity

        init(_ name: String, identity: NativeIdentity, cloud: FakeCloud?) {
            self.name = name
            self.identity = identity
            let trust = MemoryRecipientsTrustStore()
            self.trust = trust
            model = AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
            if let cloud {
                model.cloudHooks = cloud.hooks
                model.cloudPollInterval = .milliseconds(10)
                model.cloudIdleInterval = .milliseconds(20)
            }
        }

        /// Opens and unlocks (from scratch, as after a lock), then checks the list.
        func unlock(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            model.close()
            try await model.openVault(at: url)
            try await model.unlock(identityText: identity.string)
            #expect(model.phase == .unlocked, "\(name)", sourceLocation: sourceLocation)
            expectNoListWarning(sourceLocation: sourceLocation)
        }

        func expectNoListWarning(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(model.recipientsAlert == nil, "\(name): \(String(describing: model.recipientsAlert))",
                    sourceLocation: sourceLocation)
            #expect(model.vault?.recipientsStatus.problem == nil, "\(name)", sourceLocation: sourceLocation)
        }

        /// Saves the key as the remember sheet would, and reads it back.
        func rememberAndReadKey() async throws {
            let vaultID = try #require(model.vault?.vaultId)
            try await keys.save(identity.string, for: vaultID, vaultName: "Shared", storage: .thisDevice)
            #expect(try await keys.readKey(for: vaultID, reason: "test") == identity.string)
        }
    }

    enum Storage: String, CaseIterable, CustomTestStringConvertible {
        case onDevice, iCloudDrive
        var testDescription: String { rawValue }
    }

    /// Creates a vault the way the New Vault sheet does (generated key), in a
    /// fresh parent folder; returns its folder and the generated key.
    static func createVault() throws -> (url: URL, key: NativeIdentity) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("c30-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let created = try VaultLibrary.createVault(NewVaultRequest(name: "Shared", keySource: .generate, passphrase: nil),
                                                   folder: "Shared.sempere", in: parent)
        return (created.url, try IdentityFile.parse(try #require(created.secretKey)))
    }

    /// c30 on a local folder and in (faked) iCloud Drive.
    @Test(arguments: Storage.allCases)
    func c30NewVaultSharedWithASecondDeviceShowsNoListWarning(_ storage: Storage) async throws {
        let (url, keyA) = try Self.createVault()
        let cloud = storage == .iCloudDrive ? FakeCloud(vault: url) : nil
        cloud?.autoDeliver = true
        let a = Device("A", identity: keyA, cloud: cloud)
        try await a.unlock(url)
        try await a.rememberAndReadKey()
        let b = Device("B", identity: try NativeIdentity.generate(.postQuantum), cloud: cloud)
        try await a.model.addDeviceKey(recipient: b.identity.recipient.string, label: "B's iPad",
                                       authenticator: PassingOwnerAuthenticator())
        a.expectNoListWarning()
        try await b.unlock(url)
        try await b.rememberAndReadKey()

        // Edit on both, then each sees the other's note.
        let fromA = try await a.model.createNote(title: "From A", paper: Paper(kind: .ruled), notebook: nil)
        let fromB = try await b.model.createNote(title: "From B", paper: Paper(kind: .grid), notebook: nil)
        try await a.model.reload()
        try await b.model.reload()
        for device in [a, b] {
            #expect(Set(device.model.notes.map(\.id)).isSuperset(of: [fromA, fromB]), "\(device.name)")
            device.expectNoListWarning()
        }
        // Lock and unlock both.
        try await a.unlock(url)
        try await b.unlock(url)
        #expect(a.model.notes.count == 2 && b.model.notes.count == 2)
        a.model.close()
        b.model.close()
    }

    /// c30 stress: three devices, the key added while the other is open, and
    /// a device removed (a rotation) and added again. Nobody sees a warning:
    /// B's record follows the rotation through the vault's signed secret link.
    @Test func c30ThreeDevicesRemoveAndReAddShowNoListWarning() async throws {
        let (url, keyA) = try Self.createVault()
        let a = Device("A", identity: keyA, cloud: nil)
        let b = Device("B", identity: try NativeIdentity.generate(.postQuantum), cloud: nil)
        let c = Device("C", identity: try NativeIdentity.generate(.postQuantum), cloud: nil)
        try await a.unlock(url)
        try await a.model.addDeviceKey(recipient: b.identity.recipient.string, label: "B", authenticator: PassingOwnerAuthenticator())
        try await b.unlock(url)
        // C is added while B is unlocked and editing.
        try await a.model.addDeviceKey(recipient: c.identity.recipient.string, label: "C", authenticator: PassingOwnerAuthenticator())
        _ = try await b.model.createNote(title: "B, after C was added", paper: Paper(kind: .blank), notebook: nil)
        b.expectNoListWarning()
        try await c.unlock(url)

        // B removed (the secret rotates) and added again.
        try await a.model.removeDeviceKey(b.identity.recipient.string)
        try await a.model.addDeviceKey(recipient: b.identity.recipient.string, label: "B again",
                                       authenticator: PassingOwnerAuthenticator())
        for device in [a, b, c] {
            try await device.unlock(url)
            #expect(device.model.notes.count == 1, "\(device.name)")
        }
        #expect(a.model.deviceKeys.count == 3)
        for device in [a, b, c] { device.model.close() }
    }

    /// c30 over WebDAV: the server folder holds a vault created by the app's
    /// path with both keys (WebDAV copies refuse key changes, so the key was
    /// added on another device); B connects, unlocks, writes, locks, reopens.
    @Test func c30AWebDAVCopySharedWithASecondDeviceShowsNoListWarning() async throws {
        let (server, keyA) = try Self.createVault()
        let keyB = try NativeIdentity.generate(.postQuantum)
        let a = Device("A", identity: keyA, cloud: nil)
        try await a.unlock(server)
        try await a.model.addDeviceKey(recipient: keyB.recipient.string, label: "B", authenticator: PassingOwnerAuthenticator())
        a.model.close()

        let b = Device("B", identity: keyB, cloud: nil)
        let remote = FakeWebDAVRemote(server: server)
        b.model.webdavRemote = remote
        b.model.webdavPasswords = MemoryWebDAVPasswordStore()
        b.model.webdavTick = .milliseconds(20)
        b.model.webdavWriteDelay = 0.05
        let library = VaultLibrary(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString).json"))
        let vaultId = try Vault.open(at: server).vaultId.uuidString.lowercased()
        let listing = WebDAVVaultListing(path: [], name: "Shared", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/notes/")
        _ = try await b.model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
        try await b.model.unlock(identityText: keyB.string)
        b.expectNoListWarning()
        _ = try await b.model.createNote(title: "From B over WebDAV", paper: Paper(kind: .ruled), notebook: nil)
        b.model.close()
        _ = try await b.model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
        try await b.model.unlock(identityText: keyB.string)
        b.expectNoListWarning()
        #expect(b.model.notes.contains { $0.title == "From B over WebDAV" })
        b.model.close()
    }
}
