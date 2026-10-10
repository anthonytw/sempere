import CoreGraphics
import CoreText
import Foundation
import Sempere
import SempereRender
import UIKit

// Text boxes in the app (format.md §8.2.4, §8.5.3; docs/attachments.md §6,
// §13 "Text editing on the canvas"; task E2). One layout serves the canvas,
// the app's exports and the editor's writes:
//
// - `TextKitBreaks`: where TextKit breaks a box's lines at its width. The
//   editor stores these as `breaks`; a box without usable stored breaks
//   (an import, an older writer) is broken the same way when shown.
// - `TextBoxLayout`: the box laid out with CoreText at those breaks, with
//   the format's fixed vertical metrics and alignment (`LayoutText`, shared
//   with the CLI's shaper). The item layer draws it (`draw`), and
//   `CoreTextShaper` hands it to the exporters as a `ShapedText`, so the
//   canvas and the app's PDF, SVG and PNG put the same glyphs at the same
//   places, and `sempere export` the same characters on the same lines.

/// The fonts of a text box (docs/attachments.md §6): `sans` is the system
/// font (SF Pro), `serif` New York, `mono` SF Mono; CoreText's cascade list
/// covers every other script.
enum TextBoxFonts {
    struct Resolved {
        let font: UIFont
        /// The family has no bold (italic) face: drawn emboldened (slanted), format.md §8.5.3.
        let syntheticBold: Bool
        let syntheticItalic: Bool
    }

    static func font(_ generic: TextContent.Font, size: Double, bold: Bool, italic: Bool) -> Resolved {
        let pt = CGFloat(size.isFinite && size > 0 ? size : 12)
        var descriptor = UIFont.systemFont(ofSize: pt).fontDescriptor
        switch generic.effective {
        case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
        case .mono: descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        default: break
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        let font = UIFont(descriptor: descriptor, size: pt)
        let has = font.fontDescriptor.symbolicTraits
        return Resolved(font: font, syntheticBold: bold && !has.contains(.traitBold),
                        syntheticItalic: italic && !has.contains(.traitItalic))
    }

    /// Widths for laying Markdown boxes out (format.md §8.5.4): CoreText, as the canvas and exports draw.
    static let markdownMeasure: MarkdownMeasure = MarkdownLayout.measure(with: CoreTextShaper())

    /// The concrete family written to `family` (informational, format.md §8.2.4).
    static func family(_ generic: TextContent.Font) -> String {
        switch generic.effective {
        case .serif: return "New York"
        case .mono: return "SF Mono"
        default: return "SF Pro"
        }
    }
}

/// Attributed strings for laying out a box (pure mapping of the runs).
enum TextBoxText {
    /// The index of the run (in `TextContent.runs`) a character belongs to.
    static let runKey = NSAttributedString.Key("io.github.anthonytw.sempere.textRun")

    /// `layout.layoutString` (tabs as four spaces) with each run's font and
    /// colour and each paragraph's direction: what TextKit and CoreText lay out.
    static func layoutAttributed(_ layout: LayoutText) -> NSAttributedString {
        let out = NSMutableAttributedString(string: layout.layoutString)
        let content = layout.content
        var start = 0
        for (r, run) in content.runs.enumerated() {
            let count = run.t.unicodeScalars.count
            defer { start += count }
            guard count > 0 else { continue }
            let u = layout.utf16Range(start..<(start + count))
            let f = TextBoxFonts.font(run.effectiveFont(in: content.font), size: run.size ?? content.size, bold: run.b, italic: run.i)
            out.addAttributes([.font: f.font, .foregroundColor: (run.color ?? content.color).uiColor, runKey: r],
                              range: NSRange(location: u.lowerBound, length: u.count))
        }
        // Paragraph direction (UAX #9 P2–P3 for `auto`, as every renderer resolves it); no hyphenation.
        var scalarStart = 0
        for p in layout.paragraphs {
            let end = min(p.upperBound + 1, layout.scalars.count)   // with its line feed
            let u = layout.utf16Range(scalarStart..<end)
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = layout.isRightToLeft(p) ? .rightToLeft : .leftToRight
            style.lineBreakMode = .byWordWrapping
            style.lineBreakStrategy = []
            style.hyphenationFactor = 0
            if !u.isEmpty { out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: u.lowerBound, length: u.count)) }
            scalarStart = end
        }
        return out
    }
}

/// Where TextKit breaks a box's lines (the `breaks` the app writes,
/// format.md §8.2.4): TextKit 1 laying out `TextBoxText.layoutAttributed` in
/// a container as wide as the frame, without padding. Usable off the main
/// thread (each call has its own layout manager).
enum TextKitBreaks {
    static func breaks(_ layout: LayoutText, width: Double) -> [Int] {
        guard width.isFinite, width > 0, !layout.scalars.isEmpty else { return [] }
        let storage = NSTextStorage(attributedString: TextBoxText.layoutAttributed(layout))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        container.maximumNumberOfLines = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(for: container)
        var starts: [Int] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
            starts.append(manager.characterRange(forGlyphRange: range, actualGlyphRange: nil).location)
        }
        return layout.breaks(lineStartsUTF16: starts)
    }

    /// The content with `breaks` for `frame`'s width and the frame with the
    /// height its lines take (at least one line of the box's size): what
    /// the app writes after an edit or a resize.
    static func relayout(_ content: TextContent, frame: Rect) -> (content: TextContent, frame: Rect) {
        // A Markdown box stores the breaks of its rendered text (format.md §8.2.4 `layout`).
        if content.isMarkdown { return MarkdownLayout.relayout(content, frame: frame, measure: TextBoxFonts.markdownMeasure) }
        let layout = LayoutText(content)
        var out = content
        out.breaks = breaks(layout, width: frame.w)
        let lines = layout.lines(layout.lineRanges(breaks: out.breaks ?? []), top: 0)
        let h = InkJSON.round3(max(LayoutText.height(of: lines), 1.2 * content.size))
        return (out, Rect(x: frame.x, y: frame.y, w: frame.w, h: h))
    }
}

/// A text box laid out with CoreText (format.md §8.5.3).
struct TextBoxLayout {
    /// Glyphs of one CoreText run on a line, placed on the page.
    struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        /// Glyph origins on the baseline, page coordinates (y down).
        let positions: [CGPoint]
        let advances: [Double]
        /// The characters each glyph stands for (on the first glyph of its cluster).
        let texts: [String]
        let color: Sempere.Color
        let size: Double
        let syntheticBold: Bool
        let syntheticItalic: Bool
        /// The scalar offsets the run covers (for reports).
        let scalars: Range<Int>
    }

    struct Line {
        let geometry: LayoutText.Line
        /// Left edge and width of the drawn characters.
        let x: Double
        let width: Double
        let runs: [Run]
        let text: String
    }

    let content: TextContent
    let frame: Rect
    /// The breaks the lines were cut at (stored, or TextKit's).
    let breaks: [Int]
    /// Every line, empty ones included.
    let lines: [Line]
    let decorations: [TextDecoration]

    /// Bottom of the last line.
    var bottom: Double { lines.last?.geometry.bottom ?? frame.y }

    /// What the drawn text covers: the frame, and lines that overflow it
    /// (text is never clipped, format.md §8.2.4).
    var extent: Rect {
        var x0 = frame.x, x1 = frame.x + frame.w, y1 = max(frame.y + frame.h, bottom)
        for line in lines where line.width > 0 {
            x0 = min(x0, line.x)
            x1 = max(x1, line.x + line.width)
            y1 = max(y1, line.geometry.baseline + 0.5 * line.geometry.size)   // descenders, decorations
        }
        return Rect(x: x0, y: frame.y, w: x1 - x0, h: y1 - frame.y)
    }

    init(_ content: TextContent, frame: Rect) {
        self.content = content
        self.frame = frame
        let layout = LayoutText(content)
        let breaks = TextLineBreaks.usable(content) ?? TextKitBreaks.breaks(layout, width: frame.w)
        self.breaks = breaks
        let geometry = layout.lines(layout.lineRanges(breaks: breaks), top: frame.y)
        let attributed = TextBoxText.layoutAttributed(layout)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
        var lines: [Line] = []
        var decorations: [TextDecoration] = []
        for g in geometry {
            guard !g.drawn.isEmpty else {
                lines.append(Line(geometry: g, x: frame.x, width: 0, runs: [], text: ""))
                continue
            }
            let u = layout.utf16Range(g.drawn)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: u.lowerBound, length: u.count))
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let x = layout.lineX(width: width, frame: frame, rtl: g.rtl)
            var runs: [Run] = []
            for ctRun in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                guard let run = Self.run(ctRun, layout: layout, x: x, baseline: g.baseline) else { continue }
                runs.append(run)
                // Decorations (format.md §8.5.3): S/18 thick, underline 0.12 × the run's size
                // below the baseline, strikethrough 0.3 × above it.
                let source = content.runs[layout.runOfScalar[run.scalars.lowerBound]]
                guard source.u || source.s, let left = run.positions.map(\.x).min() else { continue }
                let right = zip(run.positions, run.advances).map { Double($0.x) + $1 }.max() ?? Double(left)
                let t = g.size / 18
                if source.u {
                    decorations.append(TextDecoration(x: Double(left), y: g.baseline + 0.12 * run.size - t / 2,
                                                      width: right - Double(left), height: t, color: run.color))
                }
                if source.s {
                    decorations.append(TextDecoration(x: Double(left), y: g.baseline - 0.3 * run.size - t / 2,
                                                      width: right - Double(left), height: t, color: run.color))
                }
            }
            runs.sort { ($0.positions.first?.x ?? 0) < ($1.positions.first?.x ?? 0) }
            let text = String(String.UnicodeScalarView(layout.scalars[g.drawn]))
            lines.append(Line(geometry: g, x: x, width: width, runs: runs, text: text))
        }
        self.lines = lines
        self.decorations = decorations
    }

    /// One CoreText run placed on the page.
    private static func run(_ ctRun: CTRun, layout: LayoutText, x: Double, baseline: Double) -> Run? {
        let n = CTRunGetGlyphCount(ctRun)
        guard n > 0 else { return nil }
        let all = CFRange(location: 0, length: 0)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var positions = [CGPoint](repeating: .zero, count: n)
        var advances = [CGSize](repeating: .zero, count: n)
        var indices = [CFIndex](repeating: 0, count: n)
        CTRunGetGlyphs(ctRun, all, &glyphs)
        CTRunGetPositions(ctRun, all, &positions)
        CTRunGetAdvances(ctRun, all, &advances)
        CTRunGetStringIndices(ctRun, all, &indices)
        let attributes = (CTRunGetAttributes(ctRun) as? [NSAttributedString.Key: Any]) ?? [:]
        guard let uiFont = attributes[.font] as? UIFont, let r = attributes[TextBoxText.runKey] as? Int,
              r >= 0, r < layout.content.runs.count else { return nil }
        let source = layout.content.runs[r]
        let size = source.size ?? layout.content.size
        let style = TextBoxFonts.font(source.effectiveFont(in: layout.content.font), size: size, bold: source.b, italic: source.i)
        // The characters of each cluster go on its first glyph (for search and copying in exports).
        let range = CTRunGetStringRange(ctRun)
        let runEnd = range.location + range.length
        let starts = Array(Set(indices)).sorted()
        var assigned = Set<Int>()
        var texts: [String] = []
        for i in indices {
            let s = layout.scalarOffset(utf16: i)
            guard assigned.insert(s).inserted else { texts.append(""); continue }
            let next = starts.first { $0 > i } ?? runEnd
            let e = max(s, layout.scalarOffset(utf16: next))
            texts.append(String(String.UnicodeScalarView(layout.scalars[s..<min(e, layout.scalars.count)])))
        }
        let lo = layout.scalarOffset(utf16: range.location), hi = max(lo, layout.scalarOffset(utf16: runEnd))
        return Run(font: uiFont as CTFont, glyphs: glyphs,
                   positions: positions.map { CGPoint(x: CGFloat(x) + $0.x, y: CGFloat(baseline) - $0.y) },
                   advances: advances.map { Double($0.width) }, texts: texts, color: source.color ?? layout.content.color,
                   size: size, syntheticBold: style.syntheticBold, syntheticItalic: style.syntheticItalic,
                   scalars: lo..<max(hi, min(lo + 1, layout.scalars.count)))
    }

    // MARK: Drawing

    /// Draws the text into `context`, whose coordinates are page points, y down.
    func draw(in context: CGContext) {
        let slant = CGFloat(tan(12 * Double.pi / 180))
        for line in lines {
            for run in line.runs {
                context.saveGState()
                let color = run.color.uiColor.cgColor
                context.setFillColor(color)
                if run.syntheticBold {
                    context.setStrokeColor(color)
                    context.setLineWidth(CGFloat(run.size / 30))
                    context.setTextDrawingMode(.fillStroke)
                } else {
                    context.setTextDrawingMode(.fill)
                }
                // Glyphs are drawn y up: flip, and place each origin at (x, −y).
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = CGAffineTransform(a: 1, b: 0, c: run.syntheticItalic ? slant : 0, d: 1, tx: 0, ty: 0)
                let flipped = run.positions.map { CGPoint(x: $0.x, y: -$0.y) }
                run.glyphs.withUnsafeBufferPointer { g in
                    flipped.withUnsafeBufferPointer { p in
                        if let gb = g.baseAddress, let pb = p.baseAddress {
                            CTFontDrawGlyphs(run.font, gb, pb, run.glyphs.count, context)
                        }
                    }
                }
                context.restoreGState()
            }
        }
        for d in decorations {
            context.setFillColor(d.color.uiColor.cgColor)
            context.fill(CGRect(x: d.x, y: d.y, width: d.width, height: d.height))
        }
    }

    // MARK: Exports

    /// The layout as SempereRender's `ShapedText`: each CoreText font as a
    /// font of exactly the glyphs used, built from CoreText's outlines at the
    /// instance drawn (`OutlineFont`), so exports embed what the canvas shows.
    func shapedText() -> ShapedText {
        // Glyphs per font, then one outline font each.
        var used: [String: (font: CTFont, glyphs: Set<CGGlyph>)] = [:]
        for line in lines {
            for run in line.runs {
                let key = Self.fontKey(run.font)
                used[key, default: (run.font, [])].glyphs.formUnion(run.glyphs)
            }
        }
        var faces: [String: (face: FontFace, ids: [CGGlyph: Int], bitmap: Set<CGGlyph>)] = [:]
        for (key, entry) in used {
            if let built = Self.outlineFace(entry.font, glyphs: entry.glyphs.sorted(), key: key) { faces[key] = built }
        }
        var out = ShapedText()
        let layout = LayoutText(content)
        for line in lines where !line.runs.isEmpty {
            var runs: [GlyphRun] = []
            for run in line.runs {
                let key = Self.fontKey(run.font)
                guard let face = faces[key] else { continue }
                if CTFontCopyPostScriptName(run.font) as String == "LastResort", run.scalars.lowerBound < layout.scalars.count {
                    let c = layout.scalars[run.scalars.lowerBound]
                    out.missingScripts[LayoutText.script(of: c)] = out.missingScripts[LayoutText.script(of: c)] ?? c.value
                }
                var placed: [PlacedGlyph] = []
                for k in run.glyphs.indices {
                    if face.bitmap.contains(run.glyphs[k]), let c = run.texts[k].unicodeScalars.first {
                        out.bitmapScripts[LayoutText.script(of: c)] = out.bitmapScripts[LayoutText.script(of: c)] ?? c.value
                    }
                    placed.append(PlacedGlyph(glyph: face.ids[run.glyphs[k]] ?? 0, x: Double(run.positions[k].x),
                                              y: Double(run.positions[k].y), advance: run.advances[k], text: run.texts[k]))
                }
                runs.append(GlyphRun(face: face.face, size: run.size, color: run.color, syntheticBold: run.syntheticBold,
                                     syntheticItalic: run.syntheticItalic, glyphs: placed))
            }
            out.lines.append(ShapedLine(baseline: line.geometry.baseline, size: line.geometry.size, runs: runs, text: line.text,
                                        rtl: line.geometry.rtl, x: line.x, width: line.width, range: line.geometry.range))
        }
        out.decorations = decorations
        out.bottom = bottom
        return out
    }

    /// Names a CoreText font instance: PostScript name and variation.
    static func fontKey(_ font: CTFont) -> String {
        let name = CTFontCopyPostScriptName(font) as String
        let variation = (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?
            .sorted { $0.key.intValue < $1.key.intValue }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",") ?? ""
        return variation.isEmpty ? name : name + "@" + variation
    }

    /// A font of `glyphs` of `font`, from CoreText's outlines in font units;
    /// glyphs with ink but no outline (colour, bitmap) are empty and listed.
    static func outlineFace(_ font: CTFont, glyphs: [CGGlyph], key: String)
        -> (face: FontFace, ids: [CGGlyph: Int], bitmap: Set<CGGlyph>)? {
        let upem = Int(CTFontGetUnitsPerEm(font))
        guard (16...16_384).contains(upem) else { return nil }
        let unit = CTFontCreateCopyWithAttributes(font, CGFloat(upem), nil, nil)
        var built: [OutlineFont.Glyph] = []
        var ids: [CGGlyph: Int] = [:]
        var bitmap = Set<CGGlyph>()
        for g in glyphs {
            var glyph = g
            var advance = CGSize.zero
            _ = CTFontGetAdvancesForGlyphs(unit, .horizontal, &glyph, &advance, 1)
            var outline: [OutlineSegment] = []
            if let path = CTFontCreatePathForGlyph(unit, g, nil) {
                outline = Self.segments(path)
            } else {
                // No outline: a space (nothing to draw), or a colour/bitmap glyph (ink without an outline).
                var rect = CGRect.zero
                _ = CTFontGetBoundingRectsForGlyphs(unit, .horizontal, &glyph, &rect, 1)
                if !rect.isEmpty, !rect.isNull { bitmap.insert(g) }
            }
            ids[g] = built.count + 1
            built.append(OutlineFont.Glyph(outline: outline, advance: Int(advance.width.rounded())))
        }
        let ps = CTFontCopyPostScriptName(font) as String
        let traits = CTFontGetSymbolicTraits(font)
        guard let made = try? OutlineFont.make(postScriptName: ps, family: CTFontCopyFamilyName(font) as String, unitsPerEm: upem,
                                               ascender: Int((CTFontGetAscent(unit)).rounded()),
                                               descender: -Int((CTFontGetDescent(unit)).rounded()),
                                               weight: traits.contains(.traitBold) ? 700 : 400,
                                               italic: traits.contains(.traitItalic), glyphs: built) else { return nil }
        // The name identifies the font instance and the glyph set (faces with one name must be equal).
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        for g in glyphs { h = (h ^ UInt64(g)) &* 0x100_0000_01B3 }
        let url = URL(fileURLWithPath: "/coretext/" + String(h, radix: 16))
        return (FontFace(font: made, url: url, faceIndex: 0), ids, bitmap)
    }

    /// A Core Graphics path as outline segments (y up, as CoreText gives glyphs).
    static func segments(_ path: CGPath) -> [OutlineSegment] {
        var out: [OutlineSegment] = []
        path.applyWithBlock { element in
            let e = element.pointee
            func p(_ i: Int) -> SempereRender.Point { SempereRender.Point(x: Double(e.points[i].x), y: Double(e.points[i].y)) }
            switch e.type {
            case .moveToPoint: out.append(.move(p(0)))
            case .addLineToPoint: out.append(.line(p(0)))
            case .addQuadCurveToPoint: out.append(.quad(p(0), p(1)))
            case .addCurveToPoint: out.append(.cubic(p(0), p(1), p(2)))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }
}

/// The app's `TextShaper` (docs/attachments.md §10): text boxes in the app's
/// PDF, SVG and PNG exports are laid out exactly as the canvas shows them.
struct CoreTextShaper: TextShaper {
    func shape(_ text: TextContent, frame: Rect) throws -> ShapedText {
        TextBoxLayout(text, frame: frame).shapedText()
    }
}
