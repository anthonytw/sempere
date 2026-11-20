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

    /// Any folder that is not a vault's sync folder gets a `<picked>/<name>.sempere-vault`, never the folder itself
    /// (re-check of #113) and never a `….sempere` (iCloud Drive kept those as packages); a name another vault, a backup or
    /// the user's own files took moves on to the next free one; this vault's copy there is the target.
    func testAPlainFolderGetsASyncFolderInside() throws {
        let vault = try makeVault()
        let id = vault.vaultId, other = UUID()
        let drive = try folder("Drive")
        try Data("mine".utf8).write(to: drive.appendingPathComponent("keep.txt"))
        XCTAssertEqual(try location(drive, id), drive.appendingPathComponent("Notes.sempere-vault", isDirectory: true))

        // Its copy there, a real vault.json: the target.
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes.sempere-vault"))
        XCTAssertEqual(try location(drive, id).lastPathComponent, "Notes.sempere-vault")
        // The same name for another vault: the next free name, never into the other vault.
        XCTAssertEqual(try location(drive, other).lastPathComponent, "Notes 2.sempere-vault")
        // A backup named like the sync folder: skipped too; so is a folder of the user's own files of that name.
        let shelf = try folder("Shelf")
        try backup(shelf.appendingPathComponent("Notes.sempere-vault"))
        let mine = try folder("Shelf/Notes 2.sempere-vault")
        try Data("x".utf8).write(to: mine.appendingPathComponent("letter.txt"))
        XCTAssertEqual(try location(shelf, id).lastPathComponent, "Notes 3.sempere-vault")
        // An empty one (Finder's .DS_Store only) is taken.
        let emptyOne = try folder("Empty/Notes.sempere-vault")
        try Data().write(to: emptyOne.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try location(emptyOne.deletingLastPathComponent(), id), emptyOne)
        // A folder not made yet (the CLI's path): `<path>/<name>.sempere-vault` too.
        let fresh = tmp.appendingPathComponent("Fresh", isDirectory: true)
        XCTAssertEqual(try location(fresh, id, missingIsNew: true),
                       fresh.appendingPathComponent("Notes.sempere-vault", isDirectory: true))
        XCTAssertFalse(fm.fileExists(atPath: fresh.path), "nothing is written")
    }

    /// A folder holding this vault is the target itself whatever its name, in the app too (not only the CLI's
    /// `missingIsNew`): a sync folder another device made, a 1.0.0 CLI target synced bare, or one whose `vault.json`
    /// is not downloaded yet (the engine compares ids before a run). Another vault is refused.
    func testAFolderHoldingThisVaultIsTheTargetWhateverItsName() throws {
        let vault = try makeVault()
        let id = vault.vaultId
        for name in ["Bare", "Notes.sempere-vault", "v1.2 4.sempere-vault", "Anything.zip"] {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try fm.copyItem(at: vault.url, to: dir)
            XCTAssertEqual(try location(dir, id), dir, name)
            XCTAssertEqual(try location(dir, id, missingIsNew: true), dir, name)
            XCTAssertEqual(refusal(dir, UUID()), .otherVault(VaultStore.displayName(of: dir)), name)
        }
        let unread = try folder("Unread")
        try Data().write(to: unread.appendingPathComponent(".vault.json.icloud"))
        XCTAssertEqual(try location(unread, UUID()), unread, "the engine compares ids before a run")
        // A `vault.json` that is no manifest (some other tool's file): the target only in a folder named like a sync
        // folder (`….sempere-vault`, `….sempere`); any other folder holding one is refused, never the target (every run would fail) nor nested into.
        let garbled = try folder("Garbled")
        try Data("not json".utf8).write(to: garbled.appendingPathComponent("vault.json"))
        XCTAssertEqual(FolderTargetPlacement.holdsVault(garbled, id), .unreadable)
        XCTAssertEqual(refusal(garbled, id), .otherVault("Garbled"))
        let torn = try folder("Torn/Notes.sempere-vault")
        try Data("not json".utf8).write(to: torn.appendingPathComponent("vault.json"))
        XCTAssertEqual(try location(torn, id), torn)
        let tornOld = try folder("Torn/Old.sempere")
        try Data("not json".utf8).write(to: tornOld.appendingPathComponent("vault.json"))
        XCTAssertEqual(try location(tornOld, id), tornOld)
        // A sync folder picked itself whose files have not arrived (empty), or the CLI's path to one not made yet.
        let arriving = try folder("Drive/Notes.sempere-vault")
        XCTAssertEqual(try location(arriving, id), arriving)
        let notYet = tmp.appendingPathComponent("Later/Notes.sempere-vault", isDirectory: true)
        XCTAssertEqual(try location(notYet, id, missingIsNew: true), notYet)
        // One holding the user's own files is named like a vault but is none: refused, as a `….sempere` is.
        let used = try folder("Used/Notes.sempere-vault")
        try Data("x".utf8).write(to: used.appendingPathComponent("letter.txt"))
        XCTAssertEqual(refusal(used, id), .notAVault("Notes.sempere-vault"))
        // A name of no extension that looks like a sync folder's (`… Sempere Vault`, which no release made) means nothing: such a folder is just a folder, and gets
        // the copy inside, unless it holds this vault (found by its content, above).
        let oldPlain = try folder("Older/Notes Sempere Vault")
        XCTAssertEqual(try location(oldPlain, id), oldPlain.appendingPathComponent("Notes.sempere-vault", isDirectory: true))
        try Data("not json".utf8).write(to: oldPlain.appendingPathComponent("vault.json"))
        XCTAssertEqual(refusal(oldPlain, id), .otherVault("Notes Sempere Vault"), "no name rule takes an unreadable one")
    }

    /// Existing targets keep working unchanged: an older build's `<name>.sempere` copy of this vault in the picked folder
    /// is joined (devices meet in one folder), a `….sempere-vault` copy wins over it, and a `….sempere` picked itself is
    /// the target.
    func testExistingSempereTargetsAreJoined() throws {
        let vault = try makeVault()
        let id = vault.vaultId
        let drive = try folder("Drive")
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes.sempere"))
        XCTAssertEqual(try location(drive, id).lastPathComponent, "Notes.sempere")
        XCTAssertEqual(try location(drive.appendingPathComponent("Notes.sempere"), id).lastPathComponent, "Notes.sempere")
        // Another vault's `.sempere` there: never joined, the new copy is a `….sempere-vault`.
        XCTAssertEqual(try location(drive, UUID()).lastPathComponent, "Notes.sempere-vault")
        // `Notes 2.sempere` (an older build's next free name) holding this vault behind another vault's `Notes.sempere`.
        let shelf = try folder("Shelf")
        try manifest(shelf.appendingPathComponent("Notes.sempere"), UUID())
        try fm.copyItem(at: vault.url, to: shelf.appendingPathComponent("Notes 2.sempere"))
        XCTAssertEqual(try location(shelf, id).lastPathComponent, "Notes 2.sempere")
        // An empty `Notes.sempere` is not this vault's copy: the new one is a `….sempere-vault`.
        let bare = try folder("Bare")
        _ = try folder("Bare/Notes.sempere")
        XCTAssertEqual(try location(bare, id).lastPathComponent, "Notes.sempere-vault")
        // Both kinds holding this vault: the `….sempere-vault`.
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes 2.sempere-vault"))
        XCTAssertEqual(try location(drive, id).lastPathComponent, "Notes 2.sempere-vault")
    }

    /// Review of build 112: devices whose store copies are named differently (`Notes` here, `Notes 2` on a device where
    /// that name was taken) pick the same folder and must meet in one copy: the picked folder's entries are listed and a
    /// folder holding this vault's id is joined whatever its name, never another vault's, never one whose `vault.json` is
    /// only a stand-in or unreadable; two copies with no name to prefer are refused.
    func testThisVaultsCopyIsFoundWhateverItsName() throws {
        let vault = try makeVault()
        let id = vault.vaultId
        let drive = try folder("Drive")
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes.sempere-vault"))
        XCTAssertEqual(try location(drive, id, name: "Notes 2.sempere").lastPathComponent, "Notes.sempere-vault")
        XCTAssertEqual(try location(drive, id, name: "Notes 2.sempere", missingIsNew: true).lastPathComponent,
                       "Notes.sempere-vault")
        // An older build's `….sempere` of another name, and a bare folder of any name: joined too.
        let shelf = try folder("Shelf")
        try fm.copyItem(at: vault.url, to: shelf.appendingPathComponent("Work.sempere"))
        XCTAssertEqual(try location(shelf, id).lastPathComponent, "Work.sempere")
        let box = try folder("Box")
        try fm.copyItem(at: vault.url, to: box.appendingPathComponent("Old Stuff"))
        XCTAssertEqual(try location(box, id).lastPathComponent, "Old Stuff")
        // A `….sempere-vault` before a `….sempere` before any other name.
        try fm.copyItem(at: vault.url, to: box.appendingPathComponent("Old Stuff.sempere"))
        XCTAssertEqual(try location(box, id).lastPathComponent, "Old Stuff.sempere")
        try fm.copyItem(at: vault.url, to: box.appendingPathComponent("Old Stuff.sempere-vault"))
        XCTAssertEqual(try location(box, id).lastPathComponent, "Old Stuff.sempere-vault")

        // Two copies of the same kind: refused, nothing picked for the user.
        try fm.copyItem(at: vault.url, to: drive.appendingPathComponent("Notes 2.sempere-vault"))
        XCTAssertEqual(refusal(drive, id), .severalCopies(["Notes 2.sempere-vault", "Notes.sempere-vault"]))
        // Either picked itself is taken.
        XCTAssertEqual(try location(drive.appendingPathComponent("Notes 2.sempere-vault"), id).lastPathComponent,
                       "Notes 2.sempere-vault")

        // Never another vault's folder, a backup, a hidden folder, a stand-in or an unreadable manifest of another name.
        let mixed = try folder("Mixed")
        try manifest(mixed.appendingPathComponent("Other.sempere-vault"), UUID())
        try manifest(mixed.appendingPathComponent(".Hidden"), id)
        let shelved = mixed.appendingPathComponent("Shelved")
        try manifest(shelved, id)
        try Data("{}".utf8).write(to: shelved.appendingPathComponent("backup.json"))
        let away = try folder("Mixed/Away.sempere-vault")
        try Data().write(to: away.appendingPathComponent(".vault.json.icloud"))
        let junk = try folder("Mixed/Junk")
        try Data("not json".utf8).write(to: junk.appendingPathComponent("vault.json"))
        XCTAssertEqual(try location(mixed, id, name: "Notes 2.sempere").lastPathComponent, "Notes 2.sempere-vault")
        // This device's own name with its `vault.json` not downloaded yet is still taken (the engine compares ids).
        XCTAssertEqual(try location(mixed, id, name: "Away.sempere").lastPathComponent, "Away.sempere-vault")
    }

    /// The name is `<vault>.sempere-vault`: the extension is the last component, whatever dots the vault's name holds,
    /// it stays a valid folder name, and the store's `.sempere` (or a backup's `.sempere-backup`) is never kept in it.
    func testSyncFolderNames() throws {
        let cases: [(String, String)] = [
            ("Notes.sempere", "Notes.sempere-vault"), ("v1.2", "v1.2.sempere-vault"), ("v1.2.sempere", "v1.2.sempere-vault"),
            ("Photos.app", "Photos.app.sempere-vault"), ("Work.sempere-backup", "Work.sempere-vault"),
            ("Again.sempere-vault", "Again.sempere-vault"), (".hidden", "hidden.sempere-vault"), ("a/b:c", "a-b-c.sempere-vault"),
            ("", "Notes.sempere-vault"),
        ]
        for (vault, expected) in cases {
            let name = SyncFolderName.name(forVault: vault)
            XCTAssertEqual(name, expected, vault)
            XCTAssertTrue(SyncFolderName.isSyncFolderName(URL(fileURLWithPath: "/x/\(name)")), name)
            XCTAssertEqual(URL(fileURLWithPath: "/x/\(name)").pathExtension, "sempere-vault", name)
        }
        XCTAssertEqual(SyncFolderName.name(forVault: "v1.2", 7), "v1.2 7.sempere-vault")
        let long = SyncFolderName.name(forVault: String(repeating: "é", count: 200), 100)
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertEqual(VaultStore.displayName(of: URL(fileURLWithPath: "/x/v1.2.sempere-vault")), "v1.2")
        XCTAssertEqual(VaultStore.displayName(of: URL(fileURLWithPath: "/x/Notes 2.sempere-vault")), "Notes 2")
        XCTAssertEqual(VaultStore.displayName(of: URL(fileURLWithPath: "/x/Notes Sempere Vault")), "Notes Sempere Vault",
                       "no suffix but the extensions is cut")
        XCTAssertFalse(SyncFolderName.isSyncFolderName(URL(fileURLWithPath: "/x/Notes.sempere")))
        XCTAssertTrue(SyncFolderName.isSyncFolderName(URL(fileURLWithPath: "/x/Notes.SEMPERE-VAULT")))
        XCTAssertTrue(BackupDestination.isVaultName(URL(fileURLWithPath: "/x/Notes.sempere-vault")))
        XCTAssertTrue(BackupDestination.isVaultName(URL(fileURLWithPath: "/x/Notes.sempere")))
        XCTAssertFalse(BackupDestination.isVaultName(URL(fileURLWithPath: "/x/Notes.sempere-backup")))
        XCTAssertFalse(BackupDestination.isVaultName(URL(fileURLWithPath: "/x/Notes Sempere Vault")))
        XCTAssertFalse(BackupDestination.isHolderName(URL(fileURLWithPath: "/x/Notes Sempere Vault 2")))
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
        XCTAssertEqual(FolderTargetPlacement.holdsVault(evicted, id), .notDownloaded)
        // A folder of another name holding another vault: refused, not a subfolder beside it.
        let bare = try folder("Bare")
        try manifest(bare, UUID())
        XCTAssertEqual(refusal(bare, id), .otherVault("Bare"))

        // A `….sempere-vault` picked itself follows the same rules.
        let mine = tmp.appendingPathComponent("Drive/sample.sempere-vault", isDirectory: true)
        try fm.copyItem(at: vault.url, to: mine)
        XCTAssertEqual(try location(mine, id), mine)
        XCTAssertEqual(refusal(mine, UUID()), .otherVault("sample"))
        let emptySync = try folder("Empty.sempere-vault")
        XCTAssertEqual(try location(emptySync, id), emptySync)
        let straySync = try folder("Stray.sempere-vault")
        try Data("x".utf8).write(to: straySync.appendingPathComponent("note.txt"))
        XCTAssertEqual(refusal(straySync, id), .notAVault("Stray.sempere-vault"))
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
        XCTAssertEqual(refusal(try folder("Shut.sempere-vault/notes"), id), .insideVault("Shut.sempere-vault"), "by name")
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

        // The same for a `….sempere-vault`, picked itself or listed only as its stand-in in the picked folder.
        let cloud = try folder("Cloud")
        let gone = cloud.appendingPathComponent("Notes.sempere-vault", isDirectory: true)
        XCTAssertEqual(refusal(gone, id), .notDownloaded("Notes.sempere-vault"))
        XCTAssertEqual(try location(gone, id, missingIsNew: true), gone)
        try Data().write(to: cloud.appendingPathComponent(".Notes.sempere-vault.icloud"))
        XCTAssertEqual(refusal(gone, id, missingIsNew: true), .notDownloaded("Notes.sempere-vault"))
        XCTAssertEqual(refusal(cloud, id), .notDownloaded("Notes.sempere-vault"), "its parent picked")
        XCTAssertFalse(fm.fileExists(atPath: gone.path), "no folder made")
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
        XCTAssertEqual(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/v1.2.sempere-vault/notes"))?
            .lastPathComponent, "v1.2.sempere-vault")
        XCTAssertNil(BackupDestination.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/Notes Sempere Vault/notes")),
                     "only the extensions name a vault")
        XCTAssertTrue(BackupDestination.isHolderName(URL(fileURLWithPath: "/a/B.SEMPERE")))
        XCTAssertTrue(BackupDestination.isHolderName(URL(fileURLWithPath: "/a/B.Sempere-Vault")))
        XCTAssertFalse(BackupDestination.isHolderName(URL(fileURLWithPath: "/a/B.sempere.zip")))
    }
}
