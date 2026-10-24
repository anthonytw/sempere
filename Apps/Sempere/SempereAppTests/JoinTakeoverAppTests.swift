import Age
import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import CryptoKit
import Testing
@testable import SempereApp

/// Joining and taking over in the app (key-hierarchy design §6.2, §6.3; phase KH5 part 2), through the model and
/// `RememberedKeys` with a `MemoryDeviceKeyStore`, devices in process on one vault folder.
@Suite(.serialized)
@MainActor
struct JoinTakeoverAppTests {
    struct PassingOwner: OwnerAuthenticator {
        func authenticate(reason: String) async throws {}
    }

    /// A vault created by "home" (its keys in its own store), plus a second device's model on the same folder.
    struct World {
        let url: URL
        let recovery: MLKEM768X25519Identity
        let home: AppModel
        let homeKeys: RememberedKeys
    }

    static func world(passphrase: String? = nil) async throws -> World {
        let parent = TestTemp.root.appendingPathComponent("Join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let trust = MemoryEpochTrustStore()
        let keys = RememberedKeys(store: MemoryDeviceKeyStore())
        var request = NewVaultRequest(name: "Mine", keySource: .generate, passphrase: passphrase)
        request.deviceName = "Home iPad"
        request.workFactor = 10
        request.device = try keys.store.generate()
        let created = try VaultLibrary.createVault(request, folder: "Mine.sempere", in: parent, trust: trust)
        try await keys.saveCreatedVaultKeys(created.device, vaultID: created.vaultID, vaultName: "Mine")
        guard case .mlkem768x25519(let r)? = try created.secretKey.map(IdentityFile.parse) else { throw CancellationError() }
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        model.takeoverDefaults = DevicesAppTests.defaults()
        model.ownerAuthenticator = PassingOwner()
        try await model.openVault(at: created.url)
        #expect(await keys.unlockWithDeviceKey(model) == .unlocked)
        return World(url: created.url, recovery: r, home: model, homeKeys: keys)
    }

    static func newDevice(_ url: URL) async throws -> (AppModel, RememberedKeys) {
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: MemoryEpochTrustStore())
        model.takeoverDefaults = DevicesAppTests.defaults()
        let keys = RememberedKeys(store: MemoryDeviceKeyStore())
        try await model.openVault(at: url)
        return (model, keys)
    }

    @Test func aDeviceJoinsByApprovalWithWordsBothWays() async throws {
        let w = try await Self.world()
        defer { w.home.close() }
        let (phone, phoneKeys) = try await Self.newDevice(w.url)
        defer { phone.close() }
        #expect(await phoneKeys.unlockWithDeviceKey(phone) == .noKey)
        let stage = try await phone.startJoin(store: phoneKeys.store)
        guard case .waiting(let words, let qr) = stage else { Issue.record("\(stage)"); return }
        #expect(words.count == 6)
        #expect(Data(base64Encoded: qr)?.count == 48)
        #expect(phone.joinIdentity != nil, "its runs look for the approval")
        // Still waiting: the vault does not list it.
        #expect(await phoneKeys.unlockWithDeviceKey(phone) == .joining)

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
        #expect(await phoneKeys.unlockWithDeviceKey(phone) == .joining)
        #expect(phoneKeys.joinStage == .confirming)
        let device = try await phoneKeys.store.keys(for: try #require(phone.vault?.vaultId), reason: "")
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
        let device = try await macKeys.store.keys(for: try #require(mac.vault?.vaultId), reason: "")
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
        #expect(phoneKeys.keyProblem == RememberedKeys.unreadableText)
        try await phoneKeys.forgetKeys(phone)
        #expect(!phoneKeys.hasKeys(for: phone))
        #expect(await phoneKeys.unlockWithDeviceKey(phone) == .noKey)
        // A stray: keys stored, not listed, no request in the copy.
        let id = try #require(phone.vault?.vaultId)
        try await store.save(try store.generate(), for: id, vaultName: "Mine")
        guard case .keyProblem(let why) = await phoneKeys.unlockWithDeviceKey(phone) else { Issue.record("not stray"); return }
        #expect(why == RememberedKeys.strayText)
        try await phoneKeys.forgetKeys(phone)
        guard case .waiting = try await phone.startJoin(store: store) else { Issue.record("cannot join again"); return }
    }

    /// A takeover with the passphrase alone (its copy carries the root), keeping only some devices: the others are
    /// removed (design §6.3).
    @Test func aTakeoverWithThePassphraseKeepsOnlyTheCheckedDevices() async throws {
        let pass = "tangerine wombat quarry velvet mosaic lantern"
        let w = try await Self.world(passphrase: pass)
        let homeID = try #require(w.home.vault?.vaultId)
        // Two more devices join by approval.
        var joined: [DeviceKeys] = []
        for _ in 0..<2 {
            let (d, k) = try await Self.newDevice(w.url)
            guard case .waiting(let words, _) = try await d.startJoin(store: k.store) else { return }
            let reply = try await w.home.approveDevice(words: words, qr: nil)
            await d.refreshLockedManifest()
            let keys = try await k.store.keys(for: homeID, reason: "")
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

    /// Review of #88, M4: deleting a vault this device manages devices of, with others listed, is warned about.
    @Test func deletingTheHomesCopyIsRecognized() async throws {
        let w = try await Self.world()
        defer { w.home.close() }
        let id = try #require(w.home.vault?.vaultId)
        #expect(!(await StoredVaultsSection.isHomeWithOthers(vaultID: id, at: w.url, store: w.homeKeys.store)), "alone: nothing to hand over")
        let (phone, phoneKeys) = try await Self.newDevice(w.url)
        defer { phone.close() }
        guard case .waiting(let words, _) = try await phone.startJoin(store: phoneKeys.store) else { return }
        _ = try await w.home.approveDevice(words: words, qr: nil)
        #expect(await StoredVaultsSection.isHomeWithOthers(vaultID: id, at: w.url, store: w.homeKeys.store))
        #expect(!(await StoredVaultsSection.isHomeWithOthers(vaultID: id, at: w.url, store: phoneKeys.store)))
    }

    @Test func theTypedWordsIgnoreNumbersAndPunctuation() {
        #expect(TypedWords.split("1. Abandon 2. ability, able\n4.about above  absent") == ["abandon", "ability", "able", "about", "above", "absent"])
    }

    @Test func theMemoryStoreKeepsOneSetPerVault() async throws {
        let store = MemoryDeviceKeyStore()
        let id = UUID()
        let k = try store.generate()
        try await store.save(k, for: id, vaultName: "V")
        await #expect(throws: DeviceKeyStoreError.self) { try await store.save(k, for: id, vaultName: "V") }
        #expect(try await store.keys(for: id, reason: "").key == k.key)
        try await store.setRequiresBiometry(true, for: id, vaultName: "V")
        #expect(await store.requiresBiometry(for: id))
        try await store.delete(for: id)
        #expect(!(await store.hasKeys(for: id)))
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

/// A join over a sync target (design §6.2): the joining device's runs carry its request to the server and take
/// home's approval back, keyless; it confirms with the reply words and then writes and syncs.
@Suite(.serialized)
@MainActor
struct JoinOverSyncAppTests {
    @Test func aDeviceJoinsThroughAWebDAVTarget() async throws {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let server = EngineWebDAVRemote(store: MemoryStore(name: "server"))
        let homeKeys = try DeviceKeys.parse(try String(contentsOf: keyURL, encoding: .utf8))
        let homeState = vault.deletingLastPathComponent().appendingPathComponent("home-sync.json")
        func homeSync() throws {
            let v = try Vault.open(at: vault, identities: [homeKeys.nativeIdentity], signing: homeKeys.signing)
            _ = try SyncEngine(directory: vault, vault: v, remote: server.remote, stateURL: homeState, options: SyncOptions()).run()
        }
        try homeSync()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.appendingPathComponent("vault.json")))
        let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
        let listing = WebDAVVaultListing(path: [], name: "Shared", vaultId: vaultId, format: "sempere/1",
                                         url: "https://dav.example.org/shared/")
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: MemoryEpochTrustStore())
        model.takeoverDefaults = DevicesAppTests.defaults()
        model.webdavRemote = server
        model.webdavPasswords = MemoryWebDAVPasswordStore()
        model.webdavTick = .milliseconds(20)
        model.webdavWriteDelay = 0.05
        let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("recents-\(UUID().uuidString).json"))
        _ = try await model.connectWebDAV(listing, user: nil, password: "", pin: nil, library: library)
        defer { model.close() }
        let keys = RememberedKeys(store: MemoryDeviceKeyStore())
        #expect(model.phase == .locked)
        guard case .waiting(let words, _) = try await model.startJoin(store: keys.store) else { Issue.record("not waiting"); return }
        _ = await model.webdav?.syncNow()   // a join run: the request goes up

        // Home finds the request on the server, approves it by the words, and syncs the approval.
        try homeSync()
        var home = try Vault.open(at: vault, identities: [homeKeys.nativeIdentity], signing: homeKeys.signing)
        let request = try #require(home.joinRequest(matching: words))
        let reply = try home.approveDevice(request)
        try homeSync()

        // The joining device's next run takes the approval; it confirms and unlocks.
        _ = await model.webdav?.syncNow()
        await model.refreshLockedManifest()
        #expect(await keys.unlockWithDeviceKey(model) == .joining)
        #expect(keys.joinStage == .confirming, "\(String(describing: model.webdav?.lastReport))")
        let device = try await keys.store.keys(for: try #require(model.vault?.vaultId), reason: "")
        try await model.confirmJoin(words: reply, keys: device)
        #expect(model.phase == .unlocked)
        #expect(model.joinIdentity == nil)
        let note = try await model.createNote(title: "Joined", paper: Paper(kind: .ruled), notebook: nil)
        _ = await model.webdav?.syncNow()
        try homeSync()
        #expect(try Vault.open(at: vault, identities: [homeKeys.nativeIdentity]).noteIDs().contains(note))
    }
}
