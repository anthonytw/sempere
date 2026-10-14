import Foundation

// MARK: - Cropping images and PDF pages (format.md §8.2.5, §8.2.6)
//
// A crop is a register in the source's coordinates (oriented pixels for an
// image, points on the effective page for a PDF page); the frame is where the
// crop lands on the page. Changing the crop changes what the frame shows, so
// the gesture also moves and resizes the frame: the part of the source that
// stays visible keeps its place and scale on the page (cropping never makes
// the remaining picture jump or stretch). Shared by the app's crop sheet and
// `sempere items crop`.

extension Item {
    /// The whole source in crop coordinates: `[0, 0, pixelSize]` for an
    /// image, `[0, 0, pageSize]` for a PDF page; nil for other kinds or a
    /// missing or empty size.
    public var cropBounds: Rect? {
        let size: Size?
        switch kind {
        case .image: size = pixelSize
        case .pdfPage: size = pageSize
        default: size = nil
        }
        guard let size, size.isPositive, size.w.isFinite, size.h.isFinite else { return nil }
        return Rect(x: 0, y: 0, w: size.w, h: size.h)
    }

    /// The part of the source shown: the crop clamped to the source, or all of it.
    public var shownCrop: Rect? {
        guard let bounds = cropBounds else { return nil }
        guard let crop else { return bounds }
        return ItemCrop.clamp(crop, to: bounds, minSize: 0) ?? bounds
    }
}

/// Crop geometry: clamping, the frame a new crop lands in, and dragging the
/// crop rectangle's corners or body. Pure; source coordinates are y down.
public enum ItemCrop {
    /// The smallest crop side a gesture leaves, in source units.
    public static let minSide = 1.0

    /// `r` intersected with `bounds`, its sides at least `minSize` (grown
    /// inside `bounds` where possible); nil when nothing of it is inside, or
    /// it is not finite.
    public static func clamp(_ r: Rect, to bounds: Rect, minSize: Double = minSide) -> Rect? {
        guard [r.x, r.y, r.w, r.h].allSatisfy(\.isFinite), r.w > 0, r.h > 0 else { return nil }
        let x0 = max(r.x, bounds.x), y0 = max(r.y, bounds.y)
        let x1 = min(r.x + r.w, bounds.x + bounds.w), y1 = min(r.y + r.h, bounds.y + bounds.h)
        guard x1 > x0, y1 > y0 else { return nil }
        var out = Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        let mw = min(minSize, bounds.w), mh = min(minSize, bounds.h)
        if out.w < mw { out.x = min(out.x, bounds.x + bounds.w - mw); out.w = mw }
        if out.h < mh { out.y = min(out.y, bounds.y + bounds.h - mh); out.h = mh }
        return out
    }

    /// The frame that shows `newCrop` where it was on the page while `frame`
    /// showed `oldCrop`: same scale (frame points per source unit on each
    /// axis), same place, turned by `rotation` about the old frame's centre.
    public static func frame(_ frame: Rect, rotation: Double?, from oldCrop: Rect, to newCrop: Rect) -> Rect {
        guard oldCrop.w > 0, oldCrop.h > 0 else { return frame }
        let sx = frame.w / oldCrop.w, sy = frame.h / oldCrop.h
        let x = (newCrop.x - oldCrop.x) * sx, y = (newCrop.y - oldCrop.y) * sy
        let w = newCrop.w * sx, h = newCrop.h * sy
        // The new centre, in the old frame's own axes from its centre, then turned onto the page.
        let local = ItemFrames.Point(x: x + w / 2 - frame.w / 2, y: y + h / 2 - frame.h / 2)
        let d = ItemFrames.rotate(local, about: ItemFrames.Point(x: 0, y: 0), degrees: rotation ?? 0)
        let c = ItemFrames.centre(frame)
        return Rect(x: c.x + d.x - w / 2, y: c.y + d.y - h / 2, w: w, h: h)
    }

    /// What a drag in the crop editor moves.
    public enum Handle: Hashable, Sendable {
        /// A corner (the opposite one stays put).
        case corner(ItemFrames.Corner)
        /// The whole rectangle (its size stays).
        case body
    }

    /// `crop` after dragging `handle` by `dx`, `dy` source units, kept inside
    /// `bounds` and at least `minSize` on each side.
    public static func dragged(_ crop: Rect, _ handle: Handle, dx: Double, dy: Double, bounds: Rect,
                               minSize: Double = minSide) -> Rect {
        guard dx.isFinite, dy.isFinite else { return crop }
        let mw = min(minSize, bounds.w), mh = min(minSize, bounds.h)
        switch handle {
        case .body:
            let x = min(max(crop.x + dx, bounds.x), bounds.x + bounds.w - crop.w)
            let y = min(max(crop.y + dy, bounds.y), bounds.y + bounds.h - crop.h)
            return Rect(x: x, y: y, w: crop.w, h: crop.h)
        case .corner(let corner):
            var x0 = crop.x, y0 = crop.y, x1 = crop.x + crop.w, y1 = crop.y + crop.h
            let s = corner.signs
            if s.x < 0 { x0 = min(max(x0 + dx, bounds.x), x1 - mw) } else { x1 = max(min(x1 + dx, bounds.x + bounds.w), x0 + mw) }
            if s.y < 0 { y0 = min(max(y0 + dy, bounds.y), y1 - mh) } else { y1 = max(min(y1 + dy, bounds.y + bounds.h), y0 + mh) }
            return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }
    }

    /// The handle under `p` (source units) for a crop shown at `scale` view
    /// points per source unit: a corner within `reach` view points, else the
    /// body when `p` is inside, else nil.
    public static func handle(at p: ItemFrames.Point, crop: Rect, scale: Double, reach: Double = 22) -> Handle? {
        guard scale > 0, scale.isFinite else { return nil }
        let r = reach / scale
        let corners = ItemFrames.corners(crop, rotation: nil)
        var best: (ItemFrames.Corner, Double)?
        for corner in ItemFrames.Corner.allCases {
            let c = corners[corner.rawValue]
            let d = max(abs(c.x - p.x), abs(c.y - p.y))
            if d <= r, d < best?.1 ?? .infinity { best = (corner, d) }
        }
        if let best { return .corner(best.0) }
        return ItemFrames.contains(crop, rotation: nil, p) ? .body : nil
    }
}

extension NoteOps {
    /// Crops the image or PDF page `id` to `crop` (source coordinates; nil:
    /// the whole source), one `setItem(crop)` plus, unless `keepFrame`, one
    /// `setItem(frame)` that keeps what stays visible where it was
    /// (`ItemCrop.frame`). The crop is clamped to the source; a crop covering
    /// all of it is stored as none.
    ///
    /// - Returns: nil when the page has no such item or nothing changes.
    /// - Throws: `AttachmentOpsError.invalidFrame` for an item that cannot be
    ///   cropped (not an image or PDF page, no size), a crop outside the source,
    ///   or a resulting frame beyond the writers' limits.
    public static func setCrop(_ id: UUID, to crop: Rect?, on page: Page, keepFrame: Bool = false) throws -> ItemEdit? {
        guard let i = page.items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = page.items[i]
        guard let bounds = item.cropBounds, let old = item.shownCrop else {
            throw AttachmentOpsError.invalidFrame("only images and PDF pages with a size can be cropped")
        }
        var target: Rect? = nil
        if let crop {
            guard let c = ItemCrop.clamp(crop, to: bounds) else {
                throw AttachmentOpsError.invalidFrame("the crop lies outside the \(item.kind == .image ? "image" : "page")")
            }
            target = c.rounded == bounds.rounded ? nil : c.rounded
        }
        let shown = target ?? bounds
        if item.crop?.rounded == target { return nil }
        var ops: [Op] = [.setItem(page: page.id, itemId: id, change: .crop(target))]
        var out = page
        out.items[i].crop = target
        if !keepFrame {
            let frame = ItemCrop.frame(item.frame, rotation: item.rotation, from: old, to: shown).rounded
            try validate(frame: frame)
            if frame != item.frame.rounded {
                ops.append(.setItem(page: page.id, itemId: id, change: .frame(frame)))
                out.items[i].frame = frame
            }
        }
        out.items.sort(by: Item.drawsBefore)
        return ItemEdit(ops: ops, page: out)
    }

    /// A frame for content of `size` (pixels or points, shown one per point)
    /// added while `visible` (page points; nil: unknown) is on screen: fitted
    /// inside the visible part of the page less the margin (and inside the
    /// page's content box), centred on `centre` when given (a drop) or else
    /// on the visible area, and kept on the page.
    public static func viewFrame(for size: Size, pageSize: PageSize, visible: Rect?, centre: ItemFrames.Point? = nil) -> Rect {
        let page = Rect(x: 0, y: 0, w: pageSize.width, h: pageSize.infinite ? max(pageSize.height, pageSize.sheetHeight) : pageSize.height)
        var area = page
        if let v = visible, [v.x, v.y, v.w, v.h].allSatisfy(\.isFinite), v.w > 0, v.h > 0,
           let shown = ItemCrop.clamp(v, to: Rect(x: 0, y: 0, w: page.w, h: pageSize.infinite ? Limits.extent : page.h), minSize: 0) {
            area = shown
        }
        let m = Limits.margin
        var box = Size(w: max(area.w - 2 * m, 1), h: max(area.h - 2 * m, 1))
        let content = contentBox(pageSize)
        box = Size(w: min(box.w, content.w), h: min(box.h, content.h))
        let fitted = fit(size, into: box)
        let w = fitted.w, h = fitted.h
        let c = centre ?? ItemFrames.Point(x: area.x + area.w / 2, y: area.y + area.h / 2)
        var x = c.x - w / 2, y = c.y - h / 2
        x = min(max(x, 0), max(page.w - w, 0))
        y = max(y, 0)
        if !pageSize.infinite { y = min(y, max(page.h - h, 0)) }
        return Rect(x: x, y: y, w: w, h: h).rounded
    }
}
