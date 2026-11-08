import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp
import SempereAppCore

/// Owner's test of TestFlight build 10 (iPad): New Vault's Sync With and Sync Targets' Add Folder… listed
/// "junk/Wompa.sempere", but the runs wrote the vault's files straight into "junk". The subfolder was lost when the
/// target was added: `standardizedFileURL` drops `/private` from `/private/var/…` only for a path that exists, so the
/// picked folder and the copy's folder inside it (not made yet) compared as unrelated (`AppModel.subfolder(of:in:)`).
/// These run the real `FolderTargetRun` through the model's sessions.
@MainActor
struct SyncFolderPlacementTests {
    /// A store vault, unlocked, on a device of its own; and an empty folder the user picks, holding one file of theirs.
    static func setUp() async throws -> (FolderTargetAppTests.Device, picked: URL) {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        let device = FolderTargetAppTests.device(nil)
        try await device.model.copyIn(picked: vault, library: device.library)
        try await device.model.unlock(identityText: key)
        let picked = TestTemp.root.appendingPathComponent("junk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: picked.appendingPathComponent("keep.txt"))
        return (device, picked)
    }

    static func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    /// The paths an iPhone or iPad hands over: the picked folder (which exists) standardizes to `/var/…`, the copy's
    /// folder inside it (not made yet) keeps `/private/var/…`. Both still compare as folder and subfolder.
    @Test func theSubfolderSurvivesPrivateVarPaths() {
        let picked = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/junk", isDirectory: true)
        let copy = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/junk/Wompa.sempere",
                       isDirectory: true)
        #expect(AppModel.subfolder(of: copy, in: picked) == "Wompa.sempere")
        #expect(AppModel.subfolder(of: copy.deletingLastPathComponent(), in: picked) == nil)
        #expect(AppModel.samePlace(copy.deletingLastPathComponent(), picked))
        #expect(AppModel.subfolder(of: URL(fileURLWithPath: "/private/tmp/a/b"), in: URL(fileURLWithPath: "/tmp/a")) == "b")
        #expect(AppModel.subfolder(of: URL(fileURLWithPath: "/elsewhere/b"), in: picked) == nil)
        #expect(AppModel.subfolder(of: URL(fileURLWithPath: "/var/mobile/junkyard/x"), in: URL(fileURLWithPath: "/var/mobile/junk"))
                == nil, "a sibling with a longer name is not inside")
    }

    /// Add Folder… on a folder: the vault's files land in `<picked>/<Name>.sempere` and nowhere else in it; the
    /// user's own file there is left as it was.
    @Test func addFolderWritesIntoTheVaultsOwnSubfolder() async throws {
        let (device, picked) = try await Self.setUp()
        defer { device.model.close() }
        let name = device.folder.lastPathComponent
        let target = try device.model.addPickedFolderTarget(picked, to: device.vaultID)
        #expect(target.subfolder == name)
        #expect(target.path == picked.appendingPathComponent(name).standardizedFileURL.path)
        await device.model.syncAllTargetsNow()
        let session = try #require(device.model.syncSessions.first)
        #expect(!session.needsAttention, "\(session.headline)")
        #expect(Self.listing(picked) == ["keep.txt", name].sorted(), "only the vault's folder was added")
        #expect(try String(contentsOf: picked.appendingPathComponent("keep.txt"), encoding: .utf8) == "mine")
        let copy = picked.appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("vault.json").path))
        #expect(!FolderTargetAppTests.noteFiles(copy).isEmpty)
        #expect(FolderTargetAppTests.noteFiles(copy) == FolderTargetAppTests.noteFiles(device.folder))
    }

    /// A picked `.sempere` folder is the target itself; one holding other files and no vault is refused, an empty one
    /// is taken.
    @Test func aPickedSempereFolderIsTheTargetItself() async throws {
        let (device, picked) = try await Self.setUp()
        defer { device.model.close() }
        let name = device.folder.lastPathComponent
        let copy = picked.appendingPathComponent(name)
        let added = try device.model.addPickedFolderTarget(picked, to: device.vaultID)
        await device.model.syncAllTargetsNow()
        try await device.model.removeSyncTarget(added.id, of: device.vaultID)
        let itself = try device.model.addPickedFolderTarget(copy, to: device.vaultID)
        #expect(itself.subfolder == nil && itself.path == copy.standardizedFileURL.path)
        let stray = picked.deletingLastPathComponent().appendingPathComponent("Stray-\(UUID().uuidString).sempere")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        #expect(try AppModel.folderTargetLocation(picked: stray, vaultFolderName: name, vaultId: device.vaultID)
                == stray)
        try Data("x".utf8).write(to: stray.appendingPathComponent("note.txt"))
        #expect(throws: SyncTargetProblem.notAVault(stray.lastPathComponent)) {
            try AppModel.folderTargetLocation(picked: stray, vaultFolderName: name, vaultId: device.vaultID)
        }
    }

    /// Review of #109: a folder inside a vault or a backup is never a sync target: by content (a backup's
    /// `versions/<time>` holds this vault's `vault.json`) and by name (on iOS the app cannot read above a pick).
    @Test func aFolderInsideAVaultOrBackupIsRefused() async throws {
        let (device, picked) = try await Self.setUp()
        defer { device.model.close() }
        let backup = picked.appendingPathComponent("Old Things", isDirectory: true)
        let version = backup.appendingPathComponent("versions/1", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: backup.appendingPathComponent("backup.json"))
        try FileManager.default.copyItem(at: device.folder.appendingPathComponent("vault.json"),
                                         to: version.appendingPathComponent("vault.json"))
        #expect(throws: SyncTargetProblem.insideVault("Old Things")) {
            try device.model.addPickedFolderTarget(version, to: device.vaultID)
        }
        let named = picked.appendingPathComponent("Wompa.sempere-backup/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        #expect(throws: SyncTargetProblem.insideVault("Wompa.sempere-backup")) {
            try device.model.addPickedFolderTarget(named, to: device.vaultID)
        }
        #expect(throws: SyncTargetProblem.isBackup) {
            try device.model.addPickedFolderTarget(named.deletingLastPathComponent(), to: device.vaultID)
        }
        #expect(device.model.openVaultTargets.isEmpty)
        #expect(SyncTargetProblem.insideVault("X.sempere").description.contains("outside it"))
    }

    /// Join This Device needs a sync target: a store vault without one (a backup opened as a copy) does not offer it.
    @Test func joinNeedsASyncTarget() async throws {
        let (device, picked) = try await Self.setUp()
        defer { device.model.close() }
        #expect(device.model.openVaultTargets.isEmpty)
        #expect(!device.model.canJoinOpenVault)
        try device.model.addPickedFolderTarget(picked, to: device.vaultID)
        #expect(device.model.canJoinOpenVault)
    }

    /// Review of #115 (R1): on an iPhone, an iCloud package not downloaded is not on the device as a folder (picked
    /// itself, or listed in the picked folder only as `.<name>.icloud`). It is never taken as a new, empty target (the
    /// first run would make an empty folder of that name over the other devices' package): the app asks iCloud for it
    /// and refuses the pick until it is there.
    @Test func aSyncFolderNotDownloadedIsNeverTakenAsAnEmptyTarget() async throws {
        let (device, picked) = try await Self.setUp()
        defer { device.model.close() }
        let fm = FileManager.default
        let name = device.folder.lastPathComponent
        let requested = RequestedDownloads()
        var hooks = CloudVault.Hooks.live
        hooks.request = { item in requested.add(item.url) }
        device.model.iCloudHooks = hooks
        let before = device.store.targets.targets(of: device.vaultID).count

        // The package picked itself, not on the device.
        let away = picked.appendingPathComponent(name, isDirectory: true)
        #expect(throws: SyncTargetProblem.notDownloaded(name)) {
            _ = try AppModel.folderTargetLocation(picked: away, vaultFolderName: name, vaultId: device.vaultID)
        }
        #expect(throws: SyncTargetProblem.notDownloaded(name)) {
            _ = try device.model.addPickedFolderTarget(away, to: device.vaultID)
        }
        await device.model.pickedDownloadRequest?.value
        #expect(requested.paths == [away.standardizedFileURL.path], "asked iCloud for the package")
        #expect(!fm.fileExists(atPath: away.path), "no folder made")
        #expect(SyncTargetProblem.notDownloaded(name).description.contains("not on this device yet"))

        // Its parent picked, the package listed only as iCloud's stand-in.
        try Data().write(to: picked.appendingPathComponent(".\(name).icloud"))
        #expect(throws: SyncTargetProblem.notDownloaded(name)) {
            _ = try device.model.addPickedFolderTarget(picked, to: device.vaultID)
        }
        await device.model.pickedDownloadRequest?.value
        #expect(requested.paths.last == away.standardizedFileURL.path)
        #expect(!fm.fileExists(atPath: away.path), "no folder made")
        #expect(device.store.targets.targets(of: device.vaultID).count == before, "no target added")

        // Downloaded (an empty package here): taken, picked itself or through its parent.
        try fm.removeItem(at: picked.appendingPathComponent(".\(name).icloud"))
        try fm.createDirectory(at: away, withIntermediateDirectories: true)
        let target = try device.model.addPickedFolderTarget(away, to: device.vaultID)
        #expect(target.path == away.standardizedFileURL.path)
    }
}

/// Review of #115 (F2): New Vault checks its "Sync With" pick before the vault is made, so a pick refused for not being
/// downloaded yet never leaves a new vault without its target. The check writes nothing and asks iCloud for the package.
@MainActor
struct NewVaultSyncPickTests {
    @Test func aSyncFolderNotDownloadedIsRefusedBeforeTheVaultIsMade() async throws {
        let fm = FileManager.default
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let requested = RequestedDownloads()
        var hooks = CloudVault.Hooks.live
        hooks.request = { item in requested.add(item.url) }
        model.iCloudHooks = hooks
        let picked = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: picked, withIntermediateDirectories: true)
        try Data().write(to: picked.appendingPathComponent(".Plans.sempere.icloud"))
        let id = UUID()
        #expect(throws: SyncTargetProblem.notDownloaded("Plans.sempere")) {
            try model.checkPickedFolderTarget(picked, vaultName: "Plans", vaultId: id)
        }
        await model.pickedDownloadRequest?.value
        #expect(requested.paths == [picked.appendingPathComponent("Plans.sempere").standardizedFileURL.path])
        #expect(!fm.fileExists(atPath: picked.appendingPathComponent("Plans.sempere").path), "nothing made")
        // Here now: the pick passes, and still nothing is written by the check.
        try fm.removeItem(at: picked.appendingPathComponent(".Plans.sempere.icloud"))
        try fm.createDirectory(at: picked.appendingPathComponent("Plans.sempere"), withIntermediateDirectories: true)
        try model.checkPickedFolderTarget(picked, vaultName: "Plans", vaultId: id)
        // Another name, no stand-in: fine (the first run makes its folder).
        try model.checkPickedFolderTarget(picked, vaultName: "Other", vaultId: id)
        #expect(!fm.fileExists(atPath: picked.appendingPathComponent("Other.sempere").path))
    }
}

/// The downloads a test's iCloud hooks were asked for (the request runs off the main actor).
final class RequestedDownloads: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var paths: [String] { lock.withLock { urls.map(\.standardizedFileURL.path) } }
}

extension SyncFolderPlacementTests {
    /// Owner's build 12: iCloud vault folders carried the Finder's `kHasBundle` flag, so every device showed them as
    /// packages. The app clears it on the store's vault when it opens and lists it, and on a folder target when it is
    /// added and at each run (`BundleBitRepair`).
    @Test func theBundleBitIsClearedOnTheVaultAndItsSyncFolder() async throws {
        guard Platform.isMac else { return }   // the attribute is set here through the Mac's file system
        let (device, picked) = try await Self.setUp()
        defer { device.model.close() }
        let name = device.folder.lastPathComponent
        let target = picked.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        func setBit(_ url: URL) throws {
            try (url as NSURL).setResourceValue(true, forKey: .isPackageKey)
            #expect(Self.isPackage(url), "set: \(url.lastPathComponent)")
        }
        try setBit(target)
        _ = try device.model.addPickedFolderTarget(picked, to: device.vaultID)
        #expect(!Self.isPackage(target), "cleared when the target was added")

        try setBit(target)
        try setBit(device.folder)
        await device.model.syncAllTargetsNow()
        #expect(!Self.isPackage(target), "cleared by the run")
        #expect(!Self.isPackage(device.folder), "the store's vault too")

        try setBit(device.folder)
        await device.library.refreshStoredVaults()
        #expect(!Self.isPackage(device.folder), "cleared when the store is listed")
    }

    static func isPackage(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
