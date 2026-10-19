import Foundation
import Observation
import PencilKit
import Sempere
import UIKit

/// The drawing palette's one tool state (`DrawingToolState`), shared by every canvas of every window
/// and device (docs/iphone.md "The drawing palette"). Sempere's own palette (`DrawingPaletteView`), the
/// Mac's Tools and Drawing Tools menus and the Apple Pencil's double-tap and squeeze change it here;
/// each canvas (`PageCanvasHost`) sets `PKCanvasView.tool` from it (`pkTool`) when it posts
/// `didChange`. PencilKit's `PKToolPicker` is not used: it never shows in a Mac Catalyst app.
///
/// Remembered across launches in `UserDefaults`: the tools and inks under `defaultsKey`; the eraser
/// mode under `EraserPreference.defaultsKey` (settings sync writes it there too) and the object
/// eraser's size under `ObjectEraserSize.defaultsKey`, as before.
@MainActor
@Observable
final class DrawingToolbox {
    /// The app's tool state.
    static let shared = DrawingToolbox(defaults: launchDefaults)

    /// `UserDefaults.standard`; in a demo-vault launch (`SEMPERE_DEMO`, the UI tests and the App Store
    /// screenshots) a defaults suite emptied at launch, so every such launch starts with the black pen and
    /// the object eraser whatever an earlier test picked.
    private static var launchDefaults: UserDefaults {
        #if DEBUG
        if DebugLaunch.environment["SEMPERE_DEMO"] != nil, let suite = UserDefaults(suiteName: "sempere-demo-tools") {
            suite.removePersistentDomain(forName: "sempere-demo-tools")
            return suite
        }
        #endif
        return .standard
    }
    static let defaultsKey = "Sempere.drawingTools"
    /// Posted (object: the toolbox) whenever the state changed.
    static let didChange = Notification.Name("SempereDrawingToolsDidChange")

    private(set) var state: DrawingToolState
    /// iPad: whether a finger draws while annotating, set with the palette's Draw with Finger (PencilKit's
    /// picker had this switch, `showsDrawingPolicyControls`); nil until the user sets it: the system's
    /// "Only Draw with Apple Pencil" decides (`PKCanvasViewDrawingPolicy.default`).
    private(set) var fingerDrawing: Bool?
    static let fingerDrawingKey = "Sempere.fingerDrawing"

    /// The palette shows its color and width choices (a Pencil gesture set to "show palette" toggles them).
    var showingAttributes = false
    /// Bumped by a Pencil gesture that asks for the palette (`DrawingPaletteView` follows it).
    private(set) var paletteRequests = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var state = DrawingToolState(decoding: defaults.data(forKey: Self.defaultsKey))
        state.eraserMode = Self.eraserMode(from: defaults)
        self.state = state
        fingerDrawing = defaults.object(forKey: Self.fingerDrawingKey) as? Bool
        // Settings sync (or Settings) may change the eraser mode under us.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadEraserMode() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Changing

    /// Picks `tool` (the palette, a menu, the Pencil).
    func select(_ tool: DrawingTool) {
        change { $0.select(tool) }
    }

    /// The selected ink's color, width or opacity (nothing for the eraser and the lasso).
    func setColor(_ color: Sempere.Color) {
        guard let ink = state.tool.ink else { return }
        change { $0.setColor(color, for: ink) }
    }

    func setWidth(_ width: Double) {
        guard let ink = state.tool.ink else { return }
        change { $0.setWidth(width, for: ink) }
    }

    func setOpacity(_ opacity: Double) {
        guard let ink = state.tool.ink else { return }
        change { $0.setOpacity(opacity, for: ink) }
    }

    /// The eraser's mode, remembered as `EraserPreference`.
    func setEraserMode(_ mode: EraserMode) {
        EraserPreference.save(Self.pkEraserType(mode), to: defaults)
        change { $0.eraserMode = mode }
    }

    func setPixelEraserWidth(_ width: Double) {
        change { $0.setPixelEraserWidth(width) }
    }

    /// iPad: a finger draws too (true), or only the Pencil (false).
    func setFingerDrawing(_ on: Bool) {
        guard fingerDrawing != on else { return }
        fingerDrawing = on
        defaults.set(on, forKey: Self.fingerDrawingKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Whether a finger draws on an iPad while annotating now: the palette's choice, else the system's.
    var fingersDrawNow: Bool { fingerDrawing ?? !UIPencilInteraction.prefersPencilOnlyDrawing }

    /// Shows or hides PencilKit's ruler on every canvas.
    func toggleRuler() {
        change { $0.rulerActive.toggle() }
    }

    /// The Apple Pencil's double-tap or squeeze, as the user set it (`UIPencilInteraction`).
    func pencil(_ action: PencilPreferredAction) {
        var next = state
        switch next.pencil(action) {
        case .nothing: return
        case .switchedTool: change { $0 = next }
        case .togglePalette:
            showingAttributes.toggle()
            paletteRequests &+= 1
        }
    }

    /// Applies `edit`; saves and tells the canvases when the state changed.
    private func change(_ edit: (inout DrawingToolState) -> Void) {
        var next = state
        edit(&next)
        guard next != state else { return }
        let toolChanged = next.tool != state.tool
        state = next
        defaults.set(next.encoded(), forKey: Self.defaultsKey)
        if toolChanged, next.tool == .lasso { showingAttributes = false }   // the lasso has no choices
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func reloadEraserMode() {
        let mode = Self.eraserMode(from: defaults)
        guard mode != state.eraserMode else { return }
        change { $0.eraserMode = mode }
    }

    // MARK: PencilKit

    /// The PencilKit tool for the state. The object eraser is `.vector` (the canvas hands it to the app's
    /// `ObjectEraserController`, which has a size); the pixel eraser is PencilKit's, at the state's width.
    var pkTool: PKTool { Self.pkTool(for: state) }

    static func pkTool(for state: DrawingToolState) -> PKTool {
        switch state.tool {
        case .eraser:
            switch state.eraserMode {
            case .object: return PKEraserTool(.vector)
            case .pixel: return PKEraserTool(pixelEraserType, width: CGFloat(state.pixelEraserWidth))
            }
        case .lasso:
            return PKLassoTool()
        default:
            guard let ink = state.tool.ink else { return PKInkingTool(.pen, color: .black, width: 2) }
            let s = state.settings(for: ink)
            return PKInkingTool(ink.pkInkType, color: s.inkColor.uiColor, width: CGFloat(s.width))
        }
    }

    /// The pixel eraser the canvas is given (a fixed width, whatever the zoom).
    static let pixelEraserType = PKEraserTool.EraserType.fixedWidthBitmap

    static func pkEraserType(_ mode: EraserMode) -> PKEraserTool.EraserType {
        mode == .pixel ? EraserPreference.pixelType : .vector
    }

    static func eraserMode(from defaults: UserDefaults) -> EraserMode {
        EraserPreference.isPixel(EraserPreference.load(from: defaults)) ? .pixel : .object
    }

    /// The user's Apple Pencil preference as the palette's action.
    nonisolated static func pencilAction(_ action: UIPencilPreferredAction) -> PencilPreferredAction {
        switch action {
        case .ignore: return .ignore
        case .switchEraser: return .switchEraser
        case .switchPrevious: return .switchPrevious
        case .showColorPalette, .showInkAttributes, .showContextualPalette: return .showPalette
        case .runSystemShortcut: return .ignore
        @unknown default: return .ignore
        }
    }

    /// `color` (stored, as drawn on light paper) as a page shows it: inverted for dark pages the way
    /// PencilKit shows ink there (`PageCanvasHost+Appearance`), unchanged on light pages.
    static func displayed(_ color: UIColor, darkPages: Bool) -> UIColor {
        darkPages ? PKInkingTool.convertColor(color, from: .light, to: .dark) : color
    }

    /// The color to store for `shown`, a color picked as the page shows it.
    static func stored(fromShown shown: UIColor, darkPages: Bool) -> UIColor {
        darkPages ? PKInkingTool.convertColor(shown, from: .dark, to: .light) : shown
    }
}

/// The Apple Pencil's double-tap and squeeze for the palette: one interaction per note view
/// (`DrawingPaletteView`), honoring the user's preference in Settings ▸ Apple Pencil
/// (`UIPencilInteraction.preferredTapAction` / `preferredSqueezeAction`). PencilKit shows the tool's
/// hover preview on the canvas by itself (`UIPencilInteraction.prefersHoverToolPreview`).
@MainActor
final class PencilGestures: NSObject, UIPencilInteractionDelegate {
    let interaction = UIPencilInteraction()
    var isEnabled: () -> Bool = { true }

    override init() {
        super.init()
        interaction.delegate = self
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard isEnabled() else { return }
        DrawingToolbox.shared.pencil(DrawingToolbox.pencilAction(UIPencilInteraction.preferredTapAction))
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard isEnabled(), squeeze.phase == .ended else { return }
        DrawingToolbox.shared.pencil(DrawingToolbox.pencilAction(UIPencilInteraction.preferredSqueezeAction))
    }
}
