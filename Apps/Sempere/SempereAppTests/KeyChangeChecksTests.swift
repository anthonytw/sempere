import Age
import Foundation
@testable import Sempere
import Testing
@testable import SempereApp

/// Device checks of key changes, automated (audit checklist c24, c25, c38,
/// c39): removing a key, junk rewrap journals, a key added by another device
/// mid-change, and an interrupted replacement on a vault opened with a
/// passphrase only. The interruptions use the library's internal `stopAfter`
/// seam (`Vault.replaceRecipient(…, stopAfter:)`, `VaultError.interrupted`):
/// the files on disk are exactly what a quit or crash at that point leaves.
@Suite(.serialized, .timeLimit(.minutes(10)))
@MainActor
struct KeyChangeChecksTests {
    static let passphrase = "lunar-pickle-tundra-mosaic-quiver"
    static let journalName = "rewrap-journal.json"
    static let refusedName = "rewrap-journal.refused.json"

    // MARK: - Fixtures

    /// The fixture vault, its key stored passphrase-wrapped in `keys/` (so the
    /// passphrase alone opens it), and a second device's key.
    static func passphraseOnlyVault() throws -> (url: URL, own: NativeIdentity, other: NativeIdentity) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let own = try IdentityFile.parse(String(contentsOf: keyURL, encoding: .utf8))
        var vault = try Vault.open(at: url, identities: [own])
        try vault.writeIdentityFile(own, passphrase: passphrase, workFactor: 15, replace: true)
        let other = try NativeIdentity.generate(.postQuantum)
        try vault.addRecipient(other.recipient, label: "Old iPad")
        return (url, own, other)
    }

    static func model(trust: MemoryRecipientsTrustStore = MemoryRecipientsTrustStore()) -> AppModel {
        AppModel(deviceStateURL: TS.deviceStateURL(), recipientsTrust: trust)
    }

    static func manifest(_ url: URL) throws -> VaultManifest {
        try VaultManifest.decode(Data(contentsOf: url.appendingPathComponent("vault.json")))
    }

    static func exists(_ url: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    /// The change is over: no journal, no binding, every note readable with
    /// each of `opens`, nothing with each of `locksOut`.
    static func expectFinished(_ url: URL, opens: [NativeIdentity], locksOut: [NativeIdentity] = [],
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(!exists(url, journalName), sourceLocation: sourceLocation)
        #expect(try manifest(url).rewrapPending == nil, sourceLocation: sourceLocation)
        for identity in opens {
            let vault = try Vault.open(at: url, identities: [identity])
            #expect(!vault.pendingRewrap, sourceLocation: sourceLocation)
            #expect(try vault.summaries().count == 2, sourceLocation: sourceLocation)
            for id in try vault.noteIDs() {
                #expect(try vault.loadNote(id).failures.isEmpty, sourceLocation: sourceLocation)
            }
        }
        for identity in locksOut {
            #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
                _ = try Vault.open(at: url, identities: [identity]).summaries()
            }
        }
    }

    /// Runs `change` on the model's vault through the app's key-change path,
    /// returning true when it was interrupted (the `stopAfter` seam).
    static func interrupted(_ model: AppModel,
                            _ change: @escaping @Sendable (inout Vault) throws -> Vault.RewrapReport) async throws -> Bool {
        do {
            try await model.changeRecipients(change)
            return false
        } catch let error as VaultError {
            guard case .interrupted = error else { throw error }
            return true
        }
    }

    // MARK: - c39: interrupted key replacement, passphrase only

    /// c39 at every step: a vault opened with its passphrase replaces another
    /// device's key and is stopped after 0, 1, 2… files; the app is "quit" (a
    /// new model, nothing kept in memory), unlocked with the passphrase only,
    /// and finishes the change.
    @Test func c39InterruptedReplacementFinishesWithThePassphraseAtEveryStep() async throws {
        var stop = 0
        while true {
            let (url, own, old) = try Self.passphraseOnlyVault()
            let new = try NativeIdentity.generate(.postQuantum)
            let first = Self.model()
            try await first.openVault(at: url)
            try await first.unlock(passphrase: Self.passphrase)
            #expect(first.phase == .unlocked)
            let oldR = old.recipient, newR = new.recipient, n = stop
            let wasInterrupted = try await Self.interrupted(first) {
                try $0.replaceRecipient(oldR, with: newR, label: nil, added: Date(), policy: RewrapPolicy(), stopAfter: n)
            }
            first.close()
            guard wasInterrupted else { break }
            #expect(Self.exists(url, Self.journalName), "step \(stop): the journal is left")

            let relaunched = Self.model()
            try await relaunched.openVault(at: url)
            if stop == 1 {
                // A wrong passphrase on resume changes nothing.
                await #expect(throws: AppModel.ModelError.passphraseMatchesNoKey) {
                    try await relaunched.unlock(passphrase: "wrong-passphrase-entirely")
                }
                #expect(relaunched.phase == .locked)
            }
            try await relaunched.unlock(passphrase: Self.passphrase)
            #expect(relaunched.phase == .finishingKeyChange, "step \(stop)")
            #expect(relaunched.notes.isEmpty)
            try await relaunched.finishKeyChange()
            #expect(relaunched.phase == .unlocked, "step \(stop)")
            #expect(relaunched.notes.count == 2)
            #expect(relaunched.deviceKeys.contains { $0.recipient == new.recipient.string })
            #expect(!relaunched.deviceKeys.contains { $0.recipient == old.recipient.string })
            try Self.expectFinished(url, opens: [own, new], locksOut: [old])
            relaunched.close()
            stop += 1
        }
        #expect(stop >= 3, "the fixture has several files to rewrap, so several steps were interrupted")
    }

    /// c39 stress: interrupted twice (the first resume is stopped as well),
    /// then finished from the app with the passphrase.
    @Test func c39TwoInterruptionsStillFinish() async throws {
        let (url, own, old) = try Self.passphraseOnlyVault()
        let new = try NativeIdentity.generate(.postQuantum)
        let first = Self.model()
        try await first.openVault(at: url)
        try await first.unlock(passphrase: Self.passphrase)
        let oldR = old.recipient, newR = new.recipient
        #expect(try await Self.interrupted(first) {
            try $0.replaceRecipient(oldR, with: newR, label: nil, added: Date(), policy: RewrapPolicy(), stopAfter: 0)
        })
        first.close()
        // A second attempt (here through the library) is stopped too.
        var again = try Vault.open(at: url, identities: [own])
        #expect(again.pendingRewrap)
        #expect(throws: VaultError.self) { try again.resumeRewrap(stopAfter: 1) }

        let relaunched = Self.model()
        try await relaunched.openVault(at: url)
        try await relaunched.unlock(passphrase: Self.passphrase)
        #expect(relaunched.phase == .finishingKeyChange)
        try await relaunched.finishKeyChange()
        #expect(relaunched.phase == .unlocked)
        try Self.expectFinished(url, opens: [own, new], locksOut: [old])
    }

    /// c39 variant: the passphrase key itself replaced (as `sempere vault
    /// recipients replace --store-key` does, the new key stored under the same
    /// passphrase). Finishing needs both the old and the new stored key; the
    /// passphrase gives both, though the old one is no longer listed.
    @Test func c39ReplacingThePassphraseKeyItselfFinishesWithThePassphrase() async throws {
        var stop = 0
        while stop < 4 {
            let (url, own, other) = try Self.passphraseOnlyVault()
            let new = try NativeIdentity.generate(.postQuantum)
            var vault = try Vault.open(at: url, identities: [own])
            try vault.writeIdentityFile(new, passphrase: Self.passphrase, workFactor: 15)
            do {
                try vault.replaceRecipient(own.recipient, with: new.recipient, label: nil, added: Date(),
                                           policy: RewrapPolicy(), stopAfter: stop)
                break
            } catch VaultError.interrupted {}
            let model = Self.model()
            try await model.openVault(at: url)
            try await model.unlock(passphrase: Self.passphrase)
            #expect(model.phase == .finishingKeyChange, "step \(stop)")
            try await model.finishKeyChange()
            #expect(model.phase == .unlocked)
            try Self.expectFinished(url, opens: [new, other], locksOut: [own])
            model.close()
            stop += 1
        }
    }

    /// c39, step 1: the journal was written but `vault.json` was not (quit
    /// right after the first write). The journal is not bound, so it is
    /// refused; being fresh and holding the current secret, it is kept (it may
    /// be another device's step 1), the vault opens normally, and retrying
    /// the replacement moves it aside and completes.
    @Test func c39QuitBeforeVaultJsonChangedOpensNormallyAndTheRetryCompletes() async throws {
        let (url, own, old) = try Self.passphraseOnlyVault()
        let vault = try Vault.open(at: url, identities: [own])
        let secret = try #require(vault.secret)
        let new = try NativeIdentity.generate(.postQuantum)
        let armored = String(decoding: try AgeFile.encrypt(secret.bytes, to: [own.recipient, new.recipient], armor: true),
                             as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["format": "sempere/1", "previousVaultSecret": armored, "rekeyBlobs": true])
            .write(to: url.appendingPathComponent(Self.journalName))

        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(passphrase: Self.passphrase)
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(Self.exists(url, Self.journalName), "fresh, and maybe another device's: kept for now")
        try await model.replaceDeviceKey(old.recipient.string, with: new.recipient.string, label: "",
                                         authenticator: PassingOwnerAuthenticator())
        #expect(model.keyChangeNote != nil, "the change says it moved a journal aside")
        #expect(Self.exists(url, Self.refusedName))
        try Self.expectFinished(url, opens: [own, new], locksOut: [old])
    }

    /// c39, step 4: the binding was removed but the journal was not (quit
    /// between the two last writes). The journal is refused and, holding a
    /// secret other than the current one, moved aside at unlock.
    @Test func c39QuitBetweenTheLastTwoWritesOpensNormally() async throws {
        let (url, own, old) = try Self.passphraseOnlyVault()
        let new = try NativeIdentity.generate(.postQuantum)
        var vault = try Vault.open(at: url, identities: [own])
        #expect(throws: VaultError.self) {
            try vault.replaceRecipient(old.recipient, with: new.recipient, label: nil, added: Date(),
                                       policy: RewrapPolicy(), stopAfter: 0)
        }
        let journal = try Data(contentsOf: url.appendingPathComponent(Self.journalName))
        var resumed = try Vault.open(at: url, identities: [own])
        let report = try resumed.resumeRewrap()
        #expect(report.isComplete)
        try journal.write(to: url.appendingPathComponent(Self.journalName))   // as a crash before its removal leaves it

        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(passphrase: Self.passphrase)
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(!Self.exists(url, Self.journalName))
        #expect(Self.exists(url, Self.refusedName))
        try Self.expectFinished(url, opens: [own, new], locksOut: [old])
    }

    // MARK: - c24: remove a device key

    /// c24: after removing a device key, `vault.json` carries no
    /// `rewrapPending` and this device's trust record says `rewrapFinished`.
    @Test func c24RemovingAKeyLeavesNoPendingRewrapAndAFinishedTrustRecord() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let trust = MemoryRecipientsTrustStore()
        let model = Self.model(trust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: key, encoding: .utf8))
        let others = try (0..<2).map { _ in try NativeIdentity.generate(.postQuantum) }
        for (i, other) in others.enumerated() {
            try await model.addDeviceKey(recipient: other.recipient.string, label: "Device \(i)",
                                         authenticator: PassingOwnerAuthenticator())
        }
        // Remove both, the last other key included.
        for other in others {
            try await model.removeDeviceKey(other.recipient.string)
            let json = try String(contentsOf: url.appendingPathComponent("vault.json"), encoding: .utf8)
            #expect(!json.contains("rewrapPending"))
            let vaultId = try #require(model.vault?.vaultId)
            #expect(try trust.record(for: vaultId)?.rewrapFinished == true)
        }
        #expect(model.deviceKeys.count == 1)
        try Self.expectFinished(url, opens: model.unlockIdentities.compactMap { $0 as? NativeIdentity }, locksOut: others)
    }

    /// c24 stress: the removal is interrupted (quit mid-way), the same device
    /// (same trust store) finishes it at the next unlock; the record then says
    /// `rewrapFinished` and `vault.json` has no binding.
    @Test func c24AnInterruptedRemovalFinishesWithAFinishedTrustRecord() async throws {
        let (url, own, other) = try Self.passphraseOnlyVault()
        let trust = MemoryRecipientsTrustStore()
        let first = Self.model(trust: trust)
        try await first.openVault(at: url)
        try await first.unlock(passphrase: Self.passphrase)
        let otherR = other.recipient
        #expect(try await Self.interrupted(first) { try $0.removeRecipient(otherR, policy: RewrapPolicy(), stopAfter: 1) })
        let vaultId = try #require(first.vault?.vaultId)
        first.close()
        #expect(try Self.manifest(url).rewrapPending != nil)

        let relaunched = Self.model(trust: trust)
        try await relaunched.openVault(at: url)
        try await relaunched.unlock(passphrase: Self.passphrase)
        #expect(relaunched.phase == .finishingKeyChange)
        try await relaunched.finishKeyChange()
        #expect(try trust.record(for: vaultId)?.rewrapFinished == true)
        try Self.expectFinished(url, opens: [own], locksOut: [other])
    }

    // MARK: - c25: junk rewrap journal

    /// A journal of another vault's interrupted change (it decodes, but its
    /// secret is encrypted to keys this device does not hold).
    static func foreignJournal() throws -> Data {
        let (url, key) = try AppModelTests.fixtureVault()
        let own = try IdentityFile.parse(String(contentsOf: key, encoding: .utf8))
        var foreign = try Vault.open(at: url, identities: [own])
        _ = try? foreign.addRecipient(try NativeIdentity.generate(.postQuantum).recipient, label: "x", added: Date(),
                                      policy: RewrapPolicy(), stopAfter: 0)
        let stranger = try NativeIdentity.generate(.postQuantum)
        let armored = String(decoding: try AgeFile.encrypt(VaultSecret.random().bytes, to: [stranger.recipient], armor: true),
                             as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["format": "sempere/1", "previousVaultSecret": armored,
                                                           "rekeyBlobs": true])
    }

    enum Junk: String, CaseIterable, CustomTestStringConvertible {
        case notAJournal, truncated, empty, binary, huge, wrongShape, foreignOld
        var testDescription: String { rawValue }

        @MainActor func bytes() throws -> Data {
            switch self {
            case .notAJournal: return Data(#"{"hello":"world"}"#.utf8)
            case .truncated: return Data(#"{"format":"sempere/1","previousVaultSecret":"-----BEGIN AGE ENC"#.utf8)
            case .empty: return Data()
            case .binary: return Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37) })
            case .huge: return Data(repeating: 0x20, count: (16 << 20) + 1)
            case .wrongShape: return Data(#"{"format":7,"rekeyBlobs":"yes"}"#.utf8)
            case .foreignOld: return try KeyChangeChecksTests.foreignJournal()
            }
        }
    }

    /// c25: a junk `rewrap-journal.json` planted in the vault folder; the
    /// vault opens normally and the file is moved to
    /// `rewrap-journal.refused.json`. (`foreignOld`: a real journal of another
    /// vault, two days old.)
    @Test(arguments: Junk.allCases)
    func c25AJunkJournalIsMovedAsideAndTheVaultOpens(_ junk: Junk) async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let journal = url.appendingPathComponent(Self.journalName)
        try junk.bytes().write(to: journal)
        if junk == .foreignOld {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                                                  ofItemAtPath: journal.path)
        }
        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: key, encoding: .utf8))
        #expect(model.phase == .unlocked)
        #expect(model.keyChangeResume == nil)
        #expect(model.notes.count == 2)
        #expect(!Self.exists(url, Self.journalName))
        #expect(Self.exists(url, Self.refusedName))
        model.close()
    }

    /// c25 stress: a fresh real journal of another vault may be another
    /// device's step 1 (format.md §3.3.1 "Refused journals"): the unlock keeps
    /// it for a day, the vault still opens normally, and the next key change
    /// moves it aside.
    @Test func c25AFreshForeignJournalIsKeptButBlocksNothing() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        try Self.foreignJournal().write(to: url.appendingPathComponent(Self.journalName))
        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: key, encoding: .utf8))
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(Self.exists(url, Self.journalName))
        try await model.addDeviceKey(recipient: try NativeIdentity.generate(.postQuantum).recipient.string, label: "B",
                                     authenticator: PassingOwnerAuthenticator())
        #expect(!Self.exists(url, Self.journalName))
        #expect(Self.exists(url, Self.refusedName))
        #expect(model.keyChangeNote != nil)
    }

    /// c25 stress: a second junk journal replaces the first refused copy.
    @Test func c25ASecondJunkJournalReplacesTheFirstRefusedCopy() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let keyText = try String(contentsOf: key, encoding: .utf8)
        for (i, junk) in ["{\"a\":1}", "{\"b\":2}"].enumerated() {
            try Data(junk.utf8).write(to: url.appendingPathComponent(Self.journalName))
            let model = Self.model()
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText)
            #expect(model.phase == .unlocked, "journal \(i)")
            model.close()
            #expect(!Self.exists(url, Self.journalName))
            #expect(try Data(contentsOf: url.appendingPathComponent(Self.refusedName)) == Data(junk.utf8))
        }
    }

    /// c25 stress: in a read-only folder the journal cannot be moved; the
    /// vault still opens normally (the discard nobody asked for is best effort).
    @Test func c25AJunkJournalInAReadOnlyFolderStillOpens() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        try Data("junk".utf8).write(to: url.appendingPathComponent(Self.journalName))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: key, encoding: .utf8))
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
        #expect(Self.exists(url, Self.journalName), "nothing could be moved")
        model.close()
    }

    // MARK: - c38: key added mid-change

    /// c38 stress: another device adds a key and removes it again (a
    /// rotation: a new vault secret) while this one is unlocked; this
    /// device's change reopens the vault with its key and keeps that change.
    @Test func c38AnotherDeviceAddsThenRemovesAKeyBeforeThisChange() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let own = try IdentityFile.parse(String(contentsOf: key, encoding: .utf8))
        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: key, encoding: .utf8))
        let x = try NativeIdentity.generate(.postQuantum), y = try NativeIdentity.generate(.postQuantum)
        var elsewhere = try Vault.open(at: url, identities: [own])
        try elsewhere.addRecipient(x.recipient, label: "X")
        try elsewhere.removeRecipient(x.recipient)
        try await model.addDeviceKey(recipient: y.recipient.string, label: "Y", authenticator: PassingOwnerAuthenticator())
        let keys = try Set(Vault.open(at: url).recipients.map(\.key))
        #expect(keys == [own.recipient.string, y.recipient.string])
        #expect(model.deviceKeys.count == 2)
        #expect(model.recipientsAlert == nil)
        try Self.expectFinished(url, opens: [own, y], locksOut: [x])
    }

    /// c38 stress: two additions elsewhere, then a removal here.
    @Test func c38TwoAdditionsElsewhereThenARemovalHere() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let own = try IdentityFile.parse(String(contentsOf: key, encoding: .utf8))
        let model = Self.model()
        try await model.openVault(at: url)
        try await model.unlock(identityText: String(contentsOf: key, encoding: .utf8))
        let z = try NativeIdentity.generate(.postQuantum)
        try await model.addDeviceKey(recipient: z.recipient.string, label: "Z", authenticator: PassingOwnerAuthenticator())
        let x1 = try NativeIdentity.generate(.postQuantum), x2 = try NativeIdentity.generate(.postQuantum)
        var elsewhere = try Vault.open(at: url, identities: [own])
        try elsewhere.addRecipient(x1.recipient, label: "X1")
        try elsewhere.addRecipient(x2.recipient, label: "X2")
        try await model.removeDeviceKey(z.recipient.string)
        let keys = try Set(Vault.open(at: url).recipients.map(\.key))
        #expect(keys == [own.recipient.string, x1.recipient.string, x2.recipient.string])
        #expect(model.recipientsAlert == nil)
        try Self.expectFinished(url, opens: [own, x1, x2], locksOut: [z])
    }

}
