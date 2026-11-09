import Foundation

/// Where a pinch on the canvas comes to rest (pure, tested: `ZoomDetentTests`).
///
/// The fitted width (the page fills the view) is a detent: a pinch that ends
/// within `snapBand` of it settles exactly on it, so "back to fit width" is a
/// pinch in the right direction rather than a careful one (TestFlight 1.0.0:
/// "make it easy to return to fit width, like it snaps"). Beyond the band the
/// scale stays where the fingers left it, up to `ZoomSteps.maxFactor`.
///
/// Below the fit, pages zoom out to half the fitted width, centered: a paged
/// note shows several pages at once (an overview to find a page), a pageless
/// one more of its length (TestFlight 1.0.0 (6): "still can't zoom out farther
/// than 100%" on a long note imported from Notability, which is pageless). An
/// iPhone does the same as an iPad (build 8: "zooming out on pageless locks to
/// width. Paged works.").
public enum ZoomDetent {
    /// A pinch that ends within this fraction of the fitted width settles on it.
    public static let snapBand = 0.12

    /// The smallest scale as a factor of the fitted width.
    public static let minimumFactor = 0.5

    /// The smallest scale for `fit`.
    public static func minimum(fit: Double) -> Double {
        fit * minimumFactor
    }

    /// The scale a pinch that ended at `scale` settles on. Non-finite or
    /// non-positive input gives `fit` (or 1 without a usable fit).
    public static func settle(_ scale: Double, fit: Double) -> Double {
        guard fit.isFinite, fit > 0 else { return 1 }
        guard scale.isFinite, scale > 0 else { return fit }
        let factor = scale / fit
        if abs(factor - 1) <= snapBand { return fit }
        return min(max(factor, minimumFactor), ZoomSteps.maxFactor) * fit
    }

    /// Whether `scale` is the fitted width (up to rounding).
    public static func isFit(_ scale: Double, fit: Double) -> Bool {
        fit > 0 && abs(scale - fit) < fit * 0.001
    }
}

/// Zoom steps of the canvas, relative to the fitted page width (1 = the page
/// fills the window; the canvas allows `1 ... maxFactor`).
public enum ZoomSteps {
    public static let maxFactor = 4.0
    /// The factors Zoom In and Zoom Out move between.
    public static let factors: [Double] = [1, 1.25, 1.5, 2, 2.5, 3, 4]

    /// The scale after one step from `current`, in canvas zoom scale units.
    /// Zoom in goes to the next factor above `current`, zoom out to the next
    /// one below; the result stays within `fit ... fit * maxFactor`.
    /// Non-finite or non-positive input gives `fit`.
    public static func step(from current: Double, fit: Double, zoomingIn: Bool) -> Double {
        guard fit.isFinite, fit > 0 else { return 1 }
        guard current.isFinite, current > 0 else { return fit }
        let factor = current / fit
        let epsilon = 1e-6
        let next: Double
        if zoomingIn {
            next = factors.first { $0 > factor + epsilon } ?? factors[factors.count - 1]
        } else {
            next = factors.last { $0 < factor - epsilon } ?? factors[0]
        }
        return clamped(next * fit, fit: fit)
    }

    /// 100%: one page point per screen point, within the allowed range.
    public static func actualSize(fit: Double) -> Double {
        guard fit.isFinite, fit > 0 else { return 1 }
        return clamped(1, fit: fit)
    }

    public static func clamped(_ scale: Double, fit: Double) -> Double {
        guard scale.isFinite else { return fit }
        return min(max(scale, fit), fit * maxFactor)
    }
}
