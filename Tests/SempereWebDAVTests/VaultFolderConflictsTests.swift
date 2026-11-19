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

    private func options(dryRun: Bool = false, remove: Bool = false) -> VaultFolderConflicts.MergeOptions {
        .init(quarantine: quarantine, dryRun: dryRun, removeVersions: remove, staging: tmp.appendingPathComponent("staging"))
    }

    private func merge(_ vault: Vault, dryRun: Bool = false, remove: Bool = false,
                       provider: (any FolderProvider)? = nil,
                       check: (@Sendable (String, VaultFolderConflicts.FileKind, URL) throws -> Void)? = nil)
        throws -> VaultFolderConflicts.MergeReport {
        var o = options(dryRun: dryRun, remove: remove)
        o.checkOverride = check
        return try VaultFolderConflicts.merge(folder: dir("A"), provider: provider ?? self.provider, vault: vault, options: o)
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
        let i = try VaultFolderConflicts.inspect(folder: dir("A"), provider: provider)
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
        XCTAssertTrue(try VaultFolderConflicts.inspect(folder: dir("A"), provider: provider).versions.isEmpty)
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
        let i = try VaultFolderConflicts.inspect(folder: dir("A"), provider: provider)
        XCTAssertEqual(i.versions.map(\.item), ["vault.json"])
        XCTAssertEqual(i.versions.first?.differing, [])
        let r = try merge(try openVault("A"))
        XCTAssertEqual(r.resolved, ["v3@iPhone"])
        XCTAssertTrue(r.isComplete, "\(r)")
    }

    // MARK: Review fixes (2026-11-19)

    /// B1: a version whose contents are not here, whose root is gone, or a folder of which cannot be read is never
    /// judged from what it lists: left unresolved, nothing placed from it, nothing removed.
    func testAVersionThatCannotBeListedWholeIsLeft() throws {
        let (vault, _, lost, version) = try lostRevision()
        // A folder of the version that cannot be read: the old walk took it as empty.
        let noteDir = version.appendingPathComponent("notes/\(noteID.uuidString.lowercased())")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noteDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noteDir.path) }
        guard access(noteDir.path, R_OK) != 0 else { throw XCTSkip("running as root: the folder stays readable") }
        let r = try merge(vault, remove: true)
        XCTAssertNotNil(r.inspection.versions.first?.problem)
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertTrue(r.resolved.isEmpty && r.removed.isEmpty)
        XCTAssertFalse(r.isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(path(lost)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
    }

    func testAVersionWithoutLocalContentsOrRootIsLeft() throws {
        let (vault, _, lost, version) = try lostRevision()
        try FileManager.default.createDirectory(at: store.appendingPathComponent("dataless"), withIntermediateDirectories: true)
        try Data().write(to: store.appendingPathComponent("dataless/v1@iPad"))
        var r = try merge(vault, remove: true)
        XCTAssertNotNil(r.inspection.versions.first?.problem)
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertTrue(r.copied.isEmpty)
        try FileManager.default.removeItem(at: store.appendingPathComponent("dataless"))

        let gone = CoordinatingProvider(provider)
        gone.missingRoots = ["v1@iPad"]
        r = try merge(vault, remove: true, provider: gone)
        XCTAssertEqual(r.inspection.versions.map(\.id), ["v1@iPad"], "listed, never dropped")
        XCTAssertNotNil(r.inspection.versions.first?.problem)
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(path(lost)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
    }

    /// S1: one coordinated write of the folder for the whole merge, none nested inside it (the resolve included).
    func testTheMergeHoldsOneCoordinatedWriteAndNestsNone() throws {
        let (vault, _, lost, _) = try lostRevision()
        let coordinating = CoordinatingProvider(provider)
        let r = try merge(vault, provider: coordinating)
        XCTAssertEqual(coordinating.writes, 1)
        XCTAssertEqual(coordinating.nested, 0)
        XCTAssertEqual(r.copied, [path(lost)])
        XCTAssertEqual(r.resolved, ["v1@iPad"])
        XCTAssertTrue(r.isComplete, "\(r)")
    }

    /// S1: a plain folder's merge takes `.sempere-lock`; another holder makes it busy, nothing written.
    func testAPlainFolderMergeTakesItsLock() throws {
        let (vault, _, lost, _) = try lostRevision()
        let plain = CoordinatingProvider(provider, manages: false)
        let lock = VaultFileLock.at(dir("A").appendingPathComponent(FolderRemote.lockName), kind: "folder")
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? lock.withLock(timeout: 10) { held.signal(); release.wait() }
            done.signal()
        }
        held.wait()
        var o = options()
        o.lockTimeout = 0.3
        XCTAssertThrowsError(try VaultFolderConflicts.merge(folder: dir("A"), provider: plain, vault: vault, options: o)) {
            XCTAssertEqual($0 as? VaultFolderConflicts.MergeError, .busy(dir("A").path))
        }
        release.signal()
        done.wait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(path(lost)).path))
        XCTAssertEqual(try merge(vault, provider: plain).copied, [path(lost)])
        XCTAssertEqual(plain.writes, 0, "a plain folder is not coordinated")
    }

    private func setting(_ vault: Vault, _ key: String, _ value: String) throws {
        try vault.updateSharedSettings { s in
            try s.set(SettingSlotKey(key), to: .string(value), type: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    /// S1, S2: settings.age is merged with the file on disk just before it is written (another writer added a key
    /// inside the merge's write): both keys are there.
    func testSettingsAreMergedWithTheFileOnDiskAtWriteTime() throws {
        let a = try makeVault("A")
        try setting(a, "test.theirs", "from the version")
        _ = try recordVersion("v1@iPad")
        try FileManager.default.removeItem(at: dir("A").appendingPathComponent(SharedSettings.fileName))
        let coordinating = CoordinatingProvider(provider)
        let other = try openVault("A")
        coordinating.insideWrite = { try self.setting(other, "test.meanwhile", "written meanwhile") }
        let r = try merge(try openVault("A"), provider: coordinating)
        XCTAssertEqual(r.written, [SharedSettings.fileName], "\(r)")
        let merged = try XCTUnwrap(try openVault("A").readSharedSettings())
        XCTAssertEqual(merged.value(SettingSlotKey("test.theirs")), .string("from the version"))
        XCTAssertEqual(merged.value(SettingSlotKey("test.meanwhile")), .string("written meanwhile"))
        XCTAssertEqual(r.resolved, ["v1@iPad"])
    }

    /// S2: a current settings.age that cannot be read is never replaced, and its versions stay unresolved.
    func testAnUnreadableCurrentSettingsFileIsNeverReplaced() throws {
        let a = try makeVault("A")
        try setting(a, "test.theirs", "from the version")
        _ = try recordVersion("v1@iPad")
        let junk = Data("not settings".utf8)
        try junk.write(to: dir("A").appendingPathComponent(SharedSettings.fileName))
        let r = try merge(try openVault("A"))
        XCTAssertNotNil(r.unsettled[SharedSettings.fileName], "\(r)")
        XCTAssertTrue(r.written.isEmpty)
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertEqual(try Data(contentsOf: dir("A").appendingPathComponent(SharedSettings.fileName)), junk)
    }

    /// S3: pending leaves the version unresolved; set aside goes to the set-aside store. Neither is quarantined.
    func testPendingAndSetAsideAreNeverQuarantined() throws {
        let (_, _, lost, version) = try lostRevision()
        var r = try merge(try openVault("A")) { _, _, _ in throw IncomingFileProblem("no record yet", pending: true) }
        XCTAssertNotNil(r.unsettled[path(lost)])
        XCTAssertTrue(r.quarantined.isEmpty)
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("01-iPad").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))

        // Without a set-aside store the file cannot be kept: left, not quarantined.
        let setAside: @Sendable (String, VaultFolderConflicts.FileKind, URL) throws -> Void = { _, _, _ in
            throw IncomingFileProblem("an earlier key", setAside: .notSealed)
        }
        r = try merge(try openVault("A"), check: setAside)
        XCTAssertEqual(r.left, ["v1@iPad"])
        XCTAssertTrue(r.quarantined.isEmpty)

        let store = SetAsideStore(directory: tmp.appendingPathComponent("aside"))
        let withStore = try Vault.open(at: dir("A"), identities: [identity], setAside: store)
        try? FileManager.default.removeItem(at: quarantine)
        r = try merge(withStore, check: setAside)
        XCTAssertEqual(r.setAside, [path(lost)])
        XCTAssertTrue(r.quarantined.isEmpty)
        XCTAssertEqual(r.resolved, ["v1@iPad"])
        XCTAssertEqual(store.items(vaultId: withStore.vaultId).map(\.path), [path(lost)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(path(lost)).path))
    }

    /// S3: every version's epoch records are placed (pass 1) before any other file is checked (pass 2).
    func testEpochRecordsOfEveryVersionComeFirst() throws {
        let (vault, _, lost, _) = try lostRevision()
        let second = try recordVersion("v2@Mac")
        let record = "epochs/2-0123456789abcdef.epoch.age"
        try FileManager.default.createDirectory(at: second.appendingPathComponent("epochs"), withIntermediateDirectories: true)
        try Data("record".utf8).write(to: second.appendingPathComponent(record))
        let order = ConflictBox<[String]>([])
        let r = try merge(vault) { p, _, _ in order.update { $0.append(p) } }
        XCTAssertEqual(order.value, [record, path(lost)])
        XCTAssertEqual(r.copied, [record, path(lost)])
    }

    /// S4: a real run refuses a quarantine folder that is not empty; a version with a quarantined file is never
    /// removed, only marked resolved; a quarantined copy never replaces other bytes.
    func testQuarantineSafety() throws {
        let (vault, _, _, version) = try lostRevision()
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: quarantine.appendingPathComponent("old"))
        XCTAssertThrowsError(try merge(vault)) {
            XCTAssertEqual($0 as? VaultFolderConflicts.MergeError, .quarantineNotEmpty(quarantine.path))
        }
        try FileManager.default.removeItem(at: quarantine)

        let junk = "notes/\(noteID.uuidString.lowercased())/17900000000000000-0000000a-9.delta.age"
        try Data("junk".utf8).write(to: version.appendingPathComponent(junk))
        let r = try merge(vault, remove: true)
        XCTAssertEqual(Array(r.quarantined.keys), [junk])
        XCTAssertEqual(r.resolved, ["v1@iPad"])
        XCTAssertTrue(r.removed.isEmpty, "the version still holds the only copy beside the quarantine's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("resolved/@/v1@iPad").path))

        let from = tmp.appendingPathComponent("from")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: from.appendingPathComponent("f"))
        let to = tmp.appendingPathComponent("aside/f")
        try VaultFolderConflicts.Merger.copyAside(.init(base: from, path: "f"), to: to)
        try VaultFolderConflicts.Merger.copyAside(.init(base: from, path: "f"), to: to)   // the same bytes: kept
        try Data("two".utf8).write(to: from.appendingPathComponent("f"))
        XCTAssertThrowsError(try VaultFolderConflicts.Merger.copyAside(.init(base: from, path: "f"), to: to))
        XCTAssertEqual(try Data(contentsOf: to), Data("one".utf8))
    }

    /// S5: a vault.json version `judgeIncoming` does not take (another vault's) is left, its version unresolved.
    func testAnotherVaultJSONIsLeft() throws {
        _ = try makeVault("A")
        _ = try makeVault("B")
        let file = store.appendingPathComponent("versions/vault.json/v3@iPhone")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir("B").appendingPathComponent("vault.json"), to: file)
        let before = try vaultJSON("A")
        let r = try merge(try openVault("A"))
        XCTAssertNotNil(r.unsettled[Vault.manifestName], "\(r)")
        XCTAssertEqual(r.left, ["v3@iPhone"])
        XCTAssertEqual(try vaultJSON("A"), before)
    }

    /// S7: a symbolic link in a version is reported and never followed; its version is never removed.
    func testALinkInAVersionIsNeverFollowed() throws {
        let (vault, _, lost, version) = try lostRevision()
        let outside = tmp.appendingPathComponent("outside.delta.age")
        try FileManager.default.moveItem(at: version.appendingPathComponent(path(lost)), to: outside)
        try FileManager.default.createSymbolicLink(at: version.appendingPathComponent(path(lost)), withDestinationURL: outside)
        XCTAssertThrowsError(try VaultFolderConflicts.listFiles(version, current: false, maxEntries: 2)) {
            guard case .tooManyEntries = $0 as? VaultFolderConflicts.ListingError else { return XCTFail("\($0)") }
        }
        let r = try merge(vault, remove: true)
        XCTAssertTrue(r.copied.isEmpty)
        XCTAssertEqual(r.inspection.versions.first?.skipped.count, 1)
        XCTAssertFalse(r.isComplete)
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(path(lost)).path))
    }

    /// S9: a join request must be named after its own key and name this vault.
    func testJoinRequestsMustBeThisVaultsAndNamedAfterTheirKey() throws {
        let (vault, _, _, version) = try lostRevision()
        _ = try makeVault("B")
        let joins = version.appendingPathComponent(Vault.joinsName)
        try FileManager.default.createDirectory(at: joins, withIntermediateDirectories: true)
        let other = try Vault.writeJoinRequest(at: dir("B"), device: try DeviceKeys.generate(), name: "Other", kind: "ipad")
        try FileManager.default.copyItem(at: dir("B").appendingPathComponent("joins/\(other.fileName)"),
                                         to: joins.appendingPathComponent(other.fileName))
        let mine = try Vault.writeJoinRequest(at: dir("A"), device: try DeviceKeys.generate(), name: "Mine", kind: "ipad")
        try FileManager.default.moveItem(at: dir("A").appendingPathComponent("joins/\(mine.fileName)"),
                                         to: joins.appendingPathComponent("00000000.join.json"))
        let r = try merge(vault)
        XCTAssertEqual(Set(r.quarantined.keys), ["joins/\(other.fileName)", "joins/00000000.join.json"])
        XCTAssertFalse(r.copied.contains { $0.hasPrefix("joins/") })
    }

    /// Nits: a retired kit's passphrase copy is never copied back; an unknown file only a version has is kept aside,
    /// never placed, and its version never removed; one path's messages from several versions are all kept.
    func testRetiredCopiesUnknownFilesAndMessagesOfEveryVersion() throws {
        let (vault, _, _, version) = try lostRevision()
        let retired = "keys/recovery-\(String(repeating: "0", count: 64)).key.age"
        try FileManager.default.createDirectory(at: version.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try Data("old kit".utf8).write(to: version.appendingPathComponent(retired))
        let unknown = "notes/\(noteID.uuidString.lowercased())/notes.txt"
        try Data("unknown".utf8).write(to: version.appendingPathComponent(unknown))
        let junk = "notes/\(noteID.uuidString.lowercased())/17900000000000000-0000000a-9.delta.age"
        try Data("junk".utf8).write(to: version.appendingPathComponent(junk))
        let second = try recordVersion("v2@Mac")
        try Data("junk too".utf8).write(to: second.appendingPathComponent(junk))
        let r = try merge(vault, remove: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(retired).path))
        XCTAssertNotNil(r.settled[retired])
        XCTAssertEqual(r.keptUnknown, [unknown])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent(unknown).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("kept/01-iPad/\(unknown)").path))
        XCTAssertEqual(r.quarantined[junk]?.count, 2, "\(r.quarantined)")
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertFalse(r.isComplete)
    }

    /// The quarantine check resolves symbolic links: a link outside that points into the vault is refused.
    func testTheQuarantineCheckResolvesLinks() throws {
        let (vault, _, _, _) = try lostRevision()
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir("A"))
        var o = options()
        o.quarantine = link.appendingPathComponent("q")
        XCTAssertThrowsError(try VaultFolderConflicts.merge(folder: dir("A"), provider: provider, vault: vault, options: o)) {
            guard case .quarantineInsideVault = $0 as? VaultFolderConflicts.MergeError else { return XCTFail("\($0)") }
        }
    }
}

/// A thread-safe box for test closures.
final class ConflictBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func update(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&_value) }
}

/// Recorded versions behind coordination like `NSFileCoordinator`'s: a coordination nested in another one is counted
/// and fails (the real one waits for ever).
final class CoordinatingProvider: FolderProvider, @unchecked Sendable {
    let inner: RecordedVersionsProvider
    let manages: Bool
    private let lock = NSLock()
    private var depth = 0
    private var _writes = 0, _nested = 0
    /// Versions whose contents the provider lists but cannot give.
    var missingRoots = Set<String>()
    /// Runs inside each outermost coordinated write, before its body (another writer at that moment).
    var insideWrite: (() throws -> Void)?

    init(_ inner: RecordedVersionsProvider, manages: Bool = true) { self.inner = inner; self.manages = manages }

    var writes: Int { lock.lock(); defer { lock.unlock() }; return _writes }
    var nested: Int { lock.lock(); defer { lock.unlock() }; return _nested }
    var name: String { "a coordinating provider" }
    var managesFiles: Bool { manages }

    private func enter() -> Int { lock.lock(); defer { lock.unlock() }; depth += 1; return depth }
    private func leave() { lock.lock(); defer { lock.unlock() }; depth -= 1 }

    func coordinatedWrite<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let level = enter()
        defer { leave() }
        lock.lock(); _writes += 1; if level > 1 { _nested += 1 }; lock.unlock()
        if level > 1 { throw CocoaError(.fileWriteUnknown) }
        try insideWrite?()
        return try body()
    }

    func coordinatedRead<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let level = enter()
        defer { leave() }
        if level > 1 { lock.lock(); _nested += 1; lock.unlock(); throw CocoaError(.fileReadUnknown) }
        return try body()
    }

    func conflictVersions(of url: URL) -> [RemoteVersion] { inner.conflictVersions(of: url) }
    func versionFile(of url: URL, id: String) -> URL? { missingRoots.contains(id) ? nil : inner.versionFile(of: url, id: id) }
    func resolveConflicts(of url: URL, ids: Set<String>) throws {
        try coordinatedWrite(url) { try inner.resolveConflicts(of: url, ids: ids) }
    }
    func markConflictsResolved(of url: URL, ids: Set<String>) throws {
        try coordinatedWrite(url) { try inner.markConflictsResolved(of: url, ids: ids) }
    }
    func settleConflictVersions(of url: URL, ids: Set<String>, remove: Bool) throws {
        if remove { try inner.resolveConflicts(of: url, ids: ids) } else { try inner.markConflictsResolved(of: url, ids: ids) }
    }
    func itemRecord(of url: URL) -> ProviderItemRecord? { inner.itemRecord(of: url) }
}
