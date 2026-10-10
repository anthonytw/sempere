import Sempere
import SwiftUI
import UIKit

/// How the picker lays itself out (the iPhone pass, GA-16): on a phone, and in any narrow or
/// short window, the kinds are one scrolling strip, the preview is capped so the controls are
/// not a screen away, and "Use as Default" scrolls with the controls instead of making the
/// pinned bar three buttons tall. A sheet over a page can rest at half height, so the page
/// behind shows the paper being edited live (`onPreview`).
struct PaperPickerLayout: Equatable, Sendable {
    var compact: Bool

    init(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) {
        compact = horizontal != .regular || vertical == .compact
    }

    init(compact: Bool) { self.compact = compact }

    /// The kinds in one horizontal strip (else a wrapping grid).
    var kindsInStrip: Bool { compact }
    /// Preview and controls side by side.
    var sideBySide: Bool { !compact }
    /// The preview's tallest height in points (nil: as the width gives it).
    var previewMaxHeight: Double? { compact ? 240 : nil }
    /// "Use as Default for New Notes" in the pinned bar (else at the end of the controls).
    var defaultButtonPinned: Bool { !compact }
    /// The sheet may rest at half height (only over a page: a new note's picker has no page behind it).
    func restsAtHalfHeight(page: Bool) -> Bool { compact && page }
}

/// Visual paper picker: a grid of live thumbnails (one per kind, drawn with
/// `PaperRenderer` through `PaperImage`), a large preview of the selection and
/// controls for its parameters. Used for a new note (`.newNote`) and for the
/// open note's page settings (`.page`).
struct PaperPickerView: View {
    enum Purpose {
        case newNote
        /// The page on the canvas, `number` of `count`.
        case page(number: Int, count: Int)
    }

    /// What the user chose to do with the paper.
    enum Choice {
        /// New note: use it for the note.
        case use
        case thisPage
        case allPages
    }

    let purpose: Purpose
    /// Called with the paper as it is edited (and nil when the sheet closes),
    /// so the canvas behind can follow live.
    let onPreview: (Paper?) -> Void
    let onChoose: (Paper, Choice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var draft: PaperDraft
    @State private var savedAsDefault = false

    init(paper: Paper, purpose: Purpose, onPreview: @escaping (Paper?) -> Void = { _ in },
         onChoose: @escaping (Paper, Choice) -> Void) {
        _draft = State(initialValue: PaperDraft(paper: paper))
        self.purpose = purpose
        self.onPreview = onPreview
        self.onChoose = onChoose
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if layout.kindsInStrip {
                        ScrollView(.horizontal, showsIndicators: false) { kindGrid.padding(.vertical, 4) }
                    } else {
                        kindGrid
                    }
                    if layout.sideBySide {
                        HStack(alignment: .top, spacing: 32) {
                            preview
                            controls.frame(maxWidth: .infinity)
                        }
                    } else {
                        preview.frame(maxWidth: .infinity)
                        controls
                        if !layout.defaultButtonPinned { defaultButton }
                    }
                }
                .padding()
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .presentationDetents(layout.restsAtHalfHeight(page: isPage) ? [.medium, .large] : [.large])
        .onChange(of: draft.paper) { _, paper in
            savedAsDefault = false
            onPreview(paper)
        }
        .onDisappear { onPreview(nil) }
    }

    private var layout: PaperPickerLayout { PaperPickerLayout(horizontal: sizeClass, vertical: verticalSizeClass) }

    private var isPage: Bool {
        if case .page = purpose { return true }
        return false
    }

    // MARK: Kinds

    @ViewBuilder
    private var kindGrid: some View {
        if layout.kindsInStrip {
            HStack(alignment: .top, spacing: 14) { kindButtons }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)], spacing: 14) {
                kindButtons
            }
        }
    }

    @ViewBuilder
    private var kindButtons: some View {
        ForEach(PaperKind.allCases, id: \.self) { kind in
            Button { draft.select(kind) } label: {
                VStack(spacing: 6) {
                    thumbnail(for: kind)
                    Text(kind.localizedTitle).font(.caption).foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: layout.kindsInStrip ? 96 : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(kind.localizedTitle)
            .accessibilityAddTraits(kind == draft.kind ? .isSelected : [])
        }
    }

    private func thumbnail(for kind: PaperKind) -> some View {
        var paper = kind == draft.kind ? draft.paper : Paper.template(kind)
        if kind != draft.kind { paper.background = draft.paper.background }
        let selected = kind == draft.kind
        return Image(uiImage: PaperImage.image(for: paper, size: CGSize(width: 120, height: 155), scale: displayScale))
            .resizable()
            .aspectRatio(612.0 / 792.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary.opacity(0.4),
                                                                 lineWidth: selected ? 3 : 1))
    }

    // MARK: Preview and parameters

    private var preview: some View {
        Image(uiImage: PaperImage.image(for: draft.paper, size: CGSize(width: 340, height: 440), scale: displayScale))
            .resizable()
            .aspectRatio(612.0 / 792.0, contentMode: .fit)
            .frame(maxWidth: 340, maxHeight: layout.previewMaxHeight.map { CGFloat($0) })
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(SwiftUI.Color.secondary.opacity(0.5), lineWidth: 1))
            .shadow(radius: 6, y: 2)
            .accessibilityLabel("Preview of \(draft.kind.localizedTitle) paper")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(draft.parameters) { parameter in
                parameterRow(parameter)
            }
            if draft.hasLineColor {
                colorRow(draft.kind == .dot || draft.kind == .isoDot ? String(localized: "Dot color") : String(localized: "Line color"),
                         get: { draft.paper.lineColor }, set: { draft.setLineColor($0) })
            }
            if draft.hasMarginColor {
                colorRow(String(localized: "Margin color"), get: { draft.paper.marginColor }, set: { draft.setMarginColor($0) })
            }
            backgroundRow
            Button("Reset to Defaults", systemImage: "arrow.counterclockwise") { draft.reset() }
                .buttonStyle(.bordered)
        }
    }

    private func parameterRow(_ parameter: PaperParameter) -> some View {
        let value = Binding(get: { draft.value(of: parameter) }, set: { draft.set(parameter, to: $0) })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.title)
                Spacer()
                Text(Self.format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                Stepper(parameter.title, value: value, in: parameter.range, step: parameter.step * (parameter.step < 1 ? 2 : 1))
                    .labelsHidden()
            }
            Slider(value: value, in: parameter.range, step: parameter.step)
                .accessibilityLabel(parameter.title)
        }
    }

    private static func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2))) + " pt"
    }

    private func colorRow(_ title: String, get: @escaping () -> Sempere.Color,
                          set: @escaping (Sempere.Color) -> Void) -> some View {
        ColorPicker(title, selection: Binding(
            get: { SwiftUI.Color(uiColor: get().uiColor) },
            set: { set(Sempere.Color(UIColor($0))) }), supportsOpacity: true)
    }

    private var backgroundRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page color")
            HStack(spacing: 12) {
                ForEach(PaperBackground.allCases) { preset in
                    Button { draft.select(preset) } label: {
                        VStack(spacing: 4) {
                            Circle().fill(SwiftUI.Color(uiColor: preset.color.uiColor))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(draft.background == preset ? SwiftUI.Color.accentColor
                                                                                    : SwiftUI.Color.secondary.opacity(0.5),
                                                         lineWidth: draft.background == preset ? 3 : 1))
                            Text(preset.title).font(.caption).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.title) page")
                    .accessibilityAddTraits(draft.background == preset ? .isSelected : [])
                }
                Spacer()
                ColorPicker("Custom page color", selection: Binding(
                    get: { SwiftUI.Color(uiColor: draft.paper.background.uiColor) },
                    set: { draft.setBackgroundColor(Sempere.Color(UIColor($0))) }), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(spacing: 8) { actionButtons }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch purpose {
        case .newNote:
            Button("Use This Paper") { choose(.use) }
                .buttonStyle(.borderedProminent)
        case .page(let number, let count):
            Button("Apply to This Page") { choose(.thisPage) }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Page \(number) of \(count)")
            Button("Apply to All Pages") { choose(.allPages) }
                .buttonStyle(.bordered)
        }
        if layout.defaultButtonPinned { defaultButton }
    }

    private var defaultButton: some View {
        Button(LocalizedStringKey(savedAsDefault ? "Saved as Default" : "Use as Default for New Notes"),
               systemImage: savedAsDefault ? "checkmark" : "star") {
            PaperPreference.save(draft.paper)
            savedAsDefault = true
        }
        .buttonStyle(.bordered)
        .disabled(savedAsDefault)
    }

    private func choose(_ choice: Choice) {
        onChoose(draft.paper, choice)
        dismiss()
    }
}
