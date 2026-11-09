import SempereAppCore
import SwiftUI
import UIKit

/// The words of the drag-to-Finder test runs (the runs themselves, `NoteDragTestRun`, are in SempereAppCore).
extension NoteDragTestRun {
    /// A technical label (English only: a diagnostic panel for the maintainer).
    var label: String {
        switch self {
        case .off: return "Off (as shipped)"   // l10n:ignore
        case .a: return "A: SwiftUI onDrag, note file"   // l10n:ignore
        case .b: return "B: UIDragInteraction, note file"   // l10n:ignore
        case .c: return "C: SwiftUI onDrag, control text file"   // l10n:ignore
        case .d: return "D: UIDragInteraction, file only"   // l10n:ignore
        }
    }

    /// The run the stored switches make (`settled(in:)`).
    /// Switches no run sets are cleared (Off), which is logged as setting a run is.
    static func settled() -> NoteDragTestRun {
        let defaults = UserDefaults.standard
        let stale = matching(NoteDragDebug.read(from: defaults, environment: [:])) == nil
        let run = settled(in: defaults)
        if stale { DragLog.step("test run set to \(run.rawValue) (takes effect at the next launch for the style)") }
        return run
    }

    /// Writes the run's switches (`apply(to:)`) and logs it.
    func apply() {
        apply(to: UserDefaults.standard)
        DragLog.step("test run set to \(rawValue) (takes effect at the next launch for the style)")
    }
}

/// Settings ▸ About, Mac only, hidden: an Option-click (or five clicks) on the version shows it (and it stays while a run is
/// set). Picks a `NoteDragTestRun`; the style applies from the next launch (`NoteDragStyle.current`).
struct DragTestSection: View {
    @State private var run: NoteDragTestRun = .settled()

    var body: some View {
        Section {
            Picker(selection: $run) {
                ForEach(NoteDragTestRun.allCases) { run in
                    Text(verbatim: run.label).tag(run)
                }
            } label: {
                Text(verbatim: "Drag to Finder test run")   // l10n:ignore
            }
            .accessibilityIdentifier("dragTestRun")
            .onChange(of: run) { _, new in new.apply() }
            Text(verbatim: "Running now: \(NoteDragStyle.current.rawValue). Quit Sempere (Cmd-Q) and open it again after changing the run.")   // l10n:ignore
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "Drag Diagnostics")   // l10n:ignore
        }
    }

    /// Whether the section shows without the Option-click: switches are set.
    static var isActive: Bool { NoteDragTestRun.matching(NoteDragDebug.load(environment: [:])) != .off }
}

/// Settings ▸ About's version block: on a Mac an Option-click or five quick clicks run `reveal`
/// (`DragTestSection`); elsewhere nothing is attached.
struct DragTestReveal: ViewModifier {
    let enabled: Bool
    let reveal: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .overlay { RevealClickCatcher(action: reveal) }
        } else {
            content
        }
    }
}

/// A clear view whose `UITapGestureRecognizer` runs `action` on an Option-click or on the fifth click
/// within `RevealClicks.window` (SwiftUI's `Gesture.modifiers` is unavailable on iOS, so on Mac Catalyst
/// too; one recognizer counts both, so no SwiftUI tap gesture competes with it).
struct RevealClickCatcher: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        var clicks = RevealClicks()
        init(action: @escaping () -> Void) { self.action = action }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            if clicks.click(at: Date(), option: recognizer.modifierFlags.contains(.alternate)) { action() }
        }
    }
}
