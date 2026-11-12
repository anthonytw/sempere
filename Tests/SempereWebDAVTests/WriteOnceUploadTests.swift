import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Notebook records, join requests and passphrase copies go to the server like revisions do: to a temporary name,
/// then moved to their own (design F11). A cut upload never leaves a partial file under the final name, and a cut
/// copy an earlier client left there is repaired.
final class WriteOnceUploadTests: SyncTestCase {
    /// A cut notebook-record PUT on a server that keeps what arrived stays under a temporary name; the next run
    /// uploads it whole, and another device gets the notebook.
    func testCutNotebookRecordUploadNeverLeavesAPartialFile() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        let made = try XCTUnwrap(try a.createNotebook("Ideas"))
        let path = "notebooks/\(made.fileName)"
        let local = try Data(contentsOf: dir("A").appendingPathComponent(path))
        server.cutPUT[FileIO.tempPrefix] = 40
        let first = try sync("A", server)
        XCTAssertEqual(first.errors.map(\.path), [path], "\(first)")
        XCTAssertFalse(server.names(under: "notebooks").contains(made.fileName), "no partial file under the record's name")
        let second = try sync("A", server)
        XCTAssertTrue(second.errors.isEmpty, "\(second)")
        XCTAssertTrue(second.uploaded.contains(path), "\(second)")
        XCTAssertEqual(server.file(path), local)
        XCTAssertEqual(server.names(under: "notebooks").filter { $0.hasPrefix(FileIO.tempPrefix) }, [])
        let pull = try sync("B", server)
        XCTAssertTrue(pull.errors.isEmpty && pull.skipped.isEmpty, "\(pull)")
        XCTAssertTrue(try openVault("B").readNotebookRecords().declared.contains("Ideas"))
    }

    /// A notebook record an earlier client left cut under its final name is replaced by the whole record.
    func testACutNotebookRecordAnEarlierClientLeftIsRepaired() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let made = try XCTUnwrap(try a.createNotebook("Ideas"))
        let path = "notebooks/\(made.fileName)"
        XCTAssertTrue(try sync("A", server).errors.isEmpty)
        let local = try Data(contentsOf: dir("A").appendingPathComponent(path))
        server.putDirect(path, local.prefix(40))
        let repaired = try sync("A", server)
        XCTAssertTrue(repaired.errors.isEmpty, "\(repaired)")
        XCTAssertTrue(repaired.replaced.contains { $0.side == "remote" && $0.path == path }, "\(repaired)")
        XCTAssertEqual(server.file(path), local)
        let quiet = try sync("A", server)
        XCTAssertTrue(quiet.uploaded.isEmpty && quiet.replaced.isEmpty, "\(quiet)")
        XCTAssertTrue(try sync("B", server).errors.isEmpty)
        XCTAssertTrue(try openVault("B").readNotebookRecords().declared.contains("Ideas"))
    }

    /// A join request cut on the target is not reported as delivered: the joiner's next run puts the whole request
    /// there, and home sees it.
    func testACutJoinRequestIsNotHeldAndIsRepaired() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli")
        let path = "joins/\(request.fileName)"
        let up = try n.syncLocked(t1) { $0.firstPullIdentities = [n.identity] }
        XCTAssertTrue(up.uploaded.contains(path), "\(up)")
        XCTAssertEqual(up.joinsHeld, [request.fileName])
        // What a PUT cut midway by an earlier client leaves on a server that writes bodies in place.
        let full = try XCTUnwrap(t1.file(path))
        t1.put(path, full.prefix(full.count / 2))
        let again = try n.syncLocked(t1) { $0.firstPullIdentities = [n.identity] }
        XCTAssertTrue(again.replaced.contains { $0.side == "remote" && $0.path == path }, "\(again)")
        XCTAssertEqual(again.joinsHeld, [request.fileName])
        XCTAssertEqual(t1.file(path), full)
        try w["A"].sync(t1)
        XCTAssertTrue(try w["A"].open().joinRequests().compactMap(\.request).contains { $0.fileName == request.fileName })
    }

    /// A target copy whose listed size differs from the local request, and which is not a cut of it, is never
    /// counted as delivered.
    func testAJoinRequestOfAnotherSizeIsNotHeld() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let n = EpochSyncDevice("N", root: tmp)
        try n.syncLocked(t1)
        let request = try Vault.writeJoinRequest(at: n.folder, device: n.keys, name: "N", kind: "cli")
        let path = "joins/\(request.fileName)"
        t1.put(path, Data("{\"other\":true}".utf8))
        let r = try n.syncLocked(t1) { $0.firstPullIdentities = [n.identity] }
        XCTAssertEqual(r.joinsHeld ?? [], [], "\(r)")
    }

    /// A passphrase copy an earlier client left cut under its final name is replaced by the whole copy.
    func testACutPassphraseCopyIsRepaired() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: w["A"].folder.appendingPathComponent(Vault.keysName).path)
            .first { Vault.passphraseCopyFingerprint($0) != nil })
        let path = "\(Vault.keysName)/\(name)"
        let full = try XCTUnwrap(t1.file(path))
        t1.put(path, full.prefix(full.count / 3))
        let r = try w["A"].sync(t1)
        XCTAssertTrue(r.replaced.contains { $0.side == "remote" && $0.path == path }, "\(r)")
        XCTAssertEqual(t1.file(path), full)
    }

    /// A `vault.json` cut on the target stops nobody's two-way sync: home's run, which holds the key and the list
    /// home sealed, replaces it; a run without the key leaves it alone.
    func testACutManifestIsRepairedByATwoWayRunWithTheKey() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        try w["A"].sync(t1); try w["B"].sync(t1)
        var a = try w["A"].open()
        try a.renameDevice(id: try XCTUnwrap(a.manifest.keys.first { $0.role != .recovery }?.id), to: "Renamed")
        try w["A"].sync(t1)
        let full = try XCTUnwrap(t1.file(Vault.manifestName))
        t1.put(Vault.manifestName, full.prefix(full.count / 2))
        // A run without the key never uploads vault.json.
        _ = try w["A"].push(t1)
        XCTAssertNotEqual(t1.file(Vault.manifestName), full)
        let repaired = try w["A"].sync(t1)
        XCTAssertTrue(repaired.errors.isEmpty, "\(repaired)")
        XCTAssertTrue(repaired.replaced.contains { $0.side == "remote" && $0.path == Vault.manifestName }, "\(repaired)")
        XCTAssertEqual(t1.file(Vault.manifestName), full)
        let b = try w["B"].sync(t1)
        XCTAssertTrue(b.errors.isEmpty, "\(b)")
    }

    /// The same on a device that is not home: its own verified copy of home's list repairs the target.
    func testACutManifestIsRepairedByAnotherDeviceWithTheKey() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        try w["A"].sync(t1); try w["B"].sync(t1)
        let full = try XCTUnwrap(t1.file(Vault.manifestName))
        t1.put(Vault.manifestName, full.prefix(full.count / 2))
        let repaired = try w["B"].sync(t1)
        XCTAssertTrue(repaired.errors.isEmpty, "\(repaired)")
        XCTAssertEqual(t1.file(Vault.manifestName), full)
        XCTAssertTrue(try w["A"].sync(t1).errors.isEmpty)
    }

    /// A target that is not known to be this vault's (this device never synced its `vault.json` there, and its `epochs/`
    /// lacks the local record) keeps a `vault.json` that does not parse: a two-way run with the key refuses it.
    func testACutManifestOnATargetNotKnownToBeThisVaultsIsNotReplaced() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let full = try XCTUnwrap(t1.file(Vault.manifestName))
        let record = try XCTUnwrap(t1.paths.first { $0.hasPrefix("\(Vault.epochsName)/") })
        t1.put(Vault.manifestName, full.prefix(full.count / 2))
        t1.remove(record)
        // No record of this target in the device's state either: a fresh state file.
        try? FileManager.default.removeItem(at: w["A"].stateURL(t1))
        XCTAssertThrowsError(try w["A"].sync(t1)) {
            guard case SyncError.malformedResponse = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNotEqual(t1.file(Vault.manifestName), full)
        // With the record there (or a state that names the target), it is repaired.
        t1.put(record, try Data(contentsOf: w["A"].folder.appendingPathComponent(record)))
        XCTAssertTrue(try w["A"].sync(t1).errors.isEmpty)
        XCTAssertEqual(t1.file(Vault.manifestName), full)
    }

    /// A keyless run (a joiner's) still refuses a target whose `vault.json` is not a manifest.
    func testAKeylessTwoWayRunDoesNotRepairACutManifest() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A"])
        let t1 = w.target("T1")
        let full = try XCTUnwrap(t1.file(Vault.manifestName))
        t1.put(Vault.manifestName, full.prefix(full.count / 2))
        XCTAssertThrowsError(try w["A"].syncLocked(t1))
        XCTAssertNotEqual(t1.file(Vault.manifestName), full)
    }

    /// A cut `settings.age` is replaced by the local copy in a two-way run with the key.
    func testACutSettingsFileIsRepairedByATwoWayRun() throws {
        let w = try EpochSyncWorld(in: tmp, names: ["A", "B"])
        let t1 = w.target("T1")
        var settings = SharedSettings()
        try settings.set(SettingSlotKey("Sempere.paper"), to: .string("dotted"), type: nil, now: Date())
        try w["A"].open().writeSharedSettings(settings)
        try w["A"].sync(t1)
        let full = try XCTUnwrap(t1.file(SharedSettings.fileName))
        t1.put(SharedSettings.fileName, full.prefix(full.count / 2))
        let repaired = try w["A"].sync(t1)
        XCTAssertTrue(repaired.errors.isEmpty, "\(repaired)")
        XCTAssertEqual(t1.file(SharedSettings.fileName), full)
        XCTAssertTrue(try w["B"].sync(t1).errors.isEmpty)
    }
}
