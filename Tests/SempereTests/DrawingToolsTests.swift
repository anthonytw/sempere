import Foundation
import XCTest
@testable import Sempere

/// The drawing palette's state (`DrawingToolState`): per-tool settings, storage, the eraser's way back
/// and the Apple Pencil's gestures. The app's PencilKit mapping is tested in `DrawingToolboxTests`.
final class DrawingToolsTests: XCTestCase {
    func testAFreshPaletteHasThePenAndEveryInk() {
        let s = DrawingToolState()
        XCTAssertEqual(s.tool, .pen)
        XCTAssertEqual(s.eraserMode, .object)
        XCTAssertFalse(s.rulerActive)
        for ink in InkTool.allCases {
            let settings = s.settings(for: ink)
            XCTAssertEqual(settings.opacity, 1)
            XCTAssertTrue(DrawingToolState.widthRange(for: ink).contains(settings.width), "\(ink)")
            XCTAssertTrue(DrawingToolState.widthPresets(for: ink).contains(settings.width), "\(ink): a preset")
        }
        XCTAssertEqual(s.settings(for: .pen).color, Color.black)
        XCTAssertEqual(s.settings(for: .marker).color, DrawingToolState.swatches[7], "the marker is yellow")
        XCTAssertEqual(s.currentInk, s.settings(for: .pen))
    }

    func testEveryPresetIsInsideItsInksRange() {
        for ink in InkTool.allCases {
            let presets = DrawingToolState.widthPresets(for: ink)
            XCTAssertEqual(presets.count, 5)
            XCTAssertEqual(presets, presets.sorted(), "\(ink): thin to thick")
            for w in presets { XCTAssertTrue(DrawingToolState.widthRange(for: ink).contains(w), "\(ink) \(w)") }
        }
        XCTAssertEqual(DrawingToolState.pixelEraserWidths, DrawingToolState.pixelEraserWidths.sorted())
    }

    func testEachInkKeepsItsOwnSettings() {
        var s = DrawingToolState()
        let red = DrawingToolState.swatches[3]
        s.setColor(red, for: .pen)
        s.setWidth(5, for: .pen)
        s.setOpacity(0.5, for: .marker)
        XCTAssertEqual(s.settings(for: .pen).color, red)
        XCTAssertEqual(s.settings(for: .pen).width, 5)
        XCTAssertEqual(s.settings(for: .pen).opacity, 1)
        XCTAssertEqual(s.settings(for: .marker).opacity, 0.5)
        XCTAssertEqual(s.settings(for: .marker).color, DrawingToolState.swatches[7], "the marker kept its color")
        XCTAssertEqual(s.widthIndex(for: .pen), 3)
        s.select(.marker)
        XCTAssertEqual(s.currentInk?.opacity, 0.5)
        s.select(.lasso)
        XCTAssertNil(s.currentInk)
    }

    func testColorsDropTheirAlphaAndTheInkColorCarriesTheOpacity() {
        var s = DrawingToolState()
        s.setColor(Color(r: 10, g: 20, b: 30, a: 40), for: .pen)
        XCTAssertEqual(s.settings(for: .pen).color, Color(r: 10, g: 20, b: 30))
        s.setOpacity(0.5, for: .pen)
        XCTAssertEqual(s.settings(for: .pen).inkColor, Color(r: 10, g: 20, b: 30, a: 128))
    }

    func testWidthsAndOpacitiesAreClamped() {
        var s = DrawingToolState()
        s.setWidth(1000, for: .pen)
        XCTAssertEqual(s.settings(for: .pen).width, DrawingToolState.widthRange(for: .pen).upperBound)
        s.setWidth(-3, for: .marker)
        XCTAssertEqual(s.settings(for: .marker).width, DrawingToolState.widthRange(for: .marker).lowerBound)
        s.setWidth(.nan, for: .pencil)
        XCTAssertEqual(s.settings(for: .pencil).width, DrawingToolState.defaultSettings(for: .pencil).width)
        s.setOpacity(0, for: .pen)
        XCTAssertEqual(s.settings(for: .pen).opacity, 0.05)
        s.setOpacity(.infinity, for: .pen)
        XCTAssertEqual(s.settings(for: .pen).opacity, 1)
        s.setPixelEraserWidth(2)
        XCTAssertEqual(s.pixelEraserWidth, 16.4)
        s.setPixelEraserWidth(500)
        XCTAssertEqual(s.pixelEraserWidth, 80.4)
    }

    func testTheCompactPaletteShowsTheToolInUse() {
        XCTAssertEqual(DrawingToolState.compactTools(selected: .pen), [.pen, .marker, .eraser, .lasso])
        XCTAssertEqual(DrawingToolState.compactTools(selected: .lasso), [.pen, .marker, .eraser, .lasso])
        XCTAssertEqual(DrawingToolState.compactTools(selected: .pencil), [.pencil, .pen, .marker, .eraser, .lasso])
        XCTAssertEqual(Set(DrawingToolState.fullTools), Set(DrawingTool.allCases), "the full palette has every tool")
        XCTAssertFalse(DrawingTool.allCases.map(\.rawValue).contains("hand"), "no Hand in the palette")
    }

    func testToolsAndInksMapBothWays() {
        for ink in InkTool.allCases { XCTAssertEqual(DrawingTool(ink: ink).ink, ink) }
        XCTAssertNil(DrawingTool.eraser.ink)
        XCTAssertNil(DrawingTool.lasso.ink)
        XCTAssertEqual(DrawingTool.allCases.filter(\.isInk).count, InkTool.allCases.count)
    }

    func testTheStateSurvivesStorage() {
        var s = DrawingToolState()
        s.select(.marker)
        s.select(.eraser)
        s.setColor(DrawingToolState.swatches[2], for: .pen)
        s.setWidth(10, for: .pen)
        s.setOpacity(0.25, for: .watercolor)
        s.setPixelEraserWidth(48)
        s.rulerActive = true
        s.eraserMode = .pixel
        var back = DrawingToolState(decoding: s.encoded())
        XCTAssertEqual(back.tool, .eraser)
        XCTAssertEqual(back.previousTool, .marker)
        XCTAssertEqual(back.settings(for: .pen), s.settings(for: .pen))
        XCTAssertEqual(back.settings(for: .watercolor).opacity, 0.25)
        XCTAssertEqual(back.pixelEraserWidth, 48)
        XCTAssertFalse(back.rulerActive, "the ruler is not remembered")
        XCTAssertEqual(back.eraserMode, .object, "the eraser mode is EraserPreference's, not this blob's")
        back.eraserMode = .pixel
        back.rulerActive = true
        XCTAssertEqual(back, s)
    }

    func testDamagedStorageStartsFresh() {
        XCTAssertEqual(DrawingToolState(decoding: nil), DrawingToolState())
        XCTAssertEqual(DrawingToolState(decoding: Data("not json".utf8)), DrawingToolState())
        XCTAssertEqual(DrawingToolState(decoding: Data(repeating: 0x20, count: 70_000)), DrawingToolState())
        let odd = Data(##"{"tool":"brush","previous":"hand","inks":{"pen":{"color":"#zz","width":1e9,"opacity":-1},"quill":{"width":3}},"pixelEraserWidth":-5}"##.utf8)
        let s = DrawingToolState(decoding: odd)
        XCTAssertEqual(s.tool, .pen, "an unknown tool")
        XCTAssertEqual(s.settings(for: .pen).color, Color.black, "a bad color")
        XCTAssertEqual(s.settings(for: .pen).width, DrawingToolState.widthRange(for: .pen).upperBound, "clamped")
        XCTAssertEqual(s.settings(for: .pen).opacity, 0.05)
        XCTAssertEqual(s.pixelEraserWidth, 16.4)
        // A partial blob keeps the rest.
        let partial = DrawingToolState(decoding: Data(#"{"tool":"lasso"}"#.utf8))
        XCTAssertEqual(partial.tool, .lasso)
        XCTAssertEqual(partial.settings(for: .marker), DrawingToolState.defaultSettings(for: .marker))
    }

    func testThePencilSwitchesToTheEraserAndBack() {
        var s = DrawingToolState()
        s.select(.marker)
        XCTAssertEqual(s.pencil(.switchEraser), .switchedTool)
        XCTAssertEqual(s.tool, .eraser)
        XCTAssertEqual(s.pencil(.switchEraser), .switchedTool)
        XCTAssertEqual(s.tool, .marker, "back to the tool before the eraser")
        // Picked from the eraser to the eraser's previous: never stuck on the eraser.
        var t = DrawingToolState()
        t.select(.eraser)
        t.select(.lasso)
        t.select(.eraser)
        XCTAssertEqual(t.pencil(.switchEraser), .switchedTool)
        XCTAssertEqual(t.tool, .lasso)
    }

    func testThePencilSwitchesToThePreviousTool() {
        var s = DrawingToolState()
        s.select(.pencil)
        XCTAssertEqual(s.pencil(.switchPrevious), .switchedTool)
        XCTAssertEqual(s.tool, .pen)
        XCTAssertEqual(s.pencil(.switchPrevious), .switchedTool)
        XCTAssertEqual(s.tool, .pencil, "a second double-tap goes back")
    }

    func testThePencilsOtherActions() {
        var s = DrawingToolState()
        XCTAssertEqual(s.pencil(.showPalette), .togglePalette)
        XCTAssertEqual(s.pencil(.ignore), .nothing)
        XCTAssertEqual(s.tool, .pen)
    }

    func testPickingTheToolInUseKeepsTheWayBack() {
        var s = DrawingToolState()
        s.select(.marker)
        s.select(.marker)
        XCTAssertEqual(s.previousTool, .pen)
    }
}
