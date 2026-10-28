import SwiftUI
import UIKit

/// The owner's drag-to-Finder test runs (bug 7; docs/mac.md "Debugging a drag out"): each one a set of the
/// hidden `NoteDragDebug` switches. Picked in the app (Settings ▸ About, `DragTestSection`), because
/// `defaults write` from Terminal never reached the TestFlight app (build 12: every run logged
/// `config style=onDrag control=false fileOnly=false`).
enum NoteDragTestRun: String, CaseIterable, Identifiable, Sendable {
    /// No switches: the shipped drag.
    case off
    case a, b, c, d

    var id: String { rawValue }

    /// The switches the run sets.
    var switches: NoteDragDebug {
        switch self {
        case .off: return NoteDragDebug()
        case .a: return NoteDragDebug(style: .onDrag)
        case .b: return NoteDragDebug(style: .uikit)
        case .c: return NoteDragDebug(style: .onDrag, control: true)
        case .d: return NoteDragDebug(style: .uikit, fileOnly: true)
        }
    }

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

    /// The run `debug` matches; nil for a combination no run sets.
    static func matching(_ debug: NoteDragDebug) -> NoteDragTestRun? {
        allCases.first { $0.switches == debug }
    }

    /// The run the stored switches make. A combination no run sets (an earlier `defaults write`) is
    /// cleared first, so Off is never a choice that changes nothing.
    static func settled(in defaults: UserDefaults = .standard) -> NoteDragTestRun {
        if let run = matching(NoteDragDebug.load(from: defaults, environment: [:])) { return run }
        off.apply(to: defaults)
        return .off
    }

    /// Writes the run's switches to `defaults` (`off` removes them).
    func apply(to defaults: UserDefaults = .standard) {
        let s = switches
        if self == .off {
            for key in [NoteDragDebug.styleKey, NoteDragDebug.controlKey, NoteDragDebug.fileOnlyKey] {
                defaults.removeObject(forKey: key)
            }
        } else {
            defaults.set(s.style?.rawValue, forKey: NoteDragDebug.styleKey)
            defaults.set(s.control, forKey: NoteDragDebug.controlKey)
            defaults.set(s.fileOnly, forKey: NoteDragDebug.fileOnlyKey)
        }
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

/// Counts the clicks that reveal the drag diagnostics: an Option-click, or `needed` clicks each within
/// `window` of the one before.
struct RevealClicks: Sendable {
    static let needed = 5
    static let window: TimeInterval = 0.8
    private var count = 0
    private var last: Date?

    /// Records a click; true when it reveals.
    mutating func click(at now: Date, option: Bool) -> Bool {
        if option { count = 0; last = nil; return true }
        if let last, now.timeIntervalSince(last) <= Self.window { count += 1 } else { count = 1 }
        last = now
        if count >= Self.needed { count = 0; self.last = nil; return true }
        return false
    }
}
