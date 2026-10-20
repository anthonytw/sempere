import Age
import Crypto
import Foundation
import XCTest
@testable import Sempere

/// The core of the key-change safety gate (docs/design/device-first-sync.md §6.3, §6.5; format.md
/// §3.3.1 `mode`, `lateFileWindowDays`): the policy the journal records, the secret keyring and its
/// sealed stores, the fault points of a change (`RewrapFaults`), prepared changes, the late-file rewrap
/// (R3) and the outgoing-identity guard (F4). The multi-device behavior is in SempereWebDAVTests
/// (`KeyChangeScenarioTests`, `KeyChangeInterleavingTests`).
final class KeyChangeCoreTests: VaultTestCase {
    let a = pqIdentity(), b = pqIdentity()

    func journal(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields.merging(["format": "sempere/1", "rekeyBlobs": true]) { x, _ in x })
    }

    // MARK: The policy in the journal

    func testAbsentFieldsMeanRoutineSevenDays() throws {
        let p = try KeyChangePolicy(journalMode: nil, days: nil)
        XCTAssertEqual(p, .routine)
        XCTAssertEqual(p.lateFileWindowDays, 7)
        XCTAssertEqual(try KeyChangePolicy(journalMode: "compromised", days: nil), .compromised)
        XCTAssertEqual(try KeyChangePolicy(journalMode: "routine", days: 30).lateFileWindowDays, 30)
        XCTAssertEqual(try KeyChangePolicy(journalMode: nil, days: 0).window, 0)
    }

    func testPoliciesOutsideTheFormatAreRefused() {
        for (mode, days) in [("routine", -1), ("routine", 366), ("compromised", 1), ("ROUTINE", 7), ("lenient", 7)] as [(String, Int)] {
            XCTAssertThrowsError(try KeyChangePolicy(journalMode: mode, days: days), "\(mode) \(days)")
        }
        XCTAssertThrowsError(try KeyChangePolicy.routine(days: 400))
    }

    func testAJournalWithAPolicyOutsideTheFormatIsRefusedEvenWhenBound() throws {
        var v = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["a", "b"], identities: [a])
        _ = try populate(v)
        XCTAssertThrowsError(try v.removeRecipient(b.recipient, policy: RewrapPolicy(), stopAfter: 0))
        // Rebind a journal with a bad window under the new secret: still refused.
        let opened = try Vault.open(at: vaultURL(), identities: [a])
        let secret = try XCTUnwrap(opened.currentSecret)
        var j = try JSONSerialization.jsonObject(with: Data(contentsOf: opened.journalURL)) as! [String: Any]
        j["lateFileWindowDays"] = 9999
        let bad = try JSONSerialization.data(withJSONObject: j)
        try bad.write(to: opened.journalURL)
        var m = opened.manifest
        m.rewrapPending = RecipientsAuth.rewrapPending(vaultId: m.vaultId, journal: bad, secret: secret)
        _ = try Vault.writeManifest(m, to: opened.manifestURL, replacing: true, secret: secret)
        let reopened = try Vault.open(at: vaultURL(), identities: [a])
        XCTAssertTrue(reopened.journalRefused, "a target cannot widen the window: the field is bound, and checked")
    }

    func testTheChangeRecordsItsModeAndWindowBoundByRewrapPending() throws {
        var v = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["a", "b"], identities: [a])
        _ = try populate(v)
        let p = try v.prepareRemoveRecipient(b.recipient, keyChange: try .routine(days: 3))
        let fields = try JSONSerialization.jsonObject(with: p.journal) as! [String: Any]
        XCTAssertEqual(fields["mode"] as? String, "routine")
        XCTAssertEqual(fields["lateFileWindowDays"] as? Int, 3)
        XCTAssertThrowsError(try v.commit(p, faults: RewrapFaults(stop: .afterManifest)))
        let pending = try Vault.open(at: vaultURL(), identities: [a])
        XCTAssertEqual(try Data(contentsOf: pending.journalURL), p.journal, "K1 writes exactly the prepared (claimed) bytes")
        guard case .accepted(let j, _) = pending.judgeJournal() else { return XCTFail("bound journal refused") }
        XCTAssertEqual(try j.keyChangePolicy(), try .routine(days: 3))
        // Changing the policy in the journal unbinds it (a target cannot alter the policy).
        var edited = fields
        edited["lateFileWindowDays"] = 365
        try JSONSerialization.data(withJSONObject: edited).write(to: pending.journalURL)
        XCTAssertTrue(try Vault.open(at: vaultURL(), identities: [a]).journalRefused)
    }

    // MARK: Fault points (RewrapFaults)

    func testEveryFaultPointLeavesAVaultThatFinishesOrRefusesItsJournal() throws {
        let points: [RewrapFaults.Point] = [.afterJournal, .afterManifest, .afterFiles(0), .afterFiles(2), .beforeFinish]
        for (i, point) in points.enumerated() {
            let url = vaultURL("F\(i)")
            var v = try Vault.create(at: url, recipients: [a.recipient, b.recipient], labels: ["a", "b"], identities: [a])
            _ = try populate(v)
            let ring = MemorySecretKeyringStore()
            let p = try v.prepareRemoveRecipient(b.recipient)
            XCTAssertThrowsError(try v.commit(p, faults: RewrapFaults(stop: point), keyring: ring), "\(point)")
            XCTAssertEqual(try ring.load(vaultId: v.vaultId)?.entries.filter { $0.replaced != nil }.count, 1,
                           "\(point): the outgoing secret is in the keyring before anything is written")
            var reopened = try Vault.open(at: url, identities: [a])
            if point == .afterJournal {
                XCTAssertTrue(reopened.journalRefused, "unbound: refused (F2)")
                XCTAssertEqual(reopened.recipients.count, 2, "nothing changed")
                XCTAssertNotNil(try reopened.discardRefusedJournal())
            } else {
                XCTAssertNotNil(reopened.previousSecret, "\(point)")
                XCTAssertTrue(try reopened.resumeRewrap().isComplete, "\(point)")
                XCTAssertEqual(reopened.recipients.map(\.key), [a.recipient.string])
            }
            XCTAssertTrue(reopened.verify().isHealthy, "\(point)")
        }
    }

    func testACommitRefusesAVaultJSONThatMovedSincePrepared() throws {
        var v = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["a", "b"], identities: [a])
        let p = try v.prepareRemoveRecipient(b.recipient)
        var other = try Vault.open(at: vaultURL(), identities: [a])
        try other.addRecipient(pqIdentity().recipient, label: "c")
        XCTAssertThrowsError(try v.commit(p))
    }

    // MARK: The keyring

    func testTheKeyringDeadlineIsTheEarliestOfEveryLaterWindow() throws {
        let s0 = VaultSecret.random(), s1 = VaultSecret.random(), s2 = VaultSecret.random()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var ring = SecretKeyring(vaultId: UUID())
        ring.remember(s0, now: t0)
        ring.noteReplaced(s0, now: t0)
        ring.notePolicy(try .routine(days: 7), outgoing: s0, changedAt: t0)
        XCTAssertEqual(ring.lateFileDeadline(for: s0), t0.addingTimeInterval(7 * 86_400))
        XCTAssertNil(ring.lateFileDeadline(for: s1), "a secret this device never held is never late, only invalid")
        ring.remember(s1, now: t0)
        XCTAssertNil(ring.lateFileDeadline(for: s1), "current: nothing is late")
        // A later compromised change closes the window of every older secret too.
        ring.noteReplaced(s1, now: t0.addingTimeInterval(86_400))
        ring.notePolicy(.compromised, outgoing: s1, changedAt: t0.addingTimeInterval(86_400))
        ring.remember(s2, now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(ring.lateFileDeadline(for: s0), t0.addingTimeInterval(86_400))
        XCTAssertEqual(ring.lateFileDeadline(for: s1), t0.addingTimeInterval(86_400))
        // A change whose journal this device never saw counts as 0 days (F18).
        var unseen = SecretKeyring(vaultId: UUID())
        unseen.noteReplaced(s0, now: t0)
        XCTAssertEqual(unseen.lateFileDeadline(for: s0), t0)
        // A policy seen later can only make it stricter.
        unseen.notePolicy(try .routine(days: 9), outgoing: s0, changedAt: t0)
        unseen.notePolicy(try .routine(days: 2), outgoing: s0, changedAt: t0)
        XCTAssertEqual(unseen.entry(for: s0)?.policy?.lateFileWindowDays, 2)
        XCTAssertEqual(ring.secrets(excluding: s2), [s1, s0], "newest replaced first")
    }

    func testSealedKeyringsRoundTripAndFailClosed() throws {
        let id = UUID(), s = VaultSecret.random()
        let key = SymmetricKey(size: .bits256)
        for (name, sealer, wrong) in [("symmetric", SymmetricKeyringSealer(key: key) as any KeyringSealer,
                                       SymmetricKeyringSealer(key: SymmetricKey(size: .bits256)) as any KeyringSealer),
                                      ("age", AgeKeyringSealer(identity: a), AgeKeyringSealer(identity: b))] {
            let dir = tmp.appendingPathComponent("rings-\(name)")
            let store = SealedFileKeyringStore(directory: dir, sealer: sealer)
            XCTAssertNil(try store.load(vaultId: id))
            try store.update(vaultId: id) { $0.remember(s, now: Date()); $0.noteReplaced(s, now: Date()) }
            XCTAssertEqual(try store.load(vaultId: id)?.secrets(excluding: VaultSecret.random()), [s], name)
            let file = dir.appendingPathComponent("\(id.uuidString.lowercased()).keyring")
            let sealed = try Data(contentsOf: file)
            XCTAssertNil(sealed.range(of: Data(Hex.encode(s.bytes).utf8)), "\(name): never in plaintext")
            XCTAssertNil(sealed.range(of: s.bytes), name)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, name)
            XCTAssertThrowsError(try SealedFileKeyringStore(directory: dir, sealer: wrong).load(vaultId: id), "\(name): wrong key")
            // Another vault's keyring under this name is refused, never taken.
            let other = UUID()
            try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("\(other.uuidString.lowercased()).keyring"))
            XCTAssertThrowsError(try store.load(vaultId: other), name)
            // A damaged one is an error, never "no keyring" (that would forget secrets).
            var damaged = sealed
            damaged[damaged.count / 2] ^= 1
            try damaged.write(to: file)
            XCTAssertThrowsError(try store.load(vaultId: id), name)
        }
    }

    // MARK: R3 and copies

    func testLateLocalFilesAreRewrappedFromTheKeyringOnly() throws {
        var v = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["a", "b"], identities: [a])
        _ = try populate(v)
        // A copy of the vault as B kept it before the removal: its files are under the old secret.
        try FileManager.default.copyItem(at: vaultURL(), to: vaultURL("Old"))
        let ring = MemorySecretKeyringStore()
        try v.commit(try v.prepareRemoveRecipient(b.recipient), keyring: ring)
        // An old file comes back into the working copy (the device's own late file).
        let old = try Vault.open(at: vaultURL("Old"), identities: [a])
        let name = try XCTUnwrap(try old.revisionNames(of: testNote).first)
        let path = "notes/\(testNote.uuidString.lowercased())/\(name.filename)"
        try FileManager.default.removeItem(at: vaultURL().appendingPathComponent(path))
        try FileManager.default.copyItem(at: vaultURL("Old").appendingPathComponent(path), to: vaultURL().appendingPathComponent(path))
        let current = try Vault.open(at: vaultURL(), identities: [a])
        let data = try Data(contentsOf: vaultURL().appendingPathComponent(path))
        XCTAssertNil(current.lateSecret(ofRevision: data, note: testNote, name: name), "without the keyring: unknown")
        XCTAssertFalse(current.withOlderSecrets(from: nil).classifyRevision(data, note: testNote, name: name).isCurrent)
        XCTAssertTrue(try current.rewrapLateFiles(ownDevices: [devA, devB, devC]).failures.keys.contains { $0.hasSuffix(name.filename) },
                      "without the keyring it is left as it is and reported")
        let withRing = current.withOlderSecrets(from: try ring.load(vaultId: current.vaultId))
        XCTAssertNotNil(withRing.lateSecret(ofRevision: data, note: testNote, name: name))
        let report = try withRing.rewrapLateFiles(ownDevices: [devA, devB, devC])
        XCTAssertTrue(report.isComplete, "\(report)")
        let after = try Data(contentsOf: vaultURL().appendingPathComponent(path))
        XCTAssertTrue(current.classifyRevision(after, note: testNote, name: name).isCurrent)
        XCTAssertNil(try? AgeFile.decrypt(after, with: [b]), "the removed key no longer opens it")
        XCTAssertTrue(try Vault.open(at: vaultURL(), identities: [a]).verify().isHealthy)
    }

    // MARK: F4

    func testTheOutgoingIdentityIsKeptWhileAReplaceIsPending() throws {
        let c = pqIdentity()
        var v = try Vault.create(at: vaultURL(), recipients: [a.recipient, b.recipient], labels: ["a", "b"], identities: [a, c])
        _ = try populate(v)
        let p = try v.prepareReplaceRecipient(a.recipient, with: c.recipient)
        XCTAssertThrowsError(try v.commit(p, faults: RewrapFaults(stop: .afterFiles(1))))
        var pending = try Vault.open(at: vaultURL(), identities: [a, c])
        XCTAssertNotNil(OutgoingKeyGuard.refusal(recipient: a.recipient.string, vault: pending, targetsPending: false))
        XCTAssertNil(OutgoingKeyGuard.refusal(recipient: c.recipient.string, vault: pending, targetsPending: false))
        XCTAssertNil(OutgoingKeyGuard.refusal(recipient: b.recipient.string, vault: pending, targetsPending: false))
        XCTAssertTrue(try pending.resumeRewrap().isComplete)
        XCTAssertNil(OutgoingKeyGuard.refusal(recipient: a.recipient.string, vault: pending, targetsPending: false))
        XCTAssertNotNil(OutgoingKeyGuard.refusal(recipient: a.recipient.string, vault: pending, targetsPending: true),
                        "a sync target still pending keeps it")
    }

    // MARK: Keyring store (review finding 8)

    func testKeyringUpdatesFromSeveralThreadsAndStoresLoseNothing() throws {
        let id = UUID()
        let dir = tmp.appendingPathComponent("rings-concurrent")
        let a = SealedFileKeyringStore(directory: dir, sealer: SymmetricKeyringSealer(key: SymmetricKey(data: Data(repeating: 7, count: 32))))
        let b = SealedFileKeyringStore(directory: dir, sealer: SymmetricKeyringSealer(key: SymmetricKey(data: Data(repeating: 7, count: 32))))
        let secrets = (0..<24).map { _ in VaultSecret.random() }
        DispatchQueue.concurrentPerform(iterations: secrets.count) { i in
            let store = i % 2 == 0 ? a : b
            _ = try? store.update(vaultId: id) { $0.remember(secrets[i], now: Date()) }
        }
        let ring = try XCTUnwrap(try a.load(vaultId: id))
        XCTAssertEqual(Set(ring.entries.map(\.id)), Set(secrets.map(SecretKeyring.id(of:))), "no update lost")
    }

    func testAnUnreadableKeyringIsSetAsideNotReadAsEmpty() throws {
        let id = UUID()
        let dir = tmp.appendingPathComponent("rings-aside")
        let store = SealedFileKeyringStore(directory: dir, sealer: AgeKeyringSealer(identity: a))
        try store.update(vaultId: id) { $0.remember(VaultSecret.random(), now: Date()) }
        let other = SealedFileKeyringStore(directory: dir, sealer: AgeKeyringSealer(identity: b))
        XCTAssertThrowsError(try other.load(vaultId: id))
        XCTAssertThrowsError(try other.update(vaultId: id) { _ in }, "never overwritten as if empty")
        let aside = try XCTUnwrap(try other.setAside(vaultId: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path), "kept")
        XCTAssertNil(try other.load(vaultId: id))
        try other.update(vaultId: id) { $0.remember(VaultSecret.random(), now: Date()) }
        XCTAssertNotNil(try other.load(vaultId: id))
    }

    /// The CLI's identity is also a vault key and is replaced: sealed to both, the keyring opens with the
    /// new one once it was saved again; with the old one alone it is reported unreadable, never guessed.
    func testTheCLIIdentityReplacedResealsTheKeyring() throws {
        let id = UUID(), s = VaultSecret.random()
        let dir = tmp.appendingPathComponent("rings-reseal")
        try SealedFileKeyringStore(directory: dir, sealer: AgeKeyringSealer(identity: a)).update(vaultId: id) {
            $0.remember(s, now: Date())
        }
        let both = SealedFileKeyringStore(directory: dir, sealer: AgeKeyringSealer(identities: [b, a]))
        XCTAssertNotNil(try both.load(vaultId: id))
        try both.reseal(vaultId: id)
        let newOnly = SealedFileKeyringStore(directory: dir, sealer: AgeKeyringSealer(identity: b))
        XCTAssertEqual(try newOnly.load(vaultId: id)?.secrets(excluding: VaultSecret.random()), [s])
    }

    func testTheWindowEndsAtTheChangeTimeHoweverLateItIsSeen() {
        let s0 = VaultSecret.random()
        let changedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var ring = SecretKeyring(vaultId: UUID())
        ring.noteReplaced(s0, now: changedAt.addingTimeInterval(30 * 86_400))   // seen 30 days late
        ring.notePolicy(try! .routine(days: 7), outgoing: s0, changedAt: changedAt)
        XCTAssertEqual(ring.lateFileDeadline(for: s0), changedAt.addingTimeInterval(SecretKeyring.clockSlack + 7 * 86_400))
        var early = SecretKeyring(vaultId: UUID())
        early.noteReplaced(s0, now: changedAt.addingTimeInterval(-600))   // a clock behind the changer's
        early.notePolicy(try! .routine(days: 7), outgoing: s0, changedAt: changedAt)
        XCTAssertEqual(early.lateFileDeadline(for: s0), changedAt.addingTimeInterval(-600 + 7 * 86_400))
    }
}
