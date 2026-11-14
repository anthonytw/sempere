import Age
import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

/// An unlock attempt's outcome without the failure's error, so tests compare it.
enum AttemptOutcome: Equatable {
    case unlocked, noKey, joining, cancelled, failed
    case keyProblem(DeviceKeyProblem)
}

extension RememberedKeys.Attempt {
    var outcome: AttemptOutcome {
        switch self {
        case .unlocked: return .unlocked
        case .noKey: return .noKey
        case .joining: return .joining
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .keyProblem(let problem): return .keyProblem(problem)
        }
    }
}

extension AppModelSuites {
    /// Joining and taking over (key-hierarchy design §6.2, §6.3; phase KH5 part 2), through the model and
    /// `RememberedKeys` with a `MemoryDeviceKeyStore`, devices in process on one vault folder (moved from the app's
    /// `JoinTakeoverAppTests`, which keeps the takeover screen's codes, the typed words, the Keychain's signing items
    /// and what deleting home's key costs).
    @MainActor
    struct JoinTakeoverTests {
        /// A vault created by "home" (its keys in its own store), plus a second device's model on the same folder.
        struct World {
            let url: URL
            let recovery: MLKEM768X25519Identity
            let home: AppModel
            let homeKeys: RememberedKeys
        }

        static func world(passphrase: String? = nil) async throws -> World {
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            let (created, trust) = try await Self.create(passphrase: passphrase, device: try keys.store.generate())
            try await keys.saveCreatedVaultKeys(created.device, vaultID: created.vaultID, vaultName: "Mine")
            guard case .mlkem768x25519(let r)? = try created.secretKey.map(IdentityFile.parse) else { throw CancellationError() }
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
            model.ownerAuthenticator = ScriptedOwnerCheck(.pass)
            try await model.openVault(at: created.url)
            #expect(await keys.unlockWithDeviceKey(model).outcome == .unlocked)
            return World(url: created.url, recovery: r, home: model, homeKeys: keys)
        }

        /// "Mine", created by "Home iPad" with `device` as its keys, off the main actor (the recovery key's scrypt work and
        /// the vault's first files), and the trust store it was created with.
        @concurrent static func create(passphrase: String?, device: DeviceKeys) async throws
            -> (created: CreatedVault, trust: MemoryEpochTrustStore) {
            let parent = TestTemp.root.appendingPathComponent("Join-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let trust = MemoryEpochTrustStore()
            var request = NewVaultRequest(name: "Mine", keySource: .generate, passphrase: passphrase)
            request.deviceName = "Home iPad"
            request.workFactor = 10
            request.device = device
            return (try VaultLibrary.createVault(request, folder: "Mine.sempere", in: parent, trust: trust), trust)
        }

        static func newDevice(_ url: URL) async throws -> (AppModel, RememberedKeys) {
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: MemoryEpochTrustStore())
            let keys = RememberedKeys(store: MemoryDeviceKeyStore())
            try await model.openVault(at: url)
            return (model, keys)
        }

        @Test func aDeviceJoinsByApprovalWithWordsBothWays() async throws {
            let w = try await Self.world()
            defer { w.home.close() }
            let (phone, phoneKeys) = try await Self.newDevice(w.url)
            defer { phone.close() }
            #expect(await phoneKeys.unlockWithDeviceKey(phone).outcome == .noKey)
            let stage = try await phone.startJoin(store: phoneKeys.store)
            guard case .waiting(let words, let qr) = stage else { Issue.record("\(stage)"); return }
            #expect(words.count == 6)
            #expect(Data(base64Encoded: qr)?.count == 48)
            #expect(phone.joinIdentity != nil, "its runs look for the approval")
            // Still waiting: the vault does not list it.
            #expect(await phoneKeys.unlockWithDeviceKey(phone).outcome == .joining)

            // Home: wrong words are refused; the right ones approve and give the reply.
            await #expect(throws: DeviceJoinError.self) {
                _ = try await w.home.approveDevice(words: ["abandon", "ability", "able", "about", "above", "absent"], qr: nil)
            }
            #expect(await w.home.pendingJoinRequests().count == 1)
            let reply = try await w.home.approveDevice(words: words, qr: nil)
            #expect(reply.words.count == 6)
            #expect(await w.home.pendingJoinRequests().isEmpty)
            #expect(w.home.vault?.devices.count == 2)

            // The phone sees the approval and confirms with the reply.
            await phone.refreshLockedManifest()
            #expect(await phoneKeys.unlockWithDeviceKey(phone).outcome == .joining)
            #expect(phoneKeys.joinStage?.isConfirming == true)
            let device = try await phoneKeys.store.keys(for: try #require(phone.vault?.vaultId), reason: .unlock(vaultName: nil))
            await #expect(throws: VaultError.self, "other words never confirm") {
                try await phone.confirmJoin(words: Array(reply.words.reversed()), keys: device)
            }
            try await phone.confirmJoin(words: reply.words, keys: device)
            #expect(phone.phase == .unlocked)
            #expect(phone.listAlert == nil)
            _ = try await phone.createNote(title: "From the phone", paper: Paper(kind: .ruled), notebook: nil)
        }

        @Test func approvingByTheScannedCodeAndConfirmingByTheReplyCode() async throws {
            let w = try await Self.world()
            defer { w.home.close() }
            let (mac, macKeys) = try await Self.newDevice(w.url)
            defer { mac.close() }
            guard case .waiting(_, let qr) = try await mac.startJoin(store: macKeys.store) else { Issue.record("not waiting"); return }
            let reply = try await w.home.approveDevice(words: nil, qr: qr)
            await mac.refreshLockedManifest()
            let device = try await macKeys.store.keys(for: try #require(mac.vault?.vaultId), reason: .unlock(vaultName: nil))
            #expect(mac.replyWords(fromQR: "sempere-reply:\(UUID().uuidString.lowercased()):00:00", keys: device) == nil)
            let words = try #require(mac.replyWords(fromQR: reply.qr, keys: device))
            #expect(words == reply.words)
            try await mac.confirmJoin(words: words, keys: device)
            #expect(mac.phase == .unlocked)
        }

        @Test func aCancelledJoinLeavesNoKeyAndNoRequest() async throws {
            let w = try await Self.world()
            defer { w.home.close() }
            let (pad, padKeys) = try await Self.newDevice(w.url)
            defer { pad.close() }
            _ = try await pad.startJoin(store: padKeys.store)
            #expect(await w.home.pendingJoinRequests().count == 1)
            await pad.cancelJoin(store: padKeys.store)
            #expect(!(await padKeys.store.hasKeys(for: try #require(pad.vault?.vaultId))))
            #expect(await w.home.pendingJoinRequests().isEmpty)
        }

        @Test func aKitJoinTakesOverAndTheOldHomeIsAlerted() async throws {
            let w = try await Self.world()
            let homeVaultID = try #require(w.home.vault?.vaultId)
            w.home.close()
            let (newcomer, newKeys) = try await Self.newDevice(w.url)
            defer { newcomer.close() }
            // No root and no record of the vault: refused.
            let noRoot = try await newcomer.recoveryForTakeover(keyText: w.recovery.string, rootText: nil, passphrase: nil)
            await #expect(throws: DeviceJoinError.rootNeeded) {
                _ = try await newcomer.planTakeover(recovery: noRoot.identity, root: noRoot.root, store: newKeys.store)
            }
            let root = try #require(newcomer.vault?.root)
            let groups = KitRecovery.rootGroups(root).map { "\($0.group) (\($0.checksum))" }.joined(separator: " ")
            let given = try await newcomer.recoveryForTakeover(keyText: w.recovery.string, rootText: groups, passphrase: nil)
            #expect(given.root == root)
            await #expect(throws: DeviceJoinError.rootUnreadable) {
                _ = try await newcomer.recoveryForTakeover(keyText: w.recovery.string, rootText: "1234 (0000)", passphrase: nil)
            }
            let draft = try await newcomer.planTakeover(recovery: given.identity, root: given.root, store: newKeys.store)
            #expect(draft.newKeys != nil, "a kit join makes new keys")
            let home = try #require(draft.plan.candidates.first)
            #expect(home.checkedByDefault)
            let report = try await newcomer.takeOver(draft, keep: [], store: newKeys.store)
            #expect(report.reason == .takeover)
            #expect(newcomer.phase == .unlocked)
            #expect(newcomer.vault?.isHome == true)
            #expect(newcomer.takeoverAlert == nil, "its own takeover")
            #expect(await newKeys.store.hasKeys(for: homeVaultID))
            _ = try await newcomer.createNote(title: "After", paper: Paper(kind: .ruled), notebook: nil)
        }

        /// Review of #88, M3: a key this device can no longer read is offered to be forgotten, and then the device can
        /// join again; keys of no request and not listed (a stray) likewise.
        @Test func anUnreadableOrStrayKeyIsForgottenAndTheDeviceJoinsAgain() async throws {
            let w = try await Self.world()
            defer { w.home.close() }
            let (phone, phoneKeys) = try await Self.newDevice(w.url)
            defer { phone.close() }
            let store = try #require(phoneKeys.store as? MemoryDeviceKeyStore)
            _ = try await phone.startJoin(store: store)
            store.unreadable = true
            guard case .keyProblem = await phoneKeys.unlockWithDeviceKey(phone) else { Issue.record("no key problem"); return }
            #expect(phoneKeys.keyProblem == .unreadable)
            try await phoneKeys.forgetKeys(phone)
            #expect(!phoneKeys.hasKeys(for: phone))
            #expect(await phoneKeys.unlockWithDeviceKey(phone).outcome == .noKey)
            // A stray: keys stored, not listed, no request in the copy.
            let id = try #require(phone.vault?.vaultId)
            try await store.save(try store.generate(), for: id, vaultName: "Mine")
            guard case .keyProblem(let why) = await phoneKeys.unlockWithDeviceKey(phone) else { Issue.record("not stray"); return }
            #expect(why == .stray)
            try await phoneKeys.forgetKeys(phone)
            guard case .waiting = try await phone.startJoin(store: store) else { Issue.record("cannot join again"); return }
        }

        /// A takeover with the passphrase alone (its copy carries the root), keeping only some devices: the others are
        /// removed (design §6.3).
        @Test func aTakeoverWithThePassphraseKeepsOnlyTheCheckedDevices() async throws {
            let pass = "zixwos-gUnhy4-bobsuc"
            let w = try await Self.world(passphrase: pass)
            let homeID = try #require(w.home.vault?.vaultId)
            // Two more devices join by approval.
            var joined: [DeviceKeys] = []
            for _ in 0..<2 {
                let (d, k) = try await Self.newDevice(w.url)
                guard case .waiting(let words, _) = try await d.startJoin(store: k.store) else { return }
                let reply = try await w.home.approveDevice(words: words, qr: nil)
                await d.refreshLockedManifest()
                let keys = try await k.store.keys(for: homeID, reason: .unlock(vaultName: nil))
                try await d.confirmJoin(words: reply.words, keys: keys)
                joined.append(keys)
                d.close()
            }
            w.home.close()
            let (newcomer, newKeys) = try await Self.newDevice(w.url)
            defer { newcomer.close() }
            let given = try await newcomer.recoveryForTakeover(keyText: nil, rootText: nil, passphrase: pass)
            #expect(given.root == newcomer.vault?.root)
            let draft = try await newcomer.planTakeover(recovery: given.identity, root: given.root, store: newKeys.store)
            let keep: Set<Data> = [joined[0].fingerprint]
            let report = try await newcomer.takeOver(draft, keep: keep, store: newKeys.store)
            #expect(Set(report.removed).contains(joined[1].fingerprint))
            #expect(!Set(report.removed).contains(joined[0].fingerprint))
            #expect(newcomer.vault?.devices.count == 2, "the newcomer and the one kept")
        }

        /// Review of #88, S3: a kit join that fails leaves no keys behind.
        @Test func aFailedKitJoinLeavesNoKeys() async throws {
            let w = try await Self.world()
            let id = try #require(w.home.vault?.vaultId)
            w.home.close()
            let (newcomer, newKeys) = try await Self.newDevice(w.url)
            defer { newcomer.close() }
            let root = try #require(newcomer.vault?.root)
            let draft = try await newcomer.planTakeover(recovery: w.recovery, root: root, store: newKeys.store)
            await #expect(throws: (any Error).self, "a device that is no candidate cannot be kept") {
                _ = try await newcomer.takeOver(draft, keep: [Data(repeating: 9, count: 32)], store: newKeys.store)
            }
            #expect(!(await newKeys.store.hasKeys(for: id)))
        }

        /// Re-check of #88 (stray): a joiner whose request the copy no longer holds (home took it with an approval that
        /// has not arrived) is still waiting while its join is open here, never told to forget its keys; given up, the
        /// marker goes.
        @Test func aJoinerWhoseRequestWasTakenStillWaits() async throws {
            let w = try await Self.world()
            defer { w.home.close() }
            let (phone, phoneKeys) = try await Self.newDevice(w.url)
            defer { phone.close() }
            let id = try #require(phone.vault?.vaultId)
            _ = try await phone.startJoin(store: phoneKeys.store)
            try FileManager.default.removeItem(at: w.url.appendingPathComponent("joins"))
            #expect(await phoneKeys.unlockWithDeviceKey(phone).outcome == .joining)
            #expect(phoneKeys.keyProblem == nil)
            await phone.cancelJoin(store: phoneKeys.store)
            #expect(phone.deviceMemory.string(forKey: AppModel.joinRequestedKey(id)) == nil)
            // The same keys with no open join here: a stray.
            let keys = try phoneKeys.store.generate()
            try await phoneKeys.store.save(keys, for: id, vaultName: "Mine")
            guard case .keyProblem(let why) = await phoneKeys.unlockWithDeviceKey(phone) else { Issue.record("not stray"); return }
            #expect(why == .stray)
        }

        /// Second re-check of #88: the marker lapses once home would have deleted the request (7 days): the device is
        /// told the request expired and to join again, never left waiting.
        @Test func aJoinWhoseRequestHomeDeletedExpires() async throws {
            let w = try await Self.world()
            defer { w.home.close() }
            let (phone, phoneKeys) = try await Self.newDevice(w.url)
            defer { phone.close() }
            let id = try #require(phone.vault?.vaultId)
            _ = try await phone.startJoin(store: phoneKeys.store)
            let keys = try await phoneKeys.store.keys(for: id, reason: .unlock(vaultName: nil))
            #expect(phone.joinRequested(keys, vaultID: id) == .open)
            phone.setJoinRequested(keys, vaultID: id, at: Date().addingTimeInterval(-8 * 86_400))
            #expect(phone.joinRequested(keys, vaultID: id) == .lapsed)
            // Home deleted it.
            try FileManager.default.removeItem(at: w.url.appendingPathComponent("joins"))
            guard case .keyProblem(let why) = await phoneKeys.unlockWithDeviceKey(phone) else { Issue.record("not expired"); return }
            #expect(why == .expired)
            #expect(phoneKeys.joinStage == nil, "no longer waiting")
            try await phoneKeys.forgetKeys(phone)
            guard case .waiting = try await phone.startJoin(store: phoneKeys.store) else { Issue.record("cannot join again"); return }
            #expect(phone.joinRequested(try await phoneKeys.store.keys(for: id, reason: .unlock(vaultName: nil)), vaultID: id) == .open)
        }
    }
}
