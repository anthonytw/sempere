import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Menu-driven tools and zoom, and mouse/trackpad input on the canvas host.
@MainActor
@Suite(.serialized)
struct MacInputTests {
    private func raw(_ type: UITouch.TouchType) -> Int { type.rawValue }

    @Test func theObjectEraserTakesThePointerOnAMacOnly() {
        let mac = ObjectEraserController.pressTouchTypes(fingersDraw: false, pointerErases: true).map(\.intValue)
        #expect(mac == [raw(.pencil), raw(.indirectPointer)])
        let macFingers = ObjectEraserController.pressTouchTypes(fingersDraw: true, pointerErases: true).map(\.intValue)
        #expect(macFingers == [raw(.pencil), raw(.direct), raw(.indirectPointer)])
        // The iPad is as it was: Pencil, and fingers when they draw.
        #expect(ObjectEraserController.pressTouchTypes(fingersDraw: false, pointerErases: false).map(\.intValue) == [raw(.pencil)])
        #expect(ObjectEraserController.pressTouchTypes(fingersDraw: true, pointerErases: false).map(\.intValue)
                == [raw(.pencil), raw(.direct)])
    }

    @Test func theFullPaletteHasEachMenuToolOnce() {
        let items = ToolPalette.makePicker(compact: false).toolItems
        for tool in ToolChoice.allCases {
            #expect(items.filter { tool.matches($0) }.count == 1, "\(tool)")
        }
    }

    @Test func theCompactPaletteHasNoPencil() {
        let items = ToolPalette.makePicker(compact: true).toolItems
        #expect(items.filter { ToolChoice.pencil.matches($0) }.isEmpty)
        for tool in [ToolChoice.pen, .marker, .eraser, .lasso] {
            #expect(items.filter { tool.matches($0) }.count == 1, "\(tool)")
        }
    }

    @Test func aMenuToolIsSelectedInThePalette() throws {
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        #expect(host.select(tool: .marker))
        let marker = try #require(host.toolPicker.selectedToolItem as? PKToolPickerInkingItem)
        #expect(marker.inkingTool.inkType == .marker)
        #expect(host.select(tool: .lasso))
        #expect(host.toolPicker.selectedToolItem is PKToolPickerLassoItem)
        host.isReadOnly = true
        #expect(!host.select(tool: .pen), "a read-only note has no tools")
    }

    @Test func zoomCommandsStepFromTheFittedWidth() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 306, height: 700))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: PageSize(width: 612, height: 792))
        host.layoutIfNeeded()
        let fit = host.canvas.zoomScale
        #expect(abs(fit - 0.5) < 0.001)

        func settles(at factor: CGFloat) async -> Bool {
            await TS.waitUntil { abs(host.canvas.zoomScale - fit * factor) < 0.005 }
        }
        host.zoom(in: true)
        #expect(await settles(at: 1.25))
        host.zoom(in: true)
        #expect(await settles(at: 1.5))
        host.zoom(in: false)
        #expect(await settles(at: 1.25))
        host.zoomToFit()
        #expect(await settles(at: 1))
        host.zoom(in: false)
        #expect(await settles(at: 1), "zooming out stops at the fitted width")
        host.zoomToActualSize()
        #expect(await settles(at: 2), "100% is one page point per screen point")
    }

    @Test func theRulerToggles() {
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        #expect(!host.canvas.isRulerActive)
        host.toggleRuler()
        #expect(host.canvas.isRulerActive)
        host.toggleRuler()
        #expect(!host.canvas.isRulerActive)
        host.isReadOnly = true
        host.toggleRuler()
        #expect(!host.canvas.isRulerActive)
    }
}
