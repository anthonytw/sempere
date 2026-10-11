import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Settings → Device Keys: Save Key… (this device's key after Face ID) and
/// New Key… (a key for another device), and the share sheet's staged file.
@MainActor
struct KeyExportTests {
    /// Grants or refuses, and can run something while the "prompt" is up.
    final class FakeAuthenticator: OwnerAuthenticator, @unchecked Sendable {
        var outcome: (any Error)?
        var reasons: [String] = []
        var during: (@MainActor () -> Void)?

        init(outcome: (any Error)? = nil) { self.outcome = outcome }

        func authenticate(reason: String) async throws {
            await MainActor.run {
                reasons.append(reason)
                during?()
            }
            if let outcome { throw outcome }
        }
    }

    /// Security review 2026-10 stage 4, S14 and P2: the share sheet of a secret key (its text on the new-vault
    /// and upgrade screens, its key file in Save Key… and New Key…) has no Copy, which would put the key on
    /// the general pasteboard with no expiry and hand it to Universal Clipboard.
    @Test func secretShareSheetsLeaveCopyOut() {
        let controller = SecretSharing.controller(items: ["AGE-SECRET-KEY-PQ-1EXAMPLE"])
        #expect(controller.excludedActivityTypes?.contains(.copyToPasteboard) == true)
        let sheet = ShareSheet(items: ["AGE-SECRET-KEY-PQ-1EXAMPLE"], secret: true) {}
        #expect(sheet.secret)
        #expect(ShareSheet(items: [URL(fileURLWithPath: "/tmp/x.pdf")]) {}.secret == false, "exports keep Copy")
    }

    @Test func saveKeyGivesThisDevicesKeyAfterAuthentication() async throws {
        let (model, url) = try await KeyManagementTests.unlockedModel()
        let auth = FakeAuthenticator()
        let key = try await model.exportThisDeviceKey(authenticator: auth)
        #expect(auth.reasons.count == 1)
        let held = try #require(model.heldIdentity)
        #expect(key.secret == held.string)
        #expect(key.recipient == held.recipient.string)
        #expect(key.label == model.deviceKeys.first { $0.isInUse }?.label)
        #expect(key.fileName == IdentityFile.exportFileName(label: key.label))
        // The CLI's identity file format, which opens the vault.
        let parsed = try IdentityFile.parse(key.text)
        #expect(parsed.string == held.string)
        #expect(key.text.hasPrefix("# created: "))
        #expect(try Vault.open(at: url, identities: [parsed]).summaries().count == 2)
    }

    @Test func saveKeyShowsNothingWithoutAuthentication() async throws {
        let (model, _) = try await KeyManagementTests.unlockedModel()
        await #expect(throws: AppModel.KeyExportError.notAuthenticated) {
            _ = try await model.exportThisDeviceKey(authenticator: FakeAuthenticator(outcome: AppModel.KeyExportError.notAuthenticated))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await model.exportThisDeviceKey(authenticator: FakeAuthenticator(outcome: CancellationError()))
        }
    }

    /// Biometrics when enrolled, never the passcode after a lockout (anyone who
    /// knows it could fail Face ID on purpose); the passcode only without biometrics.
    @Test func ownerCheckNeverFallsBackToThePasscodeAfterALockout() {
        #expect(OwnerCheck.choose(biometricsUsable: true, biometricsLockedOut: false) == .biometrics)
        #expect(OwnerCheck.choose(biometricsUsable: false, biometricsLockedOut: true) == .lockedOut)
        #expect(OwnerCheck.choose(biometricsUsable: false, biometricsLockedOut: false) == .passcode)
    }

    @Test func saveKeyNeedsAnUnlockedVaultThatStaysOpen() async throws {
        let locked = AppModel()
        let auth = FakeAuthenticator()
        await #expect(throws: AppModel.KeyError.notUnlocked) { _ = try await locked.exportThisDeviceKey(authenticator: auth) }
        #expect(auth.reasons.isEmpty, "no prompt without a vault")

        let (model, _) = try await KeyManagementTests.unlockedModel()
        auth.during = { model.close() }
        await #expect(throws: AppModel.KeyError.vaultChanged) { _ = try await model.exportThisDeviceKey(authenticator: auth) }
    }

    @Test func aNewKeyIsAFileTheVaultIsEncryptedTo() async throws {
        let (model, url) = try await KeyManagementTests.unlockedModel()
        let generated = try await model.generateDeviceKey(label: " Anna's\niPad ", authenticator: PassingOwnerAuthenticator())
        let file = generated.file
        #expect(file.secret == generated.secret)
        #expect(file.label == "Anna's iPad")
        #expect(file.fileName == "Sempere key - Anna's iPad.txt")
        let identity = try IdentityFile.parse(file.text)
        #expect(identity.recipient.string == file.recipient)
        #expect(model.deviceKeys.contains { $0.recipient == file.recipient && $0.label == "Anna's iPad" })
        #expect(try Vault.open(at: url, identities: [identity]).summaries().count == 2)
        let kit = try model.recoveryKitPDF(for: file)
        #expect(kit.starts(with: Data("%PDF-".utf8)))
    }

    @Test func theRecoveryKitIsOnlyForTheVaultsKeys() async throws {
        let (model, _) = try await KeyManagementTests.unlockedModel()
        let stranger = KeyFile(identity: try NativeIdentity.generate(.postQuantum), label: "x")
        #expect(throws: AppModel.KeyError.notListed) { _ = try model.recoveryKitPDF(for: stranger) }
    }

    @Test func theSharedFileIsPrivateAndPurged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyShare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = KeyFile(identity: try NativeIdentity.generate(.postQuantum), label: "Mac")
        let first = try KeyShareFile.stage(key, in: root)
        #expect(first.lastPathComponent == "Sempere key - Mac.txt")
        #expect(first.path.hasPrefix(root.path))
        #expect(try String(contentsOf: first, encoding: .utf8) == key.text)
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let second = try KeyShareFile.stage(key, in: root)
        #expect(!FileManager.default.fileExists(atPath: first.path), "staging again removes the earlier file")
        KeyShareFile.purge(in: root)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
