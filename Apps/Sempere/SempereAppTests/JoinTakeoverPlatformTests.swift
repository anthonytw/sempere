import Age
import CryptoKit
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// What of joining and taking over is the app's (key-hierarchy design §6.2, §6.3; phase KH5 part 2): what deleting
/// this device's key costs (`KeyRemoval`'s words), the takeover screen's codes, and the
/// Keychain's signing items (the Secure Enclave). The joins and takeovers themselves are `SempereAppCoreTests`
/// (`JoinTakeoverTests`, `JoinOverSyncTests`).
@MainActor
struct JoinTakeoverAppTests {
    /// Review of #88, M4, and its re-check (R2, SHOULD): what each case of the check (`KeyRemovalTests`, Linux) costs, in words.
    @Test func removingTheHomesKeySaysWhatItCosts() {
        let alone = KeyRemoval(home: .alone)
        #expect(alone.removalWarning()?.contains("recovery kit") == true)
        #expect(alone.forgetWarning?.contains("recovery kit") == true)
        #expect(!alone.offersMakeHome)
        let withOthers = KeyRemoval(home: .withOthers)
        #expect(withOthers.offersMakeHome)
        #expect(withOthers.removalWarning()?.contains("make another device home") == true)
        #expect(withOthers.forgetWarning != nil)
        let member = KeyRemoval()
        #expect(member.removalWarning() == nil)
        #expect(member.forgetWarning == nil)
    }

    /// "Mine", created by `device` (its home), off the main actor: its folder, id and keys.
    @concurrent static func vault(device: DeviceKeys) async throws -> (url: URL, id: UUID, home: DeviceKeys) {
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
    @concurrent static func approve(_ device: DeviceKeys, in url: URL, home: DeviceKeys) async throws {
        var vault = try Vault.open(at: url, identities: [home.nativeIdentity], signing: home.signing)
        _ = try vault.approveDevice(device.joinRequest(vaultId: vault.vaultId, name: "Phone", kind: "iphone"))
    }

    @Test func theTakeoverScreenTellsTheKitsCodesApart() {
        #expect(TakeoverView.kitCode("sempere-root:abcd") == .root)
        #expect(TakeoverView.kitCode("AGE-SECRET-KEY-PQ-1QQQ") == .key)
        #expect(TakeoverView.kitCode(" age-secret-key-1qqq\n") == .key)
        #expect(TakeoverView.kitCode("sempere-reply:xyz") == nil)
        #expect(TakeoverView.kitCode("https://example.com") == nil)
    }

    @Test func storedSigningRoundTripsASoftwarePair() throws {
        let pair = DeviceSigningKeys.generate()
        let stored = try StoredSigning(pair)
        let back = try JSONDecoder().decode(StoredSigning.self, from: JSONEncoder().encode(stored))
        let signer = try back.signer()
        let message = Data("m".utf8)
        #expect(try signer.sign(message).verifies(message, keys: try pair.publicKeys()))
    }

    /// The enclave pair signs what the package verifies in software (design §4.1). Where the test host has no
    /// Secure Enclave (or may not use it unsigned), it says so and checks nothing.
    @Test func anEnclavePairSignsWhatSoftwareVerifies() throws {
        // Where there is no enclave the store makes software pairs and this checks nothing; where there is one, any
        // error is a failure (review of #88, S1: a broken access control or flag must not pass silently).
        guard SecureEnclave.isAvailable else {
            print("SKIPPED: this test host has no Secure Enclave")
            return
        }
        let signer = try SecureEnclaveSigner.generate()
        let message = AuthorMessage.manifest(vaultId: UUID(), root: Data(count: 32), epoch: 1, epochId: Data(count: 32),
                                             epochRecordHash: Data(count: 32), listMessage: Data("l".utf8),
                                             format: "sempere/1", features: [])
        let sig = try signer.sign(message)
        #expect(sig.verifies(message, keys: try signer.publicKeys()))
        let stored = try StoredSigning(signer)
        #expect(try stored.signer().sign(message).verifies(message, keys: try signer.publicKeys()))
    }
}
