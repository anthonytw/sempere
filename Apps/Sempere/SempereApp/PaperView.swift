import SempereRender
import Sempere
import UIKit

/// The page's paper (background color plus its ruling) under the canvas,
/// built from `SempereRender.PaperRenderer` so it matches exports for every kind.
///
/// Rulings are vector shape layers rather than a bitmap. An infinite page can
/// be tens of thousands of points tall, so the ruling is cut into bands of
/// `band` page points (PaperRenderer's own bands), and only the bands near the
/// visible part of the canvas (`setVisible`) have layers: one shape layer per
/// look (paint and line width) per band, its path in the band's own
/// coordinates. A scroll then moves small layers Core Animation can keep
/// drawn, instead of one shape layer the height of the whole note whose path
/// it would have to draw again (TestFlight 1.0.0 (6): scrolling a long note
/// was jerky), and a zoom re-scales a screenful of paths, not the note's.
/// The background color is the view's own (no bitmap at any height).
final class PaperView: UIView {
    /// Commands of one look: all lines of a color and width, or all dots of a color.
    struct Group {
        var path = CGMutablePath()
        var stroke: Paint?
        var fill: Paint?
        var lineWidth = 0.0
    }

    /// Height of a band, page points.
    static let band = 792.0

    private var paper: Paper?
    private var size: CGSize = .zero
    private var sheetHeight: Double?
    private var zoom: CGFloat = 1
    /// The visible part of the canvas's content (canvas content points); nil: every band.
    private var visible: CGRect?
    /// Each band's groups, page points relative to the band's top (built when first shown).
    private var bandGroups: [Int: [Group]] = [:]
    /// The bands on screen: a container layer each, holding a shape layer per group.
    private var bandLayers: [Int: CALayer] = [:]
    /// The zoom each shown band's paths were scaled for.
    private var bandZoom: [Int: CGFloat] = [:]
    /// Drawn for a dark page (Settings ▸ Appearance ▸ Note Pages): every color
    /// through `PageColorInversion`. Display only; exports keep the paper's colors.
    private(set) var isDark = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuilds the ruling for `paper` on a page of `size` points.
    /// `sheetHeight` is `PaperRenderer.sheetHeight(for:)` of the page.
    /// Only a new height (an infinite page growing, or following the zoom)
    /// keeps the bands above the old end.
    func configure(paper: Paper, size: CGSize, sheetHeight: Double? = nil) {
        guard paper != self.paper || size != self.size || sheetHeight != self.sheetHeight else { return }
        let onlyHeight = paper == self.paper && size.width == self.size.width && sheetHeight == self.sheetHeight
        if onlyHeight {
            // The band holding the old end (and any after it) was cut there: built again.
            let kept = Self.bandCount(height: Double(min(size.height, self.size.height))) - 1
            for i in Array(bandGroups.keys) where i >= kept { bandGroups[i] = nil }
            for i in Array(bandLayers.keys) where i >= kept { removeBand(i) }
        } else {
            bandGroups = [:]
            for i in Array(bandLayers.keys) { removeBand(i) }
        }
        self.paper = paper
        self.size = size
        self.sheetHeight = sheetHeight
        apply()
        paint()
    }

    /// Shows the paper light (as stored and exported) or dark.
    func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        paint()
    }

    /// The background color shown (tests: Note Pages ▸ Dark changes it).
    var shownBackground: Paint? { paper.map { shown(Paint($0.background)) } }

    /// Colors the background and every shown band's layers (new bands color themselves).
    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundColor = shownBackground.map { UIColor(cgColor: Self.cgColor($0)) }
        for (i, container) in bandLayers {
            guard let groups = bandGroups[i] else { continue }
            for (group, shape) in zip(groups, container.sublayers ?? []) {
                guard let shape = shape as? CAShapeLayer else { continue }
                color(shape, group)
            }
        }
        CATransaction.commit()
    }

    private func color(_ shape: CAShapeLayer, _ group: Group) {
        shape.strokeColor = group.stroke.map { Self.cgColor(shown($0)) }
        shape.fillColor = group.fill.map { Self.cgColor(shown($0)) }
    }

    private func shown(_ p: Paint) -> Paint { isDark ? PageColorInversion.invert(p) : p }

    private static func cgColor(_ p: Paint) -> CGColor {
        UIColor(red: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: CGFloat(p.alpha)).cgColor
    }

    /// Shows the paper at `zoom` (canvas points per page point).
    func setZoom(_ zoom: CGFloat) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        apply()
    }

    /// The part of the canvas on screen (its content coordinates): only the bands within a
    /// screen of it keep layers. A scroll that stays within the same bands costs nothing.
    func setVisible(_ rect: CGRect) {
        guard rect != visible else { return }
        visible = rect
        updateBands()
    }

    /// The bands that have layers now (tests).
    var shownBands: [Int] { bandLayers.keys.sorted() }

    /// How many shape layers the ruling has now (tests).
    var shapeLayerCount: Int { bandLayers.values.reduce(0) { $0 + ($1.sublayers?.count ?? 0) } }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom)
        updateBands()
        CATransaction.commit()
    }

    private func updateBands() {
        guard let paper else { return }
        let wanted = Self.bands(visible: visible, zoom: zoom, height: Double(size.height))
        for i in Array(bandLayers.keys) where !wanted.contains(i) { removeBand(i) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in wanted {
            let container: CALayer
            if let shown = bandLayers[i] {
                container = shown
            } else {
                let groups = bandGroups[i] ?? Self.groups(paper: paper, size: size, sheetHeight: sheetHeight, band: i)
                bandGroups[i] = groups
                container = CALayer()
                for group in groups {
                    let shape = CAShapeLayer()
                    color(shape, group)
                    container.addSublayer(shape)
                }
                layer.addSublayer(container)
                bandLayers[i] = container
                bandZoom[i] = nil
            }
            let top = Double(i) * Self.band
            container.frame = CGRect(x: 0, y: CGFloat(top) * zoom, width: size.width * zoom,
                                     height: CGFloat(min(Self.band, Double(size.height) - top)) * zoom)
            guard bandZoom[i] != zoom, let groups = bandGroups[i] else { continue }
            bandZoom[i] = zoom
            var scale = CGAffineTransform(scaleX: zoom, y: zoom)
            for (group, shape) in zip(groups, container.sublayers ?? []) {
                guard let shape = shape as? CAShapeLayer else { continue }
                shape.frame = container.bounds
                shape.path = group.path.copy(using: &scale)
                shape.lineWidth = group.lineWidth * zoom
            }
        }
        CATransaction.commit()
    }

    private func removeBand(_ i: Int) {
        bandLayers.removeValue(forKey: i)?.removeFromSuperlayer()
        bandZoom[i] = nil
    }

    /// How many bands a page `height` points tall has (ruling stops at `RenderLimits.maxExtent`).
    static func bandCount(height: Double) -> Int {
        let h = min(height, RenderLimits.maxExtent)
        guard h.isFinite, h > 0 else { return 0 }
        return Int((h / band).rounded(.up))
    }

    /// The bands within a screen (the visible height) above and below `visible` (canvas content
    /// points at `zoom`); every band when `visible` is nil.
    static func bands(visible: CGRect?, zoom: CGFloat, height: Double) -> Range<Int> {
        let count = bandCount(height: height)
        guard count > 0 else { return 0..<0 }
        guard let visible, zoom > 0, visible.minY.isFinite, visible.height.isFinite else { return 0..<count }
        let margin = max(visible.height, 0)
        let top = Double((visible.minY - margin) / zoom), bottom = Double((visible.maxY + margin) / zoom)
        guard bottom > 0, top.isFinite, bottom.isFinite else { return 0..<min(1, count) }
        let first = min(max(Int((max(top, 0) / band).rounded(.down)), 0), count - 1)
        let last = min(max(Int((bottom / band).rounded(.up)), first + 1), count)
        return first..<last
    }

    /// Line and dot paths of band `band` of `paper` (page points from the band's top), grouped by
    /// how they are painted, in drawing order.
    static func groups(paper: Paper, size: CGSize, sheetHeight: Double? = nil, band index: Int) -> [Group] {
        let width = Double(size.width), height = min(Double(size.height), RenderLimits.maxExtent)
        let y = Double(index) * band
        guard width > 0, width <= RenderLimits.maxExtent, height > 0, y < height else { return [] }
        var out = Grouping()
        let end = min(y + band, height)
        let cmds = PaperRenderer.commands(paper: paper, width: width, height: end - y, yOffset: y, yEnd: end,
                                          originY: 0, includeBackground: false, sheetHeight: sheetHeight ?? height)
        out.add(cmds, shiftY: -y)
        return out.groups
    }

    /// Line and dot paths of `paper` in page points, built band by band
    /// (PaperRenderer caps the commands per band) and grouped by how they are
    /// painted, in drawing order. Ruling stops at `RenderLimits.maxExtent`, as
    /// in exports, so a corrupt or absurd page height cannot spin here.
    static func groups(paper: Paper, size: CGSize, sheetHeight: Double? = nil) -> [Group] {
        var out = Grouping()
        let width = Double(size.width), height = min(Double(size.height), RenderLimits.maxExtent)
        guard width > 0, width <= RenderLimits.maxExtent, height > 0 else { return [] }
        var y = 0.0
        while y < height {
            let end = min(y + band, height)
            out.add(PaperRenderer.commands(paper: paper, width: width, height: end - y, yOffset: y, yEnd: end,
                                           originY: 0, includeBackground: false, sheetHeight: sheetHeight ?? height),
                    shiftY: 0)
            y = end
        }
        return out.groups
    }

    /// Draw commands sorted into groups of one look.
    private struct Grouping {
        struct Key: Hashable { var stroke: Paint?; var fill: Paint?; var width: Double }
        var index: [Key: Int] = [:]
        var groups: [Group] = []

        mutating func group(_ c: DrawCommand) -> Int {
            let key = Key(stroke: c.stroke, fill: c.stroke == nil ? c.fill : nil, width: c.stroke == nil ? 0 : c.lineWidth)
            if let i = index[key] { return i }
            groups.append(Group(stroke: key.stroke, fill: key.fill, lineWidth: key.width))
            index[key] = groups.count - 1
            return groups.count - 1
        }

        mutating func add(_ cmds: [DrawCommand], shiftY dy: Double) {
            for c in cmds {
                switch c.primitive {
                case .line(let a, let b):
                    let i = group(c)
                    groups[i].path.move(to: CGPoint(x: a.x, y: a.y + dy))
                    groups[i].path.addLine(to: CGPoint(x: b.x, y: b.y + dy))
                case .circle(let center, let r):
                    let i = group(c)
                    groups[i].path.addEllipse(in: CGRect(x: center.x - r, y: center.y + dy - r, width: 2 * r, height: 2 * r))
                default:
                    break
                }
            }
        }
    }

    /// All line paths and all dot paths of `paper` (the groups merged).
    static func paths(paper: Paper, size: CGSize, sheetHeight: Double? = nil) -> (CGMutablePath, CGMutablePath) {
        let lines = CGMutablePath(), dots = CGMutablePath()
        for g in groups(paper: paper, size: size, sheetHeight: sheetHeight) {
            if g.stroke != nil { lines.addPath(g.path) } else { dots.addPath(g.path) }
        }
        return (lines, dots)
    }
}
