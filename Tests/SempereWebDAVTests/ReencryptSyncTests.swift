import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Re-encrypt everything over sync (key-hierarchy design §7, §11.1; phase KH6), over in-memory targets: home claims
/// every target, starts the epoch, re-encrypts, and the runs carry the journal and the current copies (rewrap-replace)
/// to every device and target, through a bridge; home confirms each target and finishes; afterwards nothing on a target
/// or in a working copy opens with a key from before (J7). Also: claims refused and released, an offline device back
/// after the finish, a withheld journal, a takeover by a device pinned at the re-encryption that finishes it.
final class ReencryptSyncTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        Vault.epochMutations = []
        super.tearDown()
    }

    /// Every vault identity and kit of `w` so far, as `device` holds them.
    static func keysSoFar(_ w: EpochSyncWorld, _ device: EpochSyncDevice) throws -> [any AgeIdentity] {
        let v = try device.open()
        return v.identities + v.olderEpochs.map { $0.identity as any AgeIdentity } + [NativeIdentity.mlkem768x25519(w.recovery)]
    }

    /// The epoch keys `device` holds so far (its current one and every earlier one it reads): published summaries
    /// files (`.sealed`, not age files) are sealed under keys derived from them.
    static func epochKeysSoFar(_ device: EpochSyncDevice) throws -> [VaultEpochKey] {
        let v = try device.open()
        return (v.secret.map { [$0] } ?? []) + v.olderEpochs.map(\.key)
    }

    /// True when a published summaries file (the root file, or a per-device file's sealed part) opens under `key`.
    static func summariesOpen(_ data: Data, under key: VaultEpochKey, vaultId: UUID) -> Bool {
        let sealed = PublishedSummaries.split(data)?.sealed ?? data
        return (try? PublishedSummaries.open(sealed, secret: key, vaultId: vaultId)) != nil
    }

    /// J7: the files of a working copy or target that open with one of `old` (and wraps in `vault.json`), and the
    /// published summaries files (`.sealed`) that open under one of `oldKeys` (review of #89, S1).
    static func openWithOld(files: [String: Data], _ old: [any AgeIdentity], oldKeys: [VaultEpochKey] = [],
                            vaultId: UUID? = nil) -> [String] {
        var out: [String] = []
        for (p, data) in files.sorted(by: { $0.key < $1.key }) {
            if p == Vault.manifestName {
                guard let m = try? EpochManifest.parse(data) else { continue }
                for k in m.keys where old.contains(where: { (try? AgeFile.decrypt(Data(k.wrap.utf8), with: [$0])) != nil }) {
                    out.append("vault.json \(k.role)")
                }
                continue
            }
            if p.hasSuffix(".sealed"), let vaultId {
                if oldKeys.contains(where: { summariesOpen(data, under: $0, vaultId: vaultId) }) { out.append(p) }
                continue
            }
            guard p.hasSuffix(".age") else { continue }
            if old.contains(where: { (try? AgeFile.decrypt(data, with: [$0])) != nil }) { out.append(p) }
        }
        return out
    }

    static func files(_ folder: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for p in SyncFilesList.all(in: folder) { out[p] = try? Data(contentsOf: folder.appendingPathComponent(p)) }
        return out
    }

    static func files(_ t: EpochTarget) -> [String: Data] {
        var out: [String: Data] = [:]
        for p in t.paths { out[p] = t.file(p) }
        return out
    }

    /// Home `name` starts a re-encryption on `targets`, keeping every other listed device.
    @discardableResult
    static func start(_ w: EpochSyncWorld, home name: String, targets: [EpochTarget]) throws -> MLKEM768X25519Identity {
        var a = try w[name].open()
        let kit = try MLKEM768X25519Identity()
        let keep = Set(a.manifest.devices.filter { $0.fingerprint != a.manifest.home }.compactMap(\.id))
        let prep = try a.prepareReencryption(kit, keep: keep, remove: [])
        var seen: ReencryptCoordinator.ClaimSightings = [:]
        let claims = ReencryptCoordinator.claim(prep.journalFile, vault: a, on: targets.map { .init(name: $0.name, remote: $0.remote(for: name)) },
                                                seen: &seen)
        guard claims.values.allSatisfy(\.isClaimed) else { throw VaultError.epochChangeRefused("claims: \(claims)") }
        try a.beginReencryption(prep)
        return kit
    }

    /// Home `name` advances the re-encryption once on `targets`.
    @discardableResult
    static func advance(_ w: EpochSyncWorld, home name: String, targets: [EpochTarget]) throws -> ReencryptCoordinator.Progress {
        var a = try w[name].open()
        var memo: [String: [String: String]] = [:]
        let byName = Dictionary(targets.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        return try ReencryptCoordinator.advance(&a, targets: targets.map { .init(name: $0.name, remote: $0.remote(for: name)) },
                                                sync: { t in _ = try byName[t.name].map { try w[name].sync($0) } },
                                                memo: &memo, scratch: w[name].root.appendingPathComponent("confirm"))
    }

    func testReencryptionReachesEveryDeviceAndTargetThroughABridge() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        try w["A"].sync(t2); try w["C"].sync(t2)
        var titles: [UUID: String] = [:]
        titles[try w["A"].write("A one")] = "A one"
        titles[try w["B"].write("B one")] = "B one"
        titles[try w["C"].write("C one")] = "C one"
        let b = try w["B"].open()
        let note = try XCTUnwrap(titles.first { $0.value == "B one" }?.key)
        let ref = try b.writeBlob(note: note, Data("blob bytes".utf8), type: "image/png")
        _ = try b.createNotebook("Work")
        for _ in 0..<2 { try w["B"].sync(t1); try w["A"].sync(t1); try w["A"].sync(t2); try w["C"].sync(t2) }
        let old = try Self.keysSoFar(w, w["A"])
        let oldKeys = try Self.epochKeysSoFar(w["A"])
        XCTAssertFalse(Self.openWithOld(files: Self.files(t1), old, oldKeys: oldKeys, vaultId: w.vaultId).isEmpty)

        let kit = try Self.start(w, home: "A", targets: [t1, t2])
        var finished = false
        for _ in 0..<6 where !finished {
            try w["B"].sync(t1); try w["C"].sync(t2)
            finished = try Self.advance(w, home: "A", targets: [t1, t2]).finished
        }
        XCTAssertTrue(finished)
        for _ in 0..<3 { try w["B"].sync(t1); try w["C"].sync(t2); try w["A"].sync(t1); try w["A"].sync(t2) }
        w.recovery = kit
        for (n, f) in [("T1", Self.files(t1)), ("T2", Self.files(t2)), ("A", Self.files(w["A"].folder)),
                       ("B", Self.files(w["B"].folder)), ("C", Self.files(w["C"].folder))] {
            XCTAssertEqual(Self.openWithOld(files: f, old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 at \(n)")
            XCTAssertNil(f[Vault.journalName], "the journal is gone at \(n)")
        }
        for n in ["A", "B", "C"] {
            XCTAssertEqual(try w[n].titles(), titles, n)
            let v = try w[n].open()
            XCTAssertFalse(v.isReencryptPending, n)
            XCTAssertEqual(try v.readBlob(note: note, ref), Data("blob bytes".utf8), n)
            XCTAssertEqual(try v.readNotebookRecords().records.count, 1, n)
            XCTAssertNoThrow(try v.requireWritable(), n)
        }
        // Writes after it reach everyone.
        let after = try w["C"].write("C after")
        try w["C"].sync(t2); try w["A"].sync(t2); try w["A"].sync(t1); try w["B"].sync(t1)
        XCTAssertEqual(try w["B"].titles()[after], "C after")
    }

    /// Sync stress seed 10 (KH6): a device that jumped epochs never held the keys between; while the re-encryption is
    /// pending it takes them from the bound journal into its ledger, so after the finish it can still judge (set aside
    /// and delete on the targets it bridges) a file a removed device uploaded under one of them, instead of reading it
    /// as undecryptable and only quarantining it.
    func testADeviceThatJumpedEpochsKeepsTheJournalsKeys() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C"], targets: ["T1"])
        let t1 = w.target("T1")
        try w["A"].sync(t1); try w["B"].sync(t1); try w["C"].sync(t1)
        // C is offline through epochs 2 (B removed, by a kit replacement keeping C) and 3 (the re-encryption).
        var a = try w["A"].open()
        let c = try XCTUnwrap(a.manifest.devices.first { $0.fingerprint == w["C"].keys.fingerprint }?.id)
        let b = try XCTUnwrap(a.manifest.devices.first { $0.fingerprint == w["B"].keys.fingerprint }?.id)
        _ = try a.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: [c], remove: [b])
        let epoch2 = try w["A"].open().manifest.epochId
        try w["A"].sync(t1)
        try Self.start(w, home: "A", targets: [t1])
        try w["A"].sync(t1)
        XCTAssertFalse(try w["C"].ledger.epochKeys().contains { $0.key.epochId == epoch2 }, "C never opened epoch 2")
        try w["C"].sync(t1)
        XCTAssertTrue(try w["C"].open().isReencryptPending)
        XCTAssertTrue(try w["C"].ledger.epochKeys().contains { $0.key.epochId == epoch2 }, "taken from the bound journal")
    }

    /// Review of #89, S1: the per-device published summaries (`summaries/<device>.sealed`) of a device removed in the
    /// review never get rewritten by it: they are gone from the target and every working copy after the finish, so
    /// nothing there opens under a key from before it (J7 over `.sealed` files too).
    func testARemovedDevicesSummariesGoAtTheFinish() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["X"].write("X one")] = "X one"
        titles[try w["B"].write("B one")] = "B one"
        for n in ["X", "B"] { try w[n].open().writeDevicePublishedSummaries([:]) }
        for _ in 0..<2 { for n in ["X", "B", "A"] { try w[n].sync(t1) } }
        let xFile = "\(PublishedSummaries.deviceFolderName)/\(PublishedSummaries.deviceFileName(try XCTUnwrap(w["X"].open().writerDevice)))"
        XCTAssertNotNil(t1.file(xFile), "X published its summaries")
        let old = try Self.keysSoFar(w, w["A"])
        let oldKeys = try Self.epochKeysSoFar(w["A"])
        XCTAssertTrue(Self.openWithOld(files: Self.files(t1), old, oldKeys: oldKeys, vaultId: w.vaultId).contains(xFile))
        var a = try w["A"].open()
        let kit = try MLKEM768X25519Identity()
        let xid = try XCTUnwrap(a.manifest.devices.first { $0.fingerprint == w["X"].keys.fingerprint }?.id)
        let bid = try XCTUnwrap(a.manifest.devices.first { $0.fingerprint == w["B"].keys.fingerprint }?.id)
        let prep = try a.prepareReencryption(kit, keep: [bid], remove: [xid])
        var seen: ReencryptCoordinator.ClaimSightings = [:]
        XCTAssertTrue(ReencryptCoordinator.claim(prep.journalFile, vault: a, on: [.init(name: "T1", remote: t1.remote(for: "A"))],
                                                 seen: &seen).values.allSatisfy(\.isClaimed))
        try a.beginReencryption(prep)
        var finished = false
        for _ in 0..<6 where !finished {
            try w["B"].sync(t1)
            finished = try Self.advance(w, home: "A", targets: [t1]).finished
        }
        XCTAssertTrue(finished)
        for _ in 0..<3 { try w["A"].sync(t1); try w["B"].sync(t1) }
        w.recovery = kit
        for (n, f) in [("T1", Self.files(t1)), ("A", Self.files(w["A"].folder)), ("B", Self.files(w["B"].folder))] {
            XCTAssertEqual(Self.openWithOld(files: f, old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 at \(n)")
        }
        XCTAssertEqual(try w["B"].titles(), titles)
    }

    /// Review of #89, N2 (the KH4 follow-up): junk set aside under a record's name and the right record fetched under it
    /// with the same size and modification time is hashed again by every target's run, also where the file system
    /// gives no file numbers (the cache key carries the set-aside's stamp).
    func testARecordHashCachedBeforeASetAsideIsNotReused() throws {
        for withoutNumbers in [false, true] {
            SyncEngine.fileNumbersUnavailable = withoutNumbers
            defer { SyncEngine.fileNumbersUnavailable = false }
            let w = try EpochSyncWorld(in: tmp.appendingPathComponent("n2-\(withoutNumbers)"), names: ["A"], targets: ["T1", "T2"])
            let d = w["A"]
            let name = "2-0123456789abcdef.epoch.age"
            let dir = d.folder.appendingPathComponent(Vault.epochsName)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            let junk = Data(repeating: 1, count: 64), right = Data(repeating: 2, count: 64)
            try junk.write(to: file)
            let stamp = Date(timeIntervalSince1970: 1_800_000_000)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            func engine(_ t: String) throws -> SyncEngine {
                try SyncEngine(directory: d.folder, vault: nil, remote: w.target(t).remote(for: "A"), stateURL: d.stateURL(w.target(t)),
                               options: SyncOptions(deviceLabel: "A"))
            }
            let t2 = try engine("T2")
            XCTAssertEqual(t2.localRecordHash(name), Hex.decode(FileDigest.sha256(junk)))
            // The run with T1 sets the junk aside; the right record arrives under the name, same size, same time.
            try engine("T1").setAsideWrongRecord(name)
            try right.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            XCTAssertEqual(t2.localRecordHash(name), Hex.decode(FileDigest.sha256(right)), "without file numbers: \(withoutNumbers)")
        }
    }

    /// Offline audit P17 (review of #89, S8): a home that only gets short connection windows. Each confirmation reads at
    /// most two files, and the memo is saved and loaded again between them (a new process each time): no file is read
    /// twice, and the target is confirmed after a few short runs, then the re-encryption finishes.
    func testAConfirmationGoesOnAcrossShortRunsAndProcesses() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        for i in 0..<5 { _ = try w["B"].write("B note \(i)") }
        let b = try w["B"].open()
        _ = try b.writeBlob(note: try w["B"].write("with a blob"), Data("blob bytes".utf8), type: "image/png")
        for _ in 0..<2 { try w["B"].sync(t1); try w["A"].sync(t1) }
        try Self.start(w, home: "A", targets: [t1])
        var a = try w["A"].open()
        _ = try a.reencryptPass()
        // B's runs put nothing current there: only confirm does (its replacements), so every file is read.
        try w["A"].sync(t1) { $0.pushOnly = true }
        a = try w["A"].open()
        let id = try XCTUnwrap(a.reencryptEpoch?.epochId)
        let memoURL = w["A"].root.appendingPathComponent("reencrypt-confirmed.json")
        let log = ReadLog()
        let remote = ListFailingRemote(base: t1.remote(for: "A"), failing: { _ in false }, reads: log)
        let scratch = w["A"].root.appendingPathComponent("confirm")
        var confirmed = false, runs = 0
        var readOnce: [String] = []
        var replaced = Set<String>()
        while !confirmed, runs < 20 {
            runs += 1
            var memo = ReencryptCoordinator.loadConfirmMemo(memoURL, epochId: id)   // a new process
            var m = memo["T1"] ?? [:]
            log.reset()
            let c = ReencryptCoordinator.confirm(vault: a, target: .init(name: "T1", remote: remote), memo: &m, scratch: scratch,
                                                 budget: .init(limit: 2))
            memo["T1"] = m
            ReencryptCoordinator.saveConfirmMemo(memo, epochId: id, to: memoURL)
            let files = log.paths.filter { $0.hasPrefix("notes/") || $0.hasPrefix("summaries/") }
            XCTAssertLessThanOrEqual(files.count, 2, "run \(runs): \(files)")
            readOnce += files
            replaced.formUnion(c.replaced)
            confirmed = c.confirmed
        }
        XCTAssertTrue(confirmed, "confirmed after \(runs) short runs")
        XCTAssertGreaterThan(runs, 2)
        // Only a copy confirm replaced itself is read once more (to see it current); nothing else twice.
        let twice = Dictionary(grouping: readOnce, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(Set(twice).isSubset(of: replaced), "read twice: \(twice.sorted())")
        XCTAssertTrue(Dictionary(grouping: readOnce, by: { $0 }).values.allSatisfy { $0.count <= 2 })
        var memo = ReencryptCoordinator.loadConfirmMemo(memoURL, epochId: id)
        let p = try ReencryptCoordinator.advance(&a, targets: [.init(name: "T1", remote: t1.remote(for: "A"))],
                                                 sync: { _ in try w["A"].sync(t1) }, memo: &memo, scratch: scratch)
        XCTAssertTrue(p.finished, "\(p.targets.map(\.waiting))")
    }

    /// P17: the memo is seeded from the target's sync state (the runs' own uploads and comparisons), so after a run
    /// that carried the pass's copies the confirmation reads only what that run did not vouch for.
    func testTheConfirmMemoIsSeededFromTheSyncState() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        for i in 0..<4 { _ = try w["B"].write("B note \(i)") }
        for _ in 0..<2 { try w["B"].sync(t1); try w["A"].sync(t1) }
        try Self.start(w, home: "A", targets: [t1])
        var a = try w["A"].open()
        _ = try a.reencryptPass()
        for _ in 0..<2 { try w["A"].sync(t1) }
        a = try w["A"].open()
        var seeded: [String: String] = [:]
        ReencryptCoordinator.seedConfirmMemo(&seeded, vault: a, stateURL: w["A"].stateURL(t1))
        XCTAssertGreaterThanOrEqual(seeded.count, 4, "\(seeded.keys.sorted())")
        let log = ReadLog()
        let remote = ListFailingRemote(base: t1.remote(for: "A"), failing: { _ in false }, reads: log)
        let c = ReencryptCoordinator.confirm(vault: a, target: .init(name: "T1", remote: remote), memo: &seeded,
                                             scratch: w["A"].root.appendingPathComponent("confirm"))
        XCTAssertTrue(c.confirmed, "\(c.waiting)")
        XCTAssertTrue(log.paths.filter { $0.hasPrefix("notes/") }.isEmpty, "nothing seeded read again: \(log.paths)")
    }

    /// Review of #89, S2: storage that changes the junk journal's bytes at every attempt does not restart the day: the
    /// first sighting on a target counts, whatever the bytes now, and once a day has passed the claim replaces it.
    func testChangingJunkJournalBytesDoesNotRestartTheDay() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        for _ in 0..<2 { try w["A"].sync(t1); try w["B"].sync(t1) }
        let a = try w["A"].open()
        let target = ReencryptCoordinator.Target(name: "T1", remote: t1.remote(for: "A"))
        var seen: ReencryptCoordinator.ClaimSightings = [:]
        let start = Date()
        let journal = Data("our journal bytes".utf8)
        for hour in [0, 6, 12, 18, 23] {
            t1.put(Vault.journalName, Data("junk \(hour)".utf8))
            let r = ReencryptCoordinator.claim(journal, vault: a, on: [target], seen: &seen, now: start + Double(hour) * 3600)
            XCTAssertEqual(r["T1"]?.isClaimed, false, "hour \(hour)")
        }
        t1.put(Vault.journalName, Data("junk 25".utf8))
        let late = ReencryptCoordinator.claim(journal, vault: a, on: [target], seen: &seen, now: start + 25 * 3600)
        XCTAssertEqual(late["T1"], .claimed, "a day after the first sighting, whatever the bytes")
        XCTAssertEqual(t1.file(Vault.journalName), journal)
        XCTAssertNil(seen["T1"], "forgotten once claimed")
    }

    /// Review of #89, S3: a transient error listing a note's `att/` keeps the target from being confirmed (and its
    /// earlier records from being deleted); the next confirmation, with the listing back, confirms it.
    func testAFailedAttachmentListingKeepsTheTargetWaiting() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        let b = try w["B"].open()
        let note = try w["B"].write("B one")
        _ = try b.writeBlob(note: note, Data("blob bytes".utf8), type: "image/png")
        for _ in 0..<2 { try w["B"].sync(t1); try w["A"].sync(t1) }
        try Self.start(w, home: "A", targets: [t1])
        var a = try w["A"].open()
        _ = try a.reencryptPass()
        for _ in 0..<2 { try w["A"].sync(t1); try w["B"].sync(t1) }
        a = try w["A"].open()
        let att = note.uuidString.lowercased()
        let failing = ListFailingRemote(base: t1.remote(for: "A")) { $0.count == 3 && $0[1] == att && $0[2] == Vault.attachmentsName }
        var memo: [String: String] = [:]
        let scratch = w["A"].root.appendingPathComponent("confirm")
        let cut = ReencryptCoordinator.confirm(vault: a, target: .init(name: "T1", remote: failing), memo: &memo, scratch: scratch)
        XCTAssertFalse(cut.confirmed, "\(cut)")
        XCTAssertNotNil(cut.waiting["notes/\(att)/att"])
        XCTAssertFalse(cut.deleted.contains { $0.hasPrefix(Vault.epochsName) }, "no earlier record deleted")
        memo = [:]
        let whole = ReencryptCoordinator.confirm(vault: a, target: .init(name: "T1", remote: t1.remote(for: "A")), memo: &memo, scratch: scratch)
        XCTAssertTrue(whole.confirmed, "\(whole.waiting)")
    }

    /// Review of #89, M1: a device offline for the whole re-encryption wrote a note; when it comes back after the finish,
    /// its first catch-up fails once (the ledger cannot append: a full disk). Its own write is never set aside or removed
    /// on that account (the scan and the removal wait for a ledger caught up), and the next runs carry it everywhere.
    func testAnOfflineWriteSurvivesAFailedFirstCatchUpAfterTheFinish() throws {
        let r = try offlineWriteAfterTheFinish(failing: true)
        XCTAssertFalse(r.removed, "D's own unsynced write is never removed from its working copy")
        XCTAssertTrue(r.everywhere, "and the next runs carry it everywhere")
    }

    /// The same without the failure (the control).
    func testAnOfflineWriteIsCaughtUpAfterTheFinish() throws {
        let r = try offlineWriteAfterTheFinish(failing: false)
        XCTAssertFalse(r.removed)
        XCTAssertTrue(r.everywhere)
    }

    /// The mutation `ledgerUnguarded` (the scan and the removal ignore the ledger) loses the write: the guard is what
    /// keeps it.
    func testWithoutTheLedgerGuardTheOfflineWriteIsLost() throws {
        Vault.epochMutations = [.ledgerUnguarded]
        defer { Vault.epochMutations = [] }
        let r = try offlineWriteAfterTheFinish(failing: true)
        XCTAssertTrue(r.removed && !r.everywhere, "\(r)")
    }

    /// D, offline for the whole re-encryption, wrote a note; after the finish its first run (whose ledger append fails
    /// when `failing`), then four rounds of A, B and D. Whether the first run removed D's file, and whether every device
    /// reads every note at the end.
    private func offlineWriteAfterTheFinish(failing: Bool) throws -> (removed: Bool, everywhere: Bool) {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "D"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["A"].write("A one")] = "A one"
        for n in ["A", "D", "B", "A", "D"] { try w[n].sync(t1) }
        let note = try w["D"].write("D offline")
        titles[note] = "D offline"
        let kit = try Self.start(w, home: "A", targets: [t1])
        var finished = false
        for _ in 0..<6 where !finished {
            try w["B"].sync(t1)
            finished = try Self.advance(w, home: "A", targets: [t1]).finished
        }
        XCTAssertTrue(finished)
        w.recovery = kit
        w["D"].ledger.failNextAppend = failing
        let first = try w["D"].sync(t1)
        let mine = note.uuidString.lowercased()
        // Removed, or still in place (unread until the catch-up succeeds: it is under a key from before the finish).
        let folder = w["D"].folder.appendingPathComponent("notes/\(mine)")
        let inPlace = !((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".delta.age") }.isEmpty
        let removed = first.deleted.contains { $0.side == "local" && $0.path.contains(mine) } || !inPlace
        for _ in 0..<4 { try w["D"].sync(t1); try w["A"].sync(t1); try w["B"].sync(t1) }
        let everywhere = try ["A", "B", "D"].allSatisfy { try w[$0].titles() == titles }
        return (removed, everywhere)
    }

    /// §7.2: a device offline for the whole re-encryption comes back after the finish (journal and earlier records
    /// gone everywhere): its copies are replaced by the current ones, its own write from the offline time is caught
    /// up from its ledger, and its working copy then holds nothing under an earlier key.
    func testAnOfflineDeviceReturnsAfterTheFinish() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "D"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["A"].write("A one")] = "A one"
        titles[try w["D"].write("D one")] = "D one"
        for n in ["A", "D", "B", "A", "D"] { try w[n].sync(t1) }
        let old = try Self.keysSoFar(w, w["A"])
        let oldKeys = try Self.epochKeysSoFar(w["A"])
        // D goes offline and writes there.
        titles[try w["D"].write("D offline")] = "D offline"
        let kit = try Self.start(w, home: "A", targets: [t1])
        var finished = false
        for _ in 0..<6 where !finished {
            try w["B"].sync(t1)
            finished = try Self.advance(w, home: "A", targets: [t1]).finished
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 on the target before D is back")
        w.recovery = kit
        for _ in 0..<4 { try w["D"].sync(t1); try w["A"].sync(t1); try w["B"].sync(t1) }
        for n in ["A", "B", "D"] {
            XCTAssertEqual(try w[n].titles(), titles, n)
            XCTAssertEqual(Self.openWithOld(files: Self.files(w[n].folder), old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 at \(n)")
        }
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 on the target")
    }

    /// Claims: a target holding another journal refuses the start, the claims made are released, and the abandoned
    /// start leaves the vault as it was; a day later the leftover is replaced.
    func testAClaimRefusedByAnotherJournalAbortsTheStart() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        try w["A"].sync(t2)
        t2.put(Vault.journalName, Data("someone else's claim".utf8))
        var a = try w["A"].open()
        let prep = try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id], remove: [])
        var seen: ReencryptCoordinator.ClaimSightings = [:]
        let targets: [ReencryptCoordinator.Target] = [.init(name: "T1", remote: t1.remote(for: "A")), .init(name: "T2", remote: t2.remote(for: "A"))]
        let now = Date()
        let claims = ReencryptCoordinator.claim(prep.journalFile, vault: a, on: targets, seen: &seen, now: now)
        XCTAssertEqual(claims["T1"], .claimed)
        guard case .refused = claims["T2"] else { return XCTFail("\(claims)") }
        XCTAssertEqual(ReencryptCoordinator.release(prep.journalFile, on: targets), ["T1"])
        XCTAssertEqual(try a.abandonReencryptionStart(), prep.journalFile)
        XCTAssertNil(t1.file(Vault.journalName))
        XCTAssertFalse(try w["A"].open().isReencryptPending)
        // A run never uploads, takes or deletes an unbound journal.
        try w["A"].sync(t2); try w["B"].sync(t2)
        XCTAssertEqual(t2.file(Vault.journalName), Data("someone else's claim".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w["B"].folder.appendingPathComponent(Vault.journalName).path))
        // A day later, the leftover is replaced.
        a = try w["A"].open()
        let again = try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id], remove: [])
        let later = ReencryptCoordinator.claim(again.journalFile, vault: a, on: targets, seen: &seen, now: now.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(later.values.allSatisfy(\.isClaimed), "\(later)")
        try a.beginReencryption(again)
    }

    /// Storage withholds the journal: a device that took the epoch reads its earlier files as pending (never set aside
    /// or replaced) until a run of home puts the journal back; the vault.json binding it never goes to a target without it.
    func testAWithheldJournalComesBackAndHoldsNothingAside() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["B"].write("B one")] = "B one"
        try w["B"].sync(t1); try w["A"].sync(t1)
        try Self.start(w, home: "A", targets: [t1])
        try w["A"].sync(t1)
        t1.remove(Vault.journalName)
        let r = try w["B"].sync(t1)
        XCTAssertEqual(try w["B"].open().manifest.epoch, 2, "\(r)")
        XCTAssertTrue(r.setAside.isEmpty, "\(r.setAside)")
        XCTAssertTrue(w["B"].setAside.items(vaultId: w.vaultId).isEmpty)
        // Home's next run puts it back; B takes it and reads everything.
        try w["A"].sync(t1)
        XCTAssertNotNil(t1.file(Vault.journalName))
        try w["B"].sync(t1)
        XCTAssertTrue(try w["B"].open().localBoundJournal() != nil)
        XCTAssertEqual(try w["B"].titles(), titles)
    }

    /// §7.2 "Resume … on a later home": home hands over during the pass, and the new home finishes it.
    func testANewHomeFinishesTheReencryption() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["A"].write("A one")] = "A one"
        titles[try w["B"].write("B one")] = "B one"
        try w["A"].sync(t1); try w["B"].sync(t1); try w["A"].sync(t1)
        let old = try Self.keysSoFar(w, w["A"])
        let oldKeys = try Self.epochKeysSoFar(w["A"])
        let kit = try Self.start(w, home: "A", targets: [t1])
        var a = try w["A"].open()
        _ = try a.reencryptPass(limit: 1)
        try a.handOff(to: w["B"].id)
        try w["A"].sync(t1)
        try w["B"].sync(t1)
        XCTAssertTrue(try w["B"].open().isHome)
        var finished = false
        for _ in 0..<6 where !finished {
            try w["A"].sync(t1)
            finished = try Self.advance(w, home: "B", targets: [t1]).finished
        }
        XCTAssertTrue(finished)
        for _ in 0..<2 { try w["A"].sync(t1); try w["B"].sync(t1) }
        w.recovery = kit
        for n in ["A", "B"] {
            XCTAssertEqual(try w[n].titles(), titles, n)
            XCTAssertEqual(Self.openWithOld(files: Self.files(w[n].folder), old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 at \(n)")
        }
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old, oldKeys: oldKeys, vaultId: w.vaultId), [])
    }

    /// §7.2 "a re-encryption that meets a takeover": a takeover above it (by a device that pinned it, under the new kit)
    /// keeps it, bound, and its new home finishes it.
    /// §11.1, §7.2 (review of #89, S9): a takeover from the epoch before the re-encryption, by the kit from before it.
    /// On the device that took over (pinned before the re-encryption) the re-encryption is dropped: nothing is pending
    /// and its notes read. Home, which pinned the re-encryption (and so its new kit), refuses a takeover by the old kit
    /// and keeps it. The dropped journal on the target holds the new home's own claim off for a day (N3).
    func testATakeoverBelowTheReencryptionDropsItWhereItWasNotPinned() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["A"].write("A one")] = "A one"
        titles[try w["B"].write("B one")] = "B one"
        try w["A"].sync(t1); try w["B"].sync(t1); try w["A"].sync(t1); try w["B"].sync(t1)
        let oldKit = w.recovery
        try Self.start(w, home: "A", targets: [t1])
        try w["A"].sync(t1)
        let before = try w["A"].open().manifest.epochId
        // B never saw it: it takes over from the epoch below with the kit from before.
        let (taken, _) = try Vault.takeover(at: w["B"].folder, device: w["B"].keys, recovery: oldKit, keep: [w["A"].fingerprint],
                                            trust: w["B"].trust, root: w.root, ledger: w["B"].ledger, setAside: w["B"].setAside)
        XCTAssertFalse(taken.isReencryptPending)
        for _ in 0..<4 { try w["B"].sync(t1); try w["A"].sync(t1) }
        let a = try w["A"].open(), b = try w["B"].open()
        XCTAssertEqual(b.manifest.epochId, taken.manifest.epochId, "B keeps its takeover")
        XCTAssertFalse(b.isReencryptPending)
        XCTAssertNil(b.reencryptEpoch, "the re-encryption is not on B's chain")
        XCTAssertEqual(try w["B"].titles(), titles)
        XCTAssertEqual(a.manifest.epochId, before, "A refuses a takeover by the kit its re-encryption replaced")
        XCTAssertTrue(a.isReencryptPending)
        // B's own re-encryption: the dropped journal on the target holds its claim off for a day.
        var bv = b
        let prep = try bv.prepareReencryption(try MLKEM768X25519Identity(), keep: [], remove: [try XCTUnwrap(a.deviceEntry?.id)])
        let target = ReencryptCoordinator.Target(name: "T1", remote: t1.remote(for: "B"))
        var seen: ReencryptCoordinator.ClaimSightings = [:]
        let now = Date()
        XCTAssertEqual(ReencryptCoordinator.claim(prep.journalFile, vault: bv, on: [target], seen: &seen, now: now)["T1"]?.isClaimed, false)
        XCTAssertEqual(ReencryptCoordinator.claim(prep.journalFile, vault: bv, on: [target], seen: &seen, now: now + 25 * 3600)["T1"], .claimed)
        try bv.beginReencryption(prep)
        XCTAssertTrue(bv.isReencryptPending)
    }

    func testATakeoverAboveTheReencryptionKeepsItAndItsNewHomeFinishesIt() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"], targets: ["T1"])
        let t1 = w.target("T1")
        var titles: [UUID: String] = [:]
        titles[try w["A"].write("A one")] = "A one"
        titles[try w["B"].write("B one")] = "B one"
        try w["A"].sync(t1); try w["B"].sync(t1); try w["A"].sync(t1)
        let old = try Self.keysSoFar(w, w["A"])
        let oldKeys = try Self.epochKeysSoFar(w["A"])
        let kit = try Self.start(w, home: "A", targets: [t1])
        try w["A"].sync(t1); try w["B"].sync(t1)
        XCTAssertTrue(try w["B"].open().isReencryptPending)
        let (taken, _) = try Vault.takeover(at: w["B"].folder, device: w["B"].keys, recovery: kit, keep: [w["A"].fingerprint],
                                            trust: w["B"].trust, root: w.root, ledger: w["B"].ledger, setAside: w["B"].setAside)
        XCTAssertTrue(taken.isReencryptPending, "the takeover keeps the re-encryption bound")
        XCTAssertNotNil(taken.localBoundJournal())
        var finished = false
        for _ in 0..<6 where !finished {
            try w["A"].sync(t1)
            finished = try Self.advance(w, home: "B", targets: [t1]).finished
        }
        XCTAssertTrue(finished)
        for _ in 0..<2 { try w["A"].sync(t1); try w["B"].sync(t1) }
        w.recovery = kit
        for n in ["A", "B"] {
            XCTAssertEqual(try w[n].titles(), titles, n)
            XCTAssertEqual(Self.openWithOld(files: Self.files(w[n].folder), old, oldKeys: oldKeys, vaultId: w.vaultId), [], "J7 at \(n)")
        }
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old, oldKeys: oldKeys, vaultId: w.vaultId), [])
    }
}

/// Paths of every regular file below a folder (relative), hidden ones left out.
enum SyncFilesList {
    static func all(in url: URL) -> [String] {
        var out: [String] = []
        let base = url.standardizedFileURL.path
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let f = e?.nextObject() as? URL {
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(String(f.standardizedFileURL.path.dropFirst(base.count + 1)))
            }
        }
        return out.sorted()
    }
}
