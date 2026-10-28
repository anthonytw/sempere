import PencilKit
import UIKit

/// Settings ▸ Appearance ▸ Note Pages on a page's canvas (`NotePagesAppearance`).
///
/// Dark pages: the paper and its ruling (`PaperView`) and the text boxes, equations and
/// recording cards (`ItemLayerView`) are shown through `PageColorInversion`, and the canvas
/// takes the dark style, in which PencilKit shows its ink with dark-mode colors while the
/// drawing keeps the light ones it stores (`PKInkingTool.convertColor`). The palette hands the
/// canvas the stored (light) colors and shows them converted (`DrawingToolbox.displayed`). Pictures, PDF pages
/// and videos are never converted. Display only: what is saved, thumbnails and exports do
/// not change.
extension PageCanvasHost {
    /// Applies the setting now and whenever it or the app's light or dark style changes.
    func observePageAppearance() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (host: PageCanvasHost, _: UITraitCollection) in
            host.applyPageAppearance()
        }
        // Settings and settings sync write the choice to the defaults.
        NotificationCenter.default.addObserver(self, selector: #selector(pageAppearanceDefaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        applyPageAppearance()
    }

    /// Posted on whichever thread wrote the defaults.
    @objc nonisolated private func pageAppearanceDefaultsChanged() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyPageAppearance() }
        } else {
            Task { @MainActor [weak self] in self?.applyPageAppearance() }
        }
    }

    /// Whether this canvas's pages are shown dark now.
    var showsDarkPages: Bool {
        NotePagesAppearance.load().isDark(appIsDark: traitCollection.userInterfaceStyle == .dark)
    }

    func applyPageAppearance() {
        let dark = showsDarkPages
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        guard canvas.overrideUserInterfaceStyle != style || paperView.isDark != dark else { return }
        canvas.overrideUserInterfaceStyle = style
        paperView.setDark(dark)
        itemLayer.setDark(dark)
        textOverlay.setDark(dark)
        // Text drawn again over the ink (`MarkerOrder`): multiplied on light paper; on dark paper
        // the light text is screened instead, the same effect with the roles of black and white swapped.
        textOverlay.layer.compositingFilter = dark ? "screenBlendMode" : "multiplyBlendMode"
        #if DEBUG
        itemSelection.debugRefreshReport()
        #endif
    }

    #if DEBUG
    /// `;pages=dark|light;paper=rrggbb` for the canvas's debug report (`SEMPERE_DEMO_ITEMS`): what
    /// the page shows, so a UI test sees Note Pages ▸ Dark change the paper without a screenshot.
    var pageAppearanceReport: String {
        let hex = paperView.shownBackground.map { String(format: "%02x%02x%02x", $0.r, $0.g, $0.b) } ?? "none"
        return ";pages=\(paperView.isDark ? "dark" : "light");paper=\(hex)"
    }
    #endif
}
