import Foundation
import PencilKit
import Testing
@testable import SempereApp

/// The palette's eraser starts as the object (stroke) eraser and keeps the
/// user's later choice of eraser mode (`EraserPreference`, `DrawingToolbox`).
@MainActor
@Suite(.serialized)
struct EraserPreferenceTests {
    /// An empty defaults suite (one fixed name, emptied per use; the suite runs serially).
    func scratchDefaults() -> UserDefaults {
        let name = "sempere-eraser-tests"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsToTheObjectEraser() {
        #expect(EraserPreference.load(from: scratchDefaults()) == .vector)
    }


    /// Two modes are remembered, object and pixel: any pixel type reads back as `pixelType`
    /// (the platforms' pickers keep different pixel types), and older stored names still read.
    @Test func remembersTheLastMode() {
        let d = scratchDefaults()
        EraserPreference.save(.vector, to: d)
        #expect(EraserPreference.load(from: d) == .vector)
        for pixel in [PKEraserTool.EraserType.bitmap, .fixedWidthBitmap] {
            EraserPreference.save(pixel, to: d)
            #expect(EraserPreference.load(from: d) == EraserPreference.pixelType)
        }
        for (stored, mode) in [("pixel", EraserPreference.pixelType), ("pixelFixedWidth", EraserPreference.pixelType),
                               ("object", PKEraserTool.EraserType.vector)] {
            d.set(stored, forKey: EraserPreference.defaultsKey)
            #expect(EraserPreference.load(from: d) == mode, "stored \(stored)")
        }
        d.set("garbage", forKey: EraserPreference.defaultsKey)
        #expect(EraserPreference.load(from: d) == .vector)
    }

    @Test func pixelAndObjectAreTheOnlyModes() {
        #expect(EraserPreference.canonical(.vector) == .vector)
        #expect(EraserPreference.canonical(.bitmap) == EraserPreference.pixelType)
        #expect(EraserPreference.canonical(.fixedWidthBitmap) == EraserPreference.pixelType)
        #expect(!EraserPreference.isPixel(.vector))
        #expect(EraserPreference.isPixel(.bitmap) && EraserPreference.isPixel(.fixedWidthBitmap))
    }

    /// The palette's eraser follows the stored mode, and a mode picked in the palette is stored.
    @Test func thePaletteUsesTheStoredModeAndRecordsTheUsersChoice() {
        let d = scratchDefaults()
        #expect(DrawingToolbox(defaults: d).state.eraserMode == .object, "the object eraser by default")
        for stored in ["pixel", "pixelFixedWidth"] {
            d.set(stored, forKey: EraserPreference.defaultsKey)
            #expect(DrawingToolbox(defaults: d).state.eraserMode == .pixel, "stored \(stored)")
        }
        d.set("object", forKey: EraserPreference.defaultsKey)
        let toolbox = DrawingToolbox(defaults: d)
        #expect(toolbox.state.eraserMode == .object)
        toolbox.setEraserMode(.pixel)
        #expect(d.string(forKey: EraserPreference.defaultsKey) == "pixelFixedWidth", "settings sync reads this name")
        toolbox.select(.pen)
        #expect(EraserPreference.isPixel(EraserPreference.load(from: d)), "choosing a pen keeps the eraser mode")
        toolbox.setEraserMode(.object)
        #expect(EraserPreference.load(from: d) == .vector)
    }

    /// Settings sync (or Settings) writes the mode to the defaults: the palette follows.
    @Test func thePaletteFollowsASyncedMode() async {
        let d = scratchDefaults()
        let toolbox = DrawingToolbox(defaults: d)
        toolbox.select(.eraser)
        d.set("pixelFixedWidth", forKey: EraserPreference.defaultsKey)   // what `SettingsSyncBridge` writes
        for _ in 0..<50 where toolbox.state.eraserMode != .pixel { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(toolbox.state.eraserMode == .pixel)
        #expect(EraserPreference.isPixel(EraserPreference.eraserType(of: toolbox.pkTool) ?? .vector))
    }

    /// The canvas gets PencilKit's pixel eraser at the palette's width, and keeps that type (the platforms'
    /// pickers dropped some pixel types; a canvas's tool is set directly now).
    @Test func theCanvasKeepsThePixelEraser() throws {
        let toolbox = DrawingToolbox(defaults: scratchDefaults())
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800), embedded: false, toolbox: toolbox)
        toolbox.setEraserMode(.pixel)
        toolbox.setPixelEraserWidth(48)
        #expect(host.select(drawingTool: .eraser))
        let eraser = try #require(host.canvas.tool as? PKEraserTool)
        #expect(EraserPreference.isPixel(eraser.eraserType))
        #expect(abs(eraser.width - 48) < 0.5)
        #expect(!host.objectEraserSelected)
        toolbox.setEraserMode(.object)
        #expect((host.canvas.tool as? PKEraserTool)?.eraserType == .vector)
        #expect(host.objectEraserSelected)
    }
}
