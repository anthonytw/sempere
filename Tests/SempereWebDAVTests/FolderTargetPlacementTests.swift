import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// Where a vault's sync copy goes for a folder the user named (`FolderTargetPlacement.location`): the one rule the app's
/// New Vault "Sync With", "Add Folder…", "Choose Again…" and "Keep syncing", and the CLI's `store target add --folder`
/// and `store import --keep-syncing` share (docs/design/thin-app.md, duplicate 2). Its refusals are typed values; the
/// app's words for them are in `SyncTargetProblem`, the CLI's in `CLIError.from`.
final class FolderTargetPlacementTests: SyncTestCase {
    private let fm = FileManager.default

    private func folder(_ path: String) throws -> URL {
        let url = tmp.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `vault.json` naming `id` (all the rule reads of it).
    private func manifest(_ dir: URL, _ id: UUID) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"vaultId":"\#(id.uuidString.lowercased())"}"#.utf8).write(to: dir.appendingPathComponent("vault.json"))
    }

    private func backup(_ dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("backup.json"))
    }

    private func location(_ picked: URL, _ id: UUID, name: String = "Notes.sempere", missingIsNew: Bool = false) throws -> URL {
        try FolderTargetPlacement.location(picked: picked, vaultFolderName: name, vaultId: id, missingIsNew: missingIsNew)
    }

    private func refusal(_ picked: URL, _ id: UUID, missingIsNew: Bool = false) -> FolderPlacementProblem? {
        do { _ = try location(picked, id, missingIsNew: missingIsNew); return nil } catch {
            return error as? FolderPlacementProblem
        }
    }

    /// Any folder that is not a vault's sync folder gets a plain `<picked>/<name> Sempere Vault`, never the folder itself
    /// (re-check of #113) and never a `….sempere` (iCloud Drive kept those as packages); a name another vault, a backup or
    /// the user's own files took moves on to the next free one; this vault's copy there is the target.
    func testAPlainFolderGetsAPlainSubfolder() throws {
        let vault = try makeVault()
        let id = vault.vaultId, other = UUID()
        let drive = try folder("Drive")
        try Data("mine".utf8).write(to: drive.appendingPathComponent("keep.txt"))
        XCTAssertEqual(try location(drive, id), drive.appendingPathComponent("Notes Sempere Vault", isDirectory: true))

        // Its copy there, a real vault.json: the target.
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes Sempere Vault"))
        XCTAssertEqual(try location(drive, id).lastPathComponent, "Notes Sempere Vault")
        // The same name for another vault: the next free name, never into the other vault.
        XCTAssertEqual(try location(drive, other).lastPathComponent, "Notes Sempere Vault 2")
        // A backup named like the sync folder: skipped too; so is a folder of the user's own files of that name.
        let shelf = try folder("Shelf")
        try backup(shelf.appendingPathComponent("Notes Sempere Vault"))
        let mine = try folder("Shelf/Notes Sempere Vault 2")
        try Data("x".utf8).write(to: mine.appendingPathComponent("letter.txt"))
        XCTAssertEqual(try location(shelf, id).lastPathComponent, "Notes Sempere Vault 3")
        // An empty one (Finder's .DS_Store only) is taken.
        let emptyOne = try folder("Empty/Notes Sempere Vault")
        try Data().write(to: emptyOne.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try location(emptyOne.deletingLastPathComponent(), id), emptyOne)
        // A folder not made yet (the CLI's path): `<path>/<name> Sempere Vault` too.
        let fresh = tmp.appendingPathComponent("Fresh", isDirectory: true)
        XCTAssertEqual(try location(fresh, id, missingIsNew: true),
                       fresh.appendingPathComponent("Notes Sempere Vault", isDirectory: true))
        XCTAssertFalse(fm.fileExists(atPath: fresh.path), "nothing is written")
    }

    /// A folder holding this vault is the target itself whatever its name, in the app too (not only the CLI's
    /// `missingIsNew`): a plain sync folder another device made, a 1.0.0 CLI target synced bare, or one whose `vault.json`
    /// is not downloaded yet (the engine compares ids before a run). Another vault is refused.
    func testAFolderHoldingThisVaultIsTheTargetWhateverItsName() throws {
        let vault = try makeVault()
        let id = vault.vaultId
        for name in ["Bare", "Notes Sempere Vault", "v1.2 Sempere Vault 4", "Anything.zip"] {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try fm.copyItem(at: vault.url, to: dir)
            XCTAssertEqual(try location(dir, id), dir, name)
            XCTAssertEqual(try location(dir, id, missingIsNew: true), dir, name)
            XCTAssertEqual(refusal(dir, UUID()), .otherVault(VaultStore.displayName(of: dir)), name)
        }
        let unread = try folder("Unread")
        try Data().write(to: unread.appendingPathComponent(".vault.json.icloud"))
        XCTAssertEqual(try location(unread, UUID()), unread, "the engine compares ids before a run")
        let garbled = try folder("Garbled")
        try Data("not json".utf8).write(to: garbled.appendingPathComponent("vault.json"))
        XCTAssertEqual(try location(garbled, id), garbled)
        // A plain sync folder picked itself whose files have not arrived (empty), or the CLI's path to one not made yet.
        let arriving = try folder("Drive/Notes Sempere Vault")
        XCTAssertEqual(try location(arriving, id), arriving)
        let notYet = tmp.appendingPathComponent("Later/Notes Sempere Vault", isDirectory: true)
        XCTAssertEqual(try location(notYet, id, missingIsNew: true), notYet)
        // One holding the user's own files is just a folder: the copy goes inside.
        let used = try folder("Used/Notes Sempere Vault")
        try Data("x".utf8).write(to: used.appendingPathComponent("letter.txt"))
        XCTAssertEqual(try location(used, id), used.appendingPathComponent("Notes Sempere Vault", isDirectory: true))
    }

    /// Existing targets keep working unchanged: an older build's `<name>.sempere` copy of this vault in the picked folder
    /// is joined (devices meet in one folder), a plain copy wins over it, and a `….sempere` picked itself is the target.
    func testExistingSempereTargetsAreJoined() throws {
        let vault = try makeVault()
        let id = vault.vaultId
        let drive = try folder("Drive")
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes.sempere"))
        XCTAssertEqual(try location(drive, id).lastPathComponent, "Notes.sempere")
        XCTAssertEqual(try location(drive.appendingPathComponent("Notes.sempere"), id).lastPathComponent, "Notes.sempere")
        // Another vault's `.sempere` there: never joined, the new copy is plain.
        XCTAssertEqual(try location(drive, UUID()).lastPathComponent, "Notes Sempere Vault")
        // `Notes 2.sempere` (an older build's next free name) holding this vault behind another vault's `Notes.sempere`.
        let shelf = try folder("Shelf")
        try manifest(shelf.appendingPathComponent("Notes.sempere"), UUID())
        try fm.copyItem(at: vault.url, to: shelf.appendingPathComponent("Notes 2.sempere"))
        XCTAssertEqual(try location(shelf, id).lastPathComponent, "Notes 2.sempere")
        // An empty `Notes.sempere` is not this vault's copy: the new one is plain.
        let bare = try folder("Bare")
        _ = try folder("Bare/Notes.sempere")
        XCTAssertEqual(try location(bare, id).lastPathComponent, "Notes Sempere Vault")
        // Both kinds holding this vault: the plain one.
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes Sempere Vault 2"))
        XCTAssertEqual(try location(drive, id).lastPathComponent, "Notes Sempere Vault 2")
    }

    /// The plain name never ends in anything a system could take for an extension, whatever dots the vault's name holds,
    /// stays a valid folder name, and is recognized (and its vault name recovered) by shape.
    func testPlainNamesHaveNoExtension() throws {
        let cases: [(String, String)] = [
            ("Notes.sempere", "Notes Sempere Vault"), ("v1.2", "v1.2 Sempere Vault"), ("v1.2.sempere", "v1.2 Sempere Vault"),
            ("Photos.app", "Photos.app Sempere Vault"), ("Work.sempere-backup", "Work Sempere Vault"),
            (".hidden", "hidden Sempere Vault"), ("a/b:c", "a-b-c Sempere Vault"), ("", "Notes Sempere Vault"),
        ]
        for (vault, expected) in cases {
            let name = SyncFolderName.name(forVault: vault)
            XCTAssertEqual(name, expected, vault)
            XCTAssertFalse(SyncFolderName.hasTypeExtension(name), name)
            XCTAssertFalse(SyncFolderName.hasTypeExtension(SyncFolderName.name(forVault: vault, 7)), name)
            XCTAssertTrue(SyncFolderName.isPlainName(name), name)
            #if canImport(Darwin)
            XCTAssertEqual(URL(fileURLWithPath: "/x/\(name)").pathExtension, "", name)
            #endif
        }
        let long = SyncFolderName.name(forVault: String(repeating: "é", count: 200), 100)
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertEqual(SyncFolderName.vaultName(fromPlainName: "v1.2 Sempere Vault 12"), "v1.2")
        XCTAssertEqual(VaultStore.displayName(of: URL(fileURLWithPath: "/x/v1.2 Sempere Vault")), "v1.2")
        XCTAssertEqual(VaultStore.displayName(of: URL(fileURLWithPath: "/x/My Sempere Vault.sempere")), "My Sempere Vault",
                       "a store vault's own name is never cut further")
        for name in ["Sempere Vault", " Sempere Vault", "Notes Sempere Vault 1", "Notes Sempere Vault 02", "Notes Sempere Vaults",
                     "Notes Sempere Vault x", "Notes Sempere Vault 1000"] {
            XCTAssertFalse(SyncFolderName.isPlainName(name), name)
        }
        XCTAssertTrue(SyncFolderName.hasTypeExtension("Notes.sempere"))
        XCTAssertTrue(SyncFolderName.hasTypeExtension("Foo.app"))
        XCTAssertFalse(SyncFolderName.hasTypeExtension(".hidden"))
        XCTAssertTrue(BackupDestination.isHolderName(URL(fileURLWithPath: "/x/Notes Sempere Vault 2")))
        XCTAssertTrue(BackupDestination.isVaultName(URL(fileURLWithPath: "/x/Notes Sempere Vault")))
        XCTAssertEqual(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/x/Notes Sempere Vault/notes"))?
            .lastPathComponent, "Notes Sempere Vault")
    }

    /// TestFlight 1.0.0 (9): a picked `….sempere` folder is the target only when it is THIS vault's, empty, or its
    /// `vault.json` not downloaded yet (the engine compares ids before writing); another vault's is refused by name, one
    /// holding other files is no vault.
    func testAVaultFolderPickedItself() throws {
        let vault = try makeVault()
        let id = vault.vaultId
        let own = tmp.appendingPathComponent("Drive/sample.sempere", isDirectory: true)
        try fm.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: vault.url, to: own)
        XCTAssertEqual(try location(own, id), own)
        XCTAssertEqual(refusal(own, UUID()), .otherVault("sample"))

        let empty = try folder("Empty.sempere")
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try location(empty, id), empty)
        let stray = try folder("Stray.sempere")
        try Data("x".utf8).write(to: stray.appendingPathComponent("note.txt"))
        XCTAssertEqual(refusal(stray, id), .notAVault("Stray.sempere"))
        let evicted = try folder("Evicted.sempere")
        try Data().write(to: evicted.appendingPathComponent(".vault.json.icloud"))
        XCTAssertEqual(try location(evicted, UUID()), evicted)
        XCTAssertEqual(FolderTargetPlacement.holdsVault(evicted, id), .unknown)
        // A folder of another name holding another vault: refused, not a subfolder beside it.
        let bare = try folder("Bare")
        try manifest(bare, UUID())
        XCTAssertEqual(refusal(bare, id), .otherVault("Bare"))
    }

    /// Review of #108 and #109: a backup is never a sync target, by content or by name, and neither is any folder
    /// inside a vault or a backup (by content: a backup's `versions/<time>` holds this vault's `vault.json`; by name:
    /// on iOS the app cannot read above a pick).
    func testBackupsAndFoldersInsideHoldersAreRefused() throws {
        let id = UUID()
        let old = tmp.appendingPathComponent("Old Things", isDirectory: true)
        try backup(old)
        XCTAssertEqual(refusal(old, id), .isBackup)
        XCTAssertEqual(refusal(try folder("Wompa.sempere-backup"), id), .isBackup)
        let version = try folder("Old Things/versions/1")
        try manifest(version, id)
        XCTAssertEqual(refusal(version, id), .insideVault("Old Things"))
        XCTAssertEqual(refusal(try folder("Named.sempere-backup/inner"), id), .insideVault("Named.sempere-backup"))
        XCTAssertEqual(refusal(try folder("Shut.sempere/notes"), id), .insideVault("Shut.sempere"))
        XCTAssertEqual(refusal(try folder("Shut Sempere Vault/notes"), id), .insideVault("Shut Sempere Vault"), "by name")
        let inVault = try folder("Plain")
        try manifest(inVault, id)
        XCTAssertEqual(refusal(try folder("Plain/sub"), id), .insideVault("Plain"))
    }

    /// Review of #115 (R1): a `….sempere` not on this device (an iCloud package not downloaded, picked itself or listed
    /// only as `.<name>.icloud`) is never taken as a new, empty target. The CLI's path to a folder not made yet is the
    /// target, unless iCloud's stand-in for it is there.
    func testASyncFolderNotDownloaded() throws {
        let id = UUID()
        let drive = try folder("Drive")
        let away = drive.appendingPathComponent("Notes.sempere", isDirectory: true)
        XCTAssertEqual(refusal(away, id), .notDownloaded("Notes.sempere"))
        XCTAssertEqual(try location(away, id, missingIsNew: true), away)
        try Data().write(to: drive.appendingPathComponent(".Notes.sempere.icloud"))
        XCTAssertEqual(refusal(away, id, missingIsNew: true), .notDownloaded("Notes.sempere"))
        XCTAssertEqual(refusal(drive, id), .notDownloaded("Notes.sempere"), "its parent picked")
        XCTAssertEqual(refusal(drive, id, missingIsNew: true), .notDownloaded("Notes.sempere"))
        XCTAssertFalse(fm.fileExists(atPath: away.path), "no folder made")
    }

    /// What lies above a pick goes by name where the app cannot read: `….sempere` and `….sempere-backup`, whatever
    /// dots the name holds, and never an app's container (the Mac app's own is named like a vault).
    func testEnclosingHoldersByName() {
        XCTAssertNil(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath:
            "/Users/me/Library/Containers/io.github.anthonytw.sempere/Data/tmp/junk")))
        XCTAssertNil(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath:
            "/private/var/mobile/Containers/Shared/AppGroup/group.io.github.anthonytw.sempere/Vaults")))
        XCTAssertEqual(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/v1.2 notes.sempere/x"))?
            .lastPathComponent, "v1.2 notes.sempere")
        XCTAssertEqual(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/Notes.2026.sempere/x"))?
            .lastPathComponent, "Notes.2026.sempere")
        XCTAssertEqual(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/My.Work.sempere-backup/versions"))?
            .lastPathComponent, "My.Work.sempere-backup")
        XCTAssertNil(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/Notes.sempere")),
                     "never the folder itself")
        XCTAssertTrue(BackupDestination.isHolderName(URL(fileURLWithPath: "/a/B.SEMPERE")))
        XCTAssertFalse(BackupDestination.isHolderName(URL(fileURLWithPath: "/a/B.sempere.zip")))
    }
}
