import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The iPhone's sidebar draws the notebook tree itself (a tap on an outline row only folded it, so a
/// notebook with sub-notebooks could not be opened): every notebook, in tree order, with its depth.
struct PhoneSidebarTests {
    @Test func rowsFollowTheTreeWithDepth() {
        let tree = NotebookNode.tree(["School/Biology", "School/Physics/Optics", "Personal"])
        let rows = PhoneNotebookRows.rows(tree)
        #expect(rows.map(\.node.path) == ["Personal", "School", "School/Biology", "School/Physics", "School/Physics/Optics"])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 2])
    }

    @Test func noNotebooksNoRows() {
        #expect(PhoneNotebookRows.rows([]).isEmpty)
    }
}
