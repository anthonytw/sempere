import Foundation
import Sempere

/// Paper background and ruling as draw commands.
public enum PaperRenderer {
    /// Default line width of ruled and grid lines, points (`Paper.lineWidth`).
    public static let ruleWidth = 0.5
    /// Default dot radius for `dot` paper, points (`Paper.dotRadius`).
    public static let dotRadius = 0.9

    /// Height of one "sheet" for sheet-structured paper (Cornell): the page
    /// height, or for an infinite page its `breakHeight` (else letter aspect
    /// from the width), so the structure repeats once per exported page.
    public static func sheetHeight(for size: PageSize) -> Double {
        size.sheetHeight   // format.md §5.4.3; maxSheetHeight == RenderLimits.maxExtent
    }

    /// Commands for a `width` x `height` region whose top edge is at global
    /// page y = `yOffset` and whose bottom edge is at `yEnd` (default
    /// `yOffset + height`). Non-zero `yOffset` is used for infinite-page chunks.
    ///
    /// Ruling is laid out in global coordinates, so it continues across chunks.
    /// A rule at global `y = k * spacing` (k >= 1) belongs to exactly the one
    /// chunk with `yOffset <= y < yEnd` (half-open), so a rule exactly on a
    /// boundary is drawn once, at local y = 0, in the lower chunk.
    ///
    /// `originY` is the global y that maps to output y = 0 (default `yOffset`,
    /// i.e. chunk-local output); pass 0 to emit global coordinates for a band of
    /// a taller image. `includeBackground: false` omits the background rect.
    /// `sheetHeight` (default `height`) is the period of Cornell paper's
    /// structure, see `sheetHeight(for:)`.
    ///
    /// Paper whose spacing is below `RenderLimits.minPaperSpacing` (or not
    /// finite), or that would need more than `RenderLimits.maxPaperCommands`
    /// commands in this band, renders as the plain background. Guarantee: any
    /// band up to 612 x 792 pt (a letter page, or an infinite-page chunk of
    /// width <= 612 pt) renders its full ruling at every spacing >= 4 pt.
    /// Music staves use `staffSpacing` / `staffGap` instead of `spacing`.
    /// (`PreparedPage` may still draw a whole page blank when all its bands
    /// together exceed `RenderLimits.maxPaperCommandsPerPage`.)
    public static func commands(paper rawPaper: Paper, width: Double, height: Double,
                                yOffset: Double = 0, yEnd: Double? = nil,
                                originY: Double? = nil, includeBackground: Bool = true,
                                sheetHeight: Double? = nil) -> [DrawCommand] {
        let paper = rawPaper.rendered()
        let origin = originY ?? yOffset
        var out: [DrawCommand] = []
        if includeBackground {
            out.append(DrawCommand(.rect(x: 0, y: yOffset - origin, width: width, height: height), fill: Paint(paper.background)))
        }
        let s = paper.spacing
        let bottom = yEnd ?? (yOffset + height)
        guard let estimate = rulingCount(paper: paper, width: width, yOffset: yOffset, yEnd: bottom,
                                         sheetHeight: sheetHeight ?? max(height, 1)),
              estimate <= RenderLimits.maxPaperCommands else { return out }

        let band = max(bottom - yOffset, 0)
        let line = Paint(paper.lineColor)
        let w = paper.lineWidth
        func hline(_ y: Double, from x0: Double = 0, to x1: Double = width, _ p: Paint, _ lw: Double) {
            out.append(DrawCommand(.line(from: Point(x: x0, y: y - origin), to: Point(x: x1, y: y - origin)),
                                   stroke: p, lineWidth: lw))
        }
        func diag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> DrawCommand {
            DrawCommand(.line(from: Point(x: x0, y: y0 - origin), to: Point(x: x1, y: y1 - origin)), stroke: line, lineWidth: w)
        }
        func vline(_ x: Double, from y0: Double, to y1: Double, _ p: Paint, _ lw: Double) {
            out.append(DrawCommand(.line(from: Point(x: x, y: y0 - origin), to: Point(x: x, y: y1 - origin)),
                                   stroke: p, lineWidth: lw))
        }

        // Half-open index ranges: rows k in [rowStart, rowEnd), cols k in [1, colEnd).
        let rowStartD = max((yOffset / s).rounded(.up), 1)
        let rowEndD = (bottom / s).rounded(.up)
        let colEndD = (width / s).rounded(.up)
        let rowCountD = max(rowEndD - rowStartD, 0), colCountD = max(colEndD - 1, 0)

        switch paper.kind {
        case .blank:
            break
        case .ruled, .marginRuled:
            guard rowCountD <= RenderLimits.maxPaperCommands else { return out }
            for k in stride(from: Int(rowStartD), to: Int(rowStartD + rowCountD), by: 1) { hline(Double(k) * s, line, w) }
        case .grid:
            guard rowCountD + colCountD <= RenderLimits.maxPaperCommands else { return out }
            for k in stride(from: Int(rowStartD), to: Int(rowStartD + rowCountD), by: 1) { hline(Double(k) * s, line, w) }
            for k in stride(from: 1, to: Int(colCountD) + 1, by: 1) { vline(Double(k) * s, from: yOffset, to: bottom, line, w) }
        case .dot:
            guard rowCountD * colCountD <= RenderLimits.maxPaperCommands else { return out }
            for r in stride(from: Int(rowStartD), to: Int(rowStartD + rowCountD), by: 1) {
                for k in stride(from: 1, to: Int(colCountD) + 1, by: 1) {
                    out.append(DrawCommand(.circle(center: Point(x: Double(k) * s, y: Double(r) * s - origin),
                                                   radius: paper.dotRadius), fill: line))
                }
            }
        case .isoDot, .isoGrid:
            // Triangular lattice: dots `s` apart, rows `s * sqrt(3) / 2` apart, odd rows shifted by s / 2.
            let rowH = s * 0.8660254037844386
            let r0 = max((yOffset / rowH).rounded(.up), 1), r1 = (bottom / rowH).rounded(.up)
            let rows = max(r1 - r0, 0)
            if paper.kind == .isoDot {
                guard rows * (width / s + 1) <= RenderLimits.maxPaperCommands else { return out }
                for r in stride(from: Int(r0), to: Int(r0 + rows), by: 1) {
                    let shift = r % 2 == 0 ? 0.0 : s / 2
                    var x = shift == 0 ? s : shift
                    while x < width {
                        out.append(DrawCommand(.circle(center: Point(x: x, y: Double(r) * rowH - origin),
                                                       radius: paper.dotRadius), fill: line))
                        x += s
                    }
                }
            } else {
                let slope = 1 / 3.0.squareRoot()          // dx per dy of the 60-degree lines
                let nLo = ((0 - bottom * slope) / s).rounded(.up), nHi = ((width - yOffset * slope) / s).rounded(.down)
                let nB0 = ((yOffset * slope) / s).rounded(.up), nB1 = ((width + bottom * slope) / s).rounded(.down)
                guard rows + max(nHi - nLo + 1, 0) + max(nB1 - nB0 + 1, 0) <= RenderLimits.maxPaperCommands else { return out }
                for r in stride(from: Int(r0), to: Int(r0 + rows), by: 1) { hline(Double(r) * rowH, line, w) }
                // x = n s + y slope (down-right) and x = n s - y slope (down-left), clipped to the band and page.
                if nHi >= nLo {
                    for n in stride(from: Int(nLo), through: Int(nHi), by: 1) {
                        let x0 = Double(n) * s
                        let ya = max(yOffset, (0 - x0) / slope), yb = min(bottom, (width - x0) / slope)
                        if yb > ya { out.append(diag(x0 + ya * slope, ya, x0 + yb * slope, yb)) }
                    }
                }
                if nB1 >= nB0 {
                    for n in stride(from: Int(nB0), through: Int(nB1), by: 1) {
                        let x0 = Double(n) * s
                        let ya = max(yOffset, (x0 - width) / slope), yb = min(bottom, x0 / slope)
                        if yb > ya { out.append(diag(x0 - ya * slope, ya, x0 - yb * slope, yb)) }
                    }
                }
            }
        case .cornell:
            // At least 1 pt: with |yOffset| and |bottom| bounded above, the
            // sheet indices below then always fit in an Int.
            let sheet = sheetHeight ?? max(height, 1)
            guard sheet.isFinite, sheet >= 1 else { return out }
            let firstSheet = Int(max((yOffset / sheet).rounded(.down), 0))
            let lastSheet = Int(max((bottom / sheet).rounded(.up), 1))
            guard Double(lastSheet - firstSheet) * (sheet / s + 4) <= RenderLimits.maxPaperCommands else { return out }
            let cue = min(paper.cueWidth, width * 0.6)
            let summary = min(paper.summaryHeight, sheet * 0.5)
            let structural = w * 2
            for j in firstSheet..<lastSheet {
                let top = Double(j) * sheet, notesBottom = top + sheet - summary
                var k = 1
                while top + Double(k) * s < notesBottom {
                    let y = top + Double(k) * s
                    if y >= yOffset && y < bottom { hline(y, from: cue, to: width, line, w) }
                    k += 1
                }
                let a = max(top, yOffset), b = min(notesBottom, bottom)
                if b > a { vline(cue, from: a, to: b, line, structural) }
                if notesBottom >= yOffset && notesBottom < bottom { hline(notesBottom, line, structural) }
            }
        case .staff:
            let ss = paper.staffSpacing, gap = paper.staffGap
            let period = 4 * ss + gap
            let i0 = Int(max(((yOffset - gap - 4 * ss) / period).rounded(.down), 0))
            let i1 = Int(max(((bottom - gap) / period).rounded(.up), 0))
            guard Double(max(i1 - i0, 0)) * 5 <= RenderLimits.maxPaperCommands else { return out }
            for i in i0..<max(i1, i0) {
                let top = gap + Double(i) * period
                for l in 0..<5 {
                    let y = top + Double(l) * ss
                    if y >= yOffset && y < bottom { hline(y, line, w) }
                }
            }
        }

        if paper.kind.supportsMargins, band > 0 {
            let mc = Paint(paper.marginColor)
            if paper.marginLeft > 0, paper.marginLeft < width {
                vline(paper.marginLeft, from: yOffset, to: bottom, mc, w)
            }
            if paper.marginTop > 0, paper.marginTop >= yOffset, paper.marginTop < bottom {
                hline(paper.marginTop, mc, w)
            }
        }
        return out
    }

    /// How many ruling commands the band `[yOffset, yEnd)` of a `width`-wide
    /// page needs (an upper bound, margin lines included), or nil when the
    /// paper draws no ruling there: blank, a spacing below
    /// `RenderLimits.minPaperSpacing` (staves ignore `spacing`), or a band or
    /// Cornell `sheetHeight` out of range. `commands` draws nothing for a band
    /// over `RenderLimits.maxPaperCommands`; `PreparedPage` sums the bands of a
    /// page against `RenderLimits.maxPaperCommandsPerPage`.
    static func rulingCount(paper rawPaper: Paper, width: Double, yOffset: Double, yEnd bottom: Double,
                            sheetHeight: Double) -> Double? {
        let paper = rawPaper.rendered()
        let s = paper.spacing
        let usesSpacing = paper.kind != .staff
        guard paper.kind != .blank, !usesSpacing || (s.isFinite && s >= RenderLimits.minPaperSpacing),
              width.isFinite, width > 0, bottom.isFinite, yOffset.isFinite,
              width <= RenderLimits.maxExtent, abs(bottom) <= RenderLimits.maxExtent * 2,
              abs(yOffset) <= RenderLimits.maxExtent * 2 else { return nil }
        let rowStartD = max((yOffset / s).rounded(.up), 1)
        let rowEndD = (bottom / s).rounded(.up)
        let colEndD = (width / s).rounded(.up)
        let rowCountD = max(rowEndD - rowStartD, 0), colCountD = max(colEndD - 1, 0)
        var n: Double
        switch paper.kind {
        case .blank: return nil
        case .ruled, .marginRuled: n = rowCountD
        case .grid: n = rowCountD + colCountD
        case .dot: n = rowCountD * colCountD
        case .isoDot, .isoGrid:
            let rowH = s * 0.8660254037844386
            let rows = max((bottom / rowH).rounded(.up) - max((yOffset / rowH).rounded(.up), 1), 0)
            if paper.kind == .isoDot {
                n = rows * (width / s + 1)
            } else {
                let slope = 1 / 3.0.squareRoot()
                let nLo = ((0 - bottom * slope) / s).rounded(.up), nHi = ((width - yOffset * slope) / s).rounded(.down)
                let nB0 = ((yOffset * slope) / s).rounded(.up), nB1 = ((width + bottom * slope) / s).rounded(.down)
                n = rows + max(nHi - nLo + 1, 0) + max(nB1 - nB0 + 1, 0)
            }
        case .cornell:
            guard sheetHeight.isFinite, sheetHeight >= 1 else { return nil }
            let sheets = max((bottom / sheetHeight).rounded(.up), 1) - max((yOffset / sheetHeight).rounded(.down), 0)
            n = max(sheets, 0) * (sheetHeight / s + 4)
        case .staff:
            let period = 4 * paper.staffSpacing + paper.staffGap
            let staves = max(((bottom - paper.staffGap) / period).rounded(.up), 0)
                - max(((yOffset - paper.staffGap - 4 * paper.staffSpacing) / period).rounded(.down), 0)
            n = max(staves, 0) * 5
        }
        if paper.kind.supportsMargins { n += 2 }
        return n
    }
}
