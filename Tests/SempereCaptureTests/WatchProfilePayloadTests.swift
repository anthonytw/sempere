import Age
import Foundation
@testable import Sempere
@testable import SempereCapture
import XCTest

/// Provisioning a watch (docs/design/1.1-watch.md §3.4, D3).
final class WatchProfilePayloadTests: XCTestCase {
    func watch() throws -> NativeIdentity { try WatchFixture.watchKey.get() }

    func testRoundTrip() throws {
        let key = try watch()
        let payload = try WatchFixture.payload(seq: 5, name: "Notes")
        let sealed = try payload.sealed(to: key.recipient)
        XCTAssertFalse(sealed.range(of: Data(try WatchFixture.profile.key.base64EncodedString().utf8)) != nil, "no plaintext key")
        let opened = try WatchProfilePayload.open(sealed, with: key)
        XCTAssertEqual(opened, payload)
        XCTAssertEqual(opened.profile, try WatchFixture.profile)
        XCTAssertEqual(opened.vaultName, "Notes")
        XCTAssertEqual(opened.profiles.count, 1)
        // The capture writer takes it.
        XCTAssertNoThrow(try CaptureWriter(profile: opened.profile))
    }

    func testAnotherRecipientCannotOpenIt() throws {
        let sealed = try WatchFixture.payload().sealed(to: try watch().recipient)
        let other = try NativeIdentity.generate(.postQuantum)
        XCTAssertThrowsError(try WatchProfilePayload.open(sealed, with: other)) {
            guard case .cannotOpen? = $0 as? WatchPayloadError else { return XCTFail("\($0)") }
        }
    }

    func testTamperedCiphertextFailsTyped() throws {
        let key = try watch()
        var sealed = try WatchFixture.payload().sealed(to: key.recipient)
        sealed[sealed.count - 20] ^= 0x01
        XCTAssertThrowsError(try WatchProfilePayload.open(sealed, with: key)) {
            guard case .cannotOpen? = $0 as? WatchPayloadError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try WatchProfilePayload.open(Data("garbage".utf8), with: key)) {
            guard case .cannotOpen? = $0 as? WatchPayloadError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try WatchProfilePayload.open(Data(count: WatchProfilePayload.maxBytes + 1), with: key)) {
            XCTAssertEqual($0 as? WatchPayloadError, .tooLarge)
        }
    }

    func testAProfileThatDoesNotValidateIsRefused() throws {
        let key = try watch()
        var bad = try WatchFixture.profile
        bad.epochId = "abcd"   // not 32 bytes
        XCTAssertThrowsError(try WatchFixture.payload(profile: bad).sealed(to: key.recipient)) {
            guard case .invalidProfile? = $0 as? WatchPayloadError else { return XCTFail("\($0)") }
        }
        var shortKey = try WatchFixture.profile
        shortKey.key = Data(count: 5)
        XCTAssertThrowsError(try WatchFixture.payload(profile: shortKey).validate())
        var noDevice = try WatchFixture.profile
        noDevice.device = "nothex"
        XCTAssertThrowsError(try WatchFixture.payload(profile: noDevice).validate())
        var noRecipient = try WatchFixture.profile
        noRecipient.recipients = ["not a key"]
        XCTAssertThrowsError(try WatchFixture.payload(profile: noRecipient).validate())
        // Forged on the sending side, opened on the watch: a payload with two profiles, or a future version.
        var two = try WatchFixture.payload()
        two.profiles.append(two.profiles[0])
        XCTAssertThrowsError(try two.validate()) { XCTAssertEqual($0 as? WatchPayloadError, .malformed("2 profiles (exactly one is read)")) }
        var future = try WatchFixture.payload()
        future.version = 2
        XCTAssertThrowsError(try future.validate()) { XCTAssertEqual($0 as? WatchPayloadError, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try WatchFixture.payload(seq: -1).validate())
    }

    func testOnlyPostQuantumWatchKeysAreProvisioned() throws {
        let classic = try NativeIdentity.generate(.x25519)
        XCTAssertThrowsError(try WatchFixture.payload().sealed(to: classic.recipient))
    }

    // MARK: Messages

    func testNewestPayloadWinsAndAnOlderOneIsIgnored() throws {
        let key = try watch()
        var state = WatchProfileState()
        func send(_ seq: Int) throws -> WatchProvisioning.Outcome {
            try WatchProvisioning.apply(try WatchProvisioning.provision(profile: WatchFixture.profile, vaultName: "v\(seq)", seq: seq,
                                                                        issued: Date(), to: key.recipient), identity: key, to: &state)
        }
        guard case .stored(let first) = try send(3) else { return XCTFail("not stored") }
        XCTAssertEqual(first.seq, 3)
        XCTAssertEqual(try send(2), .ignored)
        XCTAssertEqual(try send(3), .ignored, "the same counter is not newer")
        XCTAssertEqual(state.payload?.vaultName, "v3")
        guard case .stored(let newer) = try send(9) else { return XCTFail("not stored") }
        XCTAssertEqual(newer.vaultName, "v9")
        XCTAssertEqual(state.seq, 9)
    }

    func testClearDeletesAndAnOlderPayloadCannotBringTheProfileBack() throws {
        let key = try watch()
        var state = WatchProfileState()
        let old = try WatchProvisioning.provision(profile: WatchFixture.profile, vaultName: "v", seq: 4, issued: Date(), to: key.recipient)
        XCTAssertEqual(try WatchProvisioning.apply(.clear(seq: 1), identity: key, to: &state), .ignored, "nothing to clear")
        _ = try WatchProvisioning.apply(old, identity: key, to: &state)
        XCTAssertNotNil(state.payload)
        XCTAssertEqual(try WatchProvisioning.apply(.clear(seq: 5), identity: key, to: &state), .cleared)
        XCTAssertNil(state.payload)
        XCTAssertEqual(state.seq, 5)
        // WatchConnectivity redelivers the persisted context: still cleared.
        XCTAssertEqual(try WatchProvisioning.apply(old, identity: key, to: &state), .ignored)
        XCTAssertNil(state.payload)
        // A clear older than the profile is ignored too.
        let newer = try WatchProvisioning.provision(profile: WatchFixture.profile, vaultName: "v", seq: 8, issued: Date(), to: key.recipient)
        _ = try WatchProvisioning.apply(newer, identity: key, to: &state)
        XCTAssertEqual(try WatchProvisioning.apply(.clear(seq: 6), identity: key, to: &state), .ignored)
        XCTAssertNotNil(state.payload)
        XCTAssertThrowsError(try WatchProvisioning.apply(.clear(seq: -3), identity: key, to: &state))
    }

    func testMessagesTravelAsPropertyListDictionaries() throws {
        let key = try watch()
        let profile = try WatchProvisioning.provision(profile: WatchFixture.profile, vaultName: "v", seq: 1, issued: Date(), to: key.recipient)
        for m in [profile, .clear(seq: 7), WatchProvisioning.request(recipient: key.recipient)] {
            let dict = WatchProvisioning.dictionary(m)
            XCTAssertTrue(PropertyListSerialization.propertyList(dict, isValidFor: .binary), "WatchConnectivity needs a property list")
            XCTAssertEqual(WatchProvisioning.message(dict), m)
        }
        XCTAssertNil(WatchProvisioning.message(["other": 1]))
        XCTAssertNil(WatchProvisioning.message(["clear": "x"]))
        var state = WatchProfileState()
        XCTAssertEqual(try WatchProvisioning.apply(WatchProvisioning.request(recipient: key.recipient), identity: key, to: &state),
                       .notForTheWatch)
    }

    func testTheTransferMetadataAndAcksRoundTrip() throws {
        let sealed = try WatchFixture.sealed()
        let vault = try WatchFixture.profile.vaultId
        let meta = try WatchTransferMeta(sealed: sealed, vault: vault)
        XCTAssertEqual(meta.name, sealed.name)
        XCTAssertEqual(meta.size, sealed.data.count)
        XCTAssertEqual(meta.epochIdBytes, sealed.epochId)
        XCTAssertEqual(WatchTransferMeta(dictionary: meta.dictionary), meta)
        XCTAssertTrue(PropertyListSerialization.propertyList(meta.dictionary, isValidFor: .binary))
        XCTAssertEqual(try JSONDecoder().decode(WatchTransferMeta.self, from: JSONEncoder().encode(meta)), meta)
        XCTAssertNil(WatchTransferMeta(dictionary: ["id": "x"]))
        XCTAssertThrowsError(try WatchTransferMeta(sealed: SealedCapture(name: "x.age", data: Data()), vault: vault))
        XCTAssertThrowsError(try WatchTransferMeta(sealed: SealedCapture(name: sealed.name, data: sealed.data), vault: vault))

        let ack = WatchAck(acked: [UUID(), UUID()], have: [UUID()])
        XCTAssertEqual(WatchAck(dictionary: ack.dictionary), ack)
        XCTAssertNil(WatchAck(dictionary: [:]))
        XCTAssertEqual(WatchAck(dictionary: ["acked": ["nope", ack.acked[0].uuidString]])?.acked, [ack.acked[0]])
    }
}
