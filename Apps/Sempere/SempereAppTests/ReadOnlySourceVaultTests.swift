import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp

/// A vault picked from a folder this account cannot write to (build 12, demovault-mac: the demo vault in
/// /Users/Shared, made by another account, world-readable but owned by it; "permissions failure: errno 13").
/// Reproduced with a read-only copy (files 0444, folders 0555; tests cannot make another user's files): the copy into
/// the store was always writable, but "Keep syncing with this folder" made the folder a target, and every run then
/// failed to write there with "mkdir …: Permission denied (errno 13)".
@Suite(.serialized)
@MainActor
struct ReadOnlySourceVaultTests {
    static func setMode(_ root: URL, files: Int16, folders: Int16) throws {
        let fm = FileManager.default
        var all = (fm.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []).map { root.appendingPathComponent($0) }
        all.append(root)
        let locking = files & 0o200 == 0
        // Locking: children before their folder; unlocking: folders first.
        for url in all.sorted(by: { locking ? $0.path.count > $1.path.count : $0.path.count < $1.path.count }) {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            try fm.setAttributes([.posixPermissions: NSNumber(value: isDir.boolValue ? folders : files)], ofItemAtPath: url.path)
        }
    }

    static func readOnlyFixture() throws -> (vault: URL, key: String) {
        let (vault, key) = try AppModelTests.fixtureVault()
        try setMode(vault, files: 0o444, folders: 0o555)
        return (vault, try String(contentsOf: key, encoding: .utf8))
    }

    static func model() -> (AppModel, VaultLibrary) {
        let root = TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: MemoryEpochTrustStore())
        model.vaultStore = library.vaultStore
        model.folderWriteDelay = 0.05
        return (model, library)
    }

    /// Copied in once, never kept in sync: the copy is writable, confirming the root and writing work, and no run
    /// ever writes to the folder.
    @Test func aFolderThisAccountCannotWriteIsCopiedInOnce() async throws {
        let (source, key) = try Self.readOnlyFixture()
        defer { try? Self.setMode(source, files: 0o644, folders: 0o755) }
        #expect(!CopyInFollowUp.isWritable(source))
        #expect(CopyInFollowUp.suggested(for: source) == .importOnly)
        let (model, library) = Self.model()
        defer { model.close() }
        try await model.copyIn(picked: source, library: library, followUp: .keepSyncing)
        #expect(model.openVaultTargets.isEmpty, "never a sync target: every run would fail with errno 13")
        let copy = try #require(model.vaultURL)
        #expect(access(copy.appendingPathComponent("vault.json").path, W_OK) == 0)
        #expect(access(copy.appendingPathComponent("notes").path, W_OK) == 0)
        _ = try await model.unlock(identityText: key)
        let root = try Vault.open(at: copy).root
        try await model.confirmVaultRoot(KitRecovery.rootGroups(root).map(\.group).joined(separator: " "))
        _ = try await model.createNote(title: "Mine now", paper: Paper(kind: .ruled), notebook: nil)
        #expect(model.syncSessions.isEmpty)
    }

    /// A target that stops taking writes (made read-only after it was added: the case of build 12's existing target)
    /// says so in words, as the target's problem (review of #124, note 5).
    @Test func aTargetThatRefusesWritesSaysSo() async throws {
        let (vault, key) = try AppModelTests.fixtureVault()
        let (model, library) = Self.model()
        defer { model.close() }
        try await model.copyIn(picked: vault, library: library)
        _ = try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let copy = try #require(model.vaultURL)
        try await model.confirmVaultRoot(KitRecovery.rootGroups(try Vault.open(at: copy).root).map(\.group).joined(separator: " "))
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let id = try #require(model.vault?.vaultId)
        let target = try model.addFolderTarget(drive.appendingPathComponent("Shared.sempere"), scope: drive, to: id)
        await model.syncAllTargetsNow()
        let folder = try #require(target.path.map { URL(fileURLWithPath: $0) })
        try Self.setMode(folder, files: 0o444, folders: 0o555)
        defer { try? Self.setMode(folder, files: 0o644, folders: 0o755) }
        _ = try await model.createNote(title: "Refused there", paper: Paper(kind: .ruled), notebook: nil)
        await model.syncAllTargetsNow()
        let session = try #require(model.syncSessions.first)
        #expect(session.problems.contains { if case .notWritable = $0 { return true } else { return false } },
                "\(session.problems)")
        #expect(!session.headline.contains("errno"), "\(session.headline)")
    }

    /// Adding such a folder as a target is refused, in words.
    @Test func aFolderThisAccountCannotWriteIsNoTarget() async throws {
        let (vault, key) = try AppModelTests.fixtureVault()
        let (model, library) = Self.model()
        defer { model.close() }
        try await model.copyIn(picked: vault, library: library)
        _ = try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let locked = TestTemp.root.appendingPathComponent("locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o555))], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: locked.path) }
        let id = try #require(model.vault?.vaultId)
        #expect(throws: SyncTargetProblem.notWritable("Mine.sempere")) {
            _ = try model.addFolderTarget(locked.appendingPathComponent("Mine.sempere"), scope: locked, to: id)
        }
        #expect(SyncTargetProblem.notWritable("X").description.contains("no permission"))
        #expect(!SyncStatus.text(for: .notWritable(["notes/a"])).contains("errno"))
        // An EPERM on the target (a lapsed grant) has its own words: not "the folder is gone" (re-check of #124).
        #expect(SyncStatus.text(for: .writeGrantLapsed).contains("lost permission"))
        #expect(!SyncStatus.text(for: .writeGrantLapsed).contains("gone"))
    }
}
