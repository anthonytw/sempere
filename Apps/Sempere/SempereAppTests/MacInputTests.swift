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
        for tool in ToolChoice.allCases {
            #expect(DrawingToolState.fullTools.filter { $0 == tool.drawingTool }.count == 1, "\(tool)")
        }
    }

    /// The compact palette shows pen, marker, eraser and lasso; the Tools menu's pencil is shown too while picked.
    @Test func theCompactPaletteShowsAMenuPickedPencil() {
        #expect(!DrawingToolState.compactTools(selected: .pen).contains(.pencil))
        #expect(DrawingToolState.compactTools(selected: ToolChoice.pencil.drawingTool).contains(.pencil))
        for tool in [ToolChoice.pen, .marker, .eraser, .lasso] {
            #expect(DrawingToolState.compactTools(selected: .pen).filter { $0 == tool.drawingTool }.count == 1, "\(tool)")
        }
    }

    @Test func aMenuToolIsSelectedInThePalette() throws {
        let toolbox = DrawingToolbox(defaults: DrawingToolboxTests.scratchDefaults())
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 700, height: 900), embedded: false, toolbox: toolbox)
        #expect(host.select(tool: .marker))
        let marker = try #require(host.canvas.tool as? PKInkingTool)
        #expect(marker.inkType == .marker)
        #expect(toolbox.state.tool == .marker)
        #expect(host.select(tool: .pencil), "every tool, whatever the palette's size")
        #expect((host.canvas.tool as? PKInkingTool)?.inkType == .pencil)
        #expect(host.select(tool: .lasso))
        #expect(host.canvas.tool is PKLassoTool)
        host.isReadOnly = true
        #expect(!host.select(tool: .pen), "a read-only note has no tools")
        #expect(toolbox.state.tool == .lasso)
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
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 700, height: 900), embedded: false,
                                  toolbox: DrawingToolbox(defaults: DrawingToolboxTests.scratchDefaults()))
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
