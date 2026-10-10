import CoreGraphics
import Foundation
import Sempere
import SwiftMath
import UIKit

/// The app's math typesetter (format.md §8.2.8, docs/attachments.md §14 G1):
/// SwiftMath (MIT) lays out the LaTeX source; the result is stored as the
/// item's `render`, a one-page PDF of exactly the typeset box plus a margin,
/// marks only in the equation's colour on a transparent page, so every other
/// renderer (the CLI, the web viewer, exports) draws it without a typesetter.
/// Sources are checked against `MathSource` before SwiftMath parses them.
enum MathTypesetter {
    /// Written as the item's `engine`.
    static let engine = "swiftmath-1.7.3"

    /// Why `latex` cannot be typeset; nil when it can. The format's limits
    /// first (`MathSource.check`: length, groups, tokens, nesting), then
    /// SwiftMath's parser (unknown commands, misplaced `&`).
    static func problem(_ latex: String) -> String? {
        if let issue = MathSource.check(latex) { return issue.description }
        var error: NSError?
        _ = MTMathListBuilder.build(fromString: latex, error: &error)
        return error?.localizedDescription
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    /// The margin around the typeset box, points: glyphs may reach a little
    /// beyond SwiftMath's ascent, descent and width.
    static func margin(_ size: Double) -> CGFloat { CGFloat(max(1, size * 0.15)) }

    /// A laid-out label for `content`, sized to its typeset box plus margin.
    @MainActor
    private static func label(_ content: MathContent) throws -> MTMathUILabel {
        if let why = problem(content.latex) { throw Failure(description: why) }
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = content.display ? .display : .text
        label.textAlignment = .left
        label.fontSize = CGFloat(content.size)
        label.textColor = content.color.uiColor
        let m = margin(content.size)
        label.contentInsets = MTEdgeInsets(top: m, left: m, bottom: m, right: m)
        label.latex = content.latex
        if let error = label.error { throw Failure(description: error.localizedDescription) }
        let size = label.intrinsicContentSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              Double(size.width) <= NoteOps.Limits.extent, Double(size.height) <= NoteOps.Limits.extent else {
            throw Failure(description: "the equation has no size")
        }
        label.frame = CGRect(origin: .zero, size: size)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        guard label.displayList != nil else { throw Failure(description: "the equation could not be laid out") }
        return label
    }

    /// Draws the label into `cg`, whose user space is the label's bounds, y down.
    @MainActor
    private static func draw(_ label: MTMathUILabel, in cg: CGContext) {
        // SwiftMath draws with y up (its view's layer is geometry-flipped).
        cg.saveGState()
        cg.translateBy(x: 0, y: label.bounds.height)
        cg.scaleBy(x: 1, y: -1)
        label.draw(label.bounds)
        cg.restoreGState()
    }

    /// The render of `content` (format.md §8.2.8): PDF bytes and its page size in points.
    @MainActor
    static func typeset(_ content: MathContent) throws -> (data: Data, size: Size) {
        let label = try label(content)
        let bounds = label.bounds
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Sempere"]
        let data = UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { ctx in
            ctx.beginPage()
            draw(label, in: ctx.cgContext)
        }
        return (data, Size(w: InkJSON.round3(Double(bounds.width)), h: InkJSON.round3(Double(bounds.height))))
    }

    /// A formula of a Markdown text box typeset (format.md §8.2.4 `math`):
    /// the render to store first, and the entry that references it, with the
    /// depth of its baseline above the render's bottom (the margin plus
    /// SwiftMath's descent).
    @MainActor
    static func formula(_ content: MathContent) throws -> (data: Data, formula: TypesetFormula) {
        let label = try label(content)
        let bounds = label.bounds
        let descent = Double(label.displayList?.descent ?? 0)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Sempere"]
        let data = UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { ctx in
            ctx.beginPage()
            draw(label, in: ctx.cgContext)
        }
        var value = content
        value.render = BlobRef(content: data, type: MathContent.renderType)
        value.renderSize = Size(w: InkJSON.round3(Double(bounds.width)), h: InkJSON.round3(Double(bounds.height)))
        value.engine = engine
        let h = value.renderSize?.h ?? 0
        let depth = InkJSON.round3(min(max(Double(margin(content.size)) + descent, 0), h))
        return (data, TypesetFormula(math: value, depth: depth))
    }

    /// `content` with a fresh render: the PDF to store first, and the value
    /// that references it.
    @MainActor
    static func rendered(_ content: MathContent) throws -> (data: Data, content: MathContent) {
        let (data, size) = try typeset(content)
        var value = content
        value.render = BlobRef(content: data, type: MathContent.renderType)
        value.renderSize = size
        value.engine = engine
        return (data, value)
    }

    /// The equation at its natural size as pixels (`scale` per point), for the
    /// editor's preview. Nil when it cannot be typeset.
    @MainActor
    static func image(_ content: MathContent, scale: CGFloat) -> CGImage? {
        guard let label = try? label(content) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = false
        return UIGraphicsImageRenderer(size: label.bounds.size, format: format).image { ctx in
            draw(label, in: ctx.cgContext)
        }.cgImage
    }

    /// An equation without a render drawn on the canvas: typeset now and
    /// stretched onto its frame, rotated, as a renderer draws the render
    /// (format.md §8.2.8 step 2). Returns the picture and the page area it
    /// covers (the rotated frame's bounds).
    @MainActor
    static func picture(_ content: MathContent, frame: Rect, rotation: Double?, scale: Double) -> (CGImage, Rect)? {
        guard let label = try? label(content) else { return nil }
        let bounds = ItemFrames.bounds(frame, rotation: rotation)
        guard bounds.w > 0, bounds.h > 0, bounds.w.isFinite, bounds.h.isFinite else { return nil }
        let pixels = bounds.w * bounds.h * scale * scale
        let s = pixels > Double(ItemRendering.maxPixels) ? (Double(ItemRendering.maxPixels) / (bounds.w * bounds.h)).squareRoot() : scale
        guard s.isFinite, s > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(s)
        format.opaque = false
        let c = (x: frame.x + frame.w / 2, y: frame.y + frame.h / 2)
        let natural = label.bounds.size
        let image = UIGraphicsImageRenderer(size: CGSize(width: bounds.w, height: bounds.h), format: format).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: CGFloat(c.x - bounds.x), y: CGFloat(c.y - bounds.y))
            cg.rotate(by: CGFloat(ItemFrames.radians(rotation)))
            cg.translateBy(x: CGFloat(-frame.w / 2), y: CGFloat(-frame.h / 2))
            cg.scaleBy(x: CGFloat(frame.w) / natural.width, y: CGFloat(frame.h) / natural.height)
            draw(label, in: cg)
        }
        return image.cgImage.map { ($0, bounds) }
    }
}
