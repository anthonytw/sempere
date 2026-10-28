import Foundation
import Sempere
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SempereApp

/// TestFlight 1.0.0 (6) owner reports: the Inbox among the special lists, Move to Top Level in a
/// nested notebook's menu, Verify Backup's capped problem list, the backup failure alert, the
/// passphrase pair AutoFill fills together, and the Mac's folder panel with New Folder.
@MainActor
struct PickersSidebarBackupTests {
    // MARK: - Sidebar

    @Test func theInboxIsListedApartFromTheNotebooks() {
        let tree = NotebookNode.tree(["Inbox", "Inbox/Later", "School/Math", "Personal"])
        let sections = SidebarSections(tree: tree)
        #expect(sections.inbox?.path == "Inbox")
        #expect(sections.inbox?.children.map(\.path) == ["Inbox/Later"], "its sub-notebooks stay with it")
        #expect(sections.notebooks.map(\.path) == ["Personal", "School"])
    }

    @Test func onlyATopLevelInboxIsSpecial() {
        let sections = SidebarSections(tree: NotebookNode.tree(["School/Inbox", "Work"]))
        #expect(sections.inbox == nil)
        #expect(sections.notebooks.map(\.path) == ["School", "Work"])
        let none = SidebarSections(tree: [])
        #expect(none.inbox == nil && none.notebooks.isEmpty)
    }

    @Test func aNestedNotebookOffersMoveToTopLevel() {
        let plain = NotebookRowAction.notebookMenu(newInside: {}, rename: {}, move: {}, export: {})
        #expect(!plain.map(\.title.key).contains("Move to Top Level"))
        let nested = NotebookRowAction.notebookMenu(newInside: {}, rename: {}, move: {}, moveToTop: {}, export: {})
        #expect(nested.map(\.title.key) == ["New Notebook Inside…", "Rename or Move…", "Move Notebook To…", "Move to Top Level",
                                            "Export Notebook…"])
    }

    /// The drop on the Notebooks header is a drop on the top level: a nested notebook may go there,
    /// a top-level one may not (it is there already).
    @Test func theTopLevelTakesANestedNotebookOnly() {
        #expect(SidebarDrop.accepts(.notebook("School/Math"), on: .topLevel, notes: []))
        #expect(!SidebarDrop.accepts(.notebook("School"), on: .topLevel, notes: []))
        #expect(NotebookPath.moved("School/Math/Algebra", into: nil) == "Algebra")
    }

    // MARK: - Backups

    @Test func verifyListsAtMostTheLimitThenCounts() {
        let few = (1...3).map { "missing  notes/\($0)" }
        #expect(BackupText.problemList(few).shown == few)
        #expect(BackupText.problemList(few).more == 0)
        let many = (1...2_500).map { "missing  notes/\($0)" }
        let list = BackupText.problemList(many)
        #expect(list.shown.count == BackupText.problemLimit)
        #expect(list.shown.first == many.first)
        #expect(list.more == 2_500 - BackupText.problemLimit)
        #expect(BackupText.problemList(many, limit: 0).more == 2_500)
    }

    @Test func aFolderProblemAndARunFailureHaveTheirOwnTitles() {
        let folder = BackupFailure(kind: .folder, message: BackupLocation.Problem.otherVaultsBackup("Drive").description)
        #expect(folder.title == "Choose Another Backup Folder")
        #expect(folder.message.contains("another vault"))
        #expect(BackupFailure(kind: .run, message: "x").title == "Backup Failed")
    }

    // MARK: - Passphrase pair

    /// Both fields of the pair are `.newPassword` with the same rules, siblings in one stack, the new
    /// passphrase first: the shape AutoFill's Strong Password fills as a pair.
    @Test func thePassphrasePairIsOneFormForAutoFill() throws {
        let stack = PassphrasePairTextFields.makeStack(placeholders: ["Passphrase", "Repeat passphrase"], texts: ["", ""],
                                                       revealed: false,
                                                       identifiers: ["newVault.passphrase", "newVault.confirmation"])
        let fields = PassphrasePairTextFields.fields(of: stack)
        #expect(fields.map(\.accessibilityIdentifier) == ["newVault.passphrase", "newVault.confirmation"])
        for field in fields {
            #expect(field.textContentType == .newPassword)
            #expect(field.passwordRules?.passwordRulesDescriptor == PassphraseTextFieldSetup.rules)
            #expect(field.isSecureTextEntry)
            #expect(field.superview === stack)
        }
        // Shown: plain text in both, the text kept.
        fields[0].text = "abc"
        PassphraseTextFieldSetup.update(fields[0], text: "abc", revealed: true, placeholder: "Passphrase")
        #expect(!fields[0].isSecureTextEntry)
        #expect(fields[0].text == "abc")
    }

    /// TestFlight build 8 (iPad): Strong Password filled only the first field. UIKit, not the app, takes a fill
    /// of an empty field or of all its text, and a field filled without an editing event keeps what was put
    /// there (the binding takes it) instead of being reset to the binding's old value.
    @Test func autoFillOfTheConfirmationIsKept() async throws {
        #expect(!PassphraseFieldCoordinator.appliesEditItself(secure: true, composing: false, length: 0,
                                                               range: NSRange(location: 0, length: 0)), "an empty field: UIKit's")
        #expect(!PassphraseFieldCoordinator.appliesEditItself(secure: true, composing: false, length: 5,
                                                               range: NSRange(location: 0, length: 5)), "all of it: UIKit's")
        #expect(PassphraseFieldCoordinator.appliesEditItself(secure: true, composing: false, length: 5,
                                                              range: NSRange(location: 5, length: 0)), "a key at the end")
        #expect(!PassphraseFieldCoordinator.appliesEditItself(secure: false, composing: false, length: 5,
                                                               range: NSRange(location: 5, length: 0)))

        var confirmation = ""
        let binding = Binding(get: { confirmation }, set: { confirmation = $0 })
        let coordinator = PassphraseFieldCoordinator(text: binding, onSubmit: nil)
        let field = PassphraseTextFieldSetup.makeField(placeholder: "Repeat", text: "", revealed: false,
                                                       contentType: .newPassword, identifier: "c")
        coordinator.attach(field)
        field.text = "Abcd-efgh-ijkl-mn12"   // the system fills it, no editing event
        PassphraseTextFieldSetup.update(field, text: confirmation, revealed: false, placeholder: "Repeat",
                                        coordinator: coordinator)
        #expect(field.text == "Abcd-efgh-ijkl-mn12", "not reset to the binding's empty value")
        try await Task.sleep(for: .milliseconds(50))
        #expect(confirmation == "Abcd-efgh-ijkl-mn12", "the binding took it")
        // The app's own change still wins once the field's text was seen.
        confirmation = ""
        PassphraseTextFieldSetup.update(field, text: confirmation, revealed: false, placeholder: "Repeat",
                                        coordinator: coordinator)
        #expect(field.text == "")
    }

    // MARK: - Folder picker

    /// On a Mac the folder pick is AppKit's open panel, set up for one folder with New Folder.
    @Test func theMacFolderPanelCanCreateFolders() throws {
        guard Platform.isMac else {
            #expect(!MacFolderPanel.isAvailable, "iPad and iPhone use the system document picker")
            return
        }
        #expect(MacFolderPanel.isAvailable)
        let panel = try #require(MacFolderPanel.makePanel())
        #expect(panel.value(forKey: "canCreateDirectories") as? Bool == true)
        #expect(panel.value(forKey: "canChooseDirectories") as? Bool == true)
        // Files on, so a `.sempere` (a document type of the app) is not greyed out; the delegate enables folders only.
        #expect(panel.value(forKey: "canChooseFiles") as? Bool == true)
        #expect(panel.value(forKey: "allowsMultipleSelection") as? Bool == false)
        let open = try #require(MacFolderPanel.makePanel(purpose: .openVault))
        #expect(open.value(forKey: "canCreateDirectories") as? Bool == false)
    }

    /// Owner's tests of build 10: on the Mac a `.sempere` vault could not be chosen in Open Vault…, and the pickers
    /// went into vaults and backups, where a folder inside a `.sempere-backup` could be chosen for a sync. The panel's
    /// delegate (`MacPanelRules`, `PickedFolderRules`): folders only, vaults and backups themselves choosable, nothing
    /// inside one, and never a backup as a sync folder; the same words refuse such a pick on the iPad.
    @Test func thePickersChooseVaultsAndBackupsButNothingInsideThem() throws {
        let root = TestTemp.root.appendingPathComponent("pickrules-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let vault = root.appendingPathComponent("Wompa.sempere", isDirectory: true)
        let backup = root.appendingPathComponent("Wompa.sempere-backup", isDirectory: true)
        let plain = root.appendingPathComponent("junk", isDirectory: true)
        for dir in [vault.appendingPathComponent("notes"), backup.appendingPathComponent("versions/1"), plain] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let file = root.appendingPathComponent("photo.jpg")
        try Data("x".utf8).write(to: file)
        let rules = { (purpose: PickedFolderRules.Purpose) in MacPanelRules(purpose: purpose) }
        for purpose in [PickedFolderRules.Purpose.openVault, .syncFolder, .writeFolder, .exportFolder] {
            let r = rules(purpose)
            let takesVault = purpose == .openVault || purpose == .syncFolder
            #expect(r.panel(NSObject(), shouldEnable: plain))
            #expect(r.panel(NSObject(), shouldEnable: vault) == takesVault,
                    "a vault is chosen as an item, never as a backup or export folder: \(purpose)")
            #expect(!r.panel(NSObject(), shouldEnable: file), "never a file")
            #expect(!r.panel(NSObject(), shouldEnable: vault.appendingPathComponent("notes")), "nothing inside a vault")
            #expect(!r.panel(NSObject(), shouldEnable: backup.appendingPathComponent("versions/1")), "nothing inside a backup")
            #expect(throws: (any Error).self) { try r.panel(NSObject(), validate: vault.appendingPathComponent("notes")) }
            if takesVault {
                #expect(throws: Never.self) { try r.panel(NSObject(), validate: vault) }
            } else {
                #expect(throws: (any Error).self) { try r.panel(NSObject(), validate: vault) }
            }
            // An item the panel's delegate cannot read stays enabled (the sandboxed panel may not let it read folders
            // outside the container); after the pick, with the grant held, an unreadable item is refused.
            // (A backup or an export folder never takes a `.sempere` by name, so those check a plain name.)
            let gone = takesVault ? "/nowhere/Gone.sempere" : "/nowhere/Gone"
            #expect(MacPanelRules.kind(of: URL(fileURLWithPath: gone)) == .unknown)
            #expect(r.panel(NSObject(), shouldEnable: URL(fileURLWithPath: gone, isDirectory: true)))
            #expect(throws: Never.self) { try r.panel(NSObject(), validate: URL(fileURLWithPath: gone)) }
        }
        #expect(rules(.openVault).panel(NSObject(), shouldEnable: backup), "a backup opens as a copy")
        #expect(rules(.writeFolder).panel(NSObject(), shouldEnable: backup), "a backup folder takes the backup")
        #expect(!rules(.syncFolder).panel(NSObject(), shouldEnable: backup), "never a sync folder")
        #expect(!rules(.exportFolder).panel(NSObject(), shouldEnable: backup), "plaintext never goes into a backup")
        // Review of #115 (N2): exports write plaintext, so never into a vault or a backup; a backup goes next to a vault.
        #expect(PickedFolderRules.problem(vault, for: .exportFolder)?.contains("not encrypted") == true)
        #expect(PickedFolderRules.problem(backup, for: .exportFolder)?.contains("not encrypted") == true)
        #expect(PickedFolderRules.problem(vault, for: .writeFolder)?.contains("next to it") == true)
        #expect(PickedFolderRules.problem(backup, for: .writeFolder) == nil, "this vault's backup is continued")
        #expect(PickedFolderRules.problem(plain, for: .exportFolder) == nil)
        // The words: what to choose instead.
        let inside = try #require(PickedFolderRules.problem(vault.appendingPathComponent("notes"), for: .openVault, isMac: false))
        #expect(inside.contains("Wompa.sempere") && inside.contains("To open the vault") && inside.contains("tap Open"), "\(inside)")
        let mac = try #require(PickedFolderRules.problem(vault.appendingPathComponent("notes"), for: .openVault, isMac: true))
        #expect(mac.contains("without going into it"), "\(mac)")
        #expect(PickedFolderRules.problem(backup, for: .syncFolder)?.contains("is a backup") == true)
        #expect(PickedFolderRules.problem(plain, for: .syncFolder) == nil)
        // The Mac app's own container is named like a vault: not one (by its place, not its name's shape).
        #expect(PickedFolderRules.enclosingNamedHolder(of: URL(fileURLWithPath:
            "/Users/me/Library/Containers/io.github.anthonytw.sempere/Data/tmp/junk")) == nil)
        #expect(PickedFolderRules.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/v1.2 notes.sempere/x"))?
            .lastPathComponent == "v1.2 notes.sempere")
        #expect(PickedFolderRules.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/Notes.2026.sempere/x"))?
            .lastPathComponent == "Notes.2026.sempere")
        #expect(PickedFolderRules.enclosingNamedHolder(of: URL(fileURLWithPath: "/Users/me/My.Work.sempere-backup/versions"))?
            .lastPathComponent == "My.Work.sempere-backup")
        // Packages are never chosen as folders (review of #113): a bundle on disk, and the rule itself.
        let bundle = root.appendingPathComponent("Foo.app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(MacPanelRules.kind(of: bundle) == .package)
        #expect(MacPanelRules.kind(of: plain) == .folder)
        #expect(MacPanelRules.kind(of: vault) == .folder, "a vault is a plain folder")
        #expect(MacPanelRules.kind(of: file) == .file)
        for purpose in [PickedFolderRules.Purpose.openVault, .syncFolder, .writeFolder, .exportFolder] {
            #expect(!rules(purpose).panel(NSObject(), shouldEnable: bundle))
            #expect(throws: (any Error).self) { try rules(purpose).panel(NSObject(), validate: bundle) }
            let library = URL(fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary", isDirectory: true)
            #expect(!PickedFolderRules.canChoose(library, kind: .package, for: purpose))
            #expect(PickedFolderRules.canChoose(plain, kind: .unknown, for: purpose), "unknown in the panel: enabled")
            #expect(!PickedFolderRules.canChoose(vault.appendingPathComponent("notes"), kind: .unknown, for: purpose),
                    "unknown but inside a vault: greyed out")
            #expect(!PickedFolderRules.canChoose(plain, kind: .file, for: purpose))
            #expect(PickedFolderRules.canChoose(plain, kind: .folder, for: purpose))
        }
        // After the pick: only a plain folder is taken; unknown, a package or a file is refused.
        #expect(PickedFolderRules.accepts(.folder, at: plain))
        #expect(!PickedFolderRules.accepts(.unknown, at: plain) && !PickedFolderRules.accepts(.package, at: bundle)
                && !PickedFolderRules.accepts(.file, at: file))
    }

    /// Owner's test of build 11: iCloud Drive held "Wompa.sempere" as a package (an early build declared the vault type
    /// as one, and iCloud Drive kept it), so the Mac's panel greyed it out as a package and the iPhone's picker greyed
    /// it out as a file of another type. A vault or a backup the system reports as a package is chosen like the folder
    /// it is, by every purpose's rules; any other package still is not.
    @Test func aVaultOrBackupHeldAsAPackageIsChosenAsAnItem() throws {
        let root = TestTemp.root.appendingPathComponent("pickpkg-\(UUID().uuidString)", isDirectory: true)
        let vault = root.appendingPathComponent("Wompa.sempere", isDirectory: true)
        let backup = root.appendingPathComponent("Wompa.sempere-backup", isDirectory: true)
        let keynote = root.appendingPathComponent("Talk.key", isDirectory: true)
        for purpose in [PickedFolderRules.Purpose.openVault, .syncFolder] {
            #expect(PickedFolderRules.canChoose(vault, kind: .package, for: purpose), "\(purpose)")
        }
        // Never a vault as a backup folder or an export's folder, held as a package or not (review of #115, N2).
        #expect(!PickedFolderRules.canChoose(vault, kind: .package, for: .writeFolder))
        #expect(!PickedFolderRules.canChoose(vault, kind: .package, for: .exportFolder))
        #expect(!PickedFolderRules.canChoose(backup, kind: .package, for: .exportFolder))
        for purpose in [PickedFolderRules.Purpose.openVault, .syncFolder, .writeFolder, .exportFolder] {
            #expect(!PickedFolderRules.canChoose(keynote, kind: .package, for: purpose), "\(purpose)")
            #expect(!PickedFolderRules.canChoose(vault.appendingPathComponent("notes"), kind: .package, for: purpose))
        }
        #expect(PickedFolderRules.canChoose(backup, kind: .package, for: .openVault))
        #expect(PickedFolderRules.canChoose(backup, kind: .package, for: .writeFolder))
        #expect(!PickedFolderRules.canChoose(backup, kind: .package, for: .syncFolder), "never a sync folder")
        #expect(PickedFolderRules.accepts(.package, at: vault) && PickedFolderRules.accepts(.package, at: backup))
        #expect(!PickedFolderRules.accepts(.package, at: keynote) && !PickedFolderRules.accepts(.file, at: vault))
        // The document picker (iPhone, iPad): an item it cannot read is left to the opener, as before; any other
        // package is refused.
        #expect(PickedFolderRules.acceptsFromDocumentPicker(.package, at: vault))
        #expect(PickedFolderRules.acceptsFromDocumentPicker(.unknown, at: keynote))
        #expect(PickedFolderRules.acceptsFromDocumentPicker(.folder, at: keynote))
        #expect(!PickedFolderRules.acceptsFromDocumentPicker(.package, at: keynote))
        // Its types let packages through, so a vault or a backup held as one is not greyed out; an export's folder
        // is a plain folder.
        for types in [UTType.vaultPickerTypes, UTType.folderPickerTypes] {
            #expect(types.contains(.folder) && types.contains(.package) && types.contains(.sempere) && types.contains(.sempereBackup))
        }
        #expect(PickedFolderRules.documentPickerTypes(for: .exportFolder) == [.folder])
        #expect(PickedFolderRules.documentPickerTypes(for: .openVault) == UTType.vaultPickerTypes)
        // An item that is not on the device (an iCloud package an iPhone has not downloaded) reads as unknown: the
        // pick is not refused here, the code that uses it decides (`folderTargetLocation`, `previewRestore`).
        #expect(MacPanelRules.kind(of: root.appendingPathComponent("Away.sempere", isDirectory: true)) == .unknown)
        #expect(PickedFolderRules.documentPickerRefusal(root.appendingPathComponent("Away.sempere", isDirectory: true)) == nil)

        // On a Mac, a real folder with the package bit set (as iCloud Drive reports one): the panel's delegate enables
        // the vault and the backup, refuses the other package, and keeps everything inside them out of reach.
        guard Platform.isMac else { return }
        let fm = FileManager.default
        for dir in [vault.appendingPathComponent("notes"), backup.appendingPathComponent("versions"), keynote] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dir in [vault, backup, keynote] {
            try (dir as NSURL).setResourceValue(true, forKey: .isPackageKey)
            #expect(MacPanelRules.kind(of: URL(fileURLWithPath: dir.path)) == .package, "\(dir.lastPathComponent)")
        }
        let open = MacPanelRules(purpose: .openVault), sync = MacPanelRules(purpose: .syncFolder)
        #expect(open.panel(NSObject(), shouldEnable: URL(fileURLWithPath: vault.path)))
        #expect(open.panel(NSObject(), shouldEnable: URL(fileURLWithPath: backup.path)))
        #expect(sync.panel(NSObject(), shouldEnable: URL(fileURLWithPath: vault.path)))
        #expect(!sync.panel(NSObject(), shouldEnable: URL(fileURLWithPath: backup.path)))
        #expect(!open.panel(NSObject(), shouldEnable: URL(fileURLWithPath: keynote.path)))
        #expect(throws: Never.self) { try open.panel(NSObject(), validate: URL(fileURLWithPath: vault.path)) }
        #expect(throws: Never.self) { try sync.panel(NSObject(), validate: URL(fileURLWithPath: vault.path)) }
        #expect(throws: (any Error).self) { try open.panel(NSObject(), validate: URL(fileURLWithPath: keynote.path)) }
        #expect(!open.panel(NSObject(), shouldEnable: vault.appendingPathComponent("notes")))
        // An empty sync folder held as a package, picked itself, is the target (#113's rule: `<picked>/<Name>.sempere`
        // only for any other folder).
        let fresh = root.appendingPathComponent("Fresh.sempere", isDirectory: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try (fresh as NSURL).setResourceValue(true, forKey: .isPackageKey)
        let target = try AppModel.folderTargetLocation(picked: fresh, vaultFolderName: "Wompa.sempere", vaultId: UUID())
        #expect(target.standardizedFileURL == fresh.standardizedFileURL)
    }

    /// Owner's test of build 12: Save… of a note's PDF into a `.sempere-backup` saved there, and into a `.sempere`
    /// froze the app. Exported files are plaintext: never inside a vault or a backup, nor named like one. The Mac's
    /// save panel is the app's own (`MacSavePanel`), whose delegate greys them out and refuses a file there with
    /// words the panel shows; the Files export picker's copy there is removed (`removeRefused`).
    @Test func exportsAreNeverSavedIntoAVaultOrABackup() throws {
        let root = TestTemp.root.appendingPathComponent("savepanel-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let vault = root.appendingPathComponent("Sempere Demo.sempere", isDirectory: true)
        let backup = root.appendingPathComponent("Wompa.sempere-backup", isDirectory: true)
        let plain = root.appendingPathComponent("Exports", isDirectory: true)
        for dir in [vault.appendingPathComponent("notes"), backup.appendingPathComponent("versions"), plain] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        #expect(PickedFolderRules.saveProblem(vault.appendingPathComponent("Note.pdf"))?.contains("not encrypted") == true)
        #expect(PickedFolderRules.saveProblem(backup.appendingPathComponent("Note.pdf"))?.contains("not encrypted") == true)
        #expect(PickedFolderRules.saveProblem(vault.appendingPathComponent("notes/Note.pdf")) != nil, "deeper inside")
        #expect(PickedFolderRules.saveProblem(plain.appendingPathComponent("X.sempere")) != nil, "named like a vault")
        #expect(PickedFolderRules.saveProblem(plain.appendingPathComponent("Note.pdf")) == nil)

        let rules = MacSaveRules()
        #expect(!rules.panel(NSObject(), shouldEnable: vault) && !rules.panel(NSObject(), shouldEnable: backup))
        #expect(!rules.panel(NSObject(), shouldEnable: vault.appendingPathComponent("notes")))
        #expect(rules.panel(NSObject(), shouldEnable: plain))
        #expect(throws: (any Error).self) { try rules.panel(NSObject(), validate: backup.appendingPathComponent("Note.pdf")) }
        #expect(throws: (any Error).self) { try rules.panel(NSObject(), validate: vault.appendingPathComponent("Note.pdf")) }
        #expect(throws: Never.self) { try rules.panel(NSObject(), validate: plain.appendingPathComponent("Note.pdf")) }

        // The Files export picker copied before anyone could refuse: the copies in a vault or a backup go at once.
        let leaked = [vault.appendingPathComponent("Note.pdf"), backup.appendingPathComponent("Note.pdf")]
        let kept = plain.appendingPathComponent("Note.pdf")
        for url in leaked + [kept] { try Data("%PDF".utf8).write(to: url) }
        #expect(ExportHandOff.removeRefused(leaked + [kept])?.contains("not encrypted") == true)
        #expect(leaked.allSatisfy { !fm.fileExists(atPath: $0.path) })
        #expect(fm.fileExists(atPath: kept.path))
        #expect(ExportHandOff.removeRefused([kept]) == nil)

        // A plain folder that is a symbolic link to a vault counts as the vault (review of #123).
        let link = root.appendingPathComponent("Looks Plain", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: vault)
        #expect(PickedFolderRules.saveProblem(link.appendingPathComponent("Note.pdf")) != nil)
        #expect(!rules.panel(NSObject(), shouldEnable: link))

        // A copy that fails leaves no partial file, and stops there.
        let source = root.appendingPathComponent("Source.pdf")
        try Data("%PDF".utf8).write(to: source)
        let into = plain.appendingPathComponent("Copied.pdf")
        let missing = root.appendingPathComponent("Gone.pdf")
        #expect(ExportHandOff.copy([(source, into)]) == nil)
        #expect(fm.fileExists(atPath: into.path))
        #expect(ExportHandOff.copy([(source, into)]) == nil, "over an existing file")
        let failed = plain.appendingPathComponent("Failed.pdf")
        #expect(ExportHandOff.copy([(missing, failed), (source, plain.appendingPathComponent("After.pdf"))]) != nil)
        #expect(!fm.fileExists(atPath: failed.path) && !fm.fileExists(atPath: plain.appendingPathComponent("After.pdf").path))

        // Several files into one folder: none replaced, the next free name instead.
        let a = root.appendingPathComponent("Note.pdf"), b = root.appendingPathComponent("Note 2.pdf")
        let pairs = ExportHandOff.destinations(for: [a, b, URL(fileURLWithPath: "/x/Note.pdf")], in: plain)
        #expect(pairs.map(\.1.lastPathComponent) == ["Note 2.pdf", "Note 2 2.pdf", "Note 3.pdf"],
                "Note.pdf is taken in the folder: \(pairs.map(\.1.lastPathComponent))")

        guard Platform.isMac else {
            #expect(!MacSavePanel.isAvailable)
            return
        }
        let panel = try #require(MacSavePanel.makePanel(fileName: "Cellular Respiration.pdf"))
        #expect(panel.value(forKey: "nameFieldStringValue") as? String == "Cellular Respiration.pdf")
        #expect(panel.value(forKey: "canCreateDirectories") as? Bool == true)
        #expect(panel.value(forKey: "treatsFilePackagesAsDirectories") as? Bool == false)
    }
}
