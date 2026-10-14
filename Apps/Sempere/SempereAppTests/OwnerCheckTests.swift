import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// An owner check that always passes, for tests of key changes that are not
/// about the check itself.
struct PassingOwnerAuthenticator: OwnerAuthenticator {
    func authenticate(reason: String) async throws {}
}

/// Security review 2026-10 (P1): New Key…, adding a pasted public key and the
/// recovery kit ask the device owner first, like Save Key…, and change
/// nothing when the check fails, is cancelled, or the vault changes meanwhile.
@MainActor
struct OwnerCheckTests {
    typealias Fake = KeyExportTests.FakeAuthenticator

    @Test func addingAPastedKeyNeedsTheOwner() async throws {
        let (model, _) = try await KeyManagementTests.unlockedModel()
        let other = try NativeIdentity.generate(.postQuantum)
        for outcome: any Error in [AppModel.KeyExportError.notAuthenticated, CancellationError()] {
            let auth = Fake(outcome: outcome)
            await #expect(throws: (any Error).self) {
                try await model.addDeviceKey(recipient: other.recipient.string, label: "B", authenticator: auth)
            }
            #expect(auth.reasons.count == 1)
            #expect(model.deviceKeys.count == 1, "nothing added")
        }
        let auth = Fake()
        try await model.addDeviceKey(recipient: other.recipient.string, label: "B", authenticator: auth)
        #expect(auth.reasons.count == 1)
        #expect(auth.reasons[0].contains("device key"))
        #expect(model.deviceKeys.count == 2)
    }

    @Test func aNewKeyNeedsTheOwner() async throws {
        let (model, url) = try await KeyManagementTests.unlockedModel()
        let refused = Fake(outcome: AppModel.KeyExportError.notAuthenticated)
        await #expect(throws: AppModel.KeyExportError.notAuthenticated) {
            _ = try await model.generateDeviceKey(label: "Tablet", authenticator: refused)
        }
        #expect(model.deviceKeys.count == 1)
        #expect(try Vault.open(at: url).recipients.count == 1, "the vault is not encrypted to a new key")
        let generated = try await model.generateDeviceKey(label: "Tablet", authenticator: Fake())
        #expect(model.deviceKeys.contains { $0.recipient == generated.file.recipient })
    }

    @Test func theVaultClosingDuringTheCheckChangesNothing() async throws {
        let (model, url) = try await KeyManagementTests.unlockedModel()
        let auth = Fake()
        auth.during = { model.close() }
        await #expect(throws: AppModel.KeyError.vaultChanged) {
            _ = try await model.generateDeviceKey(label: "Tablet", authenticator: auth)
        }
        #expect(try Vault.open(at: url).recipients.count == 1)
    }

    @Test func theRecoveryKitNeedsTheOwner() async throws {
        let (model, _) = try await KeyManagementTests.unlockedModel()
        await #expect(throws: AppModel.KeyExportError.notAuthenticated) {
            _ = try await model.recoveryKitPDF(authenticator: Fake(outcome: AppModel.KeyExportError.notAuthenticated))
        }
        let auth = Fake()
        let kit = try await model.recoveryKitPDF(authenticator: auth)
        #expect(kit.starts(with: Data("%PDF-".utf8)))
        #expect(auth.reasons.count == 1)
    }
}
