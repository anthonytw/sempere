import Foundation
import PencilKit
import Testing
@testable import SempereApp

/// The tool picker starts with the object (stroke) eraser and keeps the
/// user's later choice of eraser mode.
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

    func eraserItems(_ picker: PKToolPicker) -> [PKToolPickerEraserItem] {
        picker.toolItems.compactMap { $0 as? PKToolPickerEraserItem }
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

    /// PencilKit's saved eraser (which restores the pixel eraser over the
    /// item the app passes) is dropped; its other tools are kept.
    @Test func forgetsOnlyPencilKitsSavedEraser() {
        let d = scratchDefaults()
        #expect(!EraserPreference.forgetPencilKitEraser(in: d))
        let pen: [String: Any] = ["identifier": "com.apple.ink.pen", "isSelected": true]
        let eraser: [String: Any] = ["identifier": "com.apple.ink.eraser", "properties": ["PKInkVariantProperty": "default"]]
        d.set(["PKPaletteTools": [pen, eraser], "other": 3], forKey: EraserPreference.pencilKitStateKey)
        #expect(EraserPreference.forgetPencilKitEraser(in: d))
        let state = d.dictionary(forKey: EraserPreference.pencilKitStateKey)
        let tools = state?["PKPaletteTools"] as? [[String: Any]]
        #expect(tools?.compactMap { $0["identifier"] as? String } == ["com.apple.ink.pen"])
        #expect(state?["other"] as? Int == 3)
        #expect(!EraserPreference.forgetPencilKitEraser(in: d))
    }

    /// What the platform's picker keeps for each eraser item type (printed for the CI and
    /// Catalyst logs: iPadOS 26 kept a pixel eraser as `.fixedWidthBitmap`; macOS 27
    /// Catalyst does not keep a `.fixedWidthBitmap` item; the iPadOS 27.0 simulator keeps neither).
    @Test func thePixelTypeIsOneThePickerKeeps() {
        for candidate in EraserPreference.pixelCandidates {
            let kept = EraserPreference.eraserType(in: EraserPreference.picker(eraserItem: candidate))
            print("ERASER-PROBE item \(String(describing: candidate)) kept as \(kept.map { String(describing: $0) } ?? "none")")
        }
        guard let pixel = EraserPreference.pixelPickerType() else {
            // The documented fallback: no pixel eraser item survives, the picker starts with the object eraser.
            #expect(EraserPreference.eraserType(in: EraserPreference.makeToolPicker(eraser: .bitmap)) == .vector)
            return
        }
        #expect(EraserPreference.pixelCandidates.contains(pixel))
        let kept = EraserPreference.eraserType(in: EraserPreference.picker(eraserItem: pixel))
        #expect(kept.map(EraserPreference.isPixel) == true, "the probed type survives the picker")
    }

    @Test func pickerKeepsTheSystemToolsAndStartsWithTheChosenEraser() {
        let system = PKToolPicker().toolItems
        let pixelKept = EraserPreference.pixelPickerType() != nil
        for mode in [PKEraserTool.EraserType.vector, .fixedWidthBitmap, .bitmap] {
            let picker = EraserPreference.makeToolPicker(eraser: mode)
            #expect(picker.toolItems.count == system.count)
            let erasers = eraserItems(picker)
            #expect(erasers.count == 1)
            let shown = erasers.first?.eraserTool.eraserType
            // The chosen mode, as this platform's picker shows it.
            let expected = EraserPreference.isPixel(mode) && pixelKept
            #expect(shown.map(EraserPreference.isPixel) == expected, "mode \(String(describing: mode)) shown as \(shown.map { String(describing: $0) } ?? "none")")
            // Every other tool is still offered, in the same order.
            let kinds = picker.toolItems.map { String(describing: type(of: $0)) }
            #expect(kinds == system.map { String(describing: type(of: $0)) })
        }
    }

    @Test func canvasPickerUsesTheStoredModeAndRecordsTheUsersChoice() throws {
        let key = EraserPreference.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        // Whatever PencilKit saved earlier (its pixel eraser), a canvas starts
        // with the object eraser when the user has not chosen another.
        let fresh = PageCanvasHost()
        #expect(eraserItems(fresh.toolPicker).first?.eraserTool.eraserType == .vector)

        // The user switches to the pixel eraser in the picker (the platform's pixel type).
        let host = PageCanvasHost()
        let pixelType = EraserPreference.pixelPickerType() ?? .bitmap
        let pixel = PKToolPickerEraserItem(type: pixelType)
        let picker = PKToolPicker(toolItems: host.toolPicker.toolItems.map { $0 is PKToolPickerEraserItem ? pixel : $0 })
        picker.selectedToolItem = pixel
        let reported = pixel.eraserTool.eraserType
        host.toolPickerSelectedToolItemDidChange(picker)
        // Whatever pixel type the item reports, the pixel mode is what is remembered.
        #expect(EraserPreference.load() == EraserPreference.canonical(reported))
        if EraserPreference.isPixel(reported) {
            #expect(EraserPreference.load() == EraserPreference.pixelType)
            if EraserPreference.pixelPickerType() != nil {
                let next = eraserItems(PageCanvasHost().toolPicker).first?.eraserTool.eraserType
                #expect(next.map(EraserPreference.isPixel) == true, "the next canvas starts with the pixel eraser")
            }
        }

        // Choosing a pen does not change the remembered eraser.
        let before = EraserPreference.load()
        let pen = try #require(picker.toolItems.first { $0 is PKToolPickerInkingItem })
        picker.selectedToolItem = pen
        host.toolPickerSelectedToolItemDidChange(picker)
        #expect(EraserPreference.load() == before)
    }
}
