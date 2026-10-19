import SwiftUI
import UIKit

extension AppTheme {
    /// The style every window is given (`.unspecified`: the system's).
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch forcesDark {
        case nil: return .unspecified
        case false?: return .light
        case true?: return .dark
        }
    }
}

/// Puts the app's theme (Settings ▸ General ▸ Appearance, `AppTheme`) on the window a view
/// is in, as its `overrideUserInterfaceStyle`: the window's sheets, popovers and menus follow,
/// on the iPad, the iPhone and every Mac window. `AppEnvironment` attaches it, so every
/// scene has it. A window's style is set on the window rather than through SwiftUI's
/// `preferredColorScheme`, which does not always go back to the system's after a forced one.
struct AppThemeModifier: ViewModifier {
    @AppStorage(AppTheme.key) private var theme = AppTheme.defaultValue

    func body(content: Content) -> some View {
        content.background(WindowThemeSetter(style: theme.userInterfaceStyle).allowsHitTesting(false))
    }
}

/// A view that sets its window's style (`AppThemeModifier`).
private struct WindowThemeSetter: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.style = style
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.style = style
    }

    final class Probe: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { if style != oldValue { apply() } }
        }
        /// Whether this probe has given its window a style: following the system
        /// again then means clearing it. A window it never styled is left as it
        /// is (the screenshot runs force light themselves, `DemoLaunch`).
        private var styled = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            if style == .unspecified && !styled { return }
            styled = style != .unspecified
            if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
        }
    }
}
