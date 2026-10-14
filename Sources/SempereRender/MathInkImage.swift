import Foundation
import Sempere

// MARK: - The image a math recogniser reads (docs/attachments.md §14 G1 part 2)
//
// Handwritten-math models read a small grey image of the formula, at a
// fixed size, with strokes of a uniform width: that is how their training
// images were made (from online ink, CROHME InkML or MathWriting, or from
// scans binarised and resized). Drawing our vector ink the same way, rather
// than as drawn (pressure, pen widths, colours), makes the input look like
// what the model saw. The app and `sempere recognize-math` both draw it here,
// in pure Swift, so they give the model the same pixels.

/// How a model wants its input image (from its manifest, `MathModelManifest`).
public struct MathImageSpec: Hashable, Sendable, Codable {
    /// Size of the input tensor, pixels.
    public var width: Int
    public var height: Int
    /// 1 (grey) or 3 (the grey value in each of R, G, B).
    public var channels: Int
    /// Free pixels kept on every side of the ink.
    public var padding: Int
    /// Width of every stroke in the image, pixels.
    public var strokeWidth: Double
    /// When set, ink is drawn at most this many pixels tall (a short line of
    /// ink is not blown up to fill the image); always within the padded box.
    public var maxInkHeight: Double?
    /// Ink at the image's left edge (`true`, as models trained on left-aligned
    /// lines expect) or centred (`false`).
    public var alignLeft: Bool
    /// White ink on black (`true`, as CROHME-trained models expect) or black on white.
    public var invert: Bool
    /// Per-channel normalisation of values in 0...1: `(v - mean) / std`.
    public var mean: [Double]
    public var std: [Double]

    public init(width: Int, height: Int, channels: Int = 1, padding: Int = 8, strokeWidth: Double = 3,
                maxInkHeight: Double? = nil, alignLeft: Bool = true, invert: Bool = false,
                mean: [Double] = [0], std: [Double] = [1]) {
        self.width = width; self.height = height; self.channels = channels; self.padding = padding
        self.strokeWidth = strokeWidth; self.maxInkHeight = maxInkHeight; self.alignLeft = alignLeft
        self.invert = invert; self.mean = mean; self.std = std
    }

    /// Largest side accepted, pixels: a manifest cannot ask for a huge tensor.
    public static let maxSide = 2_048

    /// Why the spec cannot be used, or nil.
    public var problem: String? {
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height) else {
            return "image size must be 1 to \(Self.maxSide) pixels a side"
        }
        guard channels == 1 || channels == 3 else { return "channels must be 1 or 3" }
        guard padding >= 0, 2 * padding < min(width, height) else { return "padding leaves no room for ink" }
        guard strokeWidth.isFinite, strokeWidth > 0, strokeWidth <= Double(min(width, height)) / 4 else {
            return "stroke width out of range"
        }
        if let h = maxInkHeight, !(h.isFinite && h >= 1) { return "maxInkHeight out of range" }
        guard mean.count == channels || mean.count == 1, std.count == mean.count else {
            return "mean and std need one value, or one per channel"
        }
        guard mean.allSatisfy(\.isFinite), std.allSatisfy({ $0.isFinite && $0 != 0 }) else { return "bad mean or std" }
        return nil
    }
}

/// A grey image of ink for a math recogniser (`MathInkImage.render`).
public struct MathInkImage: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// `width * height` grey values, row-major, 0 black ... 255 white, as
    /// drawn (black ink on white: `MathImageSpec.invert` applies in `tensor`).
    public var gray: [UInt8]
    /// The page region (points) the image shows, and pixels per point.
    public var region: Rect
    public var scale: Double

    /// The model's input: `channels × height × width` values, each grey value
    /// mapped to 0...1 (inverted when the spec says so), then normalised.
    public func tensor(_ spec: MathImageSpec) -> [Float] {
        let plane = width * height
        var out = [Float](repeating: 0, count: plane * spec.channels)
        for c in 0..<spec.channels {
            let mean = spec.mean.count == 1 ? spec.mean[0] : spec.mean[c]
            let std = spec.std.count == 1 ? spec.std[0] : spec.std[c]
            // One lookup per grey level.
            let table: [Float] = (0...255).map { g in
                var v = Double(g) / 255
                if spec.invert { v = 1 - v }
                return Float((v - mean) / std)
            }
            for i in 0..<plane { out[c * plane + i] = table[Int(gray[i])] }
        }
        return out
    }

    /// The image as a grey PNG (debugging, `--save-image`).
    public func png() throws -> Data {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[4 * i] = gray[i]; rgba[4 * i + 1] = gray[i]; rgba[4 * i + 2] = gray[i]
        }
        return try PNGEncoder.encode(width: width, height: height, rgba: rgba)
    }

    /// Draws `strokes` (of one page) for a model that reads `spec`: markers
    /// and empty strokes left out (`RecognitionImage.readableStrokes`), every
    /// stroke a black line `spec.strokeWidth` pixels wide on white, the ink
    /// scaled uniformly to fit inside the padding (at most
    /// `spec.maxInkHeight` tall), left-aligned or centred, centred vertically.
    /// Nil when no stroke is readable.
    ///
    /// - Throws: `RenderError.invalidGeometry` for a spec that cannot be
    ///   used (`MathImageSpec.problem`) or ink without a finite extent.
    public static func render(strokes: [Stroke], spec: MathImageSpec, tolerance: Double = 0.05) throws -> MathInkImage? {
        guard spec.problem == nil else { throw RenderError.invalidGeometry }
        let readable = RecognitionImage.readableStrokes(strokes)
        guard let bounds = InkGeometry.bounds(of: readable) else { return nil }
        guard [bounds.x, bounds.y, bounds.w, bounds.h].allSatisfy(\.isFinite) else { throw RenderError.invalidGeometry }
        let boxW = Double(spec.width - 2 * spec.padding), boxH = Double(spec.height - 2 * spec.padding)
        // A dot or a flat line still gets a finite scale.
        let inkW = max(bounds.w, 1), inkH = max(bounds.h, 1)
        var scale = min(boxW / inkW, boxH / inkH)
        if let cap = spec.maxInkHeight { scale = min(scale, cap / inkH) }
        guard scale.isFinite, scale > 0 else { throw RenderError.invalidGeometry }
        let drawnW = inkW * scale, drawnH = inkH * scale
        let left = spec.alignLeft ? Double(spec.padding) : (Double(spec.width) - drawnW) / 2
        let top = (Double(spec.height) - drawnH) / 2
        // Page point (x, y) lands at ((x + dx) * scale, (y + dy) * scale).
        let dx = left / scale - bounds.x - (inkW - bounds.w) / 2
        let dy = top / scale - bounds.y - (inkH - bounds.h) / 2
        var raster = Raster(width: spec.width, height: spec.height)
        raster.fill([[Point(x: 0, y: 0), Point(x: Double(spec.width), y: 0),
                      Point(x: Double(spec.width), y: Double(spec.height)), Point(x: 0, y: Double(spec.height))]],
                    paint: Paint(r: 255, g: 255, b: 255))
        let black = Paint(r: 0, g: 0, b: 0)
        for var stroke in readable {
            // A monoline of the spec's width in pixels, whatever the pen was.
            let meanScale = (stroke.transform ?? .identity).meanScale
            stroke.ink.tool = .monoline
            stroke.ink.width = spec.strokeWidth / scale / (meanScale > 0 && meanScale.isFinite ? meanScale : 1)
            for p in stroke.points.indices { stroke.points[p].o = 1 }
            for var c in StrokeOutline.commands(for: stroke, tolerance: tolerance) {
                if c.fill != nil { c.fill = black }
                if c.stroke != nil { c.stroke = black }
                PNGWriter.paint(c, into: &raster, sx: scale, sy: scale, dx: dx, dy: dy)
            }
        }
        let rgba = raster.pixels
        var gray = [UInt8](repeating: 255, count: spec.width * spec.height)
        for i in gray.indices { gray[i] = rgba[4 * i] }
        let region = Rect(x: -dx, y: -dy, w: Double(spec.width) / scale, h: Double(spec.height) / scale)
        return MathInkImage(width: spec.width, height: spec.height, gray: gray, region: region, scale: scale)
    }
}
