import Foundation
@testable import Sempere
@testable import SempereAppCore
import SempereRender
import XCTest

/// How dark note pages show colors (`PageColorInversion`). Moved from the app's `AppearanceSettingsTests`; what stays
/// there is the image's pixels (CoreGraphics).
final class PageColorInversionTests: XCTestCase {
    private func lightness(_ c: (r: Double, g: Double, b: Double)) -> Double {
        PageColorInversion.hsl(r: c.r, g: c.g, b: c.b).l
    }

    func testBlackInkShowsLightAndWhitePaperDark() {
        let black = PageColorInversion.invert(r: 0, g: 0, b: 0)
        let white = PageColorInversion.invert(r: 1, g: 1, b: 1)
        XCTAssertGreaterThan(lightness(black), 0.9)
        XCTAssertLessThan(lightness(white), 0.15)
        XCTAssertLessThan(abs(black.r - black.g), 1e-9, "gray stays gray")
        XCTAssertLessThan(abs(black.g - black.b), 1e-9)
    }

    func testHueAndSaturationAreKeptAndLightnessInverted() {
        let colors: [(Double, Double, Double)] = [(0.8, 0.1, 0.1), (0.1, 0.2, 0.7), (0.0, 0.5, 0.2), (0.95, 0.85, 0.2), (0.3, 0.1, 0.4)]
        for (r, g, b) in colors {
            let before = PageColorInversion.hsl(r: r, g: g, b: b)
            let out = PageColorInversion.invert(r: r, g: g, b: b)
            let after = PageColorInversion.hsl(r: out.r, g: out.g, b: out.b)
            let hueDistance = min(abs(after.h - before.h), 1 - abs(after.h - before.h))
            XCTAssertLessThan(hueDistance, 0.01, "hue of \((r, g, b))")
            XCTAssertLessThan(abs(after.s - before.s), 0.02, "saturation of \((r, g, b))")
            let expected = PageColorInversion.darkest + (1 - before.l) * (PageColorInversion.lightest - PageColorInversion.darkest)
            XCTAssertLessThan(abs(after.l - expected), 0.01, "lightness of \((r, g, b))")
        }
        // Darker in, lighter out.
        XCTAssertGreaterThan(lightness(PageColorInversion.invert(r: 0.2, g: 0.2, b: 0.6)),
                             lightness(PageColorInversion.invert(r: 0.5, g: 0.5, b: 0.9)))
    }

    func testPaintKeepsItsAlpha() {
        let p = PageColorInversion.invert(Paint(r: 0, g: 0, b: 0, alpha: 0.4))
        XCTAssertEqual(p.alpha, 0.4)
        XCTAssertGreaterThan(p.r, 200)
    }

    /// Text, equations and recording cards are converted; pictures, PDF pages and videos never.
    func testPicturesPDFsAndVideosAreNeverInverted() {
        for kind in [ItemKind.text, .math, .audio] { XCTAssertTrue(PageColorInversion.converts(kind: kind), "\(kind)") }
        for kind in [ItemKind.image, .pdfPage, .video] { XCTAssertFalse(PageColorInversion.converts(kind: kind), "\(kind)") }
    }

    func testNonFiniteAndOutOfRangeComponentsAreClamped() {
        let out = PageColorInversion.invert(r: .nan, g: 2, b: -1)
        for v in [out.r, out.g, out.b] { XCTAssertTrue(v.isFinite && (0...1).contains(v)) }
        XCTAssertEqual(PageColorInversion.byte(1.5), 255)
        XCTAssertEqual(PageColorInversion.byte(-1), 0)
        XCTAssertEqual(PageColorInversion.byte(.nan), 0)
    }
}
