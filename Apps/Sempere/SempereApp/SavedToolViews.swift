import Sempere
import SempereAppCore
import SwiftUI
import UIKit

// Saved tools in the palette (docs/design/1.3-custom-tools.md §3.5): the Saved group of the full bar, the compact bar's
// list, the editor, and Settings ▸ Writing ▸ Saved Tools. The rules are the package's (`SavedTool`, `SavedToolList`,
// `DrawingToolState.apply`); the model keeps the list (`AppModel+SavedTools`); this file only draws and asks.

/// Words and small helpers shared by the saved tools' views.
enum SavedToolText {
    /// The color's name when it is one of the palette's swatches, else its hex code.
    static func colorName(_ color: Sempere.Color) -> String {
        if let i = DrawingToolState.swatches.firstIndex(of: color) { return DrawingPaletteView.colorName(i) }
        return SavedTool.hex(color)
    }

    /// The ink's name.
    static func inkName(_ ink: InkTool) -> String {
        DrawingPaletteView.title(of: DrawingTool(ink: ink), eraserMode: .object)
    }

    /// "Saved tool: Fine red pen, Pen, 1.5, Red"
    static func accessibilityLabel(_ tool: SavedTool) -> String {
        String(localized: "Saved tool: \(tool.name), \(inkName(tool.ink)), \(DrawingPaletteView.widthText(tool.width)), \(colorName(tool.color))",
               comment: "Palette: a saved tool's accessibility label (name, ink, width, color)")
    }

    /// What a refused or paused change says.
    static func problem(_ outcome: SavedToolsOutcome) -> String? {
        switch outcome {
        case .done: return nil
        case .refused(let e):
            if e == .tooMany { return String(localized: "You can save up to 64 tools. Delete one to save another.") }
            return String(localized: "That tool cannot be saved: check its name, width and opacity.")
        case .paused(.readOnly):
            return String(localized: "Saved tools are paused: this vault is read-only on this device.")
        case .paused(.untrustedRecipients):
            return String(localized: "Saved tools are paused until the vault's device list is checked.")
        case .paused(.needsNewerApp):
            return String(localized: "Saved tools are paused: this vault's settings need a newer Sempere. Update the app to resume.")
        case .paused(.failed(let detail)):
            return String(localized: "Saved tools could not be saved: \(detail)",
                          comment: "Saved tools; the error text follows (English)")
        }
    }

    /// The icon of an ink's tool.
    static func symbol(_ ink: InkTool) -> String {
        switch ink {
        case .pen: return "pencil.tip"
        case .monoline: return "pencil.line"
        case .fountainPen: return "scribble.variable"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .watercolor: return "paintbrush"
        case .crayon: return "paintbrush.pointed"
        }
    }
}

/// What the editor sheet edits.
struct SavedToolEditorTarget: Identifiable, Equatable {
    /// A tool to change, or nil for a new one made from the current tool.
    var existing: SavedTool?
    let id = UUID()
}

// MARK: - Actions

/// What the palette's buttons and menus do with saved tools (one place, so the palette, the compact list and Settings agree).
@MainActor
struct SavedToolActions {
    let model: AppModel
    var toolbox = DrawingToolbox.shared
    /// The note's editor, when the palette is in one (picking a tool ends the Hand, the text tool and the math lasso).
    var editor: NoteEditor?
    /// Shown when a change is refused or paused.
    var report: (String) -> Void = { _ in }

    /// Picks `tool`: its ink with its color, width and opacity (`DrawingToolState.apply`).
    func apply(_ tool: SavedTool) {
        toolbox.apply(tool)
        _ = editor?.canvasTarget?.select(drawingTool: DrawingTool(ink: tool.ink))
    }

    func perform(_ change: SavedToolChange) {
        Task {
            if let text = SavedToolText.problem(await model.changeSavedTools(change)) { report(text) }
        }
    }

    func duplicate(_ tool: SavedTool) {
        var copy = tool
        copy.id = SavedTool.newID()
        copy.at = SharedSettings.millis(Date())
        let suffix = String(localized: " Copy", comment: "Saved tools: appended to a duplicated tool's name")
        copy.name = String((tool.name + suffix).prefix(SavedTool.maxNameLength)).trimmingCharacters(in: .whitespaces)
        perform(.add(copy))
    }

    func move(_ tool: SavedTool, by offset: Int) {
        guard let i = model.savedTools.tools.firstIndex(where: { $0.id == tool.id }) else { return }
        let target = i + offset
        guard target >= 0, target < model.savedTools.tools.count else { return }
        perform(.move(tool.id, .position(target + 1)))
    }

    /// A drag in the list: `source` rows to the `offset` of `List.onMove`.
    func move(from source: IndexSet, to offset: Int) {
        guard let i = source.first, i < model.savedTools.tools.count else { return }
        perform(.move(model.savedTools.tools[i].id, .position(offset > i ? offset : offset + 1)))
    }
}

// MARK: - The group in the full bar

/// The full bar's Saved group: one button per tool, then a + that saves the current tool.
struct SavedToolsGroup: View {
    let tools: [SavedTool]
    let state: DrawingToolState
    let actions: SavedToolActions
    var shown: (Sempere.Color) -> UIColor
    @Binding var editing: SavedToolEditorTarget?
    @Binding var deleting: SavedTool?

    /// Width of one button and the gap.
    private static let slot: CGFloat = 40

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { i, tool in
                        SavedToolButton(tool: tool, selected: state.isActive(tool), color: shown(tool.color)) {
                            actions.apply(tool)
                        }
                        .accessibilityIdentifier("palette.savedTool.\(i)")
                        .contextMenu { SavedToolMenu(tool: tool, actions: actions, editing: $editing, deleting: $deleting) }
                    }
                }
            }
            // A fixed width, so the bar's `ViewThatFits` can tell whether it fits: up to six buttons, then it scrolls.
            .frame(width: Self.slot * CGFloat(min(max(tools.count, 0), 6)))
            .accessibilityIdentifier("palette.savedTools")
            addButton
        }
    }

    private var addButton: some View {
        PaletteButton(title: "Save Tool", systemImage: "plus.circle", help: "Save the current tool as a palette entry",
                      enabled: state.tool.isInk && tools.count < SavedTool.maxTools) {
            editing = SavedToolEditorTarget(existing: nil)
        }
        .accessibilityIdentifier("palette.savedTool.add")
    }
}

/// One saved tool's button: its ink's icon in its color, with a dot as thick as its width.
struct SavedToolButton: View {
    let tool: SavedTool
    let selected: Bool
    let color: UIColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: SavedToolText.symbol(tool.ink))
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                    .foregroundStyle(SwiftUI.Color(uiColor: color).opacity(max(tool.opacity, 0.35)))
                Capsule().fill(SwiftUI.Color(uiColor: color).opacity(tool.opacity))
                    .frame(width: 14, height: Self.dotHeight(tool))
            }
            .frame(width: 36, height: 36)
            .background(selected ? SwiftUI.Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(verbatim: SavedToolText.accessibilityLabel(tool)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(Text(verbatim: tool.name))
    }

    /// The dot's thickness, 2 to 6 points, by where the width sits in the ink's range.
    static func dotHeight(_ tool: SavedTool) -> CGFloat {
        let range = DrawingToolState.widthRange(for: tool.ink)
        let t = (tool.width - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.001)
        return 2 + 4 * CGFloat(min(max(t, 0), 1))
    }
}

/// The context menu (long press on the iPad, right-click on the Mac) of a saved tool.
struct SavedToolMenu: View {
    let tool: SavedTool
    let actions: SavedToolActions
    @Binding var editing: SavedToolEditorTarget?
    @Binding var deleting: SavedTool?

    // help-lint: titled
    var body: some View {
        Button { editing = SavedToolEditorTarget(existing: tool) } label: {
            Label("Edit…", systemImage: "slider.horizontal.3")
        }
        Button { actions.duplicate(tool) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            .disabled(actions.model.savedTools.tools.count >= SavedTool.maxTools)
        Button { actions.move(tool, by: -1) } label: { Label("Move Left", systemImage: "arrow.left") }
        Button { actions.move(tool, by: 1) } label: { Label("Move Right", systemImage: "arrow.right") }
        Button(role: .destructive) { deleting = tool } label: { Label("Delete", systemImage: "trash") }
    }
}

// MARK: - The list (compact bar, Settings)

/// The saved tools as rows: tap to use one, Edit to reorder and delete; a button to save the current tool.
struct SavedToolsList: View {
    let actions: SavedToolActions
    var onPick: (() -> Void)?
    @Binding var editing: SavedToolEditorTarget?
    @Binding var deleting: SavedTool?
    @State private var editMode: EditMode = .inactive

    private var tools: [SavedTool] { actions.model.savedTools.tools }

    var body: some View {
        List {
            ForEach(tools) { tool in
                Button {
                    if editMode == .active {
                        editing = SavedToolEditorTarget(existing: tool)
                    } else {
                        actions.apply(tool)
                        onPick?()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(SwiftUI.Color(uiColor: tool.color.uiColor))
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading) {
                            Text(verbatim: tool.name)
                            Text(verbatim: "\(SavedToolText.inkName(tool.ink)), \(DrawingPaletteView.widthText(tool.width))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if actions.toolbox.state.isActive(tool) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: SavedToolText.accessibilityLabel(tool)))
                .contextMenu { SavedToolMenu(tool: tool, actions: actions, editing: $editing, deleting: $deleting) }
            }
            .onMove { actions.move(from: $0, to: $1) }
            .onDelete { offsets in if let i = offsets.first, i < tools.count { deleting = tools[i] } }
            if tools.isEmpty {
                Text("No saved tools yet. Set up a pen or highlighter, then save it here.")
                    .foregroundStyle(.secondary)
            }
            Button { editing = SavedToolEditorTarget(existing: nil) } label: {
                Label("Save Current Tool…", systemImage: "plus.circle")
            }
            .disabled(!actions.toolbox.state.tool.isInk || tools.count >= SavedTool.maxTools)
            .accessibilityIdentifier("savedTools.add")
        }
        .environment(\.editMode, $editMode)
        .accessibilityIdentifier("palette.savedToolsList")
    }
}

// MARK: - The editor

/// Creates or changes a saved tool: name, ink, color, width and opacity, with a preview stroke.
struct SavedToolEditor: View {
    let target: SavedToolEditorTarget
    let actions: SavedToolActions
    let close: () -> Void

    @State private var name: String
    @State private var ink: InkTool
    @State private var color: Sempere.Color
    @State private var width: Double
    @State private var opacity: Double
    @State private var problem: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    init(target: SavedToolEditorTarget, actions: SavedToolActions, close: @escaping () -> Void) {
        self.target = target
        self.actions = actions
        self.close = close
        if let t = target.existing {
            _name = State(initialValue: t.name); _ink = State(initialValue: t.ink); _color = State(initialValue: t.color)
            _width = State(initialValue: t.width); _opacity = State(initialValue: t.opacity)
        } else {
            let state = actions.toolbox.state
            let ink = state.tool.ink ?? .pen
            let s = state.settings(for: ink)
            _name = State(initialValue: ""); _ink = State(initialValue: ink)
            _color = State(initialValue: Sempere.Color(r: s.color.r, g: s.color.g, b: s.color.b))
            _width = State(initialValue: s.width); _opacity = State(initialValue: s.opacity)
        }
    }

    private var cleanName: String? { SavedTool.cleanName(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Fine red pen"))
                        .focused($nameFocused)
                        .onChange(of: name) { _, new in if new.count > SavedTool.maxNameLength { name = String(new.prefix(SavedTool.maxNameLength)) } }
                        .accessibilityIdentifier("savedTool.name")
                    SavedToolStrokePreview(ink: ink, color: color, width: width, opacity: opacity)
                        .frame(height: 64)
                        .accessibilityHidden(true)
                }
                Section {
                    Picker("Ink", selection: $ink) {
                        ForEach(InkTool.allCases, id: \.self) { Text(SavedToolText.inkName($0)).tag($0) }
                    }
                    .accessibilityIdentifier("savedTool.ink")
                    .onChange(of: ink) { _, new in width = DrawingToolState.clamped(width, to: DrawingToolState.widthRange(for: new)) }
                    swatches
                    widthRow
                    HStack {
                        Text("Opacity")
                        Slider(value: $opacity, in: 0.05...1).accessibilityIdentifier("savedTool.opacity")
                        Text(DrawingPaletteView.percent(opacity)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle(target.existing == nil ? Text("Save Tool") : Text("Edit Saved Tool"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(cleanName == nil || saving)
                        .help("Save this tool")
                        .accessibilityIdentifier("savedTool.save")
                }
            }
            .onAppear { if target.existing == nil { nameFocused = true } }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("savedTool.editor")
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 5), spacing: 4) {
            ForEach(Array(DrawingToolState.swatches.enumerated()), id: \.offset) { i, swatch in
                let selected = color == swatch
                Button { color = swatch } label: {
                    Circle().fill(SwiftUI.Color(uiColor: swatch.uiColor))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                        .padding(selected ? 4 : 2)
                        .overlay(Circle().strokeBorder(selected ? SwiftUI.Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(DrawingPaletteView.colorName(i)))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("savedTool.swatch.\(i)")
                .help(Text(DrawingPaletteView.colorName(i)))
            }
            ColorPicker("Other Color", selection: Binding(
                get: { SwiftUI.Color(uiColor: color.uiColor) },
                set: { color = Sempere.Color(UIColor($0)) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32, height: 32)
                .help("Pick any color")
        }
    }

    private var widthRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                let presets = DrawingToolState.widthPresets(for: ink)
                ForEach(presets.indices, id: \.self) { i in
                    let selected = abs(presets[i] - width) < 0.005
                    Button { width = presets[i] } label: {
                        let d = 4 + CGFloat(i) * 14 / CGFloat(max(presets.count - 1, 1))
                        Circle().fill(.primary).frame(width: d, height: d)
                            .frame(width: 30, height: 30)
                            .background(selected ? SwiftUI.Color.accentColor.opacity(0.25) : .clear, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Width \(i + 1)", comment: "Drawing palette: line width preset (1 is the thinnest)"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help("Line width")
                }
            }
            HStack {
                Text("Width")
                Slider(value: $width, in: DrawingToolbox.widthRange(for: ink))
                    .accessibilityIdentifier("savedTool.width")
                Text(DrawingPaletteView.widthText(width)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    private func save() {
        guard let clean = cleanName else { return }
        saving = true
        let tool: SavedTool
        if var t = target.existing {
            t.name = clean; t.ink = ink; t.color = color; t.width = width; t.opacity = opacity
            tool = t
        } else {
            tool = SavedTool(name: clean, ink: ink, color: color, width: width, opacity: opacity,
                             at: SharedSettings.millis(Date()))
        }
        Task {
            let change: SavedToolChange = target.existing == nil ? .add(tool) : .update(tool)
            let outcome = await actions.model.changeSavedTools(change)
            saving = false
            if let text = SavedToolText.problem(outcome) { problem = text } else { close() }
        }
    }
}

/// A stroke drawn with the choices, on light paper (stored colors are as drawn on light paper). A marker multiplies
/// over the paper as a highlighter does; the width is the tool width in points, which only approximates what PencilKit
/// draws (the real width depends on the ink: `NibSize`).
struct SavedToolStrokePreview: View {
    let ink: InkTool
    let color: Sempere.Color
    let width: Double
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.white))
            var path = Path()
            let midY = size.height / 2, amplitude = size.height * 0.25
            path.move(to: CGPoint(x: 16, y: midY))
            for x in stride(from: CGFloat(16), through: size.width - 16, by: 4) {
                let t = (x - 16) / max(size.width - 32, 1)
                path.addLine(to: CGPoint(x: x, y: midY - amplitude * sin(t * 2 * .pi)))
            }
            var layer = context
            layer.opacity = opacity
            if ink == .marker { layer.blendMode = .multiply }
            layer.stroke(path, with: .color(SwiftUI.Color(uiColor: color.uiColor)),
                         style: StrokeStyle(lineWidth: CGFloat(min(max(width, 0.5), 40)), lineCap: ink == .marker ? .butt : .round,
                                            lineJoin: .round))
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}

// MARK: - Settings

/// Settings ▸ Writing ▸ Saved Tools.
struct SavedToolsSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var editing: SavedToolEditorTarget?
    @State private var deleting: SavedTool?
    @State private var message: String?

    private var actions: SavedToolActions {
        SavedToolActions(model: model, report: { message = $0 })
    }

    var body: some View {
        Section {
            ForEach(model.savedTools.tools) { tool in
                HStack(spacing: 10) {
                    Circle().fill(SwiftUI.Color(uiColor: tool.color.uiColor))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading) {
                        Text(verbatim: tool.name)
                        Text(verbatim: "\(SavedToolText.inkName(tool.ink)), \(DrawingPaletteView.widthText(tool.width)), \(DrawingPaletteView.percent(tool.opacity))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        SavedToolMenu(tool: tool, actions: actions, editing: $editing, deleting: $deleting)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Edit, duplicate, move or delete this saved tool")
                    .accessibilityLabel(Text("Actions for \(tool.name)"))
                }
                .accessibilityElement(children: .combine)
                .contextMenu { SavedToolMenu(tool: tool, actions: actions, editing: $editing, deleting: $deleting) }
            }
            if model.savedTools.isEmpty {
                Text("No saved tools yet. Set up a pen or highlighter in the palette, then save it here or with + in the palette.")
                    .foregroundStyle(.secondary)
            }
            if model.savedToolsFollowVault, !model.localSavedTools.isEmpty, model.localSavedTools.tools.map(\.id) != model.savedTools.tools.map(\.id) {
                Button("Replace the Vault's Saved Tools with This Device's") {
                    Task { message = SavedToolText.problem(await model.replaceVaultSavedToolsWithLocal()) }
                }
            }
            if let message { Text(message).foregroundStyle(.red) }
        } header: {
            Text("Saved Tools", comment: "Settings section: the palette's saved tools")
        } footer: {
            Text("Saved tools are pen and highlighter setups in the palette. With Sync Settings with This Vault on, they are the vault's and follow you to your other devices; otherwise they stay on this device. At most 64.")
        }
        .sheet(item: $editing) { target in
            SavedToolEditor(target: target, actions: actions) { editing = nil }
        }
        .confirmationDialog("Delete this saved tool?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { tool in
            Button("Delete", role: .destructive) { actions.perform(.remove(tool.id)) }
        }
    }
}
