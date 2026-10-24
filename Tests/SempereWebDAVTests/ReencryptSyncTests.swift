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

    /// J7: the files of a working copy or target that open with one of `old` (and wraps in `vault.json`).
    static func openWithOld(files: [String: Data], _ old: [any AgeIdentity]) -> [String] {
        var out: [String] = []
        for (p, data) in files.sorted(by: { $0.key < $1.key }) {
            if p == Vault.manifestName {
                guard let m = try? EpochManifest.parse(data) else { continue }
                for k in m.keys where old.contains(where: { (try? AgeFile.decrypt(Data(k.wrap.utf8), with: [$0])) != nil }) {
                    out.append("vault.json \(k.role)")
                }
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
        XCTAssertFalse(Self.openWithOld(files: Self.files(t1), old).isEmpty)

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
            XCTAssertEqual(Self.openWithOld(files: f, old), [], "J7 at \(n)")
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
        // D goes offline and writes there.
        titles[try w["D"].write("D offline")] = "D offline"
        let kit = try Self.start(w, home: "A", targets: [t1])
        var finished = false
        for _ in 0..<6 where !finished {
            try w["B"].sync(t1)
            finished = try Self.advance(w, home: "A", targets: [t1]).finished
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old), [], "J7 on the target before D is back")
        w.recovery = kit
        for _ in 0..<4 { try w["D"].sync(t1); try w["A"].sync(t1); try w["B"].sync(t1) }
        for n in ["A", "B", "D"] {
            XCTAssertEqual(try w[n].titles(), titles, n)
            XCTAssertEqual(Self.openWithOld(files: Self.files(w[n].folder), old), [], "J7 at \(n)")
        }
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old), [], "J7 on the target")
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
            XCTAssertEqual(Self.openWithOld(files: Self.files(w[n].folder), old), [], "J7 at \(n)")
        }
        XCTAssertEqual(Self.openWithOld(files: Self.files(t1), old), [])
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
