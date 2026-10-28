import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Signed per-device summaries files (format.md §12.5): every forgery a key holder, a removed device or
/// storage alone can make is refused by `openDevicePublishedSummaries`, which every reader and the sync's
/// ordering go through. The engine side (an unordered copy never replaces an ordered one, and is repaired)
/// is `InboxSummariesScenarioCase.scenarioForgedDeviceFilesNeverWin` and
/// `InboxSummariesOverMemoryTests.testARemovedDevicesSignedFileIsNeverOrdered`.
final class SignedSummariesAdversarialTests: VaultTestCase {
    let ids = [pqIdentity(), pqIdentity(), pqIdentity()]
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var version: Int64 { PublishedSummaries.millis(now) }

    /// A vault listing A (home), B and X, opened as each of them with its signing keys.
    func devices() throws -> (a: Vault, b: Vault, x: Vault) {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let a = try TestVaults.create(at: vaultURL("Shared"), identities: ids, names: ["A", "B", "X"])
        return (a, try TestVaults.open(at: a.url, identity: ids[1]), try TestVaults.open(at: a.url, identity: ids[2]))
    }

    func device(_ v: Vault) throws -> DeviceID { try XCTUnwrap(v.writerDevice) }

    func refused(_ data: Data, as device: DeviceID, by readers: [Vault], _ why: String,
                 file: StaticString = #filePath, line: UInt = #line) {
        for r in readers {
            XCTAssertThrowsError(try r.openDevicePublishedSummaries(data, device: device, now: now), why,
                                 file: file, line: line) { XCTAssert($0 is PublishedSummariesError, "\($0)", file: file, line: line) }
            XCTAssertTrue(r.summariesSigningKeys(of: device).count <= 1)
        }
    }

    /// The honest file opens for every listed device.
    func testTheOwnersFileOpensEverywhere() throws {
        let (a, b, x) = try devices()
        let file = try a.sealDevicePublishedSummaries([:], version: version)
        for r in [a, b, x] { XCTAssertEqual(try r.openDevicePublishedSummaries(file, device: try device(a), now: now).version, version) }
    }

    /// Another listed device (B, which holds the vault key and its own signing keys) writes A's file: the
    /// content names A, but B's signature never verifies under A's keys. B's own file put under A's name is
    /// not A's either.
    func testAFileForgedByAnotherListedDeviceIsRefused() throws {
        let (a, b, x) = try devices()
        let aDev = try device(a), bDev = try device(b)
        let forged = try b.sealDeviceFile([:], device: aDev, version: version + 1, signer: TestVaults.signing(ids[1]))
        refused(forged, as: aDev, by: [a, b, x], "signed by B, not A")
        let bsOwn = try b.sealDevicePublishedSummaries([:], version: version + 1)
        XCTAssertNoThrow(try a.openDevicePublishedSummaries(bsOwn, device: bDev, now: now))
        refused(bsOwn, as: aDev, by: [a, b, x], "B's file under A's name")
    }

    /// X is removed (a new epoch, KH3). Its signatures no longer verify for the devices of the new epoch, even
    /// over content sealed under the new epoch's key (as if X had it): its entry is gone from the checked
    /// list. Its last real file, of the old epoch, does not open either.
    func testAFileSignedByARemovedDeviceIsRefused() throws {
        var (a, _, x) = try devices()
        let xDev = try device(x), aDev = try device(a)
        let old = try x.sealDevicePublishedSummaries([:], version: version)
        XCTAssertNoThrow(try a.openDevicePublishedSummaries(old, device: xDev, now: now), "valid while X is listed")
        try a.removeDevices([xDev.rawValue])
        XCTAssertEqual(a.manifest.epoch, 2)
        let b = try TestVaults.open(at: a.url, identity: ids[1])
        XCTAssertEqual(b.manifest.epoch, 2)
        XCTAssertEqual(b.summariesSigningKeys(of: xDev), [], "X is off the checked list")
        refused(old, as: xDev, by: [a, b], "an old-epoch file")
        let xSigning = TestVaults.signing(ids[2])
        let asX = try a.sealDeviceFile([:], device: xDev, version: version + 1, signer: xSigning)
        refused(asX, as: xDev, by: [a, b], "X's own name, X's keys, the new key")
        let asA = try a.sealDeviceFile([:], device: aDev, version: version + 1, signer: xSigning)
        refused(asA, as: aDev, by: [a, b], "A's name, X's keys")
    }

    /// Someone with storage access only (no vault key, no signing key): garbage behind the header, the
    /// owner's file with its signature replaced, cut, or a ciphertext byte changed, and an unsigned body.
    func testAKeylessWritersFilesAreRefused() throws {
        let (a, b, _) = try devices()
        let aDev = try device(a)
        let file = try a.sealDevicePublishedSummaries([:], version: version)
        let epoch = UInt8(a.manifest.epoch)
        let garbage = Data([0x53, 0x4D, 0x50, 0x55, 0x04, 0, 0, 0, epoch]) + Data(repeating: 0x42, count: 4000)
        refused(garbage, as: aDev, by: [a, b], "garbage")
        var zeroed = file
        zeroed.replaceSubrange((file.count - PublishedSummaries.signatureSize)..<file.count,
                               with: Data(count: PublishedSummaries.signatureSize))
        refused(zeroed, as: aDev, by: [a, b], "signature zeroed")
        refused(Data(file.prefix(file.count - 1)), as: aDev, by: [a, b], "signature cut")
        refused(Data(file.prefix(file.count - PublishedSummaries.signatureSize)), as: aDev, by: [a, b], "unsigned body")
        var flipped = file
        flipped[30] ^= 0x01
        refused(flipped, as: aDev, by: [a, b], "ciphertext changed")
        var sigFlipped = file
        sigFlipped[file.count - 10] ^= 0x01
        refused(sigFlipped, as: aDev, by: [a, b], "ML-DSA signature changed")
        var p256Flipped = file
        p256Flipped[file.count - PublishedSummaries.signatureSize + 5] ^= 0x01
        refused(p256Flipped, as: aDev, by: [a, b], "P-256 signature changed")
        // The signature of one of A's files moved onto the sealed part of another.
        let other = try a.sealDevicePublishedSummaries([:], version: version + 1)
        let (sealed, _) = try XCTUnwrap(PublishedSummaries.split(other))
        let (_, signature) = try XCTUnwrap(PublishedSummaries.split(file))
        refused(PublishedSummaries.attach(signature, to: sealed), as: aDev, by: [a, b], "a signature moved to other bytes")
    }

    /// A replayed old signed file still verifies (it is A's), but only as the older version it is: ordering
    /// keeps the later one (the engine side: `scenarioAnOlderCopyNeverReplacesANewer`). Replayed into a later
    /// epoch, it does not open at all.
    func testAReplayedOldFileIsOnlyAnOlderVersion() throws {
        var (a, b, x) = try devices()
        let aDev = try device(a)
        let v1 = try a.sealDevicePublishedSummaries([:], version: version)
        let v2 = try a.sealDevicePublishedSummaries([:], version: version + 1)
        let o1 = try b.openDevicePublishedSummaries(v1, device: aDev, now: now).version
        let o2 = try b.openDevicePublishedSummaries(v2, device: aDev, now: now).version
        XCTAssertLessThan(try XCTUnwrap(o1), try XCTUnwrap(o2))
        try a.removeDevices([try device(x).rawValue])
        let b2 = try TestVaults.open(at: a.url, identity: ids[1])
        refused(v2, as: aDev, by: [a, b2], "a file of the previous epoch")
    }

    /// A's own keys over a message that is not the file's: another version, epoch, epoch id, device or vault
    /// than the sealed content and the reader's vault say. Each is refused.
    func testTheRightSignerOverTheWrongMessageIsRefused() throws {
        let (a, b, _) = try devices()
        let aDev = try device(a), bDev = try device(b)
        let signing = TestVaults.signing(ids[0])
        let sealed = try a.sealDeviceBody([:], device: aDev, version: version)
        func signed(vaultId: UUID? = nil, epoch: Int? = nil, epochId: Data? = nil, device: DeviceID? = nil,
                    version v: Int64? = nil) throws -> Data {
            let m = AuthorMessage.summaries(vaultId: vaultId ?? a.vaultId, epoch: epoch ?? a.manifest.epoch,
                                            epochId: epochId ?? a.manifest.epochId, device: device ?? aDev,
                                            version: v ?? version, sealed: sealed)
            return PublishedSummaries.attach(try signing.sign(m), to: sealed)
        }
        XCTAssertNoThrow(try b.openDevicePublishedSummaries(try signed(), device: aDev, now: now), "the right message")
        refused(try signed(version: version + 1), as: aDev, by: [a, b], "another version")
        refused(try signed(version: version - 1), as: aDev, by: [a, b], "an older version")
        refused(try signed(epoch: a.manifest.epoch + 1), as: aDev, by: [a, b], "another epoch")
        refused(try signed(epochId: Data(repeating: 7, count: 32)), as: aDev, by: [a, b], "another epoch id")
        refused(try signed(device: bDev), as: aDev, by: [a, b], "another device")
        refused(try signed(vaultId: UUID()), as: aDev, by: [a, b], "another vault")
        // The message is length-prefixed: a version that only moves bytes between fields does not verify.
        XCTAssertNotEqual(AuthorMessage.summaries(vaultId: a.vaultId, epoch: 1, epochId: a.manifest.epochId, device: aDev,
                                                  version: 11, sealed: sealed),
                          AuthorMessage.summaries(vaultId: a.vaultId, epoch: 11, epochId: a.manifest.epochId, device: aDev,
                                                  version: 1, sealed: sealed))
    }

    /// A list that did not check gives no signing keys: nothing verifies, so nothing is ordered.
    func testNoKeysFromAListThatDidNotCheck() throws {
        let (a, _, _) = try devices()
        let aDev = try device(a)
        let file = try a.sealDevicePublishedSummaries([:], version: version)
        var locked = try Vault.open(at: a.url)
        XCTAssertEqual(locked.summariesSigningKeys(of: aDev), [])
        locked = try TestVaults.open(at: a.url, identity: ids[1])
        locked.listStatus = .refused(ListProblem(.rootUnconfirmed, "test"))
        XCTAssertEqual(locked.summariesSigningKeys(of: aDev), [])
        refused(file, as: aDev, by: [locked], "a refused list")
    }
}

/// The one check of "this `vault.json` is the next epoch after the one this device verified"
/// (`EpochFrontier.verifiedChild`), shared by the removal notice (design §5.5) and the per-device summaries
/// sync (format.md §12.5): a real child verifies; one whose link is not from the pinned epoch, of another
/// vault, or two epochs on, does not.
final class EpochFrontierTests: VaultTestCase {
    func testOnlyAVerifiedDirectChildIsBelieved() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let ids = [pqIdentity(), pqIdentity(), pqIdentity()]
        let trust = MemoryEpochTrustStore()
        var a = try TestVaults.create(at: vaultURL("A"), identities: ids, names: ["A", "B", "X"], trust: trust)
        try a.requireWritable()   // the trust record pins epoch 1
        let frontier = try XCTUnwrap(a.epochFrontier)
        XCTAssertEqual(frontier.epoch, 1)
        XCTAssertEqual(frontier, try XCTUnwrap(EpochFrontier(record: try XCTUnwrap(try trust.record(for: a.vaultId)))))
        let epoch1 = a.manifest
        XCTAssertNil(frontier.verifiedChild(epoch1), "not a child of itself")
        let other = try TestVaults.create(at: vaultURL("Other"), identities: [pqIdentity(), pqIdentity()], names: ["O", "P"])
        var o = other
        try o.removeDevices([try XCTUnwrap(o.devices.last?.id)])
        try a.removeDevices([try XCTUnwrap(a.devices.last?.id)])
        let child = a.manifest
        XCTAssertEqual(frontier.verifiedChild(child)?.epoch, 2)
        XCTAssertEqual(frontier.verifiedChild(child)?.signer.fingerprint, epoch1.home)
        var badLink = child
        badLink.epochLink = o.manifest.epochLink
        XCTAssertNil(frontier.verifiedChild(badLink), "a link that is not from the pinned epoch's keys")
        XCTAssertNil(frontier.verifiedChild(o.manifest), "another vault's epoch 2")
        var unsigned = child
        unsigned.epochSig = o.manifest.epochSig
        XCTAssertNil(frontier.verifiedChild(unsigned), "epochSig not by the pinned home")
        try a.removeDevices([try XCTUnwrap(a.devices.last?.id)])
        XCTAssertNil(frontier.verifiedChild(a.manifest), "two epochs on")
    }
}
