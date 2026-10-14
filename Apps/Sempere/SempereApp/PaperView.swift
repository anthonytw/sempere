import SempereRender
import Sempere
import UIKit

/// The page's paper (background colour plus its ruling) under the canvas,
/// built from `SempereRender.PaperRenderer` so it matches exports for every kind.
///
/// Rulings are vector shape layers rather than a bitmap: an infinite page can
/// be tens of thousands of points tall. The draw commands are grouped by paint
/// and line width into one path per group (a layer each), built once in page
/// points and re-scaled for the zoom level.
final class PaperView: UIView {
    /// Commands of one look: all lines of a colour and width, or all dots of a colour.
    struct Group {
        var path = CGMutablePath()
        var stroke: Paint?
        var fill: Paint?
        var lineWidth = 0.0
    }

    private var groups: [Group] = []
    private var layers: [CAShapeLayer] = []
    private var paper: Paper?
    private var size: CGSize = .zero
    private var sheetHeight: Double?
    private var zoom: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuilds the ruling for `paper` on a page of `size` points.
    /// `sheetHeight` is `PaperRenderer.sheetHeight(for:)` of the page.
    func configure(paper: Paper, size: CGSize, sheetHeight: Double? = nil) {
        guard paper != self.paper || size != self.size || sheetHeight != self.sheetHeight else { return }
        self.paper = paper
        self.size = size
        self.sheetHeight = sheetHeight
        backgroundColor = paper.background.uiColor
        groups = Self.groups(paper: paper, size: size, sheetHeight: sheetHeight)
        layers.forEach { $0.removeFromSuperlayer() }
        layers = groups.map { group in
            let layer = CAShapeLayer()
            layer.strokeColor = group.stroke.map(Self.cgColor)
            layer.fillColor = group.fill.map(Self.cgColor)
            self.layer.addSublayer(layer)
            return layer
        }
        apply()
    }

    private static func cgColor(_ p: Paint) -> CGColor {
        UIColor(red: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: CGFloat(p.alpha)).cgColor
    }

    /// Shows the paper at `zoom` (canvas points per page point).
    func setZoom(_ zoom: CGFloat) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom)
        var scale = CGAffineTransform(scaleX: zoom, y: zoom)
        for (group, layer) in zip(groups, layers) {
            layer.frame = bounds
            layer.path = group.path.copy(using: &scale)
            layer.lineWidth = group.lineWidth * zoom
        }
        CATransaction.commit()
    }

    /// Line and dot paths of `paper` in page points, built band by band
    /// (PaperRenderer caps the commands per band) and grouped by how they are
    /// painted, in drawing order. Ruling stops at `RenderLimits.maxExtent`, as
    /// in exports, so a corrupt or absurd page height cannot spin here.
    static func groups(paper: Paper, size: CGSize, sheetHeight: Double? = nil) -> [Group] {
        struct Key: Hashable { var stroke: Paint?; var fill: Paint?; var width: Double }
        var index: [Key: Int] = [:]
        var out: [Group] = []
        func group(_ c: DrawCommand) -> Int {
            let key = Key(stroke: c.stroke, fill: c.stroke == nil ? c.fill : nil, width: c.stroke == nil ? 0 : c.lineWidth)
            if let i = index[key] { return i }
            out.append(Group(stroke: key.stroke, fill: key.fill, lineWidth: key.width))
            index[key] = out.count - 1
            return out.count - 1
        }
        let width = Double(size.width), height = min(Double(size.height), RenderLimits.maxExtent)
        guard width > 0, width <= RenderLimits.maxExtent, height > 0 else { return out }
        let band = 792.0
        var y = 0.0
        while y < height {
            let end = min(y + band, height)
            let cmds = PaperRenderer.commands(paper: paper, width: width, height: end - y, yOffset: y, yEnd: end,
                                              originY: 0, includeBackground: false, sheetHeight: sheetHeight ?? height)
            for c in cmds {
                switch c.primitive {
                case .line(let a, let b):
                    let i = group(c)
                    out[i].path.move(to: CGPoint(x: a.x, y: a.y))
                    out[i].path.addLine(to: CGPoint(x: b.x, y: b.y))
                case .circle(let center, let r):
                    let i = group(c)
                    out[i].path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                default:
                    break
                }
            }
            y = end
        }
        return out
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
