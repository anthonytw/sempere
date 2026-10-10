import Foundation
import Sempere

/// How every writer draws a Markdown text box (format.md §8.5.4): laid out
/// by `MarkdownLayout` and turned into items it already draws, in the box's
/// place in the drawing order: text items with fixed lines, `math` items for
/// the formula boxes (their render, else their source), and the shapes
/// (markers, bars, rules, code fills) as the first piece's underlay. The
/// pieces turn with the box: each keeps the box's rotation about the box's
/// centre.
enum MarkdownItems {
    /// `it`'s pieces, or nil when it is not a Markdown box (or there is no
    /// shaper to measure with: it is then drawn like any text item without one).
    static func expand(_ it: PreparedItem, shaper: (any TextShaper)?) -> [PreparedItem]? {
        var ignored: [String] = []
        return expand(it, shaper: shaper, warnings: &ignored)
    }

    /// Like `expand(_:shaper:)`, adding to `warnings` when formulas are drawn
    /// as their source (no typeset rendering stored, format.md §8.5.4).
    static func expand(_ it: PreparedItem, shaper: (any TextShaper)?, warnings: inout [String]) -> [PreparedItem]? {
        guard it.item.kind == .text, let content = it.item.text, content.isMarkdown, let shaper else { return nil }
        let plan = MarkdownPlan(content)
        let layout = MarkdownLayout(plan: plan, frame: it.item.frame, measure: MarkdownLayout.measure(with: shaper))
        let unrendered = plan.formulas.filter {
            MarkdownText.formula(in: content, latex: $0.latex, display: $0.display, size: $0.size, color: $0.color) == nil
        }.count
        if unrendered > 0 {
            warnings.append("page \(it.pageNumber): text box \(it.item.id.uuidString.lowercased().prefix(8)): "
                + "\(unrendered) formula\(unrendered == 1 ? " is" : "s are") drawn as its LaTeX source "
                + "(no typeset rendering stored; typeset it in the app)")
        }
        return pieces(it, layout)
    }

    /// The pieces of `layout`, laid out for `it`.
    static func pieces(_ it: PreparedItem, _ layout: MarkdownLayout) -> [PreparedItem] {
        let degrees = it.item.rotation ?? 0
        let turn = ItemGeometry.rotate(frame: it.item.frame, degrees: degrees)
        func place(_ r: Rect) -> Rect {
            let c = turn.apply(Point(x: r.x + r.w / 2, y: r.y + r.h / 2))
            return Rect(x: c.x - r.w / 2, y: c.y - r.h / 2, w: r.w, h: r.h)
        }
        var n = 0
        func nextID() -> UUID {
            n += 1
            return UUID.derived(from: "sempere-markdown-piece/\(it.item.id.uuidString.lowercased())/\(n)")
        }
        func prepared(_ item: Item) -> PreparedItem? {
            var item = item
            item.rotation = it.item.rotation
            item.layer = it.item.layer
            return try? PreparedItem(item, pageNumber: it.pageNumber)
        }
        var out: [PreparedItem] = []
        // The shapes ride on an empty text item at the box's frame, drawn first.
        let empty = TextContent(size: it.item.text?.size ?? 12, color: it.item.text?.color ?? .black, runs: [], breaks: [])
        if var carrier = prepared(Item.text(id: nextID(), empty, frame: it.item.frame, z: it.item.z, layer: it.item.layer)) {
            carrier.underlay = layout.shapes.map { $0.mapped(turn.apply) }
            out.append(carrier)
        }
        for t in layout.texts {
            if let p = prepared(Item.text(id: nextID(), t.content, frame: place(t.frame), z: it.item.z, layer: it.item.layer)) {
                out.append(p)
            }
        }
        for b in layout.boxes {
            if let p = prepared(Item.math(id: nextID(), b.formula.math, frame: place(b.frame), z: it.item.z, layer: it.item.layer)) {
                out.append(p)
            }
        }
        return out
    }
}

extension DrawCommand {
    /// The command with every point mapped by `f` (rectangles and circles
    /// become paths, so any affine map applies).
    func mapped(_ f: (Point) -> Point) -> DrawCommand {
        var c = self
        switch primitive {
        case let .rect(x, y, w, h):
            c.primitive = .path([Subpath(points: [Point(x: x, y: y), Point(x: x + w, y: y), Point(x: x + w, y: y + h),
                                                  Point(x: x, y: y + h)].map(f), closed: true)])
        case let .line(a, b): c.primitive = .line(from: f(a), to: f(b))
        case let .circle(center, r):
            c.primitive = .path([Subpath(points: (0..<32).map { k in
                let t = Double(k) / 32 * 2 * Double.pi
                return f(Point(x: center.x + r * cos(t), y: center.y + r * sin(t)))
            }, closed: true)])
        case let .path(subs): c.primitive = .path(subs.map { Subpath(points: $0.points.map(f), closed: $0.closed) })
        }
        return c
    }
}
