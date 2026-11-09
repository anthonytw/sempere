import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The pointer over placed items (`ItemPointer`, docs/mac.md "Placed items"): the zone a drag is in and the angle of a
/// handle's two-way arrow. The outlines and the keys are the app's tests (`ItemPointerTests`).
struct ItemPointerTests {
    func image(_ frame: Rect, rotation: Double? = nil) -> Item {
        var item = Item.image(blob: BlobRef(content: Data("x".utf8), type: "image/png"), pixelSize: Size(w: 4, h: 3), frame: frame, z: "b")
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
        let item = image(Rect(x: 100, y: 100, w: 100, h: 100))
        var model = ItemSelectionModel()
        // Not selected: the inside moves it, nothing else.
        #expect(ItemPointer.zone(model.drag(at: .init(x: 150, y: 150), items: [item], zoom: 1), items: [item]) == .move)
        #expect(ItemPointer.zone(model.drag(at: .init(x: 20, y: 20), items: [item], zoom: 1), items: [item]) == nil)
        model.selected = item.id
        #expect(ItemPointer.zone(model.drag(at: .init(x: 201, y: 199), items: [item], zoom: 1), items: [item])
                == .resize(degrees: 45))
        #expect(ItemPointer.zone(model.drag(at: .init(x: 150, y: 150), items: [item], zoom: 1), items: [item]) == .move)
        #expect(ItemPointer.move.identifier != ItemPointer.resize(degrees: 45).identifier)
    }
}
