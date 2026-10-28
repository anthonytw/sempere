import Foundation
import Sempere

/// A dense note for performance work, shared by `sempere notes dense` and the app's performance
/// tests: many pages (or one long page), tens of thousands of seeded strokes (`SyntheticInk`) and
/// pictures (`SyntheticImage`), written the way a writer that saves a page at a time would: one delta
/// that makes the note and its pages, then one per page with its strokes and pictures.
public struct DenseNote: Sendable {
    public var title: String
    public var pages = 40
    public var strokes = 20_000
    public var points = 16
    public var images = 12
    public var imageSize = 480
    public var seed: UInt64 = 1
    public var notebook: String?
    /// One long (infinite) page instead of `pages` pages.
    public var pageless = false

    public init(title: String) { self.title = title }

    public struct Written: Sendable {
        public var note: UUID
        public var pages: [UUID]
        public var files: [String]
    }

    static let width = 612.0, rowHeight = 24.0, pictureHeight = 120.0

    /// Writes the note into `vault` (pictures first, as blobs) and returns what it wrote.
    public func write(to vault: Vault, deviceState: URL, app: String, id: UUID = UUID()) throws -> Written {
        let pageCount = pageless ? 1 : max(pages, 1)
        let perPage = strokes / pageCount, extra = strokes % pageCount
        let imagesPerPage = images / pageCount, imageExtra = images % pageCount
        // A pageless note is as tall as its ink (about 24 glyphs to a row) and its pictures need.
        let rows = Int(ceil(Double(perPage + (extra > 0 ? 1 : 0)) / 24))
        let inkHeight = 48 + Double(rows + 1) * Self.rowHeight
        let size: PageSize
        if pageless {
            size = PageSize(width: Self.width,
                            height: max(792, inkHeight + 40 + Double(images) * (Self.pictureHeight + 12)),
                            infinite: true, breakHeight: 792)
        } else {
            size = .letter
        }
        var ops = NoteOps.newNote(title: title.trimmingCharacters(in: .whitespacesAndNewlines), pageSize: size,
                                  notebook: NotebookPath.canonical(notebook))
        guard case .addPage(let firstPage) = ops[0] else { preconditionFailure("newNote adds the first page first") }
        var pageList = [firstPage]
        for _ in 1..<pageCount {
            let page = Page(order: PageOrder.between(pageList.last?.order, nil))
            pageList.append(page)
            ops.append(.addPage(page))
        }
        var deltas: [[Op]] = [ops]
        var pictureNumber = 0
        for (n, page) in pageList.enumerated() {
            var ink = SyntheticInk(seed: seed &+ UInt64(n), options: .init(pointsPerStroke: points, pageWidth: Self.width,
                                                                          rowHeight: Self.rowHeight, top: 48))
            var delta = ink.strokes(perPage + (n < extra ? 1 : 0)).map { Op.addStroke(page: page.id, stroke: $0) }
            for k in 0..<(imagesPerPage + (n < imageExtra ? 1 : 0)) {
                let data = try SyntheticImage.png(width: imageSize, height: imageSize, seed: seed &+ UInt64(pictureNumber))
                let ref = try vault.writeBlob(note: id, data, type: "image/png")
                let y = pageless ? inkHeight + 40 + Double(k) * (Self.pictureHeight + 12) : 560
                let frame = Rect(x: 36 + Double(k % 4) * 140, y: y, w: 120, h: Self.pictureHeight)
                delta += try NoteOps.placeImage(blob: ref, pixelSize: Size(w: Double(imageSize), h: Double(imageSize)),
                                                on: page, pageSize: size, frame: frame).ops
                pictureNumber += 1
            }
            if !delta.isEmpty { deltas.append(delta) }
        }
        let revisions = try vault.applyInOrder(deltas, to: id, deviceState: deviceState, app: app)
        return Written(note: id, pages: pageList.map(\.id), files: revisions.map(\.name.filename))
    }
}
