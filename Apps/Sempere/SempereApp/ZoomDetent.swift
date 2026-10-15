import Foundation

/// Where a pinch on the canvas comes to rest (pure, tested: `ZoomDetentTests`).
///
/// The fitted width (the page fills the view) is a detent: a pinch that ends
/// within `snapBand` of it settles exactly on it, so "back to fit width" is a
/// pinch in the right direction rather than a careful one (TestFlight 1.0.0:
/// "make it easy to return to fit width, like it snaps"). Beyond the band the
/// scale stays where the fingers left it, up to `ZoomSteps.maxFactor`.
///
/// Below the fit: a paged note zooms out to half the fitted width, so several
/// pages show at once (an overview to find a page); a pageless note is one
/// page as wide as the view, and zooming out would only add empty margins, so
/// it stops at the fit (the scroll view bounces back to it).
enum ZoomDetent {
    /// A pinch that ends within this fraction of the fitted width settles on it.
    static let snapBand = 0.12

    /// The smallest scale as a factor of the fitted width.
    static func minimumFactor(paged: Bool) -> Double { paged ? 0.5 : 1 }

    /// The smallest scale for `fit`.
    static func minimum(fit: Double, paged: Bool) -> Double { fit * minimumFactor(paged: paged) }

    /// The scale a pinch that ended at `scale` settles on. Non-finite or
    /// non-positive input gives `fit` (or 1 without a usable fit).
    static func settle(_ scale: Double, fit: Double, paged: Bool) -> Double {
        guard fit.isFinite, fit > 0 else { return 1 }
        guard scale.isFinite, scale > 0 else { return fit }
        let factor = scale / fit
        if abs(factor - 1) <= snapBand { return fit }
        return min(max(factor, minimumFactor(paged: paged)), ZoomSteps.maxFactor) * fit
    }

    /// Whether `scale` is the fitted width (up to rounding).
    static func isFit(_ scale: Double, fit: Double) -> Bool {
        fit > 0 && abs(scale - fit) < fit * 0.001
    }
}
