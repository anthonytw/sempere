import Foundation
import Testing
@testable import SempereApp

struct ZoomStepsTests {
    @Test func zoomInMovesThroughTheFactorsAndStopsAtTheMaximum() {
        let fit = 0.5
        var scale = fit
        var visited: [Double] = []
        for _ in 0..<12 {
            scale = ZoomSteps.step(from: scale, fit: fit, zoomingIn: true)
            visited.append(scale / fit)
        }
        #expect(Array(visited.prefix(6)) == [1.25, 1.5, 2, 2.5, 3, 4])
        #expect(visited.last == 4)
        #expect(scale <= fit * ZoomSteps.maxFactor + 1e-12)
    }

    @Test func zoomOutStopsAtTheFittedWidth() {
        let fit = 0.75
        var scale = fit * 4
        for _ in 0..<12 { scale = ZoomSteps.step(from: scale, fit: fit, zoomingIn: false) }
        #expect(scale == fit)
        #expect(ZoomSteps.step(from: fit * 1.6, fit: fit, zoomingIn: false) == fit * 1.5)
        #expect(ZoomSteps.step(from: fit * 1.6, fit: fit, zoomingIn: true) == fit * 2)
    }

    @Test func aPinchedScaleBetweenFactorsSteps() {
        let fit = 1.0
        #expect(ZoomSteps.step(from: 1.3, fit: fit, zoomingIn: true) == 1.5)
        #expect(ZoomSteps.step(from: 1.3, fit: fit, zoomingIn: false) == 1.25)
    }

    @Test func badInputGivesTheFittedScale() {
        #expect(ZoomSteps.step(from: .nan, fit: 0.5, zoomingIn: true) == 0.5)
        #expect(ZoomSteps.step(from: -1, fit: 0.5, zoomingIn: false) == 0.5)
        #expect(ZoomSteps.step(from: 1, fit: 0, zoomingIn: true) == 1)
        #expect(ZoomSteps.step(from: 1, fit: .infinity, zoomingIn: true) == 1)
        #expect(ZoomSteps.clamped(.infinity, fit: 0.5) == 0.5)
    }

    @Test func actualSizeStaysInRange() {
        #expect(ZoomSteps.actualSize(fit: 0.5) == 1)
        #expect(ZoomSteps.actualSize(fit: 2) == 2)        // already wider than 100%
        #expect(ZoomSteps.actualSize(fit: 0.1) == 0.4)    // 4x the fit is the most the canvas allows
    }
}

struct PointerCursorTests {
    @Test func diameterFollowsWidthAndZoomWithinBounds() {
        #expect(PointerCursor.diameter(toolWidth: 10, zoom: 2) == 20)
        #expect(PointerCursor.diameter(toolWidth: 1, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: 500, zoom: 4) == PointerCursor.range.upperBound)
        #expect(PointerCursor.diameter(toolWidth: .nan, zoom: 1) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: 5, zoom: 0) == PointerCursor.range.lowerBound)
        #expect(PointerCursor.diameter(toolWidth: -5, zoom: 1) == PointerCursor.range.lowerBound)
    }
}

struct WindowValueTests {
    @Test func aNoteWindowValueSurvivesTheRoundTripStateRestorationDoes() throws {
        let value = NoteWindowValue(vaultID: UUID(), noteID: UUID())
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(NoteWindowValue.self, from: data) == value)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/"), "no path is stored: \(text)")
    }

    @Test func aSelectionRoundTripsThroughItsStoredString() throws {
        let note = UUID(), vault = UUID()
        // A stand-in digest: the model's is keyed by the vault secret (`AppModel.selectionDigest`).
        let digest: (String) -> String = { "d" + String($0.utf8.count) }
        let expected: [(SidebarItem, RestorableSelection.Sidebar)] = [
            (.allNotes, .item(.allNotes)), (.deleted, .item(.deleted)),
            (.notebook("School/Math"), .notebook(digest: digest(RestorableSelection.digestLabel(notebook: "School/Math")))),
            (.tag("a:b/c"), .tag(digest: digest(RestorableSelection.digestLabel(tag: "a:b/c")))),
        ]
        for (item, ref) in expected {
            let saved = RestorableSelection(sidebar: item, note: note, vault: vault, digest: digest)
            let back = try #require(RestorableSelection(stored: saved.stored))
            #expect(back == saved)
            #expect(back.sidebarRef == ref)
            #expect(!saved.stored.contains("Math") && !saved.stored.contains("a:b/c"), "no names are stored")
        }
        #expect(RestorableSelection(sidebar: nil, note: nil, vault: nil, digest: digest).sidebarRef == .item(.allNotes))
    }

    @Test func anUnreadableStoredSelectionIsNoSelection() {
        #expect(RestorableSelection(stored: "") == nil)
        #expect(RestorableSelection(stored: "{not json") == nil)
        #expect(RestorableSelection(stored: "{\"sidebar\":\"all\",\"note\":\"not-a-uuid\"}") == nil)
        #expect(RestorableSelection(sidebar: .allNotes, note: nil, vault: nil, digest: { $0 }).stored.isEmpty == false)
        // An unknown sidebar word falls back to All Notes.
        let odd = RestorableSelection(stored: "{\"sidebar\":\"future\"}")
        #expect(odd?.sidebarRef == .item(.allNotes))
    }
}

struct ExportFileNameTests {
    @Test func plainTitlesKeepTheirName() {
        #expect(ExportFileName.pdf(title: "Fixture lecture") == "Fixture lecture.pdf")
        #expect(ExportFileName.pdf(title: "Física – tema 3") == "Física – tema 3.pdf")
    }

    @Test func pathCharactersAndControlsAreReplaced() {
        #expect(ExportFileName.pdf(title: "a/b:c\\d") == "a b c d.pdf")
        #expect(ExportFileName.pdf(title: "line\none\u{0}two\u{7}") == "line one two.pdf")
        #expect(ExportFileName.pdf(title: "../../etc/passwd") == "etc passwd.pdf")
        #expect(ExportFileName.pdf(title: ".hidden") == "hidden.pdf")
    }

    @Test func emptyTitlesAreUntitled() {
        #expect(ExportFileName.pdf(title: "") == "Untitled.pdf")
        #expect(ExportFileName.pdf(title: "  \n ") == "Untitled.pdf")
        #expect(ExportFileName.pdf(title: "///") == "Untitled.pdf")
    }

    @Test func longTitlesAreCutOnACharacterBoundary() {
        let name = ExportFileName.pdf(title: String(repeating: "é", count: 500))
        let base = String(name.dropLast(4))
        #expect(base.utf8.count <= ExportFileName.maxBytes)
        #expect(base.allSatisfy { $0 == "é" })
        #expect(name.utf8.count <= 255)
    }
}
