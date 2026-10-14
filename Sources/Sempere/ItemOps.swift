import Foundation

// MARK: - Item gestures (docs/format.md §8.2)
//
// The ops for placing, moving, resizing, deleting and copying items on a
// page, built once here so the app and the CLI write the same deltas. Every
// builder takes the page as it is now (its live items) and returns the ops
// for ONE delta plus the page they leave, like `PageEdit` for page gestures.
// Items are LWW registers (§8.2.2): a move is one `setItem(frame)`, never a
// remove + add; ids live for the item's life. Tombstones are permanent, so
// an item that comes back (undo of a delete) gets a new id with `parent`.

/// The ops for one item gesture and the page they leave.
public struct ItemEdit: Hashable, Sendable {
    /// The ops, for one delta, in order.
    public var ops: [Op]
    /// The page afterwards, its items in drawing order (`Item.drawsBefore`).
    public var page: Page
    /// The ids of the items the gesture added, in the order given.
    public var added: [UUID]

    public init(ops: [Op], page: Page, added: [UUID] = []) {
        self.ops = ops; self.page = page; self.added = added
    }
}

/// Why an item gesture cannot be built.
public enum ItemEditError: Error, Hashable, Sendable {
    /// The item is not valid (format.md §8.2): the reason.
    case invalidItem(String)
    /// The page already has an item with this id.
    case duplicateID(UUID)
}

extension NoteOps {
    /// A `z` key that draws above every item of `layer` on `page`
    /// (format.md §8.2.3: compared byte-wise, like page `order`).
    public static func topZ(on page: Page, layer: ItemLayer) -> String {
        let top = page.items.filter { $0.layer == layer }.map(\.z).max { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return PageOrder.between(top, nil)
    }

    /// Adds `items` to `page` as given (ids, `z` and all), one `addItem` each.
    /// The snapshot-only `origin` and `clocks` are dropped.
    ///
    /// - Throws: `ItemEditError.invalidItem` for an item that would not
    ///   encode, `.duplicateID` for an id already on the page or given twice.
    public static func addItems(_ items: [Item], to page: Page) throws -> ItemEdit {
        var seen = Set(page.items.map(\.id))
        var out = page
        var ops: [Op] = []
        for var item in items {
            if let why = item.validationError { throw ItemEditError.invalidItem(why) }
            guard seen.insert(item.id).inserted else { throw ItemEditError.duplicateID(item.id) }
            item.origin = nil
            item.clocks = nil
            ops.append(.addItem(page: page.id, item: item))
            out.items.append(item)
        }
        out.items.sort(by: Item.drawsBefore)
        return ItemEdit(ops: ops, page: out, added: items.map(\.id))
    }

    /// Places `item` above everything in its layer (a new `z`) on `page`.
    public static func placeOnTop(_ item: Item, on page: Page) throws -> ItemEdit {
        var placed = item
        placed.z = topZ(on: page, layer: item.layer)
        return try addItems([placed], to: page)
    }

    /// Moves or resizes the item `id` to `frame` (one `setItem(frame)`); nil
    /// when the page has no such item, the frame is not finite and positive,
    /// or nothing changes at the stored precision.
    public static func setFrame(_ id: UUID, to frame: Rect, on page: Page) -> ItemEdit? {
        guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite), frame.hasPositiveSize else { return nil }
        return setRegister(id, .frame(frame), on: page) { $0.frame.rounded == frame.rounded }
    }

    /// Sets the rotation (degrees clockwise; 0 is stored as absent).
    public static func setRotation(_ id: UUID, to degrees: Double, on page: Page) -> ItemEdit? {
        guard degrees.isFinite else { return nil }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        let value: Double? = InkJSON.round3(d) == 0 || InkJSON.round3(d) == 360 ? nil : d
        return setRegister(id, .rotation(value), on: page) {
            InkJSON.round3($0.rotation ?? 0) == InkJSON.round3(value ?? 0)
        }
    }

    /// The rotation (degrees clockwise, in 0..<360) of an item that has `current`
    /// (nil is upright) after it is turned by `delta` degrees (negative: anticlockwise).
    /// Non-finite input gives 0.
    public static func rotation(_ current: Double?, turnedBy delta: Double) -> Double {
        let sum = (current ?? 0) + delta
        guard sum.isFinite else { return 0 }
        var d = sum.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d >= 360 ? 0 : d
    }

    /// `degrees` (0..<360) snapped to the nearest multiple of `step` when within
    /// `tolerance` of it, else rounded to a tenth of a degree: what a two-finger
    /// turn ends at, so an item turned "about 90°" ends upright-ish exactly.
    public static func snappedRotation(_ degrees: Double, step: Double = 15, tolerance: Double = 3) -> Double {
        guard degrees.isFinite, step > 0 else { return 0 }
        let nearest = (degrees / step).rounded() * step
        let value = abs(degrees - nearest) <= tolerance ? nearest : (degrees * 10).rounded() / 10
        return rotation(nil, turnedBy: value)
    }

    /// Draws the item `id` above every other item of its layer; nil when it
    /// already is the top one.
    public static func bringToFront(_ id: UUID, on page: Page) -> ItemEdit? {
        guard let item = page.items.first(where: { $0.id == id }) else { return nil }
        let others = page.items.filter { $0.layer == item.layer && $0.id != id }
        if others.allSatisfy({ Item.drawsBefore($0, item) }) { return nil }
        var rest = page
        rest.items = page.items.filter { $0.id != id }
        return setRegister(id, .z(topZ(on: rest, layer: item.layer)), on: page) { _ in false }
    }

    private static func setRegister(_ id: UUID, _ change: ItemChange, on page: Page,
                                    unchanged: (Item) -> Bool) -> ItemEdit? {
        guard let i = page.items.firstIndex(where: { $0.id == id }), !unchanged(page.items[i]) else { return nil }
        var out = page
        out.items[i].apply(change)
        out.items.sort(by: Item.drawsBefore)
        return ItemEdit(ops: [.setItem(page: page.id, itemId: id, change: change)], page: out)
    }

    /// Sets or removes (nil) a video's poster frame (format.md §8.2.7), one
    /// `setItem(poster)`; nil when the page has no such video or it already
    /// has that poster. Store the poster's blob first (`Vault.writeBlob`).
    ///
    /// - Throws: `AttachmentOpsError.invalidPoster` when `poster` is not a
    ///   JPEG or PNG reference.
    public static func setPoster(_ id: UUID, to poster: BlobRef?, on page: Page) throws -> ItemEdit? {
        if let poster { try VideoIngestRules.checkPoster(poster) }
        guard page.items.contains(where: { $0.id == id && $0.kind == .video }) else { return nil }
        return setRegister(id, .poster(poster), on: page) { $0.poster == poster }
    }

    /// Removes the items `ids` from `page`, one `removeItem` each (ids not on
    /// the page are skipped); nil when none is there. The blobs stay: they are
    /// collected later (format.md §8.1.6), so undo and history can use them.
    public static func removeItems(_ ids: [UUID], from page: Page) -> ItemEdit? {
        let gone = Set(ids)
        let present = page.items.filter { gone.contains($0.id) }
        guard !present.isEmpty else { return nil }
        var out = page
        out.items.removeAll { gone.contains($0.id) }
        return ItemEdit(ops: present.map { .removeItem(page: page.id, itemId: $0.id) }, page: out)
    }

    /// Puts removed items back (undo of a delete): item tombstones are
    /// permanent (format.md §8.2.2), so each comes back under a new id with
    /// `parent` naming the removed one, with every other field (`z`
    /// included, so it draws where it was) as it was.
    public static func restoreItems(_ items: [Item], to page: Page, newID: () -> UUID = UUID.init) throws -> ItemEdit {
        try addItems(items.map { NoteOps.moved($0, id: newID(), by: 0, parent: $0.id) }, to: page)
    }

    /// Replaces the item `id` with `replacement` in one delta: `removeItem`
    /// of the old one, then `addItem` of the new one, as given (`z` and
    /// `parent` included: the caller names the item it replaces, §8.2.1).
    /// For a change of an immutable field, such as an image's blob.
    ///
    /// - Throws: `ItemEditError.invalidItem` when the page has no item `id`
    ///   or the replacement would not encode, `.duplicateID` for a
    ///   replacement whose id is on the page.
    public static func replaceItem(_ id: UUID, with replacement: Item, on page: Page) throws -> ItemEdit {
        guard let removed = removeItems([id], from: page) else {
            throw ItemEditError.invalidItem("no item \(id.uuidString.lowercased()) on the page")
        }
        if replacement.id == id { throw ItemEditError.duplicateID(id) }
        let added = try addItems([replacement], to: removed.page)
        return ItemEdit(ops: removed.ops + added.ops, page: added.page, added: added.added)
    }

    /// Copies of `items` (from this note or another) on `page`: new ids, no
    /// `parent` (a copy replaces nothing), frames shifted by `dx`, `dy`, drawn
    /// above everything in their layer in the order given. The caller copies
    /// the blobs first when they come from another note (`blobs`,
    /// `Vault.copyBlob`).
    public static func copyItems(_ items: [Item], to page: Page, dx: Double = 0, dy: Double = 0,
                                 newID: () -> UUID = UUID.init) throws -> ItemEdit {
        var target = page
        var copies: [Item] = []
        for item in items {
            var copy = NoteOps.moved(item, id: newID(), by: dy, parent: nil)
            copy.frame.x += dx
            copy.rec = nil   // the copy was not placed during that recording
            copy.z = topZ(on: target, layer: copy.layer)
            target.items.append(copy)
            copies.append(copy)
        }
        return try addItems(copies, to: page)
    }

    /// The blobs `items` reference (a video's poster too), each once (to copy into another note
    /// before the delta that adds the copies).
    public static func blobs(of items: [Item]) -> [BlobRef] {
        var seen: Set<String> = []
        return items.flatMap(\.blobReferences).filter { seen.insert($0.sha256).inserted }
    }
}

extension Rect {
    /// The rect at the stored precision (format.md §5.6: 3 decimals).
    var rounded: Rect { Rect(x: InkJSON.round3(x), y: InkJSON.round3(y), w: InkJSON.round3(w), h: InkJSON.round3(h)) }
}

// MARK: - Item frames on the page

/// Geometry of placed items on a page (format.md §8.5.1): hit testing,
/// bounds, moving and resizing a rotated frame. Page coordinates, y down;
/// rotation is clockwise about the frame's centre.
public enum ItemFrames {
    /// A point in page coordinates.
    public struct Point: Hashable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// cos and sin of `degrees`, exact for multiples of 90.
    static func trig(_ degrees: Double) -> (cos: Double, sin: Double) {
        let r = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch r {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default: return (cos(r * .pi / 180), sin(r * .pi / 180))
        }
    }

    /// `p` turned by `degrees` (clockwise on the y-down page) about `c`.
    static func rotate(_ p: Point, about c: Point, degrees: Double) -> Point {
        let (cs, sn) = trig(degrees)
        let dx = p.x - c.x, dy = p.y - c.y
        return Point(x: c.x + cs * dx - sn * dy, y: c.y + sn * dx + cs * dy)
    }

    static func centre(_ f: Rect) -> Point { Point(x: f.x + f.w / 2, y: f.y + f.h / 2) }

    /// The frame's corners after rotation: top-left, top-right, bottom-right,
    /// bottom-left of the unrotated frame.
    public static func corners(_ frame: Rect, rotation: Double?) -> [Point] {
        let c = centre(frame), d = rotation ?? 0
        return [Point(x: frame.x, y: frame.y), Point(x: frame.x + frame.w, y: frame.y),
                Point(x: frame.x + frame.w, y: frame.y + frame.h), Point(x: frame.x, y: frame.y + frame.h)]
            .map { rotate($0, about: c, degrees: d) }
    }

    /// The axis-aligned bounds of the rotated frame.
    public static func bounds(_ frame: Rect, rotation: Double?) -> Rect {
        let ps = corners(frame, rotation: rotation)
        let xs = ps.map(\.x), ys = ps.map(\.y)
        let x0 = xs.min() ?? frame.x, y0 = ys.min() ?? frame.y
        return Rect(x: x0, y: y0, w: (xs.max() ?? x0) - x0, h: (ys.max() ?? y0) - y0)
    }

    /// Whether `p` lies in the rotated frame grown by `slop` on each side.
    public static func contains(_ frame: Rect, rotation: Double?, _ p: Point, slop: Double = 0) -> Bool {
        let local = rotate(p, about: centre(frame), degrees: -(rotation ?? 0))
        return local.x >= frame.x - slop && local.x <= frame.x + frame.w + slop
            && local.y >= frame.y - slop && local.y <= frame.y + frame.h + slop
    }

    /// The item drawn topmost at `p`, or nil. Content items win over
    /// background items (PDF pages fill the page; selecting one by every tap
    /// would hide the image or text on it); `includeBackground: false` never
    /// returns a background item.
    public static func item(at p: Point, in items: [Item], slop: Double = 0, includeBackground: Bool = true) -> Item? {
        let hits = items.sorted(by: Item.drawsBefore).reversed().filter {
            isDrawable($0.frame, rotation: $0.rotation) && contains($0.frame, rotation: $0.rotation, p, slop: slop)
        }
        return hits.first { !$0.layer.isBackground } ?? (includeBackground ? hits.first : nil)
    }

    /// The frame moved by `dx`, `dy`.
    public static func moved(_ frame: Rect, dx: Double, dy: Double) -> Rect {
        Rect(x: frame.x + dx, y: frame.y + dy, w: frame.w, h: frame.h)
    }

    /// A corner of the frame, for resizing (indices as in `corners`).
    public enum Corner: Int, CaseIterable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft

        /// The corner across the frame (it stays put while this one is dragged).
        var opposite: Corner { Corner(rawValue: (rawValue + 2) % 4) ?? .topLeft }
        /// Unit signs of this corner relative to the centre, in frame axes.
        var signs: (x: Double, y: Double) {
            switch self {
            case .topLeft: return (-1, -1)
            case .topRight: return (1, -1)
            case .bottomRight: return (1, 1)
            case .bottomLeft: return (-1, 1)
            }
        }
    }

    /// The middle of a side of the frame, for resizing along one axis.
    public enum Edge: Int, CaseIterable, Sendable {
        case top, right, bottom, left

        /// The side across the frame (it stays put while this one is dragged).
        var opposite: Edge { Edge(rawValue: (rawValue + 2) % 4) ?? .top }
        /// Unit signs of this side's middle relative to the centre, in frame axes.
        var signs: (x: Double, y: Double) {
            switch self {
            case .top: return (0, -1)
            case .right: return (1, 0)
            case .bottom: return (0, 1)
            case .left: return (-1, 0)
            }
        }
    }

    /// A resize handle of a selected item: a corner, or the middle of a side.
    public enum Handle: Hashable, Sendable {
        case corner(Corner)
        case edge(Edge)

        /// Unit signs of the handle relative to the centre, in frame axes (0: that axis is not dragged).
        var signs: (x: Double, y: Double) {
            switch self {
            case .corner(let c): return c.signs
            case .edge(let e): return e.signs
            }
        }

        /// The handle across the frame.
        var opposite: Handle {
            switch self {
            case .corner(let c): return .corner(c.opposite)
            case .edge(let e): return .edge(e.opposite)
            }
        }
    }

    /// The resize handles a selected item of `kind` offers, the same for
    /// every way of selecting it. A text box's height follows its lines
    /// (format.md §8.2.4), so it has its left and right sides (its wrapping
    /// width); every other kind (images, PDF pages, video posters, math and
    /// kinds this reader does not know) its four corners.
    public static func handles(for kind: ItemKind) -> [Handle] {
        kind == .text ? [.edge(.left), .edge(.right)] : Corner.allCases.map { .corner($0) }
    }

    /// Whether resizing an item of `kind` keeps its proportions: everything
    /// drawn from a picture (a crop's aspect is the frame's, §8.2.5) or of a
    /// kind this reader cannot lay out; a text box re-wraps instead, and an
    /// audio card lays its label out in whatever frame it gets (§8.2.9), so a
    /// taller card shows more of the transcript.
    public static func keepsAspect(_ kind: ItemKind) -> Bool { kind != .text && kind != .audio }

    /// Where `handle` is on the page, the frame turned by `rotation`.
    public static func point(of handle: Handle, _ frame: Rect, rotation: Double?) -> Point {
        let s = handle.signs
        return rotate(Point(x: frame.x + frame.w * (1 + s.x) / 2, y: frame.y + frame.h * (1 + s.y) / 2),
                      about: centre(frame), degrees: rotation ?? 0)
    }

    /// The frame after dragging `corner` by `dx`, `dy` (page coordinates):
    /// the opposite corner stays where it is on the page, the rotation is
    /// kept, and the size is at least `minSize` on each side. With
    /// `keepAspect` (images, PDF pages) the size keeps the frame's
    /// proportions, following the larger of the two changes.
    public static func resized(_ frame: Rect, rotation: Double?, corner: Corner, dx: Double, dy: Double,
                               keepAspect: Bool, minSize: Double = 8) -> Rect {
        resized(frame, rotation: rotation, handle: .corner(corner), dx: dx, dy: dy, keepAspect: keepAspect, minSize: minSize)
    }

    /// The frame after dragging `handle` by `dx`, `dy` (page coordinates).
    /// A corner works as `resized(_:rotation:corner:…)`. A side changes the
    /// size along its own axis only: the middle of the opposite side stays
    /// where it is on the page and, with `keepAspect`, the other axis scales
    /// by the same factor about that middle. The size is at least `minSize`
    /// on each side; a drag that is not finite leaves the frame as it is.
    public static func resized(_ frame: Rect, rotation: Double?, handle: Handle, dx: Double, dy: Double,
                               keepAspect: Bool, minSize: Double = 8) -> Rect {
        let d = rotation ?? 0
        // The drag in the frame's own axes.
        let local = rotate(Point(x: dx, y: dy), about: Point(x: 0, y: 0), degrees: -d)
        let s = handle.signs
        var w = frame.w + s.x * local.x
        var h = frame.h + s.y * local.y
        if keepAspect, frame.w > 0, frame.h > 0 {
            // The axis that changed more (relative to its size) sets the scale, so
            // a corner dragged inward along one axis only shrinks the item too; a
            // side has one axis.
            let rw = w / frame.w, rh = h / frame.h
            let k = s.y == 0 ? rw : s.x == 0 ? rh : abs(rw - 1) >= abs(rh - 1) ? rw : rh
            w = frame.w * k
            h = frame.h * k
        }
        let floor = max(minSize, 0)
        if keepAspect, frame.w > 0, frame.h > 0, w < floor || h < floor {
            let k = max(floor / frame.w, floor / frame.h)
            w = frame.w * k; h = frame.h * k
        } else {
            w = max(w, floor); h = max(h, floor)
        }
        guard w.isFinite, h.isFinite else { return frame }
        // The fixed point on the page (the opposite corner, or the opposite
        // side's middle), and the new centre from it.
        let fixed = point(of: handle.opposite, frame, rotation: d)
        let o = handle.opposite.signs
        let half = rotate(Point(x: -o.x * w / 2, y: -o.y * h / 2), about: Point(x: 0, y: 0), degrees: d)
        let c = Point(x: fixed.x + half.x, y: fixed.y + half.y)
        return Rect(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h)
    }

    /// `frame` fitted to an item of proportions `size` (`w` × `h`, both
    /// positive): the largest such frame inside `frame`, centred on it.
    /// The frame unchanged when either is empty or not finite.
    public static func fitted(_ size: Size, into frame: Rect) -> Rect {
        guard size.w.isFinite, size.h.isFinite, size.w > 0, size.h > 0, frame.hasPositiveSize,
              [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else { return frame }
        let k = min(frame.w / size.w, frame.h / size.h)
        let w = size.w * k, h = size.h * k
        return Rect(x: frame.x + (frame.w - w) / 2, y: frame.y + (frame.h - h) / 2, w: w, h: h)
    }
}

// MARK: - Text boxes (format.md §8.2.4, task E2)

extension NoteOps {
    /// Runs as writers store them (format.md §8.2.4): `\r\n`, `\r` and the
    /// other line breaking controls (vertical tab, form feed) as `\n`, any
    /// other control character but the tab dropped (the format refuses them,
    /// `TextRun.isValidText`; pasted text can hold them), each run's text in
    /// NFC, empty runs dropped, adjacent runs with equal attributes merged.
    public static func normalizedRuns(_ runs: [TextRun]) -> [TextRun] {
        var out: [TextRun] = []
        for var run in runs {
            run.t = withoutControls(run.t.replacingOccurrences(of: "\r\n", with: "\n"))
                .precomposedStringWithCanonicalMapping
            guard !run.t.isEmpty else { continue }
            if let last = out.last, last.hasSameAttributes(as: run) {
                out[out.count - 1].t += run.t
                out[out.count - 1].t = out[out.count - 1].t.precomposedStringWithCanonicalMapping
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// `text` with `\r`, vertical tab and form feed as `\n` and every other
    /// C0 control but `\n` and `\t` removed.
    static func withoutControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.value {
            case 0x0D, 0x0B, 0x0C: out.append("\n")
            case 0x09, 0x0A: out.append(s)
            case ..<0x20: continue
            default: out.append(s)
            }
        }
        return String(out)
    }

    /// Sets the text of the text box `id` (one `setItem(text)`, the whole
    /// `text` object being one register) and, when `frame` is given and
    /// differs, its frame (a `setItem(frame)` in the same delta: a writer
    /// that lays text out keeps the height its lines need). Nil when nothing
    /// changes or the page has no such text box.
    ///
    /// - Throws: `AttachmentOpsError.invalidText` for control characters or
    ///   content beyond the limits of format.md §8.4, `.invalidFrame` for a
    ///   frame that is not finite and positive.
    public static func setText(_ id: UUID, to content: TextContent, frame: Rect? = nil, on page: Page) throws -> ItemEdit? {
        guard let i = page.items.firstIndex(where: { $0.id == id }), page.items[i].kind == .text else { return nil }
        guard content.runs.allSatisfy({ TextRun.isValidText($0.t) }) else { throw AttachmentOpsError.invalidText("control characters") }
        if let why = content.limitViolation { throw AttachmentOpsError.invalidText(why) }
        if let frame {
            guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite), frame.hasPositiveSize else {
                throw AttachmentOpsError.invalidFrame("frame must be finite with a positive width and height")
            }
        }
        var out = page
        var ops: [Op] = []
        if let frame, out.items[i].frame.rounded != frame.rounded {
            out.items[i].apply(.frame(frame))
            ops.append(.setItem(page: page.id, itemId: id, change: .frame(frame)))
        }
        if out.items[i].text != content {
            out.items[i].apply(.text(content))
            ops.append(.setItem(page: page.id, itemId: id, change: .text(content)))
        }
        guard !ops.isEmpty else { return nil }
        out.items.sort(by: Item.drawsBefore)
        return ItemEdit(ops: ops, page: out)
    }

    /// Moves or resizes item `id` like `setFrame`; for a text box whose
    /// width changes, `relayout` lays its text out again at the new frame and
    /// returns the content (new `breaks`) and the frame (the height its lines
    /// need) to store, written in the same delta (format.md §8.2.4: `breaks`
    /// belong to the wrapping width). Nil when nothing changes.
    public static func setFrame(_ id: UUID, to frame: Rect, on page: Page,
                                relayout: (TextContent, Rect) -> (content: TextContent, frame: Rect)) -> ItemEdit? {
        guard let item = page.items.first(where: { $0.id == id }), item.kind == .text, let text = item.text,
              InkJSON.round3(item.frame.w) != InkJSON.round3(frame.w),
              [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite), frame.hasPositiveSize else {
            return setFrame(id, to: frame, on: page)
        }
        let laid = relayout(text, frame)
        return (try? setText(id, to: laid.content, frame: laid.frame, on: page)) ?? setFrame(id, to: frame, on: page)
    }
}
