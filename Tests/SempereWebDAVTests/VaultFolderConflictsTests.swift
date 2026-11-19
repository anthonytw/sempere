import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// `VaultFolderConflicts` (docs/io.md "A vault folder held as a package"): whole-vault conflict versions of a vault
/// folder a provider holds as a package, through `RecordedVersionsProvider` (versions are folders on disk, no iCloud).
final class VaultFolderConflictsTests: SyncTestCase {
    private var store: URL { tmp.appendingPathComponent("records") }
    private var quarantine: URL { tmp.appendingPathComponent("quarantine") }
    private var provider: RecordedVersionsProvider { RecordedVersionsProvider(root: dir("A"), store: store) }

    /// Records a copy of the vault folder as it is now as a conflict version `id` of it.
    private func recordVersion(_ id: String) throws -> URL {
        let v = store.appendingPathComponent("versions/@/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: v.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir("A"), to: v)
        return v
    }

    private func path(_ r: Revision) -> String { "notes/\(r.noteId.uuidString.lowercased())/\(r.name.filename)" }

    /// A vault with one revision, and a version that also holds a second one the folder lost.
    private func lostRevision() throws -> (vault: Vault, kept: Revision, lost: Revision, version: URL) {
        let a = try makeVault("A")
        let kept = try delta(a, device: devA, t: 0, title: "one")
        let lost = try delta(a, device: devA, t: 10, title: "two")
        let version = try recordVersion("v1@iPad")
        try FileManager.default.removeItem(at: dir("A").appendingPathComponent(path(lost)))
        return (try openVault("A"), kept, lost, version)
    }

    private func merge(_ vault: Vault, dryRun: Bool = false, remove: Bool = false) throws -> VaultFolderConflicts.MergeReport {
        try VaultFolderConflicts.merge(folder: dir("A"), provider: provider, vault: vault,
                                       options: .init(quarantine: quarantine, dryRun: dryRun, removeVersions: remove))
    }

    func testKinds() {
        let n = "notes/7e57c0de-0000-4000-8000-000000000001"
        XCTAssertEqual(VaultFolderConflicts.kind(of: "\(n)/17944053862720000-9bca3cce-3.delta.age"), .revision)
        XCTAssertEqual(VaultFolderConflicts.kind(of: "inbox/da0ae00d-0000-4000-8000-000000000001.capture.age"), .inbox)
        XCTAssertEqual(VaultFolderConflicts.kind(of: "joins/7f26db62.join.json"), .join)
        XCTAssertEqual(VaultFolderConflicts.kind(of: "vault.json"), .manifest)
        XCTAssertEqual(VaultFolderConflicts.kind(of: "settings.age"), .settings)
        XCTAssertEqual(VaultFolderConflicts.kind(of: "sempere-index.json"), .derived)
        XCTAssertEqual(VaultFolderConflicts.kind(of: "\(n)/notes.txt"), .other)
        XCTAssertNil(VaultFolderConflicts.kind(of: "\(n)/.sempere-tmp-1"))
        XCTAssertTrue(VaultFolderConflicts.FileKind.join.isWriteOnce)
        XCTAssertFalse(VaultFolderConflicts.FileKind.settings.isWriteOnce)
    }

    func testInspectionListsWhatOnlyTheVersionHolds() throws {
        let (_, _, lost, _) = try lostRevision()
        try Data().write(to: store.appendingPathComponent("package"))
        let i = VaultFolderConflicts.inspect(folder: dir("A"), provider: provider)
        XCTAssertTrue(i.heldAsPackage)
        XCTAssertEqual(i.record?.packageCause, .providerRecord)
        XCTAssertEqual(i.versions.map(\.id), ["v1@iPad"])
        XCTAssertEqual(i.versions.first?.device, "iPad")
        XCTAssertEqual(i.versions.first?.missing, ["revision": [path(lost)]])
        XCTAssertEqual(i.writeOnceMissing, [path(lost)])
        XCTAssertTrue(i.mutableToReview.isEmpty)
    }

    func testDryRunWritesNothing() throws {
        let (vault, _, lost, version) = try lostRevision()
        let r = try merge(vault, dryRun: true)
        XCTAssertEqual(r.copied, [path(lost)])
        XCTAssertEqual(r.resolved, ["v1@iPad"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(path(lost)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path), "still unresolved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testMergeCopiesOnlyMissingWriteOnceFilesAndNeverOverwrites() throws {
        let (vault, kept, lost, version) = try lostRevision()
        // The version holds other bytes under a name the folder has: never written over (not even looked at).
        let keptURL = dir("A").appendingPathComponent(path(kept))
        let before = try Data(contentsOf: keptURL)
        try Data("other bytes".utf8).write(to: version.appendingPathComponent(path(kept)))
        let r = try merge(vault)
        XCTAssertEqual(r.copied, [path(lost)])
        XCTAssertTrue(r.isComplete, "\(r)")
        XCTAssertEqual(try Data(contentsOf: keptURL), before)
        XCTAssertEqual(Set(try fileNames(try openVault("A"))), [kept.name.filename, lost.name.filename])
        XCTAssertEqual(try title(try openVault("A")), "two")
        // Resolved, and kept (not removed) by default.
        XCTAssertEqual(r.resolved, ["v1@iPad"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("resolved/@/v1@iPad").path))
        XCTAssertTrue(VaultFolderConflicts.inspect(folder: dir("A"), provider: provider).versions.isEmpty)
    }

    func testABadFileIsQuarantinedNeverPlaced() throws {
        let (vault, _, lost, version) = try lostRevision()
        let junk = "notes/\(noteID.uuidString.lowercased())/17900000000000000-0000000a-9.delta.age"
        try Data("junk".utf8).write(to: version.appendingPathComponent(junk))
        let r = try merge(vault)
        XCTAssertEqual(r.copied, [path(lost)])
        XCTAssertEqual(Array(r.quarantined.keys), [junk])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(junk).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("01-iPad/\(junk)").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("report.json").path))
        // Kept in the quarantine, so the version is resolved; the run says it was not complete.
        XCTAssertEqual(r.resolved, ["v1@iPad"])
        XCTAssertFalse(r.isComplete)
    }

    func testAVersionWithAnUnsettledFileStaysUnresolved() throws {
        let (vault, _, lost, version) = try lostRevision()
        let clean = try recordVersion("v2@Mac")
        _ = clean
        // A re-encryption journal only the first version has: kept aside, never picked, so that version stays.
        try Data("journal".utf8).write(to: version.appendingPathComponent(Vault.journalName))
        let r = try merge(vault)
        XCTAssertEqual(r.copied, [path(lost)])
        XCTAssertNotNil(r.unsettled[Vault.journalName])
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertEqual(r.resolved, ["v2@Mac"])
        XCTAssertTrue(r.keptAside.contains("01-iPad/\(Vault.journalName)"), "\(r.keptAside)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("kept/01-iPad/\(Vault.journalName)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(Vault.journalName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
    }

    func testAFailedCopyLeavesTheVersionUnresolved() throws {
        let (vault, _, lost, version) = try lostRevision()
        let noteDir = dir("A").appendingPathComponent("notes/\(noteID.uuidString.lowercased())")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: noteDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noteDir.path) }
        guard access(noteDir.path, W_OK) != 0 else { throw XCTSkip("running as root: the folder stays writable") }
        let r = try merge(vault)
        XCTAssertNotNil(r.errors[path(lost)])
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertTrue(r.resolved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
    }

    func testLockedRealRunIsRefusedAndRemoveVersionsRemoves() throws {
        let (_, _, _, version) = try lostRevision()
        let locked = try Vault.open(at: dir("A"))
        XCTAssertThrowsError(try merge(locked))
        let r = try merge(try openVault("A"), remove: true)
        XCTAssertEqual(r.removed, ["v1@iPad"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: version.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("resolved/@/v1@iPad").path))
    }

    func testTheQuarantineMayNotBeInsideTheVault() throws {
        let (vault, _, _, _) = try lostRevision()
        XCTAssertThrowsError(try VaultFolderConflicts.merge(folder: dir("A"), provider: provider, vault: vault,
                                                            options: .init(quarantine: dir("A").appendingPathComponent("q"))))
    }

    func testAVersionOfVaultJSONItselfIsSettledWhenTheSame() throws {
        _ = try makeVault("A")
        let file = store.appendingPathComponent("versions/vault.json/v3@iPhone")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir("A").appendingPathComponent("vault.json"), to: file)
        let i = VaultFolderConflicts.inspect(folder: dir("A"), provider: provider)
        XCTAssertEqual(i.versions.map(\.item), ["vault.json"])
        XCTAssertEqual(i.versions.first?.differing, [])
        let r = try merge(try openVault("A"))
        XCTAssertEqual(r.resolved, ["v3@iPhone"])
        XCTAssertTrue(r.isComplete, "\(r)")
    }
}
