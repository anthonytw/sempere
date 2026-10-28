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

    /// TestFlight build 8: "the minimum stroke widths are too large". Every ink's thinnest preset is the
    /// thinnest width it accepts, and the writing inks' default (middle) preset is thinner than it was.
    func testTheThinnestPresetIsTheInksMinimum() {
        for ink in InkTool.allCases {
            XCTAssertEqual(DrawingToolState.widthPresets(for: ink).first, DrawingToolState.widthRange(for: ink).lowerBound, "\(ink)")
        }
        XCTAssertLessThanOrEqual(DrawingToolState.defaultSettings(for: .pen).width, 1.8)
        XCTAssertLessThanOrEqual(DrawingToolState.defaultSettings(for: .monoline).width, 1)
        XCTAssertLessThanOrEqual(DrawingToolState.defaultSettings(for: .fountainPen).width, 2.5)
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
        XCTAssertEqual(s.widthIndex(for: .pen), 4)
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
        XCTAssertTrue(back.rulerActive, "the ruler is remembered")
        XCTAssertEqual(back.eraserMode, .object, "the eraser mode is EraserPreference's, not this blob's")
        back.eraserMode = .pixel
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

    /// Owner, PR #51: "Every tool should remember its last settings." Distinct, off-preset values on every ink
    /// (color, exact width, opacity), the pixel eraser and the ruler, kept through tool switches and storage.
    func testEveryToolRemembersItsOwnExactSettings() {
        var s = DrawingToolState()
        var expected: [InkTool: InkSettings] = [:]
        for (i, ink) in InkTool.allCases.enumerated() {
            let range = DrawingToolState.widthRange(for: ink)
            // Between presets, with digits a preset never has.
            let width = range.lowerBound + (range.upperBound - range.lowerBound) * (0.137 + 0.1 * Double(i))
            let color = Color(r: UInt8(10 + i * 31), g: UInt8(200 - i * 17), b: UInt8(33 + i * 5))
            let opacity = 0.31 + 0.09 * Double(i)
            s.select(DrawingTool(ink: ink))
            s.setColor(color, for: ink)
            s.setWidth(width, for: ink)
            s.setOpacity(opacity, for: ink)
            expected[ink] = InkSettings(color: color, width: width, opacity: opacity)
            XCTAssertFalse(DrawingToolState.widthPresets(for: ink).contains(width), "\(ink): not a preset")
        }
        s.select(.eraser)
        s.setPixelEraserWidth(41.7)
        s.select(.lasso)
        s.rulerActive = true
        s.select(.marker)   // the last tool
        // Switching through every tool changes no other tool's settings.
        for tool in DrawingTool.allCases { s.select(tool) }
        s.select(.marker)
        for ink in InkTool.allCases { XCTAssertEqual(s.settings(for: ink), expected[ink], "\(ink) after switching") }
        let back = DrawingToolState(decoding: s.encoded())
        for ink in InkTool.allCases {
            XCTAssertEqual(back.settings(for: ink), expected[ink], "\(ink) after a relaunch")
        }
        XCTAssertEqual(back.pixelEraserWidth, 41.7)
        XCTAssertTrue(back.rulerActive)
        XCTAssertEqual(back.tool, .marker)
        XCTAssertEqual(back.previousTool, .lasso)
    }

    func testPickingTheToolInUseKeepsTheWayBack() {
        var s = DrawingToolState()
        s.select(.marker)
        s.select(.marker)
        XCTAssertEqual(s.previousTool, .pen)
    }

    /// Build 10 asked for 0.2, but PencilKit draws nothing thinner than its floor: the palette's thinnest width is
    /// that floor, so it never shows a width that is not drawn.
    func testTheThinnestWidthIsPencilKitsFloor() {
        for ink in [InkTool.pen, .monoline, .fountainPen] {
            let floor = try! XCTUnwrap(DrawingToolState.pencilKitFloor(for: ink))
            XCTAssertEqual(DrawingToolState.widthRange(for: ink).lowerBound, floor, "\(ink)")
            XCTAssertEqual(DrawingToolState.widthPresets(for: ink).first, floor, "\(ink)")
            XCTAssertEqual(DrawingToolState.pencilKitWidth(0.1, for: ink), floor)
        }
        XCTAssertEqual(DrawingToolState.pencilKitWidth(3, for: .pen), 3)
        XCTAssertEqual(DrawingToolState.pencilKitWidth(0.2, for: .marker), 0.2)
    }
}
