import CoreGraphics
import Foundation
import PencilKit
import Sempere
import SempereRender
import UIKit
import Vision

/// Reads the handwriting of one page. Implementations run off the main
/// actor; tests substitute a fake.
protocol PageRecognizing: Sendable {
    /// The text of `strokes` (one page's live strokes), read in `language`
    /// (the note's `meta.lang`, format.md §5.4; nil: the recogniser's
    /// default). `basis` is left nil: the caller sets it from the stroke ids it passed.
    func recognize(strokes: [Stroke], language: String?) async throws -> Recognition
}

/// Why a page could not be read.
enum RecognitionFailure: Error, CustomStringConvertible {
    /// The page's ink could not be drawn into an image (for example, out of memory).
    case cannotRender

    var description: String { String(localized: "The page could not be drawn for reading.") }
}

/// Whether the app recognises handwriting on its own (default on). It is
/// on-device only: Vision runs here and nothing leaves the device.
enum RecognitionPreference {
    static let key = "Sempere.recognizeHandwriting"
    /// On until the user turns it off (docs/attachments.md §15).
    static let defaultValue = true

    /// The stored choice, `defaultValue` when never set.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    static var enabled: Bool {
        get { isEnabled() }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Recognition with Vision on an image of the page's ink: the strokes are
/// drawn black on white (markers left out, they would cover text), cropped
/// to the ink, at the scale `RecognitionImage.plan` picks. The region, the
/// scale and the Vision mapping (`VisionText`) are shared with `sempere
/// recognize`; only the drawing is PencilKit's here.
struct VisionPageRecognizer: PageRecognizing {
    /// `vision-<iPadOS major.minor>` (format.md §5.5 `engine`).
    static var engine: String { VisionText.engine }

    func recognize(strokes: [Stroke], language: String?) async throws -> Recognition {
        try await Task.detached(priority: .utility) { try Self.recognizeNow(strokes, language: language) }.value
    }

    static func recognizeNow(_ strokes: [Stroke], language: String? = nil) throws -> Recognition {
        let empty = Recognition(engine: engine, text: "")
        let drawable = RecognitionImage.readableStrokes(strokes).map(StrokeConversion.pkStroke)
        let drawing = PKDrawing(strokes: drawable)
        let bounds = drawing.bounds
        guard !drawable.isEmpty, !bounds.isNull, !bounds.isInfinite,
              let plan = RecognitionImage.plan(inkBounds: .init(x: Double(bounds.minX), y: Double(bounds.minY),
                                                                w: Double(bounds.width), h: Double(bounds.height)))
        else { return empty }
        let region = CGRect(x: plan.region.x, y: plan.region.y, width: plan.region.w, height: plan.region.h)
        // A page whose ink cannot be drawn is an error, not "nothing legible": an
        // empty result would be stored as current and never read again.
        guard let image = render(drawing, region: region, scale: CGFloat(plan.scale)) else {
            throw RecognitionFailure.cannotRender
        }
        let lines = try VisionText.lines(VNImageRequestHandler(cgImage: image, options: [:]), region: plan.region,
                                         language: language)
        return RecognitionLayout.assemble(engine: engine, lines: lines, basis: nil)
    }

    /// The ink on white, as the light appearance draws it.
    static func render(_ drawing: PKDrawing, region: CGRect, scale: CGFloat) -> CGImage? {
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: region, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: region.size)
        return UIGraphicsImageRenderer(size: region.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            ink?.draw(in: bounds)
        }.cgImage
    }
}
