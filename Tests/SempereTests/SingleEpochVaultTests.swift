import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Vaults of one epoch (phase KH2, docs/design/key-hierarchy.md §12; format.md §15): creation with this
/// device as home, the recovery entry and its passphrase copy, device approval and rename by home, the
/// joining device's confirmation, the read-only recovery key, and the checks of `vault.json`.
final class SingleEpochVaultTests: VaultTestCase {
    let home = pqIdentity(), laptop = pqIdentity()
    let homeTrust = MemoryEpochTrustStore(), laptopTrust = MemoryEpochTrustStore()
    var state: URL { tmp.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    private func newNote(_ vault: Vault, _ title: String) throws -> UUID {
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: title, paper: .ruled, pageId: UUID()), to: id, deviceState: state, app: "test/1")
        return id
    }

    private func manifestJSON(_ vault: Vault) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vault.url.appendingPathComponent("vault.json")))
            as? [String: Any])
    }

    private func writeManifestJSON(_ obj: [String: Any], _ vault: Vault) throws {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            .write(to: vault.url.appendingPathComponent("vault.json"))
    }

    // MARK: - Create and open

    func testCreateListsHomeAndTheRecoveryKeyAndEncryptsToTheVaultIdentity() throws {
        let recovery = try MLKEM768X25519Identity()
        let vault = try TestVaults.create(at: vaultURL(), identities: [home], names: ["Home Mac"], recovery: recovery,
                                          trust: homeTrust)
        let m = vault.manifest
        XCTAssertEqual(m.epoch, 1)
        XCTAssertEqual(m.devices.count, 1)
        XCTAssertEqual(m.devices.first?.name, "Home Mac")
        XCTAssertEqual(m.homeEntry?.fingerprint, m.home)
        XCTAssertEqual(m.recoveryEntry?.key, NativeIdentity.mlkem768x25519(recovery).recipient.string)
        XCTAssertTrue(vault.isHome)
        XCTAssertEqual(vault.listStatus, .verified(.firstUse))
        XCTAssertNotNil(try homeTrust.record(for: vault.vaultId), "the creator keeps a trust record")

        let note = try newNote(vault, "One")
        let report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        // One stanza, to the vault recipient: a device key alone opens no file.
        let file = try XCTUnwrap(try vault.revisionNames(of: note).first)
        let data = try Data(contentsOf: fileURL(vault, note, file))
        XCTAssertThrowsError(try AgeFile.decrypt(data, with: [home]))
        XCTAssertNoThrow(try AgeFile.decrypt(data, with: vault.identities))

        // Reopened as the device: verified against its record.
        let again = try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)
        XCTAssertEqual(again.listStatus, .verified(.unchanged))
        XCTAssertEqual(again.openedWith, .device(m.home))
        XCTAssertNoThrow(try again.requireWritable())
    }

    func testAKeyTheVaultDoesNotListOpensNothing() throws {
        let vault = try TestVaults.create(at: vaultURL(), identities: [home], trust: homeTrust)
        XCTAssertThrowsError(try TestVaults.open(at: vault.url, identity: laptop)) {
            guard case VaultError.keyNotListed = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: - The recovery key

    func testTheRecoveryKeyReadsAndNeverWrites() throws {
        let recovery = try MLKEM768X25519Identity()
        let vault = try TestVaults.create(at: vaultURL(), identities: [home], recovery: recovery, trust: homeTrust)
        let note = try newNote(vault, "Kept")
        let id = NativeIdentity.mlkem768x25519(recovery)

        let withRoot = try Vault.open(at: vault.url, identities: [id], root: vault.root)
        XCTAssertEqual(withRoot.openedWith, .recovery)
        XCTAssertEqual(withRoot.listStatus.problem, nil, "\(withRoot.listStatus)")
        XCTAssertEqual(try withRoot.reconstruct(noteId: note).meta.title, "Kept")
        XCTAssertThrowsError(try withRoot.apply([.deleteNote], to: note, deviceState: state, app: "t")) {
            XCTAssertEqual($0 as? VaultError, .recoveryKeyReadOnly)
        }
        // Without the kit's root (and no trust record) it reads against epoch 1's own list only: the CLI
        // warns that the vault was not checked against the kit's root.
        let unchecked = try Vault.open(at: vault.url, identities: [id])
        XCTAssertEqual(unchecked.listStatus, .verified(.firstUse))
        XCTAssertEqual(try unchecked.reconstruct(noteId: note).meta.title, "Kept")
        // Another root: refused.
        let wrong = try Vault.open(at: vault.url, identities: [id], root: Data(repeating: 0xab, count: 32))
        XCTAssertEqual(wrong.listStatus.problem?.reason, .rootMismatch)
    }

    func testThePassphraseCopyHoldsTheRecoveryKeyAndTheRoot() throws {
        let recovery = try MLKEM768X25519Identity()
        let pass = "correct horse battery staple orbit lantern"
        let vault = try TestVaults.create(at: vaultURL(), identities: [home], recovery: recovery, recoveryPassphrase: pass,
                                          trust: homeTrust)
        XCTAssertEqual(vault.passphraseCopyNames().count, 1)
        let copy = try vault.openPassphraseCopy(passphrase: pass)
        XCTAssertEqual(copy.identity.recipient.string, NativeIdentity.mlkem768x25519(recovery).recipient.string)
        XCTAssertEqual(copy.root, vault.root)
        XCTAssertEqual(copy.vaultId, vault.vaultId)
        XCTAssertThrowsError(try vault.openPassphraseCopy(passphrase: "not it")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassphrase)
        }
        // No copy without a passphrase.
        let plain = try TestVaults.create(at: vaultURL("Plain"), identities: [laptop])
        XCTAssertEqual(plain.passphraseCopyNames(), [])
        XCTAssertThrowsError(try plain.openPassphraseCopy(passphrase: pass)) {
            XCTAssertEqual($0 as? VaultError, .passphraseCopyMissing)
        }
    }

    // MARK: - Devices: approve, confirm, rename

    func testJoinApproveConfirmAndRename() throws {
        var vault = try TestVaults.create(at: vaultURL(), identities: [home], names: ["Home"], trust: homeTrust)
        let before = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        let request = TestVaults.device(laptop).joinRequest(vaultId: vault.vaultId, name: "  Work\nlaptop ", kind: "mac")
        let words = try vault.approveDevice(request)
        XCTAssertEqual(words.count, 6)
        XCTAssertEqual(vault.manifest.devices.count, 2)
        XCTAssertEqual(vault.manifest.epoch, 1, "approval starts no epoch")
        let entry = try XCTUnwrap(vault.manifest.devices.first { $0.key == laptop.recipient.string })
        XCTAssertEqual(entry.name, "Work laptop")
        XCTAssertEqual(entry.kind, "mac")
        XCTAssertThrowsError(try vault.approveDevice(request)) {
            guard case VaultError.deviceAlreadyListed = $0 else { return XCTFail("\($0)") }
        }

        // The new device reads at once, writes only once it typed home's reply.
        var mine = try TestVaults.open(at: vault.url, identity: laptop, trust: laptopTrust)
        XCTAssertEqual(mine.listStatus.problem?.reason, .rootUnconfirmed)
        let note = try newNote(vault, "From home")
        XCTAssertEqual(try mine.reconstruct(noteId: note).meta.title, "From home")
        XCTAssertThrowsError(try newNote(mine, "Too soon")) {
            guard case VaultError.untrustedList = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try mine.confirmJoin(words: Array(words.reversed()))) {
            XCTAssertEqual($0 as? VaultError, .replyMismatch)
        }
        try mine.confirmJoin(words: words)
        XCTAssertNil(mine.listStatus.problem)
        XCTAssertNoThrow(try newNote(mine, "From the laptop"))
        XCTAssertFalse(mine.isHome)

        // Only home approves and renames.
        let other = pqIdentity()
        XCTAssertThrowsError(try mine.approveDevice(TestVaults.device(other).joinRequest(vaultId: vault.vaultId, name: "x", kind: "cli"))) {
            guard case VaultError.notHome = $0 else { return XCTFail("\($0)") }
        }
        let laptopID = try XCTUnwrap(entry.id)
        XCTAssertThrowsError(try mine.renameDevice(id: laptopID, to: "Mine now")) {
            guard case VaultError.notHome = $0 else { return XCTFail("\($0)") }
        }
        // The laptop's notes changed no list: home's value of the vault still renames.
        try vault.renameDevice(id: laptopID, to: "Old laptop")
        XCTAssertEqual(vault.manifest.devices.first { $0.id == laptopID }?.name, "Old laptop")
        // The laptop sees home's later version and keeps writing.
        let reread = try TestVaults.open(at: vault.url, identity: laptop, trust: laptopTrust)
        XCTAssertNil(reread.listStatus.problem, "\(reread.listStatus)")

        // Later versions: the approved/renamed list is a later version of the first, never the reverse.
        let old = try Vault.readManifest(before)
        XCTAssertTrue(vault.isLaterVersion(vault.manifest, of: old))
        XCTAssertFalse(vault.isLaterVersion(old, of: vault.manifest))
        XCTAssertNil(vault.laterVersion(before))
    }

    func testApprovalRefusesRequestsForAnotherVaultOrABadKind() throws {
        var vault = try TestVaults.create(at: vaultURL(), identities: [home], trust: homeTrust)
        let device = TestVaults.device(laptop)
        XCTAssertThrowsError(try vault.approveDevice(device.joinRequest(vaultId: UUID(), name: "x", kind: "cli"))) {
            guard case VaultError.joinRequestRefused = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try vault.approveDevice(device.joinRequest(vaultId: vault.vaultId, name: "x", kind: "Not A Kind"))) {
            guard case VaultError.joinRequestRefused = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(vault.manifest.devices.count, 1)
    }

    func testJoinRequestFilesRoundTripAndMatchByWords() throws {
        let vault = try TestVaults.create(at: vaultURL(), identities: [home], trust: homeTrust)
        let device = TestVaults.device(laptop)
        let request = try Vault.writeJoinRequest(at: vault.url, device: device, name: "Laptop", kind: "mac")
        XCTAssertEqual(vault.joinRequests().compactMap(\.request), [request])
        XCTAssertEqual(vault.joinRequest(matching: JoinCodes.words(request.commitment)), request)
        XCTAssertNil(vault.joinRequest(matching: ["one", "two", "three", "four", "five", "six"]))
    }

    // MARK: - Tampering with vault.json

    func testAnEditedListIsRefusedAndBlocksWrites() throws {
        var vault = try TestVaults.create(at: vaultURL(), identities: [home], trust: homeTrust)
        try vault.approveDevice(TestVaults.device(laptop).joinRequest(vaultId: vault.vaultId, name: "Laptop", kind: "mac"))
        let original = try manifestJSON(vault)

        // A renamed device without home's signature.
        var renamed = original
        var keys = try XCTUnwrap(renamed["keys"] as? [[String: Any]])
        keys[1]["name"] = "Evil"
        renamed["keys"] = keys
        try writeManifestJSON(renamed, vault)
        let a = try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)
        XCTAssertNotNil(a.listStatus.problem)
        XCTAssertThrowsError(try newNote(a, "x")) {
            guard case VaultError.untrustedList = $0 else { return XCTFail("\($0)") }
        }

        // A device dropped from the list (the tag no longer matches).
        var dropped = original
        dropped["keys"] = (original["keys"] as? [[String: Any]])?.filter { $0["key"] as? String != laptop.recipient.string }
        try writeManifestJSON(dropped, vault)
        XCTAssertNotNil(try TestVaults.open(at: vault.url, identity: home, trust: homeTrust).listStatus.problem)

        // A removed markers tag: not a vault.json of this format at all (a typed error, never a downgrade).
        var noMarkers = original
        noMarkers["markersTag"] = nil
        try writeManifestJSON(noMarkers, vault)
        XCTAssertThrowsError(try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)) {
            guard case VaultError.manifestCorrupt = $0 else { return XCTFail("\($0)") }
        }
        // Changed markers (a feature added without the key): refused.
        var features = original
        features["features"] = ["tables"]
        try writeManifestJSON(features, vault)
        let marked = try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)
        XCTAssertNotNil(marked.listStatus.problem, "\(marked.listStatus)")

        // A device added and re-tagged with the key, but without home's addSig: refused.
        try writeManifestJSON(original, vault)
        let opened = try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)
        XCTAssertNil(opened.listStatus.problem)
        var m = opened.manifest
        var forged = m.keys[1]
        let stranger = TestVaults.device(pqIdentity())
        forged.key = stranger.key
        forged.sign = stranger.joinRequest(vaultId: vault.vaultId, name: "x", kind: "cli").sign
        forged.id = String(Hex.encode(stranger.fingerprint).prefix(8))
        m.keys.insert(forged, at: 1)
        try opened.writeResealedManifest(try opened.resealed(m, home: home))
        let after = try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)
        XCTAssertNotNil(after.listStatus.problem, "\(after.listStatus)")
    }

    func testIncomingManifests() throws {
        var vault = try TestVaults.create(at: vaultURL(), identities: [home], trust: homeTrust)
        let local = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        // The same vault with another label: taken.
        var labelled = try manifestJSON(vault)
        labelled["label"] = "Renamed elsewhere"
        let relabelled = try JSONSerialization.data(withJSONObject: labelled, options: [.sortedKeys])
        XCTAssertNil(Vault.incomingManifestProblem(relabelled, local: local, vault: vault))
        // Another vault: refused.
        let other = try TestVaults.create(at: vaultURL("Other"), identities: [laptop])
        let foreign = try Data(contentsOf: other.url.appendingPathComponent("vault.json"))
        XCTAssertNotNil(Vault.incomingManifestProblem(foreign, local: local, vault: vault))
        // Home's later version: taken; the older one back again: refused.
        try vault.approveDevice(TestVaults.device(laptop).joinRequest(vaultId: vault.vaultId, name: "Laptop", kind: "mac"))
        let later = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        let stale = try TestVaults.open(at: vault.url, identity: home, trust: homeTrust)
        XCTAssertNil(Vault.incomingManifestProblem(later, local: local, vault: stale))
        XCTAssertNotNil(Vault.incomingManifestProblem(local, local: later, vault: stale))
        // Garbage never parses.
        XCTAssertNotNil(Vault.incomingManifestProblem(Data("{".utf8), local: local, vault: vault))
    }

    // MARK: - Local caches

    /// Cache keys are derived from `K_e` like the vault's own keys: a purpose that is one of those
    /// derivations' names would give a cache the vault's key (and name a plaintext folder after it).
    func testCachePurposesCannotReuseTheVaultsDerivations() {
        for purpose in ["list", "markers", "blob", "capture", "recipients", "summary-cache"] {
            XCTAssertFalse(LocalCacheKey.isUsablePurpose(purpose), purpose)
        }
        XCTAssertTrue(LocalCacheKey.isUsablePurpose("drawing-cache"))
    }
}
