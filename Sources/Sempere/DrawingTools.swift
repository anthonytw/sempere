import Foundation

/// A tool of Sempere's drawing palette (the app's own palette, which replaced PencilKit's
/// `PKToolPicker` on every device: docs/iphone.md "The drawing palette"). The inks are PencilKit's
/// (`InkTool`); the eraser is the app's object eraser or PencilKit's pixel eraser (`EraserMode`).
public enum DrawingTool: String, Hashable, Sendable, Codable, CaseIterable {
    case pen, monoline, fountainPen, marker, pencil, watercolor, crayon, eraser, lasso

    /// The ink this tool draws with, nil for the eraser and the lasso.
    public var ink: InkTool? {
        switch self {
        case .pen: return .pen
        case .monoline: return .monoline
        case .fountainPen: return .fountainPen
        case .marker: return .marker
        case .pencil: return .pencil
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        case .eraser, .lasso: return nil
        }
    }

    /// The tool that draws with `ink`.
    public init(ink: InkTool) {
        switch ink {
        case .pen: self = .pen
        case .monoline: self = .monoline
        case .fountainPen: self = .fountainPen
        case .marker: self = .marker
        case .pencil: self = .pencil
        case .watercolor: self = .watercolor
        case .crayon: self = .crayon
        }
    }

    /// Whether the tool draws ink (it has a color, a width and an opacity).
    public var isInk: Bool { ink != nil }
}

/// The eraser's two modes: the app's object eraser (whole strokes, `ObjectEraser.swift`) or
/// PencilKit's pixel eraser.
public enum EraserMode: String, Hashable, Sendable, Codable, CaseIterable {
    case object, pixel
}

/// What the user set for one ink: its color as drawn on light paper (stored ink colors never
/// change with dark pages), its width in PencilKit's tool units and its opacity.
public struct InkSettings: Hashable, Sendable, Codable {
    /// Opaque: the opacity is `opacity`.
    public var color: Color
    public var width: Double
    /// 0.05 ... 1.
    public var opacity: Double

    public init(color: Color, width: Double, opacity: Double = 1) {
        self.color = color
        self.width = width
        self.opacity = opacity
    }

    /// The color with `opacity` as its alpha: what the ink draws.
    public var inkColor: Color {
        var c = color
        c.a = UInt8((DrawingToolState.clampOpacity(opacity) * 255).rounded())
        return c
    }
}

/// What the user set the Apple Pencil's double-tap or squeeze to do (Settings ▸ Apple Pencil),
/// as the palette understands it (`UIPencilPreferredAction` in the app).
public enum PencilPreferredAction: Hashable, Sendable {
    /// Nothing (also "run a shortcut", which the system handles).
    case ignore
    /// The eraser, or back to the tool before it.
    case switchEraser
    /// The tool used before this one.
    case switchPrevious
    /// The color and width choices (the system's "show color palette", "show ink attributes" and
    /// "show contextual palette").
    case showPalette
}

/// What the palette does after a Pencil gesture (`DrawingToolState.pencil(_:)`).
public enum PencilOutcome: Hashable, Sendable {
    case nothing
    /// The tool changed.
    case switchedTool
    /// Show or hide the color and width choices.
    case togglePalette
}

/// The palette's state, shared by every canvas (one value app-wide: the tool, each ink's color,
/// width and opacity, the eraser mode and the pixel eraser's width, the ruler). Pure, so it is tested
/// on Linux; the app maps it to PencilKit (`DrawingToolbox`) and keeps it in `UserDefaults`
/// (`encoded()` / `init(decoding:)`). The object eraser's size stays `ObjectEraserSize`'s.
public struct DrawingToolState: Hashable, Sendable {
    /// The tool the canvases draw with.
    public private(set) var tool: DrawingTool
    /// The tool before `tool` (the Pencil's "switch to previous", the way back from the eraser).
    public private(set) var previousTool: DrawingTool
    /// Each ink's settings; every `InkTool` has one.
    public private(set) var inks: [InkTool: InkSettings]
    public var eraserMode: EraserMode
    /// The pixel eraser's width (PencilKit units, `pixelEraserWidths`).
    public private(set) var pixelEraserWidth: Double
    /// PencilKit's ruler is shown (remembered across launches, as every tool's state).
    public var rulerActive = false

    /// A fresh palette: the pen, black, at its default width; the object eraser.
    public init() {
        tool = .pen
        previousTool = .marker
        inks = Dictionary(uniqueKeysWithValues: InkTool.allCases.map { ($0, Self.defaultSettings(for: $0)) })
        eraserMode = .object
        pixelEraserWidth = Self.pixelEraserWidths[1]
    }

    // MARK: The palette's contents

    /// Every tool, in the full palette's order.
    public static let fullTools: [DrawingTool] = [.pen, .monoline, .fountainPen, .marker, .pencil, .watercolor, .crayon,
                                                   .eraser, .lasso]

    /// The compact palette's tools (the iPhone's, and the iPad's or the Mac's Compact Palette): pen, marker,
    /// eraser and lasso, as PencilKit's compact picker had. A tool picked elsewhere (the Mac's Tools menu
    /// picks the pencil) is shown too, first, so the palette always shows the tool in use.
    public static func compactTools(selected: DrawingTool) -> [DrawingTool] {
        let base: [DrawingTool] = [.pen, .marker, .eraser, .lasso]
        return base.contains(selected) ? base : [selected] + base
    }

    /// The color swatches (as drawn on light paper): black, gray, blue, red, green, orange, purple, yellow.
    public static let swatches: [Color] = [
        Color(r: 0, g: 0, b: 0), Color(r: 142, g: 142, b: 147), Color(r: 0, g: 122, b: 255),
        Color(r: 255, g: 59, b: 48), Color(r: 52, g: 199, b: 89), Color(r: 255, g: 149, b: 0),
        Color(r: 175, g: 82, b: 222), Color(r: 255, g: 204, b: 0),
    ]

    /// The opacity presets the palette offers.
    public static let opacityPresets: [Double] = [0.25, 0.5, 0.75, 1]

    /// Five widths per ink, thin to thick, in PencilKit's tool units (inside each ink's
    /// `PKInkingTool.InkType.validWidthRange`, measured on macOS 27). The writing inks start at the
    /// thinnest width PencilKit draws and are dense at the thin end (TestFlight build 8: "the minimum
    /// stroke widths are too large. I like a thin line"); thicker widths are on the slider.
    public static func widthPresets(for ink: InkTool) -> [Double] {
        switch ink {
        case .pen: return [0.88, 1.3, 1.8, 2.7, 5]
        case .monoline: return [0.5, 0.75, 1, 1.75, 2.75]
        case .fountainPen: return [1.5, 2, 2.5, 4, 7]
        case .marker: return [7.5, 12, 20, 35, 60]
        case .pencil: return [2.4, 3, 3.5, 5, 8]
        case .watercolor: return [10, 20, 40, 60, 80]
        case .crayon: return [10, 20, 30, 40, 50]
        }
    }

    /// The widths an ink accepts (PencilKit's `validWidthRange`); stored widths outside are clamped.
    public static func widthRange(for ink: InkTool) -> ClosedRange<Double> {
        switch ink {
        case .pen: return 0.88...25.6
        case .monoline: return 0.5...4
        case .fountainPen: return 1.5...14
        case .marker: return 7.5...60
        case .pencil: return 2.4...16
        case .watercolor: return 10...80
        case .crayon: return 10...50
        }
    }

    /// The thinnest tool width PencilKit takes for `ink` (`PKInkingTool` clamps below it; measured on macOS 27:
    /// pen 0.878, monoline 0.5, fountain pen 1.5), nil when the model's range is all PencilKit takes. Thinner lines
    /// than these need Sempere's own stroke rendering (post-v1): a tool width below the floor is never drawn, so the
    /// palette offers none (build 10 asked for 0.2; rewriting strokes after the fact was tried and dropped).
    public static func pencilKitFloor(for ink: InkTool) -> Double? {
        switch ink {
        case .pen: return 0.88
        case .monoline: return 0.5
        case .fountainPen: return 1.5
        case .marker, .pencil, .watercolor, .crayon: return nil
        }
    }

    /// The tool width to give PencilKit for a palette width: never below what PencilKit draws.
    public static func pencilKitWidth(_ width: Double, for ink: InkTool) -> Double {
        guard let floor = pencilKitFloor(for: ink) else { return width }
        return max(width, floor)
    }

    /// The pixel eraser's widths (PencilKit's `validWidthRange` for it is 16.4 ... 80.4).
    public static let pixelEraserWidths: [Double] = [16.4, 24, 32, 48, 80]

    /// A fresh ink: black (the marker yellow, watercolor blue, crayon red), at its middle preset.
    public static func defaultSettings(for ink: InkTool) -> InkSettings {
        let color: Color
        switch ink {
        case .marker: color = swatches[7]
        case .watercolor: color = swatches[2]
        case .crayon: color = swatches[3]
        case .pen, .monoline, .fountainPen, .pencil: color = swatches[0]
        }
        let presets = widthPresets(for: ink)
        return InkSettings(color: color, width: presets[presets.count / 2], opacity: 1)
    }

    /// `opacity` inside 0.05 ... 1 (NaN: 1).
    public static func clampOpacity(_ opacity: Double) -> Double {
        opacity.isFinite ? min(max(opacity, 0.05), 1) : 1
    }

    // MARK: Reading

    /// `ink`'s settings.
    public func settings(for ink: InkTool) -> InkSettings {
        inks[ink] ?? Self.defaultSettings(for: ink)
    }

    /// The selected tool's settings, nil for the eraser and the lasso.
    public var currentInk: InkSettings? { tool.ink.map(settings(for:)) }

    /// The selected width preset's index for `ink` (the nearest one).
    public func widthIndex(for ink: InkTool) -> Int {
        Self.nearestIndex(of: settings(for: ink).width, in: Self.widthPresets(for: ink))
    }

    /// The index of the preset nearest to `value` (0 for no presets).
    public static func nearestIndex(of value: Double, in presets: [Double]) -> Int {
        presets.indices.min { abs(presets[$0] - value) < abs(presets[$1] - value) } ?? 0
    }

    // MARK: Changing

    /// Picks `tool`. Picking the tool in use changes nothing (so the way back stays).
    public mutating func select(_ tool: DrawingTool) {
        guard tool != self.tool else { return }
        previousTool = self.tool
        self.tool = tool
    }

    /// Sets `ink`'s color (its alpha is ignored: the opacity is separate).
    public mutating func setColor(_ color: Color, for ink: InkTool) {
        var s = settings(for: ink)
        s.color = Color(r: color.r, g: color.g, b: color.b)
        inks[ink] = s
    }

    /// Sets `ink`'s width, clamped to what the ink accepts.
    public mutating func setWidth(_ width: Double, for ink: InkTool) {
        var s = settings(for: ink)
        s.width = Self.clampWidth(width, for: ink)
        inks[ink] = s
    }

    /// Sets `ink`'s opacity (0.05 ... 1).
    public mutating func setOpacity(_ opacity: Double, for ink: InkTool) {
        var s = settings(for: ink)
        s.opacity = Self.clampOpacity(opacity)
        inks[ink] = s
    }

    /// Sets the pixel eraser's width (16.4 ... 80.4).
    public mutating func setPixelEraserWidth(_ width: Double) {
        pixelEraserWidth = width.isFinite ? min(max(width, 16.4), 80.4) : Self.pixelEraserWidths[1]
    }

    static func clampWidth(_ width: Double, for ink: InkTool) -> Double {
        let range = widthRange(for: ink)
        guard width.isFinite else { return defaultSettings(for: ink).width }
        return min(max(width, range.lowerBound), range.upperBound)
    }

    /// The Apple Pencil's double-tap or squeeze, as the user set it in Settings: switches to the eraser
    /// (or back from it), to the previous tool, or asks for the color and width choices.
    public mutating func pencil(_ action: PencilPreferredAction) -> PencilOutcome {
        switch action {
        case .ignore:
            return .nothing
        case .switchEraser:
            if tool == .eraser {
                // Back to the tool before the eraser (the pen when that was the eraser too).
                select(previousTool == .eraser ? .pen : previousTool)
            } else {
                select(.eraser)
            }
            return .switchedTool
        case .switchPrevious:
            select(previousTool)
            return .switchedTool
        case .showPalette:
            return .togglePalette
        }
    }

    // MARK: Storage

    /// What is remembered (`encoded`): the tool, the one before it, each ink's exact color, width and opacity,
    /// the pixel eraser's width and the ruler. The eraser mode is `EraserPreference`'s in the app (settings sync
    /// writes it there), as is the object eraser's size (`ObjectEraserSize`).
    struct Stored: Codable {
        var tool: String?
        var previous: String?
        var inks: [String: StoredInk]?
        var pixelEraserWidth: Double?
        var ruler: Bool?
    }

    struct StoredInk: Codable {
        var color: String?
        var width: Double?
        var opacity: Double?
    }

    /// The state as JSON, for `UserDefaults`.
    public func encoded() -> Data {
        var inks: [String: StoredInk] = [:]
        for ink in InkTool.allCases {
            let s = settings(for: ink)
            inks[ink.rawValue] = StoredInk(color: s.color.hex, width: s.width, opacity: s.opacity)
        }
        let stored = Stored(tool: tool.rawValue, previous: previousTool.rawValue, inks: inks,
                            pixelEraserWidth: pixelEraserWidth, ruler: rulerActive)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(stored)) ?? Data()
    }

    /// The state stored by `encoded`. Whatever is missing, unknown or out of range takes its default (a
    /// width or opacity is clamped), so a damaged value never fails: the palette starts fresh instead.
    public init(decoding data: Data?) {
        self.init()
        guard let data, data.count <= 64 * 1024,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        if let t = stored.tool.flatMap(DrawingTool.init(rawValue:)) { tool = t }
        if let p = stored.previous.flatMap(DrawingTool.init(rawValue:)) { previousTool = p }
        for (name, value) in stored.inks ?? [:] {
            guard let ink = InkTool.allCases.first(where: { $0.rawValue == name }) else { continue }
            if let hex = value.color, let c = Color(hex: hex) { setColor(c, for: ink) }
            if let w = value.width { setWidth(w, for: ink) }
            if let o = value.opacity { setOpacity(o, for: ink) }
        }
        if let w = stored.pixelEraserWidth { setPixelEraserWidth(w) }
        if let r = stored.ruler { rulerActive = r }
    }
}
