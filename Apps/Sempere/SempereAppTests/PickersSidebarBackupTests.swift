import Foundation
import Sempere
import Testing
import UIKit
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
        #expect(panel.value(forKey: "canChooseFiles") as? Bool == false)
        #expect(panel.value(forKey: "allowsMultipleSelection") as? Bool == false)
    }
}
