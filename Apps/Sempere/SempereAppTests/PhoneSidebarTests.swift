import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The iPhone's sidebar draws the notebook tree itself (a tap on an outline row only folded it, so a
/// notebook with sub-notebooks could not be opened): the notebooks in tree order with their depth, folded
/// like the iPad's outline (a chevron of their own folds and unfolds; the row's tap opens the notebook).
struct PhoneSidebarTests {
    @Test func rowsFollowTheTreeWithDepth() {
        let tree = NotebookNode.tree(["School/Biology", "School/Physics/Optics", "Personal"])
        let rows = PhoneNotebookRows.rows(tree)
        #expect(rows.map(\.node.path) == ["Personal", "School", "School/Biology", "School/Physics", "School/Physics/Optics"])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 2])
        #expect(rows.map(\.hasChildren) == [false, true, false, true, false])
    }

    @Test func noNotebooksNoRows() {
        #expect(PhoneNotebookRows.rows([]).isEmpty)
        #expect(PhoneNotebookRows.rows([], unfolded: []).isEmpty)
    }

    /// Folded by default, as the iPad's outline: only the top notebooks; unfolding one lists its sub-notebooks
    /// (folded in turn), folding it again hides them and everything under them.
    @Test func foldedNotebooksHideTheirSubNotebooks() {
        let tree = NotebookNode.tree(["School/Biology", "School/Physics/Optics", "Personal"])
        #expect(PhoneNotebookRows.rows(tree, unfolded: []).map(\.node.path) == ["Personal", "School"])
        var unfolded = PhoneNotebookRows.toggled("School", in: [])
        #expect(PhoneNotebookRows.rows(tree, unfolded: unfolded).map(\.node.path)
                == ["Personal", "School", "School/Biology", "School/Physics"])
        #expect(PhoneNotebookRows.rows(tree, unfolded: unfolded).first { $0.node.path == "School" }?.unfolded == true)
        unfolded = PhoneNotebookRows.toggled("School/Physics", in: unfolded)
        #expect(PhoneNotebookRows.rows(tree, unfolded: unfolded).map(\.node.path).last == "School/Physics/Optics")
        unfolded = PhoneNotebookRows.toggled("School", in: unfolded)
        #expect(PhoneNotebookRows.rows(tree, unfolded: unfolded).map(\.node.path) == ["Personal", "School"],
                "folding a notebook hides every level under it")
        #expect(unfolded == ["School/Physics"], "the inner one stays unfolded for the next time")
    }

    /// A notebook chosen elsewhere is listed: its parents are unfolded.
    @Test func revealingUnfoldsTheParents() {
        #expect(PhoneNotebookRows.revealing("School/Physics/Optics", in: []) == ["School", "School/Physics"])
        #expect(PhoneNotebookRows.revealing("Personal", in: ["X"]) == ["X"])
        let tree = NotebookNode.tree(["School/Physics/Optics"])
        let rows = PhoneNotebookRows.rows(tree, unfolded: PhoneNotebookRows.revealing("School/Physics/Optics", in: []))
        #expect(rows.map(\.node.path).contains("School/Physics/Optics"))
    }
}
