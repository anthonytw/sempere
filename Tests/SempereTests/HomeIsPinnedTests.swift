import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The home device is pinned (design §4.3): the pinned epoch's home and first list come from this device's
/// trust record, never from the vault.json at hand, and a later version of a vault.json keeps the epoch's
/// head (review of PR #71, H1).
final class HomeIsPinnedTests: VaultTestCase {
    let home = pqIdentity(), laptop = pqIdentity(), attacker = pqIdentity()
    let homeTrust = MemoryEpochTrustStore(), laptopTrust = MemoryEpochTrustStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    /// A listed NON-home device (the laptop) rewrites epoch 1's vault.json making itself home and
    /// approving an attacker device under its own signature. Design §4.3/§5.6: the pinned epoch's home
    /// comes from the trust record, never from the new file; only home approves devices.
    func testNonHomeDeviceCannotMakeItselfHome() throws {
        var homeVault = try TestVaults.create(at: vaultURL(), identities: [home], names: ["Home"], trust: homeTrust)
        let words = try homeVault.approveDevice(TestVaults.device(laptop).joinRequest(vaultId: homeVault.vaultId, name: "Laptop", kind: "mac"))
        var mine = try TestVaults.open(at: homeVault.url, identity: laptop, trust: laptopTrust)
        try mine.confirmJoin(words: words)
        XCTAssertNil(mine.listStatus.problem)
        let before = try Data(contentsOf: homeVault.url.appendingPathComponent("vault.json"))

        // The laptop (holds K_1 and its own signing keys) forges.
        let key = try XCTUnwrap(mine.secret)
        let L = TestVaults.device(laptop), X = TestVaults.device(attacker)
        var m = mine.manifest
        m.home = L.fingerprint
        m.epochAuthor = L.id
        let claim = EntryClaim(key: X.key, sign: X.sign, kind: "cli", added: m.created, addedEpoch: 1, addedBy: L.id)
        let xEntry = EpochKeyEntry(role: .device, key: X.key, id: X.id, sign: X.sign, kind: "cli", added: claim.added,
                                   addedEpoch: 1, addedBy: L.id,
                                   addSig: try L.signing.sign(AuthorMessage.entry(vaultId: m.vaultId, claim)),
                                   name: "Home (new)",
                                   wrap: try EpochKeyWrap.seal(key, vaultId: m.vaultId, epoch: 1, to: X.nativeIdentity.recipient))
        m.keys.insert(xEntry, at: m.keys.firstIndex { $0.role == .recovery }!)
        m.epochSig = try L.signing.sign(try XCTUnwrap(m.epochMessage))
        try Vault.seal(&m, key: key, signing: L.signing, author: L.id)
        let forged = try m.encoded()

        // Sync / copy-merge path: home's open vault must not take it as a later version.
        XCTAssertTrue(homeVault.laterVersion(forged) == nil, "home accepts a list in which another device made itself home")
        XCTAssertNotNil(Vault.incomingManifestProblem(forged, local: before, vault: homeVault),
                        "sync accepts the forged vault.json")

        // Open path: written to storage, every device re-opens against its trust record.
        try forged.write(to: homeVault.url.appendingPathComponent("vault.json"))
        let reopened = try TestVaults.open(at: homeVault.url, identity: home, trust: homeTrust)
        XCTAssertNotNil(reopened.listStatus.problem, "home verifies a list whose home is now another device: \(reopened.listStatus)")
        XCTAssertTrue(reopened.isHome || reopened.listStatus.problem != nil, "home silently lost home")
        // The attacker device opens and writes (its addSig is the laptop's).
        let x = try TestVaults.open(at: homeVault.url, identity: attacker, trust: MemoryEpochTrustStore())
        _ = x
        let relaptop = try TestVaults.open(at: homeVault.url, identity: laptop, trust: laptopTrust)
        XCTAssertNotNil(relaptop.listStatus.problem, "laptop's own verified list accepts itself as home: \(relaptop.listStatus)")
    }
}
