import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The palette's tool state in the app (`DrawingToolbox`): what PencilKit tool each state gives the
/// canvases, what is remembered, the Apple Pencil's preferences, and the canvases following it. The
/// state itself is tested on Linux (`DrawingToolsTests`).
@MainActor
struct DrawingToolboxTests {
    /// An empty defaults suite of its own (tests run in parallel).
    static func scratchDefaults() -> UserDefaults {
        let name = "sempere-toolbox-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func eachToolBecomesItsPencilKitTool() throws {
        let toolbox = DrawingToolbox(defaults: Self.scratchDefaults())
        for tool in DrawingTool.allCases where tool.isInk {
            toolbox.select(tool)
            let ink = try #require(toolbox.pkTool as? PKInkingTool, "\(tool)")
            #expect(InkTool(ink.inkType) == tool.ink, "\(tool)")
            let settings = toolbox.state.settings(for: try #require(tool.ink))
            #expect(abs(Double(ink.width) - settings.width) < 0.01, "\(tool): its width")
        }
        toolbox.select(.lasso)
        #expect(toolbox.pkTool is PKLassoTool)
        toolbox.select(.eraser)
        toolbox.setEraserMode(.object)
        #expect((toolbox.pkTool as? PKEraserTool)?.eraserType == .vector, "the app's object eraser takes over from `.vector`")
        toolbox.setEraserMode(.pixel)
        #expect((toolbox.pkTool as? PKEraserTool)?.eraserType == DrawingToolbox.pixelEraserType)
    }

    /// Color, width and opacity: the ink's color carries the opacity as its alpha, as drawn on light paper.
    @Test func colorWidthAndOpacityReachTheInk() throws {
        let toolbox = DrawingToolbox(defaults: Self.scratchDefaults())
        toolbox.select(.marker)
        toolbox.setColor(DrawingToolState.swatches[2])
        toolbox.setWidth(35)
        toolbox.setOpacity(0.5)
        let ink = try #require(toolbox.pkTool as? PKInkingTool)
        #expect(ink.inkType == .marker)
        let color = Sempere.Color(ink.color)
        #expect(color.r == 0 && color.g == 122 && color.b == 255)
        #expect(abs(Int(color.a) - 128) <= 1)
        #expect(abs(ink.width - 35) < 0.01)
        // The pen kept its own.
        toolbox.select(.pen)
        let pen = try #require(toolbox.pkTool as? PKInkingTool)
        #expect(Sempere.Color(pen.color) == Sempere.Color.black)
        // The lasso and the eraser have no ink: nothing changes.
        toolbox.select(.lasso)
        let before = toolbox.state
        toolbox.setColor(DrawingToolState.swatches[3])
        toolbox.setWidth(2)
        #expect(toolbox.state == before)
    }

    @Test func theStateIsRememberedAcrossLaunches() {
        let d = Self.scratchDefaults()
        let toolbox = DrawingToolbox(defaults: d)
        toolbox.select(.fountainPen)
        toolbox.setColor(DrawingToolState.swatches[6])
        toolbox.setWidth(7)
        toolbox.setOpacity(0.75)
        toolbox.setPixelEraserWidth(32)
        toolbox.toggleRuler()
        let next = DrawingToolbox(defaults: d)
        #expect(next.state.tool == .fountainPen)
        #expect(next.state.settings(for: .fountainPen) == toolbox.state.settings(for: .fountainPen))
        #expect(next.state.pixelEraserWidth == 32)
        #expect(next.state.rulerActive, "the ruler is remembered too")
    }

    /// Owner, PR #51: "Every tool should remember its last settings." Distinct values on every ink (exact,
    /// off-preset widths from the slider), both eraser modes and their sizes, the ruler and Draw with Finger,
    /// through tool and mode switches and a relaunch (a new tool state over the same defaults); and each ink's
    /// exact width reaches PencilKit's tool.
    @Test func everyToolRemembersItsOwnSettingsAcrossLaunches() throws {
        let d = Self.scratchDefaults()
        let toolbox = DrawingToolbox(defaults: d)
        var expected: [InkTool: InkSettings] = [:]
        for (i, ink) in InkTool.allCases.enumerated() {
            let range = DrawingToolbox.widthRange(for: ink)
            let width = range.lowerBound + (range.upperBound - range.lowerBound) * (0.23 + 0.09 * Double(i))
            let color = Sempere.Color(r: UInt8(20 + i * 29), g: UInt8(180 - i * 13), b: UInt8(90 + i * 7))
            let opacity = 0.35 + 0.08 * Double(i)
            toolbox.select(DrawingTool(ink: ink))
            toolbox.setColor(color)
            toolbox.setWidth(width)
            toolbox.setOpacity(opacity)
            expected[ink] = InkSettings(color: color, width: width, opacity: opacity)
        }
        toolbox.select(.eraser)
        toolbox.setEraserMode(.pixel)
        toolbox.setPixelEraserWidth(37.25)
        ObjectEraserSize.save(16, to: d)
        toolbox.select(.lasso)
        toolbox.toggleRuler()
        toolbox.setFingerDrawing(false)
        toolbox.select(.fountainPen)

        for launch in 0..<2 {
            let box = launch == 0 ? toolbox : DrawingToolbox(defaults: d)
            let what = launch == 0 ? "this launch" : "the next launch"
            #expect(box.state.tool == .fountainPen, "\(what)")
            for ink in InkTool.allCases {
                #expect(box.state.settings(for: ink) == expected[ink], "\(ink), \(what)")
                box.select(DrawingTool(ink: ink))
                let tool = try #require(box.pkTool as? PKInkingTool)
                #expect(abs(Double(tool.width) - (expected[ink]?.width ?? 0)) < 0.001, "\(ink): PencilKit gets the exact width, \(what)")
                #expect(Sempere.Color(tool.color) == expected[ink]?.color.withAlpha(tool), "\(ink)'s color, \(what)")
            }
            #expect(box.state.eraserMode == .pixel && box.state.pixelEraserWidth == 37.25, "\(what)")
            box.select(.eraser)
            #expect(abs(Double((box.pkTool as? PKEraserTool)?.width ?? 0) - 37.25) < 0.01)
            #expect(ObjectEraserSize.load(from: d) == 16)
            #expect(box.state.rulerActive, "\(what)")
            #expect(box.fingerDrawing == false, "\(what)")
            box.select(.fountainPen)
        }
    }


    @Test func changesAreAnnounced() {
        let toolbox = DrawingToolbox(defaults: Self.scratchDefaults())
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: DrawingToolbox.didChange, object: toolbox, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        toolbox.select(.marker)
        toolbox.select(.marker)   // no change: no post
        toolbox.setWidth(12)
        #expect(posts == 2)
    }

    /// iPad: Draw with Finger decides the annotating policy once set; until then the system's setting does.
    @Test func drawWithFingerSetsTheIPadsPolicy() {
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: false, padFingers: nil) == .default)
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: false, padFingers: true) == .anyInput)
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: false, padFingers: false) == .pencilOnly)
        #expect(PageCanvasHost.drawingPolicy(device: .pad, phoneFingersDraw: false, pencilAnnotates: true, padFingers: true) == .pencilOnly,
                "reading and Hand: only the Pencil, whatever the switch")
        #expect(PageCanvasHost.drawingPolicy(device: .mac, phoneFingersDraw: false, pencilAnnotates: false, padFingers: false) == .anyInput)
        let d = Self.scratchDefaults()
        let toolbox = DrawingToolbox(defaults: d)
        #expect(toolbox.fingerDrawing == nil)
        toolbox.setFingerDrawing(true)
        #expect(DrawingToolbox(defaults: d).fingerDrawing == true, "remembered")
        toolbox.setFingerDrawing(false)
        #expect(!toolbox.fingersDrawNow)
    }

    /// The user's Apple Pencil preference (Settings ▸ Apple Pencil) as the palette's action.
    @Test func pencilPreferencesMapToActions() {
        #expect(DrawingToolbox.pencilAction(.ignore) == .ignore)
        #expect(DrawingToolbox.pencilAction(.switchEraser) == .switchEraser)
        #expect(DrawingToolbox.pencilAction(.switchPrevious) == .switchPrevious)
        #expect(DrawingToolbox.pencilAction(.showColorPalette) == .showPalette)
        #expect(DrawingToolbox.pencilAction(.showInkAttributes) == .showPalette)
        #expect(DrawingToolbox.pencilAction(.showContextualPalette) == .showPalette)
        #expect(DrawingToolbox.pencilAction(.runSystemShortcut) == .ignore)
    }

    @Test func aPencilDoubleTapSwitchesTheCanvasesTool() {
        let toolbox = DrawingToolbox(defaults: Self.scratchDefaults())
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800), embedded: false, toolbox: toolbox)
        toolbox.select(.pen)
        toolbox.setEraserMode(.object)
        toolbox.pencil(.switchEraser)
        #expect(toolbox.state.tool == .eraser)
        #expect(host.objectEraserSelected, "the canvas erases")
        toolbox.pencil(.switchEraser)
        #expect((host.canvas.tool as? PKInkingTool)?.inkType == .pen, "and back")
        let shown = toolbox.showingAttributes
        toolbox.pencil(.showPalette)
        #expect(toolbox.showingAttributes != shown)
        #expect(toolbox.state.tool == .pen)
    }

    /// Every canvas draws with the palette's tool, and follows it: the one-page canvas and an embedded one.
    @Test func canvasesFollowTheToolState() throws {
        let toolbox = DrawingToolbox(defaults: Self.scratchDefaults())
        let one = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800), embedded: false, toolbox: toolbox)
        let page = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800), embedded: true, toolbox: toolbox)
        toolbox.select(.pencil)
        toolbox.setColor(DrawingToolState.swatches[4])
        for host in [one, page] {
            let ink = try #require(host.canvas.tool as? PKInkingTool)
            #expect(ink.inkType == .pencil)
            #expect(Sempere.Color(ink.color) == DrawingToolState.swatches[4])
        }
        toolbox.toggleRuler()
        #expect(one.canvas.isRulerActive)
        page.rulerHere = false   // a page without the stack's focus
        #expect(!page.canvas.isRulerActive)
        toolbox.toggleRuler()
        #expect(!one.canvas.isRulerActive)
    }

    /// Picking a tool is drawing: the Hand, the text tool and the math lasso end on the canvas it was picked for.
    @Test func pickingAToolEndsTheOtherModes() {
        let toolbox = DrawingToolbox(defaults: Self.scratchDefaults())
        let host = PageCanvasHost(frame: CGRect(x: 0, y: 0, width: 600, height: 800), embedded: false, toolbox: toolbox)
        var ended: [String] = []
        host.onItemSelectionEnded = { ended.append("hand") }
        host.onTextToolEnded = { _ in ended.append("text") }
        host.itemSelectionActive = true
        host.select(drawingTool: .marker)
        host.itemSelectionActive = false
        host.textToolActive = true
        host.select(drawingTool: .pen)
        #expect(ended == ["hand", "text"])
        // A change made elsewhere (another window's palette) only changes the tool.
        host.textToolActive = true
        toolbox.select(.lasso)
        #expect(ended == ["hand", "text"])
        #expect(host.canvas.tool is PKLassoTool)
    }

    /// Colors are stored as drawn on light paper; dark pages show them as PencilKit shows the ink there,
    /// and a color picked as shown on a dark page is stored back as the light one.
    @Test func darkPagesShowTheConvertedColor() {
        let blue = DrawingToolState.swatches[2].uiColor
        #expect(DrawingToolbox.displayed(blue, darkPages: false) == blue)
        let shown = DrawingToolbox.displayed(blue, darkPages: true)
        #expect(Sempere.Color(shown) == Sempere.Color(PKInkingTool.convertColor(blue, from: .light, to: .dark)))
        let back = Sempere.Color(DrawingToolbox.stored(fromShown: shown, darkPages: true))
        let original = Sempere.Color(blue)
        #expect(abs(Int(back.r) - Int(original.r)) <= 3 && abs(Int(back.g) - Int(original.g)) <= 3
                && abs(Int(back.b) - Int(original.b)) <= 3, "\(back.hex) vs \(original.hex)")
        // Black ink shows light on a dark page.
        let black = Sempere.Color(DrawingToolbox.displayed(.black, darkPages: true))
        #expect(Int(black.r) + Int(black.g) + Int(black.b) > 600)
    }
}

private extension Sempere.Color {
    /// This color with `tool`'s alpha (the opacity rides in the ink's alpha; compared on its own).
    func withAlpha(_ tool: PKInkingTool) -> Sempere.Color {
        var c = self
        c.a = Sempere.Color(tool.color).a
        return c
    }
}
