import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The scenarios of key-hierarchy design §11.1 that need sync (phase KH4), over in-memory targets: device
/// changes reach every target through ordinary runs (records first, `vault.json` judged by the chain and the
/// precedence rule), unverified-pending holds uploads back (J5b), unlisted devices keep pulling, takeovers win
/// over sync, an accepted copy replaces an unaccepted one, `joins/` and `keys/` follow their rules.
final class EpochSyncScenarioTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    // MARK: - A removal reaches every target

    func testRemovalPropagatesThroughABridgeAndTheRemovedDeviceIsUnlisted() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C", "X"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        // C syncs only with T2, through B (which syncs both).
        try w["B"].sync(t2)
        try w["C"].sync(t2)
        let a1 = try w["A"].write("A one")
        let x1 = try w["X"].write("X before")
        try w["A"].sync(t1); try w["X"].sync(t1)
        try w["B"].sync(t1); try w["B"].sync(t2); try w["C"].sync(t2)
        XCTAssertEqual(try w["C"].titles()[x1], "X before")

        // Home removes X, after pulling what it can reach (design §5.2 step 2): X's file is sealed.
        var a = try w["A"].open()
        let pulled = EpochChangePull.run(vault: a, folder: w["A"].folder,
                                         targets: [.init(name: "T1", remote: t1.remote(for: "A"))],
                                         scratch: w["A"].root.appendingPathComponent("pull"))
        XCTAssertTrue(pulled.allSatisfy(\.reached), "\(pulled.map(\.error))")
        a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        XCTAssertEqual(a.manifest.epoch, 2)
        let up = try w["A"].sync(t1)
        XCTAssertTrue(up.uploaded.contains { $0.hasPrefix("epochs/2-") }, "the record goes to the target: \(up.uploaded)")
        XCTAssertTrue(up.uploaded.contains(Vault.manifestName))

        // B takes it on T1 and carries it to T2; C takes it there.
        let b1 = try w["B"].sync(t1)
        XCTAssertEqual(b1.epoch?.taken, 2, "\(b1)")
        XCTAssertEqual(try w["B"].open().manifest.epoch, 2)
        let b2 = try w["B"].sync(t2)
        XCTAssertTrue(b2.uploaded.contains(Vault.manifestName), "\(b2.uploaded)")
        XCTAssertTrue(b2.uploaded.contains { $0.hasPrefix("epochs/2-") })
        let c = try w["C"].sync(t2)
        XCTAssertEqual(c.epoch?.taken, 2, "\(c)")
        XCTAssertEqual(try w["C"].open().manifest.epoch, 2)

        // Writes after the change are under the new key and reach everyone listed.
        let c2 = try w["C"].write("C after")
        try w["C"].sync(t2); try w["B"].sync(t2); try w["B"].sync(t1); try w["A"].sync(t1)
        XCTAssertEqual(try w["A"].titles()[c2], "C after")
        XCTAssertEqual(try w["A"].titles()[a1], "A one")
        XCTAssertEqual(try w["C"].titles()[x1], "X before", "sealed: X's file from before stays")

        // X: the change does not list it. It uploads nothing, keeps its data readable, writes nothing.
        let xAfter = try w["X"].sync(t1)
        XCTAssertNotNil(xAfter.epoch?.unlisted, "\(xAfter)")
        XCTAssertTrue(xAfter.uploaded.isEmpty, "\(xAfter.uploaded)")
        XCTAssertThrowsError(try w["X"].write("X after")) { e in
            guard case VaultError.removedFromVault = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(try w["X"].titles()[x1], "X before", "its own copy stays readable")
    }

    // MARK: - vault.json before its record

    /// The epoch records under `epochs/` on `target` (names).
    private func records(_ target: EpochTarget) -> [String] {
        target.paths.filter { $0.hasPrefix("epochs/") }.map { String($0.dropFirst("epochs/".count)) }.sorted()
    }

    func testADirectChildWhoseRecordIsWithheldIsTakenAndOlderFilesWaitForIt() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        let b0 = try w["B"].write("B before")
        try w["B"].sync(t1); try w["A"].sync(t1)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        // The target loses the new record (withheld): only vault.json of epoch 2 is there.
        let name = try XCTUnwrap(records(t1).first { $0.hasPrefix("2-") })
        t1.store.removeDirect([Vault.epochsName, name])

        let r = try w["B"].sync(t1)
        XCTAssertEqual(r.epoch?.taken, 2, "a direct child of the pinned epoch is taken: \(r)")
        XCTAssertEqual(r.epoch?.recordPending, true)
        let b = try w["B"].open()
        XCTAssertTrue(b.isRecordPending)
        XCTAssertNil(try w["B"].titles()[b0], "under the older key: pending until the record arrives")
        // Writes go under the new key meanwhile, and are uploaded (the change is verified).
        let b1 = try w["B"].write("B under epoch 2")
        let up = try w["B"].sync(t1)
        XCTAssertTrue(up.uploaded.contains { $0.contains(b1.uuidString.lowercased()) }, "\(up.uploaded)")

        // The record comes back (home pushes what the target lacks): B pins the epoch and reads everything.
        let again = try w["A"].sync(t1)
        XCTAssertTrue(again.uploaded.contains("epochs/\(name)"), "\(again.uploaded)")
        try w["B"].sync(t1)
        XCTAssertFalse(try w["B"].open().isRecordPending)
        XCTAssertEqual(try w["B"].trust.record(for: w.vaultId)?.pinned?.epoch, 2)
        XCTAssertEqual(try w["B"].titles()[b0], "B before")
        XCTAssertEqual(try w["A"].titles()[b1], "B under epoch 2")
    }

    func testTwoEpochsAboveWithoutRecordsWaitAndUploadNothing() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X", "Y"])
        let t1 = w.target("T1")
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try a.removeDevices([w["Y"].id])
        try w["A"].sync(t1)
        for r in records(t1) where !r.hasPrefix("1-") { t1.store.removeDirect([Vault.epochsName, r]) }

        // B (pinned at epoch 1) cannot verify epoch 3: it keeps its own, writes locally, uploads nothing (J5b).
        let note = try w["B"].write("written while waiting")
        let r = try w["B"].sync(t1)
        XCTAssertNotNil(r.epoch?.waiting, "\(r)")
        XCTAssertTrue(r.epoch?.waiting?.contains("memory") == true || r.epoch?.waiting?.isEmpty == false)
        XCTAssertTrue(r.uploaded.isEmpty, "\(r.uploaded)")
        XCTAssertEqual(try w["B"].open().manifest.epoch, 1)
        // Remembered as a detached sighting (epoch 3's parent was never pinned here): it holds runs on T1, which
        // shows it, run after run; not the open, and not a target that never showed it (review of #86, M3).
        XCTAssertEqual(try w["B"].open().sightings().map(\.epoch), [3])
        XCTAssertNil(try w["B"].open().waitingNotice)
        XCTAssertNoThrow(try w["B"].write("still writes locally"))
        let still = try w["B"].sync(t1)
        XCTAssertNotNil(still.epoch?.waiting)
        XCTAssertTrue(still.uploaded.allSatisfy { $0.hasPrefix("epochs/") }, "\(still.uploaded)")

        // The records come back: B verifies epoch 3, catches up its own file and uploads it.
        try w["A"].sync(t1)
        let taken = try w["B"].sync(t1)
        XCTAssertEqual(taken.epoch?.taken, 3, "\(taken)")
        XCTAssertNil(try w["B"].open().waitingNotice)
        let after = try w["B"].sync(t1)
        let pulled = try w["A"].sync(t1)
        XCTAssertEqual(try w["A"].titles()[note], "written while waiting", "\(taken)\n\(after)\n\(pulled)")
    }

    func testAWithheldRecordIsUploadedAgainByAnotherDeviceToEveryTarget() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        try w["B"].sync(t1)
        let name = try XCTUnwrap(records(t1).first { $0.hasPrefix("2-") })
        t1.store.removeDirect([Vault.epochsName, name])
        let again = try w["B"].sync(t1)
        XCTAssertTrue(again.uploaded.contains("epochs/\(name)"), "B pushes the record T1 lost: \(again.uploaded)")
        let other = try w["B"].sync(t2)
        XCTAssertTrue(other.uploaded.contains("epochs/\(name)"), "and to every target it syncs: \(other.uploaded)")
        XCTAssertTrue(records(t2).contains(name))
    }

    // MARK: - Home and takeover over sync (design §5.6)

    /// `device` takes over the vault in its working copy with the kit, keeping `keep` (device names).
    @discardableResult
    private func takeOver(_ w: EpochSyncWorld, _ device: EpochSyncDevice, keep: [String]) throws -> EpochChangeReport {
        let fps = Set(keep.map { w[$0].fingerprint })
        return try Vault.takeover(at: device.folder, device: device.keys, recovery: w.recovery, keep: fps, trust: device.trust,
                                  root: w.root, ledger: device.ledger, setAside: device.setAside).report
    }

    func testStolenHomeRemovesCWhichIsUnlistedUntilTheOwnersTakeoverReadmitsIt() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C"])
        let t1 = w.target("T1")
        let c0 = try w["C"].write("C before")
        try w["C"].sync(t1); try w["A"].sync(t1); try w["B"].sync(t1)
        // A is stolen; the thief removes C.
        var thief = try w["A"].open()
        try thief.removeDevices([w["C"].id])
        try w["A"].sync(t1)
        let cs = try w["C"].sync(t1)
        XCTAssertNotNil(cs.epoch?.unlisted, "\(cs)")
        XCTAssertTrue(cs.uploaded.isEmpty)
        XCTAssertThrowsError(try w["C"].write("refused")) { e in
            guard case VaultError.removedFromVault = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(try w["C"].titles()[c0], "C before")
        try w["B"].sync(t1)

        // The owner takes over on B with the kit, re-admitting C and leaving A out.
        let report = try takeOver(w, w["B"], keep: ["C"])
        XCTAssertEqual(report.reason, .takeover)
        let push = try w["B"].sync(t1)
        XCTAssertTrue(push.uploaded.contains(Vault.manifestName), "\(push.uploaded)")
        // C takes it and resumes: it writes and uploads again.
        let back = try w["C"].sync(t1)
        XCTAssertEqual(back.epoch?.taken, 3, "\(back)")
        XCTAssertNil(try w["C"].open().unlistedNotice)
        let c1 = try w["C"].write("C after the takeover")
        try w["C"].sync(t1); try w["B"].sync(t1)
        XCTAssertEqual(try w["B"].titles()[c1], "C after the takeover")
        // The stolen home is not on the takeover's list: unlisted, uploads nothing.
        let a = try w["A"].sync(t1)
        XCTAssertNotNil(a.epoch?.unlisted, "\(a)")
        XCTAssertTrue(a.uploaded.isEmpty)
    }

    func testATakeoverFromBelowBeatsTheStolenHomesLaterEpochsOnEveryDevice() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "D", "E", "F"])
        let t1 = w.target("T1")
        for n in ["A", "B", "D", "E", "F"] { try w[n].sync(t1) }
        // B goes offline at epoch 1. The thief, holding home A, removes D and then F.
        var thief = try w["A"].open()
        try thief.removeDevices([w["D"].id])
        try thief.removeDevices([w["F"].id])
        try w["A"].sync(t1)
        try w["E"].sync(t1)
        XCTAssertEqual(try w["E"].open().manifest.epoch, 3)
        let e3 = try w["E"].write("E at the thief's epoch 3")
        try w["E"].sync(t1)

        // B takes over from its pinned epoch 1, keeping D and E: a takeover at epoch 2 with another id.
        try takeOver(w, w["B"], keep: ["D", "E"])
        XCTAssertEqual(try w["B"].open().manifest.epoch, 2)
        let push = try w["B"].sync(t1)
        XCTAssertTrue(push.uploaded.contains(Vault.manifestName), "B's chain is the later one: \(push)")
        // E follows the takeover although its number is lower, and its own file of the dropped epoch comes back.
        let e = try w["E"].sync(t1)
        XCTAssertEqual(e.epoch?.taken, 2, "\(e)")
        XCTAssertEqual(try w["E"].open().manifest.epochId, try w["B"].open().manifest.epochId)
        try w["E"].sync(t1)
        try w["B"].sync(t1); try w["B"].sync(t1)
        XCTAssertEqual(try w["B"].titles()[e3], "E at the thief's epoch 3")
        XCTAssertNotNil(try w["A"].sync(t1).epoch?.unlisted)
        XCTAssertEqual(try w["D"].sync(t1).epoch?.taken, 2, "D, removed by the thief, is back")
    }

    func testTwoTakeoversSettleOnTheSmallerIdSilently() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C"])
        let t1 = w.target("T1")
        for n in ["A", "B", "C"] { try w[n].sync(t1) }
        try takeOver(w, w["B"], keep: ["C"])
        try takeOver(w, w["C"], keep: ["B"])
        let ids = [try w["B"].open().manifest.epochId, try w["C"].open().manifest.epochId]
        let winner = try XCTUnwrap(ids.min { $0.lexicographicallyPrecedes($1) })
        for _ in 0..<3 { try w["B"].sync(t1); try w["C"].sync(t1) }
        XCTAssertEqual(try w["B"].open().manifest.epochId, winner)
        XCTAssertEqual(try w["C"].open().manifest.epochId, winner)
        XCTAssertNil(try w["B"].sync(t1).epoch?.conflict, "no question, no conflict")
    }

    // MARK: - An accepted copy replaces an unaccepted one (design §5.4 step 4)

    /// D writes while it reaches only T2; B bridges T1 and T2; home A, on T1, removes X after a pull that
    /// cannot reach T2, so D's file is not sealed. Returns the world and D's note.
    private func unsealedOnTwoTargets(_ t2Server: MockDAV? = nil) throws -> (EpochSyncWorld, UUID) {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "D", "X"], targets: ["T1", "T2"])
        let t1 = w.target("T1"), t2 = w.target("T2")
        if let t2Server {
            let client = try client(t2Server)
            t2.reach = { _ in WebDAVSyncRemote(client) }
        }
        try w["B"].sync(t2); try w["D"].sync(t2)
        let nd = try w["D"].write("D, offline from T1")
        try w["D"].sync(t2)
        try w["B"].sync(t2)
        XCTAssertEqual(try w["B"].titles()[nd], "D, offline from T1")
        t2.reachable = false
        var a = try w["A"].open()
        let pulled = EpochChangePull.run(vault: a, folder: w["A"].folder,
                                         targets: [.init(name: "T1", remote: t1.remote(for: "A")),
                                                   .init(name: "T2", remote: t2.remote(for: "A"))],
                                         scratch: w["A"].root.appendingPathComponent("pull"))
        XCTAssertEqual(pulled.map(\.reached), [true, false], "T2 is not reachable: reported, not waited for")
        XCTAssertNotNil(pulled[1].error)
        t2.reachable = true
        a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        return (w, nd)
    }

    func testTheWritersCatchUpReplacesTheUnsealedCopyOnTheTargetAndOnEveryDevice() throws {
        let (w, nd) = try unsealedOnTwoTargets()
        let t1 = w.target("T1"), t2 = w.target("T2")
        let path = "notes/\(nd.uuidString.lowercased())/"
        let file = try XCTUnwrap(t2.paths.first { $0.hasPrefix(path) })
        let old = try XCTUnwrap(t2.file(file))
        XCTAssertNotNil(old)

        // B takes the change: D's file under the old key is set aside on B (kept in place, never uploaded).
        let b1 = try w["B"].sync(t1)
        XCTAssertEqual(b1.epoch?.taken, 2)
        XCTAssertNil(try w["B"].titles()[nd], "not sealed: set aside until its writer catches up")
        XCTAssertFalse(b1.uploaded.contains(file), "a file set aside is never uploaded")
        let asideBefore = w["B"].setAside.items(vaultId: w.vaultId).map { "\($0.path):\($0.sha256)" }
        XCTAssertTrue(asideBefore.contains("\(file):\(FileDigest.sha256(old))"))
        try w["B"].sync(t2)

        // D takes it on T2, re-encrypts its own file and replaces the target's copy (set aside on D first).
        let d = try w["D"].sync(t2)
        XCTAssertEqual(d.epoch?.taken, 2, "\(d)")
        XCTAssertTrue(d.replaced.contains(.init(side: "remote", path: file)), "\(d)")
        XCTAssertNotEqual(t2.file(file), old)
        XCTAssertTrue(w["D"].setAside.items(vaultId: w.vaultId).contains { $0.path == file && $0.sha256 == FileDigest.sha256(old) })

        // B: the accepted copy replaces its unaccepted one (already set aside: J6), and it reaches T1 and A.
        let b2 = try w["B"].sync(t2)
        XCTAssertTrue(b2.replaced.contains(.init(side: "local", path: file)), "\(b2)")
        XCTAssertEqual(try w["B"].titles()[nd], "D, offline from T1")
        let asideAfter = Set(w["B"].setAside.items(vaultId: w.vaultId).map { "\($0.path):\($0.sha256)" })
        XCTAssertTrue(Set(asideBefore).isSubset(of: asideAfter), "J6: nothing leaves the set-aside store")
        try w["B"].sync(t1)
        try w["A"].sync(t1)
        XCTAssertEqual(try w["A"].titles()[nd], "D, offline from T1")
        // Quiet afterwards: nothing is compared or replaced again.
        XCTAssertTrue(try w["D"].sync(t2).replaced.isEmpty)
        XCTAssertTrue(try w["B"].sync(t2).replaced.isEmpty)
    }

    func testASetAsideStoreThatCannotKeepACopyStopsTheReplacement() throws {
        let (w, nd) = try unsealedOnTwoTargets()
        let t1 = w.target("T1"), t2 = w.target("T2")
        let path = "notes/\(nd.uuidString.lowercased())/"
        let file = try XCTUnwrap(t2.paths.first { $0.hasPrefix(path) })
        let local = w["B"].folder.appendingPathComponent(file)
        let old = try Data(contentsOf: local)
        // B's set-aside store cannot be written (a full disk, a permission).
        let store = w["B"].setAside.directory
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        let b1 = try w["B"].sync(t1)
        XCTAssertEqual(b1.epoch?.taken, 2)
        try w["B"].sync(t2)
        try w["D"].sync(t2)
        try w["B"].sync(t2)
        XCTAssertEqual(try Data(contentsOf: local), old, "never replaced without its copy kept aside first")
        XCTAssertNil(try w["B"].titles()[nd])
        // Writable again: the next write catches up (sets it aside), and the next run replaces it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        try w["B"].write("B again")
        let b3 = try w["B"].sync(t2)
        XCTAssertTrue(b3.replaced.contains(.init(side: "local", path: file)), "\(b3)")
        XCTAssertEqual(try w["B"].titles()[nd], "D, offline from T1")
    }

    func testATargetWithoutStrongVersionTagsKeepsItsCopyAndSaysSo() throws {
        let server = MockDAV()
        server.weakFileETags = true
        let (w, nd) = try unsealedOnTwoTargets(server)
        try w["B"].sync(w.target("T1"))
        try w["B"].sync(w.target("T2"))
        let dir = w["D"].folder.appendingPathComponent("notes/\(nd.uuidString.lowercased())")
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { RevisionName($0) != nil })
        let path = "notes/\(nd.uuidString.lowercased())/\(name)"
        let before = try XCTUnwrap(server.file(path))
        let d = try w["D"].sync(w.target("T2"))
        XCTAssertEqual(d.epoch?.taken, 2)
        XCTAssertTrue(d.replaced.isEmpty, "never replaced without a strong version tag: \(d)")
        XCTAssertTrue(d.skipped.contains { $0.message.contains("strong version tag") }, "\(d.skipped)")
        XCTAssertEqual(server.file(path), before)
    }

    // MARK: - A removed device that writes anyway (J3)

    func testFilesARemovedDeviceUploadsAfterItsRemovalAreSetAsideEverywhereNeverPlaced() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        try w["X"].sync(t1); try w["A"].sync(t1)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        try w["B"].sync(t1)
        // X has not seen its removal; modified software uploads what it writes anyway.
        let planted = try w["X"].write("planted after removal")
        let folder = w["X"].folder.appendingPathComponent("notes/\(planted.uuidString.lowercased())")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            t1.store.putDirect(["notes", planted.uuidString.lowercased(), name], try Data(contentsOf: folder.appendingPathComponent(name)))
        }
        let b = try w["B"].sync(t1)
        XCTAssertFalse(b.setAside.isEmpty, "\(b)")
        XCTAssertTrue(b.quarantined.isEmpty, "set aside, not quarantined: \(b.quarantined)")
        XCTAssertNil(try w["B"].titles()[planted])
        XCTAssertTrue(w["B"].setAside.items(vaultId: w.vaultId).contains { $0.path.hasPrefix("notes/\(planted.uuidString.lowercased())/") })
        let again = try w["B"].sync(t1)
        XCTAssertTrue(again.setAside.isEmpty && again.downloaded.isEmpty, "not fetched again while unchanged: \(again)")
        XCTAssertNil(try w["A"].titles()[planted])
    }

    // MARK: - joins/

    func testAJoinRequestReachesHomeThroughATargetAndIsDeletedEverywhereOnceApproved() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli")
        let up = try n.syncLocked(t1)
        XCTAssertTrue(up.uploaded.contains("joins/\(request.fileName)"), "\(up)")
        try w["A"].sync(t1)
        var a = try w["A"].open()
        let found = try XCTUnwrap(a.joinRequests().first { $0.name == request.fileName }?.request)
        let words = try a.approveDevice(found)
        let home = try w["A"].sync(t1)
        XCTAssertTrue(home.deleted.contains(.init(side: "remote", path: "joins/\(request.fileName)")), "\(home)")
        XCTAssertFalse(t1.paths.contains("joins/\(request.fileName)"))
        // N: its request is gone from the target, so from its copy too; with its key it takes the approval.
        try n.syncLocked(t1) { $0.firstPullIdentities = [n.identity] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: n.folder.appendingPathComponent("joins/\(request.fileName)").path))
        try n.sync(t1)
        var nv = try n.open()
        try nv.confirmJoin(words: words)
        XCTAssertNoThrow(try n.write("N joined"))
        XCTAssertTrue(try n.sync(t1).uploaded.contains { $0.hasPrefix("notes/") })
    }

    func testHomeDeletesStaleRequestsAndThoseOfListedKeys() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        let old = EpochSyncDevice("Old", root: tmp)
        try old.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: old.folder, device: old.keys, name: "Old", kind: "cli",
                                                 created: Date().addingTimeInterval(-8 * 86_400))
        try old.syncLocked(t1)
        try w["A"].sync(t1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w["A"].folder.appendingPathComponent("joins/\(request.fileName)").path)
                      || !t1.paths.contains("joins/\(request.fileName)"))
        try w["A"].sync(t1)
        XCTAssertFalse(t1.paths.contains("joins/\(request.fileName)"), "older than 7 days: deleted by home")
        // B (not home) never deletes a request on its own.
        let fresh = EpochSyncDevice("Fresh", root: tmp)
        try fresh.syncLocked(t1)
        let r2 = try Vault.writeJoinRequest(at: fresh.folder, device: fresh.keys, name: "Fresh", kind: "cli")
        try fresh.syncLocked(t1)
        try w["B"].sync(t1); try w["B"].sync(t1)
        XCTAssertTrue(t1.paths.contains("joins/\(r2.fileName)"))
    }

    // MARK: - keys/ (design §8.2)

    func testASupersededPassphraseCopyIsDeletedFromTargetsAndNeverComesBack() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "C"])
        let t1 = w.target("T1")
        for n in ["A", "B", "C"] { try w[n].sync(t1) }
        let oldCopy = try XCTUnwrap(t1.paths.first { $0.hasPrefix("keys/recovery-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: w["B"].folder.appendingPathComponent(oldCopy).path),
                      "the copy reaches every device")
        var a = try w["A"].open()
        try a.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: [w["B"].id, w["C"].id], remove: [],
                                 passphrase: "another long passphrase for the new kit", workFactor: 10)
        try w["A"].sync(t1); try w["A"].sync(t1)
        let copies = t1.paths.filter { $0.hasPrefix("keys/") }
        XCTAssertEqual(copies.count, 1, "\(copies)")
        XCTAssertFalse(copies.contains(oldCopy))
        // C, still holding the old copy, takes the change and never uploads the old copy again.
        try w["C"].sync(t1); try w["C"].sync(t1)
        XCTAssertFalse(t1.paths.contains(oldCopy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w["C"].folder.appendingPathComponent(oldCopy).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: w["C"].folder.appendingPathComponent(copies.first ?? "").path))
    }

    // MARK: - synced (design §5.5)

    func testACompleteTwoWayRunRecordsSyncedWhichHomeReadsForTheStaleRemovalWarning() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        let twelveDaysAgo = Date().addingTimeInterval(-12 * 86_400)
        try w["B"].sync(t1) { $0.recordSynced = true; $0.now = twelveDaysAgo }
        try w["A"].sync(t1)
        let seen = try XCTUnwrap(try w["A"].open().lastSynced(device: w["B"].id))
        XCTAssertEqual(seen.timeIntervalSince1970, twelveDaysAgo.timeIntervalSince1970, accuracy: 1)
        // Not rewritten within the interval; rewritten after it.
        let r = try w["B"].sync(t1) { $0.recordSynced = true; $0.now = twelveDaysAgo.addingTimeInterval(60) }
        XCTAssertFalse(r.uploaded.contains { $0.hasPrefix("summaries/") }, "\(r.uploaded)")
        try w["B"].sync(t1) { $0.recordSynced = true }
        try w["A"].sync(t1)
        XCTAssertLessThan(abs(try XCTUnwrap(try w["A"].open().lastSynced(device: w["B"].id)).timeIntervalSinceNow), 60)
    }

    // MARK: - Restores (design §5.4 "Restores")

    func testARestoreOfTheSameDeviceCatchesUpFromItsBackupState() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        let b0 = try w["B"].write("B before the backup")
        try w["B"].sync(t1)
        // The backup: B's working copy, ledger and trust record as they are now.
        let backup = tmp.appendingPathComponent("B-backup.sempere")
        try FileManager.default.copyItem(at: w["B"].folder, to: backup)
        let ledger = try w["B"].ledger.entries(), keys = try w["B"].ledger.epochKeys()
        let trust = try XCTUnwrap(try w["B"].trust.record(for: w.vaultId))
        let b1 = try w["B"].write("B after the backup")
        try w["B"].sync(t1); try w["A"].sync(t1)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        // The same device, restored: the same keys, its ledger and trust record at the backup's state.
        let restored = EpochSyncDevice("B-restored", root: tmp, identity: w["B"].identity)
        try FileManager.default.copyItem(at: backup, to: restored.folder)
        try restored.ledger.append(ledger)
        for k in keys { try restored.ledger.rememberKey(epoch: k.epoch, key: k.key) }
        try restored.trust.save(trust)
        let r = try restored.sync(t1)
        XCTAssertEqual(r.epoch?.taken, 2, "\(r)")
        let titles = try restored.titles()
        XCTAssertEqual(titles[b0], "B before the backup")
        XCTAssertEqual(titles[b1], "B after the backup", "what it wrote after the backup comes back from the target")
        let b2 = try restored.write("B restored writes")
        try restored.sync(t1); try w["A"].sync(t1)
        XCTAssertEqual(try w["A"].titles()[b2], "B restored writes")
    }

    func testARestoreOntoAnotherDeviceIsAJoinSourceWhoseUnacceptedFilesAreOfferedForExport() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        let b0 = try w["B"].write("B synced")
        try w["B"].sync(t1); try w["A"].sync(t1)
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        try w["A"].sync(t1)
        // B writes under the old key without syncing, then is lost; its working copy survives in a backup.
        let lost = try w["B"].write("B never synced")
        let backup = tmp.appendingPathComponent("B-backup.sempere")
        try FileManager.default.copyItem(at: w["B"].folder, to: backup)
        // A new device joins by approval (its own keys) and takes the backup as a source.
        let n = EpochSyncDevice("N", root: tmp)
        a = try w["A"].open()
        let words = try a.approveDevice(n.keys.joinRequest(vaultId: w.vaultId, name: "N", kind: "cli"))
        try w["A"].sync(t1)
        try n.sync(t1)
        var nv = try n.open()
        try nv.confirmJoin(words: words)
        let outcomes = EpochChangePull.run(vault: try n.open(), folder: n.folder,
                                           targets: [.init(name: "backup", remote: FolderRemote(root: backup))],
                                           scratch: n.root.appendingPathComponent("import"))
        let report = try XCTUnwrap(outcomes.first?.report)
        XCTAssertTrue(report.setAside.contains { $0.path.hasPrefix("notes/\(lost.uuidString.lowercased())/") }, "\(report)")
        XCTAssertEqual(try n.titles()[b0], "B synced")
        XCTAssertNil(try n.titles()[lost])
        let item = try XCTUnwrap(n.setAside.items(vaultId: w.vaultId).first { $0.path.contains(lost.uuidString.lowercased()) })
        let out = tmp.appendingPathComponent("export")
        XCTAssertNoThrow(try n.open().exportSetAside(item, to: out))
    }

    // MARK: - Record first, then vault.json (design §5.2; F7's deferred uploads)

    func testTheRecordReachesATargetBeforeVaultJsonAndAFailedRecordUploadHoldsVaultJsonBack() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B", "X"])
        let t1 = w.target("T1")
        var a = try w["A"].open()
        try a.removeDevices([w["X"].id])
        // The record's upload fails (the connection drops before every request under epochs/).
        let faults = MemoryFaults(seed: 7, rates: MemoryFaults.Rates([.dropBefore: 1]))
        faults.eligible = { _, _, path in path.first == Vault.epochsName }
        t1.reach = { _ in MemoryRemote(store: t1.store, faults: faults) }
        let failed = try w["A"].sync(t1)
        XCTAssertFalse(failed.uploaded.contains(Vault.manifestName), "never a vault.json without its record: \(failed)")
        XCTAssertTrue(failed.skipped.contains { $0.path == Vault.manifestName }, "\(failed.skipped)")
        let onTarget = try XCTUnwrap(t1.file(Vault.manifestName))
        XCTAssertEqual(try EpochManifest.parse(onTarget).epoch, 1)
        XCTAssertFalse(t1.paths.contains { $0.hasPrefix("epochs/2-") })
        // B meanwhile sees no change and keeps working at epoch 1.
        XCTAssertNil(try w["B"].sync(t1).epoch)
        // The fault gone: the record first, then vault.json, in one run.
        t1.reach = nil
        let ok = try w["A"].sync(t1)
        let record = try XCTUnwrap(ok.uploaded.firstIndex { $0.hasPrefix("epochs/2-") }, "\(ok.uploaded)")
        let manifest = try XCTUnwrap(ok.uploaded.firstIndex(of: Vault.manifestName))
        XCTAssertLessThan(record, manifest)
        XCTAssertEqual(try w["B"].sync(t1).epoch?.taken, 2)
    }

    func testACutUploadOfAReEncryptedFileLeavesTheOldOrTheNewCopyNeverAMix() throws {
        let (w, nd) = try unsealedOnTwoTargets()
        let t2 = w.target("T2")
        let prefix = "notes/\(nd.uuidString.lowercased())/"
        let file = try XCTUnwrap(t2.paths.first { $0.hasPrefix(prefix) })
        let old = try XCTUnwrap(t2.file(file))
        try w["B"].sync(w.target("T1")); try w["B"].sync(t2)
        // Every write to the note's folder on T2 is cut off mid-body or lost.
        let faults = MemoryFaults(seed: 3, rates: MemoryFaults.Rates([.cutBody: 1, .loseAnswer: 0.5]))
        faults.eligible = { _, verb, path in verb == .write && path.starts(with: [Vault.notesName, nd.uuidString.lowercased()]) }
        t2.reach = { _ in MemoryRemote(store: t2.store, faults: faults) }
        _ = try? w["D"].sync(t2)
        let after = try XCTUnwrap(t2.file(file))
        let local = try Data(contentsOf: w["D"].folder.appendingPathComponent(file))
        XCTAssertTrue(after == old || after == local, "the target holds a whole copy, old or new")
        // Without faults the next run finishes the replacement, and every device reads the note.
        t2.reach = nil
        try w["D"].sync(t2)
        XCTAssertEqual(t2.file(file), local)
        try w["B"].sync(t2)
        XCTAssertEqual(try w["B"].titles()[nd], "D, offline from T1")
    }
}
