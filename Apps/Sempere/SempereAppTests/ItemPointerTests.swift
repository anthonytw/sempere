import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Placed items with a pointer and a keyboard (docs/mac.md "Placed items"):
/// the pointer's shape over an item and its handles, the arrow keys and
/// Escape. The drags themselves are `MacItemUITests` (a real mouse).
@MainActor
struct ItemPointerTests {
    static func image(_ frame: Rect, rotation: Double? = nil) -> Item {
        var item = AttachmentEditorTests.imageItem(BlobRef(content: Data("x".utf8), type: "image/png"), frame: frame)
        item.rotation = rotation
        return item
    }

    @Test func aHandlePointsAlongItsDrag() {
        let square = Rect(x: 0, y: 0, w: 100, h: 100)
        #expect(ItemPointer.angle(of: .corner(.bottomRight), frame: square, rotation: nil) == 45)
        #expect(ItemPointer.angle(of: .corner(.topLeft), frame: square, rotation: nil) == 45)
        #expect(ItemPointer.angle(of: .corner(.topRight), frame: square, rotation: nil) == 135)
        #expect(ItemPointer.angle(of: .edge(.left), frame: square, rotation: nil) == 0)
        #expect(ItemPointer.angle(of: .edge(.right), frame: square, rotation: 90) == 90)
        // A wide picture's corner is flatter than 45°.
        let wide = ItemPointer.angle(of: .corner(.bottomRight), frame: Rect(x: 0, y: 0, w: 200, h: 100), rotation: nil)
        #expect(wide > 20 && wide < 30)
    }

    @Test func zonesFollowTheDragRule() {
        let item = Self.image(Rect(x: 100, y: 100, w: 100, h: 100))
        var model = ItemSelectionModel()
        // Not selected: the inside moves it, nothing else.
        #expect(ItemPointer.zone(model.drag(at: .init(x: 150, y: 150), items: [item], zoom: 1), items: [item]) == .move)
        #expect(ItemPointer.zone(model.drag(at: .init(x: 20, y: 20), items: [item], zoom: 1), items: [item]) == nil)
        model.selected = item.id
        #expect(ItemPointer.zone(model.drag(at: .init(x: 201, y: 199), items: [item], zoom: 1), items: [item])
                == .resize(degrees: 45))
        #expect(ItemPointer.zone(model.drag(at: .init(x: 150, y: 150), items: [item], zoom: 1), items: [item]) == .move)
        #expect(ItemPointer.move.identifier != ItemPointer.resize(degrees: 45).identifier)
        #expect(!ItemPointer.move.path.isEmpty && !ItemPointer.resize(degrees: 135).path.isEmpty)
    }

    @Test func arrowsNudgeAndEscapeDeselects() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        _ = try editor.addItems([AttachmentEditorTests.textItem()], on: page)   // 10, 10, 200 × 40
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let undo = AttachmentEditorTests.undoManager()
        host.itemSelection.reset(editor: editor, pageID: page, undoManager: undo)
        host.itemSelectionActive = true
        #expect(host.keyCommands?.contains { $0.input == UIKeyCommand.inputEscape } != true, "no keys without a selection")
        let id = try #require(editor.items(on: page).first?.id)
        host.itemSelection.select(id)
        #expect(host.keyCommands?.contains { $0.input == UIKeyCommand.inputLeftArrow } == true)
        #expect(host.itemSelection.pointer(at: CGPoint(x: 100, y: 30)) == .move)
        let revisions = editor.itemRevisions[page] ?? 0
        AttachmentEditorTests.grouped(undo) { _ = host.itemSelection.nudge(dx: 1, dy: 0) }
        AttachmentEditorTests.grouped(undo) { _ = host.itemSelection.nudge(dx: 0, dy: -10) }
        // Screen points: one page point at zoom 1.
        let z = Double(host.canvas.zoomScale)
        let frame = try #require(editor.item(id, on: page)).frame
        #expect(abs(frame.x - (10 + 1 / z)) < 0.01 && abs(frame.y - (10 - 10 / z)) < 0.01)
        #expect(editor.itemRevisions[page] == revisions + 2, "one edit per press")
        undo.undo()
        #expect(abs((editor.item(id, on: page)?.frame.y ?? 0) - 10) < 0.01)
        #expect(host.itemSelection.clearSelection())
        #expect(host.itemSelection.selectedID == nil)
        #expect(!host.itemSelection.clearSelection())
        host.itemSelectionActive = false
        #expect(host.itemSelection.pointer(at: CGPoint(x: 100, y: 30)) == nil, "no item pointer outside selection")
        await editor.flush()
    }
}
