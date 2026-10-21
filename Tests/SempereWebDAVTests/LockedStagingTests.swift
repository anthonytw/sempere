import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// Locked staging (P8b, docs/design/device-first-sync.md §4.1): a locked device's run downloads what other
/// devices wrote into a shadow of its working copy, never into the copy itself; the unlock checks and
/// places it, quarantining what does not verify.
final class LockedStagingTests: SyncTestCase {
    struct World {
        let remote: MemoryRemote
        let a: Vault
        let bFolder: URL
        let bState: URL
        let staging: LockedStaging
    }

    /// A and B share a vault through one remote, both in step.
    func world() throws -> World {
        let a = try makeVault("A")
        try delta(a, device: devA, t: 1, title: "first")
        let remote = MemoryRemote(store: MemoryStore(name: "staging"), base: ["dav", "v"])
        _ = try SyncEngine(directory: dir("A"), vault: a, remote: remote, stateURL: tmp.appendingPathComponent("a.json"),
                           options: SyncOptions(deviceLabel: "A")).run()
        let bFolder = dir("B")
        try FileManager.default.copyItem(at: dir("A"), to: bFolder)
        let bState = tmp.appendingPathComponent("b/sync-state.json")
        try FileManager.default.createDirectory(at: bState.deletingLastPathComponent(), withIntermediateDirectories: true)
        let b = try openVault("B")
        let first = try SyncEngine(directory: bFolder, vault: b, remote: remote, stateURL: bState,
                                   options: SyncOptions(deviceLabel: "B")).run()
        XCTAssertTrue(first.errors.isEmpty, "\(first.errors)")
        return World(remote: remote, a: a, bFolder: bFolder, bState: bState, staging: LockedStaging(targetState: bState))
    }

    func stage(_ w: World) throws -> SyncReport {
        try w.staging.stage(vaultFolder: w.bFolder) { shadow, state in
            try SyncEngine(directory: shadow, vault: nil, remote: w.remote, stateURL: state,
                           options: SyncOptions(deviceLabel: "B")).run()
        }
    }

    func noteFiles(_ folder: URL) -> Set<String> {
        let notes = folder.appendingPathComponent("notes")
        guard let e = FileManager.default.enumerator(atPath: notes.path) else { return [] }
        return Set(e.compactMap { $0 as? String }.filter { $0.hasSuffix(".age") && !($0 as NSString).lastPathComponent.hasPrefix(".") })
    }

    func testALockedRunStagesWithoutTouchingTheCopyAndTheUnlockPlaces() throws {
        let w = try world()
        // A writes a new note and uploads it.
        let newNote = UUID()
        try delta(w.a, device: devA, t: 2, title: "from A", note: newNote)
        _ = try SyncEngine(directory: dir("A"), vault: w.a, remote: w.remote, stateURL: tmp.appendingPathComponent("a.json"),
                           options: SyncOptions(deviceLabel: "A")).run()
        let before = noteFiles(w.bFolder)

        // B is locked: the staging run takes it into the shadow only.
        let staged = try stage(w)
        XCTAssertTrue(staged.errors.isEmpty, "\(staged.errors)")
        XCTAssertEqual(noteFiles(w.bFolder), before, "nothing unverified is placed in the working copy")
        let pending = w.staging.pending(vaultFolder: w.bFolder)
        XCTAssertTrue(pending.contains { $0.hasPrefix("notes/\(newNote.uuidString.lowercased())/") }, "\(pending)")

        // A second locked run stages nothing new and still leaves the copy alone.
        _ = try stage(w)
        XCTAssertEqual(noteFiles(w.bFolder), before)

        // The unlock places it, checked under the key, and the staging goes.
        let b = try openVault("B")
        let placed = try XCTUnwrap(try w.staging.place(vaultFolder: w.bFolder, vault: b))
        XCTAssertTrue(placed.errors.isEmpty, "\(placed.errors)")
        XCTAssertEqual(noteFiles(w.bFolder), noteFiles(dir("A")))
        XCTAssertTrue(placed.changed?.noteIDs.contains(newNote) == true, "the arrival is reported to the model")
        XCTAssertFalse(w.staging.exists)
        XCTAssertEqual(try title(b, newNote), "from A")
        XCTAssertNil(try w.staging.place(vaultFolder: w.bFolder, vault: b), "nothing staged: nothing to do")
    }

    func testAStagedFileThatDoesNotVerifyIsQuarantinedNotPlaced() throws {
        let w = try world()
        // Another writer puts a damaged revision on the remote.
        let bad = UUID()
        let name = "notes/\(bad.uuidString.lowercased())/17596320000990000-cccccccc-1.delta.age"
        let shadowName = w.staging.shadow.appendingPathComponent(name)
        _ = try stage(w)
        try FileManager.default.createDirectory(at: shadowName.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("age-encryption.org/v1\n-> X25519 junk\n---\n".utf8).write(to: shadowName)
        let b = try openVault("B")
        let placed = try XCTUnwrap(try w.staging.place(vaultFolder: w.bFolder, vault: b))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.bFolder.appendingPathComponent(name).path),
                       "a file that does not verify is never placed")
        XCTAssertFalse(placed.errors.isEmpty && placed.skipped.isEmpty && placed.quarantined.isEmpty,
                       "it is reported")
    }

    func testOnlyWriteOnceFilesCount() {
        XCTAssertTrue(LockedStaging.isWriteOnce(["notes", "id", "1-a-1.delta.age"]))
        XCTAssertTrue(LockedStaging.isWriteOnce(["inbox", "x.capture.age"]))
        XCTAssertFalse(LockedStaging.isWriteOnce(["vault.json"]))
        XCTAssertFalse(LockedStaging.isWriteOnce(["notes", "id", ".sempere-pending"]))
    }
}
