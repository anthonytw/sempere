import SempereRender
import Sempere
import UIKit

/// Draws a paper into an image with `PaperRenderer`, the same geometry the
/// canvas and the exports use. Images are cached per (paper, size, scale).
@MainActor
enum PaperImage {
    /// A letter page, which the thumbnails and the preview show.
    static let page = CGSize(width: 612, height: 792)

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        return c
    }()

    /// The whole letter page of `paper` scaled to `size` points.
    static func image(for paper: Paper, size: CGSize, scale: CGFloat) -> UIImage {
        let key = "\(Self.key(paper))|\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = render(paper, size: size, scale: scale)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func key(_ paper: Paper) -> String {
        guard let data = try? InkJSON.encoder().encode(paper) else { return "\(paper.kind)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Draws the page; lines and dots are kept at least about a pixel wide so
    /// a small thumbnail still shows the pattern.
    static func render(_ paper: Paper, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let zoom = size.width / page.width
        let commands = PaperRenderer.commands(paper: paper, width: Double(page.width), height: Double(page.height),
                                              sheetHeight: Double(page.height))
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            g.fill(CGRect(origin: .zero, size: size))
            g.scaleBy(x: zoom, y: zoom)
            let minWidth = 0.8 / (zoom * scale)
            for c in commands {
                switch c.primitive {
                case .rect(let x, let y, let w, let h):
                    if let fill = c.fill {
                        g.setFillColor(color(fill))
                        g.fill(CGRect(x: x, y: y, width: w, height: h))
                    }
                case .line(let a, let b):
                    guard let stroke = c.stroke else { continue }
                    g.setStrokeColor(color(stroke))
                    g.setLineWidth(max(c.lineWidth, minWidth))
                    g.move(to: CGPoint(x: a.x, y: a.y))
                    g.addLine(to: CGPoint(x: b.x, y: b.y))
                    g.strokePath()
                case .circle(let center, let radius):
                    guard let fill = c.fill else { continue }
                    let r = max(radius, 0.7 / (zoom * scale))
                    g.setFillColor(color(fill))
                    g.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                case .path:
                    break   // paper uses no free paths
                }
            }
        }
    }

    nonisolated private static func color(_ p: Paint) -> CGColor {
        UIColor(red: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: CGFloat(p.alpha)).cgColor
    }
}
