import PencilKit
import Sempere
import SwiftUI
import UIKit

/// Sempere's drawing palette, on every device (docs/iphone.md "The drawing palette"): PencilKit's
/// `PKToolPicker` never shows in a Mac Catalyst app, so the iPad, the iPhone and the Mac share this one
/// instead. Shown only while annotating (`NoteMode.showsPalette`), docked at the bottom of the note.
///
/// - Full (iPad and Mac): every tool, the selected tool's choices inline (an ink's swatches, any color,
///   widths and opacity; the eraser's mode and size), the ruler. A window too narrow for it gets the
///   compact palette.
/// - Compact (always on an iPhone; Compact Palette elsewhere): pen, marker, eraser, lasso (and a tool picked
///   elsewhere), the choices in a popover from the color button; on an iPhone, undo and redo.
///
/// A tap on the selected tool shows or hides its choices, as PencilKit's palette did. Every canvas draws
/// with the one tool state (`DrawingToolbox`); picking a tool here goes through the note's canvas
/// (`CanvasCommandTarget.select(drawingTool:)`), which ends the Hand, the text tool or the math lasso.
/// Colors are stored as drawn on light paper; on dark pages the palette shows them as the page does.
struct DrawingPaletteView: View {
    let editor: NoteEditor
    var compact: Bool
    var toolbox = DrawingToolbox.shared
    @AppStorage(ObjectEraserSize.defaultsKey) private var eraserRadius = ObjectEraserSize.defaultRadius
    @AppStorage(NotePagesAppearance.key) private var notePages = NotePagesAppearance.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if compact {
                compactBar
            } else {
                // A window too narrow for every tool gets the compact bar.
                ViewThatFits(in: .horizontal) {
                    fullBar
                    compactBar
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Drawing-Palette")
    }

    // MARK: The bars

    private var fullBar: some View {
        HStack(spacing: 6) {
            ForEach(DrawingToolState.fullTools, id: \.self) { toolButton($0) }
            separator
            HStack(spacing: 6) { inlineChoices }
                .popover(isPresented: attributesShown) { choicesPanel }
            separator
            rulerButton
        }
        .modifier(PaletteChrome())
    }

    private var compactBar: some View {
        HStack(spacing: 4) {
            ForEach(DrawingToolState.compactTools(selected: state.tool), id: \.self) { toolButton($0) }
            if state.tool != .lasso {
                separator
                choicesButton
                    .popover(isPresented: attributesShown) { choicesPanel }
            }
            if Platform.isPhone {
                separator
                PaletteButton(title: "Undo", systemImage: "arrow.uturn.backward", help: "Undo the last change") {
                    editor.canvasTarget?.undo()
                }
                PaletteButton(title: "Redo", systemImage: "arrow.uturn.forward", help: "Redo the last change undone") {
                    editor.canvasTarget?.redo()
                }
            }
        }
        .modifier(PaletteChrome())
    }

    private var separator: some View {
        Divider().frame(height: 24).padding(.horizontal, 2)
    }

    // MARK: Tools

    private var state: DrawingToolState { toolbox.state }

    private var attributesShown: Binding<Bool> {
        Binding(get: { toolbox.showingAttributes && state.tool != .lasso },
                set: { toolbox.showingAttributes = $0 })
    }

    @ViewBuilder
    private func toolButton(_ tool: DrawingTool) -> some View {
        let selected = state.tool == tool
        PaletteButton(label: Self.title(of: tool, eraserMode: state.eraserMode), systemImage: icon(of: tool),
                      tip: Self.help(of: tool), selected: selected,
                      tint: tool.ink.map { shown(state.settings(for: $0).inkColor) }) {
            if selected {
                // As PencilKit's palette: a tap on the selected tool shows its choices.
                if tool != .lasso { toolbox.showingAttributes.toggle() }
            } else {
                pick(tool)
            }
        }
    }

    private func pick(_ tool: DrawingTool) {
        if editor.canvasTarget?.select(drawingTool: tool) != true { toolbox.select(tool) }
    }

    private func icon(of tool: DrawingTool) -> String {
        switch tool {
        case .pen: return "pencil.tip"
        case .monoline: return "pencil.line"
        case .fountainPen: return "scribble.variable"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .watercolor: return "paintbrush"
        case .crayon: return "paintbrush.pointed"
        case .eraser: return state.eraserMode == .object ? "eraser" : "eraser.line.dashed"
        case .lasso: return "lasso"
        }
    }

    /// The tool's name (its button's label, which UI tests tap by).
    static func title(of tool: DrawingTool, eraserMode: EraserMode) -> String {
        switch tool {
        case .pen: return String(localized: "Pen", comment: "Tools menu: select the pen")
        case .monoline: return String(localized: "Monoline", comment: "Drawing palette: the monoline pen")
        case .fountainPen: return String(localized: "Fountain Pen", comment: "Drawing palette: the fountain pen")
        case .marker: return String(localized: "Marker", comment: "Tools menu: select the marker")
        case .pencil: return String(localized: "Pencil", comment: "Tools menu: select the pencil tool")
        case .watercolor: return String(localized: "Watercolor", comment: "Drawing palette: the watercolor brush")
        case .crayon: return String(localized: "Crayon", comment: "Drawing palette: the crayon")
        case .eraser:
            return eraserMode == .object ? String(localized: "Object Eraser", comment: "Drawing palette: erases whole strokes")
                : String(localized: "Pixel Eraser", comment: "Drawing palette: erases parts of strokes")
        case .lasso: return String(localized: "Lasso", comment: "Tools menu: select the lasso")
        }
    }

    static func help(of tool: DrawingTool) -> String {
        switch tool {
        case .eraser: return String(localized: "Erase; tap again for the object or pixel eraser and its size")
        case .lasso: return String(localized: "Select ink by drawing around it")
        default: return String(localized: "Draw with this tool; tap again for its color, width and opacity")
        }
    }

    private var rulerButton: some View {
        PaletteButton(title: "Ruler", systemImage: "ruler", help: "Show or hide the ruler for straight lines",
                      selected: state.rulerActive) {
            editor.canvasTarget?.toggleRuler()
        }
        .accessibilityIdentifier("palette.ruler")
    }

    // MARK: Choices

    /// The full bar's choices for the selected tool.
    @ViewBuilder
    private var inlineChoices: some View {
        if let ink = state.tool.ink {
            ForEach(Array(DrawingToolState.swatches.enumerated()), id: \.offset) { i, color in
                swatch(color, index: i, ink: ink)
            }
            colorPicker(ink)
            separator
            widthButtons(ink)
            opacityMenu(ink)
        } else if state.tool == .eraser {
            eraserModeButtons
            separator
            eraserSizeButtons
        }
    }

    /// The compact bar's button for the choices: the ink's color, or the eraser's size.
    @ViewBuilder
    private var choicesButton: some View {
        if let ink = state.tool.ink {
            Button {
                toolbox.showingAttributes.toggle()
            } label: {
                Circle().fill(SwiftUI.Color(uiColor: shown(state.settings(for: ink).inkColor)))
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                    .frame(width: 24, height: 24)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Color and Width"))
            .accessibilityIdentifier("palette.choices")
            .help("The ink's color, width and opacity")
        } else {
            PaletteButton(title: "Eraser Size", systemImage: "circle.dashed", help: "The eraser's mode and size") {
                toolbox.showingAttributes.toggle()
            }
            .accessibilityIdentifier("palette.choices")
        }
    }

    /// The popover: every choice for the selected tool, in rows.
    private var choicesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ink = state.tool.ink {
                Text(Self.title(of: state.tool, eraserMode: state.eraserMode)).font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 5), spacing: 4) {
                    ForEach(Array(DrawingToolState.swatches.enumerated()), id: \.offset) { i, color in
                        swatch(color, index: i, ink: ink)
                    }
                    colorPicker(ink)
                }
                HStack(spacing: 4) { widthButtons(ink) }
                opacitySlider(ink)
            } else if state.tool == .eraser {
                HStack(spacing: 4) { eraserModeButtons }
                HStack(spacing: 4) { eraserSizeButtons }
            }
        }
        .padding()
        .frame(minWidth: 220)
        .presentationCompactAdaptation(.popover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette.choicesPanel")
    }

    private func swatch(_ color: Sempere.Color, index: Int, ink: InkTool) -> some View {
        let selected = state.settings(for: ink).color == color
        return Button {
            toolbox.setColor(color)
        } label: {
            Circle().fill(SwiftUI.Color(uiColor: shown(color)))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                .padding(selected ? 4 : 2)
                .overlay(Circle().strokeBorder(selected ? SwiftUI.Color.accentColor : .clear, lineWidth: 2))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.colorName(index)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("palette.swatch.\(index)")
        .help(Text(Self.colorName(index)))
    }

    /// The swatches' names, in `DrawingToolState.swatches` order.
    static func colorName(_ index: Int) -> String {
        switch index {
        case 0: return String(localized: "Black", comment: "Drawing palette: ink color")
        case 1: return String(localized: "Gray", comment: "Drawing palette: ink color")
        case 2: return String(localized: "Blue", comment: "Drawing palette: ink color")
        case 3: return String(localized: "Red", comment: "Drawing palette: ink color")
        case 4: return String(localized: "Green", comment: "Drawing palette: ink color")
        case 5: return String(localized: "Orange", comment: "Drawing palette: ink color")
        case 6: return String(localized: "Purple", comment: "Drawing palette: ink color")
        default: return String(localized: "Yellow", comment: "Drawing palette: ink color")
        }
    }

    /// Any color (the system's picker), chosen as the page shows it and stored as drawn on light paper.
    private func colorPicker(_ ink: InkTool) -> some View {
        let binding = Binding<SwiftUI.Color>(
            get: { SwiftUI.Color(uiColor: shown(state.settings(for: ink).color)) },
            set: { picked in
                let stored = DrawingToolbox.stored(fromShown: UIColor(picked), darkPages: darkPages)
                toolbox.setColor(Sempere.Color(stored))
            })
        return ColorPicker("Other Color", selection: binding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30, height: 30)
            .accessibilityIdentifier("palette.colorPicker")
            .help("Pick any color")
    }

    @ViewBuilder
    private func widthButtons(_ ink: InkTool) -> some View {
        let presets = DrawingToolState.widthPresets(for: ink)
        let current = state.widthIndex(for: ink)
        ForEach(presets.indices, id: \.self) { i in
            sizeButton(index: i, count: presets.count, selected: i == current,
                       label: String(localized: "Width \(i + 1)", comment: "Drawing palette: line width preset (1 is the thinnest)"),
                       identifier: "palette.width.\(i)") {
                toolbox.setWidth(presets[i])
            }
            .help("Line width")
        }
    }

    private func sizeButton(index: Int, count: Int, selected: Bool, label: String, identifier: String,
                            action: @escaping () -> Void) -> some View {
        let d = 4 + CGFloat(index) * 14 / CGFloat(max(count - 1, 1))
        return Button(action: action) {
            Circle().fill(.primary)
                .frame(width: d, height: d)
                .frame(width: 28, height: 28)
                .background(selected ? SwiftUI.Color.accentColor.opacity(0.25) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func opacityMenu(_ ink: InkTool) -> some View {
        let current = state.settings(for: ink).opacity
        return Menu {
            Picker("Opacity", selection: Binding(get: { Self.nearestOpacity(current) },
                                                 set: { toolbox.setOpacity($0) })) {
                ForEach(DrawingToolState.opacityPresets, id: \.self) { o in
                    Text(Self.percent(o)).tag(o)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(Self.percent(current)).monospacedDigit().font(.callout).frame(minWidth: 44)
        }
        .accessibilityLabel(Text("Opacity"))
        .accessibilityValue(Text(Self.percent(current)))
        .accessibilityIdentifier("palette.opacity")
        .help("Opacity")
    }

    private func opacitySlider(_ ink: InkTool) -> some View {
        let current = state.settings(for: ink).opacity
        return HStack {
            Text("Opacity")
            Slider(value: Binding(get: { current }, set: { toolbox.setOpacity($0) }), in: 0.05...1)
                .accessibilityIdentifier("palette.opacitySlider")
                .help("Opacity")
            Text(Self.percent(current)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
        }
    }

    static func nearestOpacity(_ value: Double) -> Double {
        DrawingToolState.opacityPresets.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    @ViewBuilder
    // help-lint: titled
    private var eraserModeButtons: some View {
        ForEach(EraserMode.allCases, id: \.self) { mode in
            let selected = state.eraserMode == mode
            Button {
                toolbox.setEraserMode(mode)
                pick(.eraser)
            } label: {
                Text(Self.title(of: .eraser, eraserMode: mode))
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selected ? SwiftUI.Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("palette.eraser.\(mode.rawValue)")
        }
    }

    @ViewBuilder
    private var eraserSizeButtons: some View {
        if state.eraserMode == .object {
            ForEach(Array(ObjectEraserSize.radii.enumerated()), id: \.offset) { i, r in
                sizeButton(index: i, count: ObjectEraserSize.radii.count, selected: eraserRadius == r,
                           label: "\(ObjectEraserSize.name(of: r)) – \(Int(r)) pt", identifier: "palette.eraserSize.\(i)") {
                    eraserRadius = r
                }
                .help("Size of the object eraser")
            }
        } else {
            let widths = DrawingToolState.pixelEraserWidths
            let current = DrawingToolState.nearestIndex(of: state.pixelEraserWidth, in: widths)
            ForEach(widths.indices, id: \.self) { i in
                sizeButton(index: i, count: widths.count, selected: i == current,
                           label: String(localized: "Width \(i + 1)", comment: "Drawing palette: line width preset (1 is the thinnest)"),
                           identifier: "palette.eraserSize.\(i)") {
                    toolbox.setPixelEraserWidth(widths[i])
                }
                .help("Size of the pixel eraser")
            }
        }
    }

    // MARK: Colors on the page

    /// Pages are shown dark (Settings ▸ Appearance ▸ Note Pages).
    private var darkPages: Bool {
        (NotePagesAppearance(rawValue: notePages) ?? .defaultValue).isDark(appIsDark: colorScheme == .dark)
    }

    /// A stored color as the page shows it.
    private func shown(_ color: Sempere.Color) -> UIColor {
        DrawingToolbox.displayed(color.uiColor, darkPages: darkPages)
    }
}

/// One of the palette's icon buttons: big enough for a finger, a hover effect for the pointer, lit when
/// selected; an ink's button shows its color under the icon.
private struct PaletteButton: View {
    let title: String
    let systemImage: String
    let help: String
    var selected = false
    var tint: UIColor?
    let action: () -> Void

    init(label: String, systemImage: String, tip: String, selected: Bool = false, tint: UIColor? = nil,
         action: @escaping () -> Void) {
        self.title = label
        self.systemImage = systemImage
        self.help = tip
        self.selected = selected
        self.tint = tint
        self.action = action
    }

    /// For literal titles and help (localized).
    init(title: LocalizedStringResource, systemImage: String, help: LocalizedStringResource, selected: Bool = false,
         action: @escaping () -> Void) {
        self.init(label: String(localized: title), systemImage: systemImage, tip: String(localized: help),
                  selected: selected, tint: nil, action: action)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                if let tint {
                    Capsule().fill(SwiftUI.Color(uiColor: tint)).frame(width: 14, height: 4)
                }
            }
            .frame(width: 36, height: 36)
            .background(selected ? SwiftUI.Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(Text(verbatim: help))
    }
}

/// The palette's floating background.
private struct PaletteChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// The Apple Pencil's double-tap and squeeze for the palette (`PencilGestures`): a view behind the note.
struct PencilGestureHost: UIViewRepresentable {
    var enabled: Bool

    func makeCoordinator() -> PencilGestures { PencilGestures() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true
        view.addInteraction(context.coordinator.interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let enabled = enabled
        context.coordinator.isEnabled = { enabled }
    }
}
