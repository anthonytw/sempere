import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// What a folder pick may choose (`PickedFolderRules`; owner's tests of build 10 and 11): vaults and backups
/// themselves choosable, nothing inside one, never a backup as a sync folder, plaintext never into either. The panel
/// that asks these (`MacPanelRules`) and the words for each refusal (`PickersSidebarBackupTests`) are the app's.
struct PickedFolderRulesTests {
    /// A folder with a vault, a backup and a plain folder in it.
    struct Fixture {
        let root: URL, vault: URL, backup: URL, plain: URL
    }

    static func fixture() throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("pickrules-\(UUID().uuidString)", isDirectory: true)
        let vault = root.appendingPathComponent("Wompa.sempere", isDirectory: true)
        let backup = root.appendingPathComponent("Wompa.sempere-backup", isDirectory: true)
        let plain = root.appendingPathComponent("junk", isDirectory: true)
        for dir in [vault.appendingPathComponent("notes"), backup.appendingPathComponent("versions/1"), plain] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Fixture(root: root, vault: vault, backup: backup, plain: plain)
    }

    static let purposes: [PickedFolderRules.Purpose] = [.openVault, .syncFolder, .writeFolder, .exportFolder]

    @Test func whatEachPurposeRefuses() throws {
        let f = try Self.fixture()
        let inside = f.vault.appendingPathComponent("notes")
        // Review of #115 (N2): exports write plaintext, so never into a vault or a backup; a backup goes next to a vault.
        #expect(PickedFolderRules.violation(of: f.vault, for: .exportFolder) == .holderAsExportFolder(name: "Wompa.sempere"))
        #expect(PickedFolderRules.violation(of: f.backup, for: .exportFolder) == .holderAsExportFolder(name: "Wompa.sempere-backup"))
        #expect(PickedFolderRules.violation(of: f.vault, for: .writeFolder) == .vaultAsBackupFolder(name: "Wompa.sempere"))
        #expect(PickedFolderRules.violation(of: f.backup, for: .writeFolder) == nil, "this vault's backup is continued")
        #expect(PickedFolderRules.violation(of: f.backup, for: .syncFolder) == .backupAsSyncFolder(name: "Wompa.sempere-backup"))
        #expect(PickedFolderRules.violation(of: f.plain, for: .syncFolder) == nil)
        #expect(PickedFolderRules.violation(of: f.plain, for: .exportFolder) == nil)
        // Inside a vault: Open Vault says to select the vault itself, the others to choose outside it.
        #expect(PickedFolderRules.violation(of: inside, for: .openVault)
                == .insideHolder(name: "notes", holder: "Wompa.sempere", opening: true))
        #expect(PickedFolderRules.violation(of: inside, for: .syncFolder)
                == .insideHolder(name: "notes", holder: "Wompa.sempere", opening: false))
        // A save: never into a vault or a backup, and never named like one.
        #expect(PickedFolderRules.saveViolation(of: f.plain.appendingPathComponent("a.pdf")) == nil)
        #expect(PickedFolderRules.saveViolation(of: f.vault.appendingPathComponent("a.pdf")) != nil)
        #expect(PickedFolderRules.saveViolation(of: f.backup.appendingPathComponent("a.pdf")) != nil)
        #expect(PickedFolderRules.saveViolation(of: f.plain.appendingPathComponent("x.sempere-backup")) != nil)
    }

    @Test func thePanelEnablesFoldersAndHoldersButNothingInsideThem() throws {
        let f = try Self.fixture()
        for purpose in Self.purposes {
            let takesVault = purpose == .openVault || purpose == .syncFolder
            #expect(PickedFolderRules.canChoose(f.plain, kind: .folder, for: purpose))
            #expect(PickedFolderRules.canChoose(f.vault, kind: .folder, for: purpose) == takesVault,
                    "a vault is chosen as an item, never as a backup or export folder: \(purpose)")
            #expect(!PickedFolderRules.canChoose(f.plain, kind: .file, for: purpose), "never a file")
            #expect(!PickedFolderRules.canChoose(f.vault.appendingPathComponent("notes"), kind: .folder, for: purpose),
                    "nothing inside a vault")
            #expect(!PickedFolderRules.canChoose(f.backup.appendingPathComponent("versions/1"), kind: .folder, for: purpose),
                    "nothing inside a backup")
            // Packages are never chosen as folders (review of #113).
            let library = URL(fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary", isDirectory: true)
            #expect(!PickedFolderRules.canChoose(library, kind: .package, for: purpose))
            #expect(PickedFolderRules.canChoose(f.plain, kind: .unknown, for: purpose), "unknown in the panel: enabled")
            #expect(!PickedFolderRules.canChoose(f.vault.appendingPathComponent("notes"), kind: .unknown, for: purpose),
                    "unknown but inside a vault: greyed out")
        }
        #expect(PickedFolderRules.canChoose(f.backup, kind: .folder, for: .openVault), "a backup opens as a copy")
        #expect(PickedFolderRules.canChoose(f.backup, kind: .folder, for: .writeFolder), "a backup folder takes the backup")
        #expect(!PickedFolderRules.canChoose(f.backup, kind: .folder, for: .syncFolder), "never a sync folder")
        #expect(!PickedFolderRules.canChoose(f.backup, kind: .folder, for: .exportFolder), "plaintext never goes into a backup")
    }

    /// Build 11: iCloud Drive can hold a vault or a backup as a package; it is chosen like the folder it is.
    @Test func aVaultHeldAsAPackageIsAFolder() throws {
        let f = try Self.fixture()
        let bundle = f.root.appendingPathComponent("Foo.app", isDirectory: true)
        #expect(PickedFolderRules.isFolderLike(f.vault, kind: .package))
        #expect(PickedFolderRules.isFolderLike(f.backup, kind: .package))
        #expect(!PickedFolderRules.isFolderLike(bundle, kind: .package))
        // After the pick: only a plain folder (or a holder held as a package) is taken.
        #expect(PickedFolderRules.accepts(.folder, at: f.plain))
        #expect(PickedFolderRules.accepts(.package, at: f.vault))
        #expect(!PickedFolderRules.accepts(.unknown, at: f.plain) && !PickedFolderRules.accepts(.package, at: bundle)
                && !PickedFolderRules.accepts(.file, at: f.plain))
        // The iPhone's picker has no delegate: an unreadable item is left to the code that opens it.
        #expect(PickedFolderRules.acceptsFromDocumentPicker(.unknown, at: f.plain))
        #expect(!PickedFolderRules.acceptsFromDocumentPicker(.package, at: bundle))
        #expect(!PickedFolderRules.acceptsFromDocumentPicker(.file, at: f.plain))
    }
}
