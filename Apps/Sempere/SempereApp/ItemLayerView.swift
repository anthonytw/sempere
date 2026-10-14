import Sempere
import UIKit

/// Where the item layer gets a note's attachments from (the model's).
struct ItemLayerSource {
    /// The decrypted blobs of the open vault; nil: every blob-backed item is a placeholder.
    var cache: BlobCache?
    /// Pictures and PDF page previews drawn before, kept across note opens and launches.
    var renders: RenderCache?
    /// Asks iCloud for the image and PDF blobs of the items shown (`AppModel.prefetchBlobs`).
    var prefetch: @MainActor (_ note: UUID, _ items: [Item]) -> Void = { _, _ in }
}

/// A page's placed items, drawn between the paper and the ink (format.md
/// §8.2.3: ink is always on top). One sublayer per item, in drawing order,
/// in canvas content coordinates (page points × zoom). Items are drawn off
/// the main actor (`ItemRendering`) at a power-of-two scale of the zoom
/// (`ItemScale`) and drawn again only when that step, the item or the
/// paper changes; meanwhile, and for what cannot be drawn, a placeholder.
/// PDF pages are not pictures: each is a `PDFTileLayer` that Core Graphics
/// draws in tiles at the zoom's detail, from the PDF blob held open in the
/// cache while a page of it is shown (docs/attachments.md §13), so a long
/// PDF never costs a full-page bitmap per page. Under each page's tiles lies
/// its preview (`RenderCache`: one bitmap at the unzoomed scale, kept across
/// note opens and launches), so a PDF note opened before shows its pages at
/// once, sharpening as the tiles are drawn; image pictures come from the
/// same cache.
/// A recording on the page (format.md §8.2.9) is its card, drawn like the
/// other items from the note's recordings; its play/pause control is a
/// button over the card (`AudioCardControls`).
/// Not interactive: selection is `ItemSelectionController`'s.
final class ItemLayerView: UIView {
    private(set) var noteID: UUID?
    private(set) var items: [Item] = []
    /// The note's recordings, for its audio items' cards.
    private(set) var recordings: [Recording] = []
    private var source = ItemLayerSource()
    private var paper = Paper.blank
    private var zoom: CGFloat = 1
    /// Frames shown instead of the stored ones while a gesture moves or resizes an item.
    private var previews: [UUID: Rect] = [:]
    /// Degrees a two-finger turn has turned an item by so far (`preview(_:turn:)`).
    private var turns: [UUID: Double] = [:]
    private var sublayers: [UUID: ItemSublayer] = [:]
    /// Drawn pictures, by what they depend on (kept across small changes, such as undo of a move).
    private var pictures: [ItemRenderKey: ItemPicture] = [:]
    private var tasks: [ItemRenderKey: Task<Void, Never>] = [:]
    /// PDF pages on screen, by item id.
    private var tiles: [UUID: PDFTileLayer] = [:]
    /// PDF blobs held open for the tiles (by sha256), each acquired once from the cache.
    private var documents: [String: OpenDocument] = [:]
    private var documentTasks: [String: Task<Void, Never>] = [:]
    /// PDF blobs that cannot be drawn, and why (until the note changes).
    private var documentFailures: [String: String] = [:]
    /// PDF page previews shown, by `RenderCache.previewLabel`.
    private var pagePreviews: [String: RenderCache.Picture] = [:]
    private var previewTasks: [String: Task<Void, Never>] = [:]
    /// Previews not in the render cache: drawn once their document is open.
    private var previewMisses: Set<String> = []

    private struct OpenDocument {
        var box: PDFDocumentBox
        var cache: BlobCache
        var note: UUID
        var ref: BlobRef
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "itemLayer"
        // A Mac window moved to a display of another scale: pictures and tiles at the new density.
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: ItemLayerView, _: UITraitCollection) in
            if view.noteID != nil { view.layout() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Items on screen, by id (for tests and the selection overlay).
    var shownItemIDs: [UUID] { items.map(\.id) }

    /// Shows `items` of note `note` (in any order) over `paper`; audio items
    /// show their recording from `recordings`.
    func show(_ items: [Item], note: UUID, paper: Paper, source: ItemLayerSource, recordings: [Recording] = []) {
        // A frame that overflows to NaN would make Core Animation raise (format.md §9).
        let sorted = items.filter { ItemFrames.isDrawable($0.frame, rotation: $0.rotation) }.sorted(by: Item.drawsBefore)
        let changedNote = note != noteID
        let changed = changedNote || sorted != self.items || paper != self.paper || recordings != self.recordings
        self.source = source
        self.recordings = recordings
        guard changed else { return }
        if changedNote {
            for task in tasks.values { task.cancel() }
            tasks = [:]
            pictures = [:]
            previews = [:]
            turns = [:]
            for task in previewTasks.values { task.cancel() }
            previewTasks = [:]
            pagePreviews = [:]
            previewMisses = []
            closeDocuments()
        }
        noteID = note
        let newIDs = Set(sorted.map(\.id))
        if changedNote || Set(self.items.map(\.id)) != newIDs { source.prefetch(note, sorted) }
        self.items = sorted
        self.paper = paper
        for (id, layer) in sublayers where !newIDs.contains(id) {
            layer.removeFromSuperlayer()
            sublayers[id] = nil
        }
        for (id, tile) in tiles where !newIDs.contains(id) {
            tile.removeFromSuperlayer()
            tiles[id] = nil
        }
        previews = previews.filter { newIDs.contains($0.key) }
        layout()
    }


    /// The canvas zoom changed.
    func setZoom(_ zoom: CGFloat) {
        guard zoom > 0, zoom != self.zoom else { return }
        self.zoom = zoom
        layout()
    }

    /// Shows `frame` for item `id` while a gesture changes it (nil: the stored one).
    func preview(_ id: UUID, frame: Rect?) {
        previews[id] = frame
        if !placeOnly(id) { layout() }
    }

    /// Shows item `id` turned by `degrees` more than its rotation while a two-finger
    /// turn runs (nil: as stored). The drawn picture is turned as it is, about the
    /// frame's centre; PDF page tiles are not turned until the turn ends.
    func preview(_ id: UUID, turn degrees: Double?) {
        turns[id] = degrees
        if !placeOnly(id) { layout() }
    }

    /// A gesture frame of one item: places its sublayer as `layout` would, without
    /// laying out every item (the pictures wanted do not depend on previews). False
    /// when `layout` must run: the item is not laid out yet or is a PDF page (tiles).
    private func placeOnly(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.kind != .pdfPage, tiles[id] == nil,
              let sub = sublayers[id], sub.item?.id == id else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sub.transform = CATransform3DIdentity   // `place` sets the frame, which a transform would skew
        sub.place(frame: previews[id] ?? item.frame, rotation: item.rotation, zoom: zoom)
        if let degrees = turns[id] {
            sub.transform = CATransform3DMakeRotation(CGFloat(degrees * .pi / 180), 0, 0, 1)
        }
        return true
    }

    /// The item being edited in place (a text box under its editor): not drawn.
    var hiddenItem: UUID? {
        didSet {
            guard hiddenItem != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (id, sub) in sublayers { sub.isHidden = id == hiddenItem }
            CATransaction.commit()
        }
    }

    /// The frame item `id` is shown with (a preview's while one is set).
    func shownFrame(of id: UUID) -> Rect? {
        previews[id] ?? items.first { $0.id == id }?.frame
    }

    /// `shownFrame(of:)` of every item at once (one pass, not a search per item).
    func shownFrames() -> [UUID: Rect] {
        var out = Dictionary(items.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        for (id, frame) in previews { out[id] = frame }
        return out
    }

    /// The frame and transform of item `id`'s sublayer (tests).
    func sublayerGeometry(of id: UUID) -> (frame: CGRect, transform: CATransform3D)? {
        sublayers[id].map { ($0.frame, $0.transform) }
    }

    private var scaleStep: Double {
        ItemScale.bucket(zoom: Double(zoom), screenScale: Double(traitCollection.displayScale))
    }

    private func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let step = scaleStep
        let shown = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), pages: [], recordings: recordings)
        var wanted: Set<ItemRenderKey> = []
        var wantedDocuments: Set<String> = []
        var wantedPreviews: Set<String> = []
        for (index, item) in items.enumerated() {
            if item.kind == .pdfPage, let ref = item.blob, source.cache != nil {
                wantedDocuments.insert(ref.sha256)
                if let label = previewLabel(item) { wantedPreviews.insert(label) }
                layoutTiled(item, ref: ref, index: index)
                continue
            }
            if let tile = tiles.removeValue(forKey: item.id) { tile.removeFromSuperlayer() }
            let sub: ItemSublayer
            if let existing = sublayers[item.id] {
                sub = existing
            } else {
                sub = ItemSublayer()
                layer.addSublayer(sub)
                sublayers[item.id] = sub
            }
            sub.zPosition = CGFloat(index)
            sub.isHidden = item.id == hiddenItem
            let recording = item.kind == .audio ? shown.recording(shownBy: item) : nil
            let key = ItemRenderKey(item, scale: step, paper: paper, recording: recording)
            wanted.insert(key)
            if pictures[key] == nil, let label = RenderCache.pictureLabel(key),
               let hit = source.renders?.pictureInMemory(label) {
                pictures[key] = .image(hit.image, bounds: hit.bounds)   // drawn before in this session
            }
            if let picture = pictures[key] {
                sub.show(picture, item: item)
            } else if sub.item?.id != item.id || sub.picture == nil {
                sub.show(.placeholder(.loading), item: item)
            }
            // A picture of an older version stays up (stretched to the frame) until the new one is drawn.
            sub.transform = CATransform3DIdentity   // `place` sets the frame, which a transform would skew
            sub.place(frame: previews[item.id] ?? item.frame, rotation: item.rotation, zoom: zoom)
            if let degrees = turns[item.id] {
                sub.transform = CATransform3DMakeRotation(CGFloat(degrees * .pi / 180), 0, 0, 1)
            }
            if pictures[key] == nil, tasks[key] == nil { draw(key) }
        }
        for (key, task) in tasks where !wanted.contains(key) {
            task.cancel()
            tasks[key] = nil
        }
        closeDocuments(except: wantedDocuments)
        for (label, task) in previewTasks where !wantedPreviews.contains(label) {
            task.cancel()
            previewTasks[label] = nil
        }
        pagePreviews = pagePreviews.filter { wantedPreviews.contains($0.key) }
        // Keep the current pictures and a few others (an undo brings one back).
        if pictures.count > wanted.count + 16 {
            for key in pictures.keys where !wanted.contains(key) { pictures[key] = nil }
        }
    }

    private func draw(_ key: ItemRenderKey) {
        guard let note = noteID else { return }
        let cache = source.cache, renders = source.renders
        tasks[key] = Task { @MainActor [weak self] in
            let picture = await ItemRendering.render(key, note: note, cache: cache, renders: renders)
            guard let self, !Task.isCancelled, self.noteID == note else { return }
            self.tasks[key] = nil
            if case .placeholder(.loading) = picture {
                // Not available for now (iCloud, a cleared cache): keep the loading
                // placeholder and draw it again later, never keep this as its picture.
                self.retry(key, note: note)
                return
            }
            self.pictures[key] = picture
            self.layout()
        }
    }

    /// Pause before an item whose blob was not available is drawn again.
    var retryDelay: Duration = .seconds(3)

    private func retry(_ key: ItemRenderKey, note: UUID) {
        let delay = retryDelay
        tasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.noteID == note else { return }
            self.tasks[key] = nil
            self.layout()   // draws it again: it has no picture and no task
        }
    }

    /// Whether every item shown has its final picture (tests).
    var isSettled: Bool { tasks.isEmpty && documentTasks.isEmpty && previewTasks.isEmpty }

    /// PDF page items whose preview is shown (tests).
    var previewedItemIDs: Set<UUID> {
        Set(items.filter { item in previewLabel(item).map { pagePreviews[$0] != nil } ?? false }.map(\.id))
    }

    /// Items drawn in tiles (PDF pages whose document is open), for tests.
    var tiledItemIDs: Set<UUID> { Set(tiles.keys) }

    /// The tile layer of PDF page item `id` (tests).
    func tileLayer(of id: UUID) -> PDFTileLayer? { tiles[id] }

    /// PDF blobs held open now (tests: one per PDF, whatever the pages shown).
    var openDocumentCount: Int { documents.count }

    // MARK: PDF pages in tiles

    /// A PDF page: its tile layer once the document is open, over its preview
    /// (when there is one); the preview or a placeholder until then.
    private func layoutTiled(_ item: Item, ref: BlobRef, index: Int) {
        let frame = previews[item.id] ?? item.frame
        let label = previewLabel(item)
        var preview = label.flatMap { pagePreviews[$0] }
        if preview == nil, let label, let hit = source.renders?.pictureInMemory(label) {
            pagePreviews[label] = hit
            preview = hit
        }
        if let label, preview == nil { requestPreview(item, label: label) }
        if let open = documents[ref.sha256] {
            if let preview {
                showPreview(preview, item: item, frame: frame, index: index)
            } else if let sub = sublayers.removeValue(forKey: item.id) {
                sub.removeFromSuperlayer()
            }
            let tile: PDFTileLayer
            if let existing = tiles[item.id] {
                tile = existing
            } else {
                tile = PDFTileLayer()
                layer.addSublayer(tile)
                tiles[item.id] = tile
            }
            tile.zPosition = CGFloat(index)
            tile.show(item, document: open.box, frame: frame, zoom: zoom, screenScale: traitCollection.displayScale)
            return
        }
        if let tile = tiles.removeValue(forKey: item.id) { tile.removeFromSuperlayer() }
        if documentFailures[ref.sha256] == nil { openDocument(ref) }
        if let preview, documentFailures[ref.sha256] == nil {
            showPreview(preview, item: item, frame: frame, index: index)
            return
        }
        let sub: ItemSublayer
        if let existing = sublayers[item.id] {
            sub = existing
        } else {
            sub = ItemSublayer()
            layer.addSublayer(sub)
            sublayers[item.id] = sub
        }
        sub.zPosition = CGFloat(index)
        let reason: ItemPicture.Reason = documentFailures[ref.sha256].map { .unavailable($0) } ?? .loading
        var shown: ItemPicture.Reason?
        if case .placeholder(let r)? = sub.picture { shown = r }
        if sub.item != item || shown != reason { sub.show(.placeholder(reason), item: item) }
        sub.place(frame: frame, rotation: item.rotation, zoom: zoom)
    }

    /// The preview label of PDF page `item` at this screen's scale.
    private func previewLabel(_ item: Item) -> String? {
        guard source.renders != nil else { return nil }
        return RenderCache.previewLabel(item, scale: RenderCache.previewScale(for: item, screenScale: Double(traitCollection.displayScale)))
    }

    /// Shows `preview` as item `item`'s sublayer, just under its tiles.
    private func showPreview(_ preview: RenderCache.Picture, item: Item, frame: Rect, index: Int) {
        let sub: ItemSublayer
        if let existing = sublayers[item.id] {
            sub = existing
        } else {
            sub = ItemSublayer()
            layer.addSublayer(sub)
            sublayers[item.id] = sub
        }
        sub.zPosition = CGFloat(index) - 0.5
        if sub.item != item || sub.shownImage !== preview.image { sub.show(.image(preview.image, bounds: preview.bounds), item: item) }
        sub.place(frame: frame, rotation: item.rotation, zoom: zoom)
    }

    /// Looks the preview of `item` up in the render cache, off the main
    /// actor; one not there is drawn from the open document (and stored), or,
    /// before the document is open, once it is.
    private func requestPreview(_ item: Item, label: String) {
        guard let renders = source.renders, let note = noteID, pagePreviews[label] == nil, previewTasks[label] == nil else { return }
        let box = item.blob.flatMap { documents[$0.sha256]?.box }
        if previewMisses.contains(label), box == nil { return }   // waits for the document
        let scale = RenderCache.previewScale(for: item, screenScale: Double(traitCollection.displayScale))
        previewTasks[label] = Task { @MainActor [weak self] in
            let interval = Perf.begin(.pdfPreview)
            let (picture, hit) = await Task.detached(priority: .utility) { () -> (RenderCache.Picture?, Bool) in
                if let found = renders.picture(label) { return (found, true) }
                guard let box, !Task.isCancelled, let drawn = RenderCache.drawPreview(item, document: box, scale: scale)
                else { return (nil, false) }
                renders.store(drawn, label: label)
                return (drawn, false)
            }.value
            Perf.end(interval, hit ? "hit" : picture == nil ? "missing" : "drawn")
            guard let self, !Task.isCancelled, self.noteID == note else { return }
            self.previewTasks[label] = nil
            if let picture {
                self.pagePreviews[label] = picture
                self.layout()
            } else {
                self.previewMisses.insert(label)
                if box == nil, self.documents[item.blob?.sha256 ?? ""] != nil { self.layout() }   // opened meanwhile
            }
        }
    }

    /// Acquires the PDF blob from the cache and opens it; a blob not there
    /// yet (iCloud) is tried again after `retryDelay`.
    private func openDocument(_ ref: BlobRef) {
        let key = ref.sha256
        guard let note = noteID, let cache = source.cache, documents[key] == nil, documentTasks[key] == nil else { return }
        let delay = retryDelay
        documentTasks[key] = Task { @MainActor [weak self] in
            do {
                let interval = Perf.begin(.pdfOpen)
                let (fetchedBefore, adoptedBefore) = (await cache.fetchCount, await cache.adoptedCount)
                let url = try await cache.acquire(note: note, ref: ref)
                let box = await Task.detached(priority: .userInitiated) { PDFDocumentBox(url: url) }.value
                let fetched = await cache.fetchCount > fetchedBefore, adopted = await cache.adoptedCount > adoptedBefore
                Perf.end(interval, "\(Perf.short(note)) " + (fetched ? "fetched" : adopted ? "adopted" : "cached"))
                guard let self, !Task.isCancelled, self.noteID == note else {
                    await cache.release(note: note, ref: ref)
                    return
                }
                self.documentTasks[key] = nil
                if let box {
                    self.documents[key] = OpenDocument(box: box, cache: cache, note: note, ref: ref)
                } else {
                    await cache.release(note: note, ref: ref)
                    self.documentFailures[key] = "not a PDF that can be drawn"
                }
                self.layout()
            } catch {
                guard let self, !Task.isCancelled, self.noteID == note else { return }
                if ItemRendering.isTransient(error) {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, self.noteID == note else { return }
                } else {
                    self.documentFailures[key] = "\(error)"
                }
                self.documentTasks[key] = nil
                self.layout()
            }
        }
    }

    /// Releases the open PDF blobs not in `keep` (all by default) and stops opening others.
    private func closeDocuments(except keep: Set<String> = []) {
        for (key, task) in documentTasks where !keep.contains(key) {
            task.cancel()
            documentTasks[key] = nil
        }
        for (key, open) in documents where !keep.contains(key) {
            documents[key] = nil
            Task { await open.cache.release(note: open.note, ref: open.ref) }
        }
        if keep.isEmpty {
            documentFailures = [:]
            for tile in tiles.values { tile.removeFromSuperlayer() }
            tiles = [:]
        }
    }

    /// Off screen, the PDF blobs are let go (the cache may drop their files);
    /// back on screen they are opened again.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            closeDocuments()
        } else if noteID != nil {
            layout()
        }
    }

    /// What item `id` shows now (tests).
    func picture(of id: UUID) -> ItemPicture? { sublayers[id]?.picture }
}

/// One item: its picture (bounds of the rotated frame), or a placeholder
/// frame with diagonals and a symbol (loading, unavailable).
final class ItemSublayer: CALayer {
    private(set) var item: Item?
    private(set) var picture: ItemPicture?

    /// The image shown, if the picture is one.
    var shownImage: CGImage? {
        if case .image(let image, _)? = picture { return image }
        return nil
    }
    private let outline = CAShapeLayer()
    private let symbol = CALayer()
    /// The picture, placed over the page area it covers (a text box's lines
    /// may reach beyond its frame: text is never clipped, format.md §8.2.4).
    private let image = CALayer()
    /// The page area the picture covers, for placing it.
    private var pictureBounds: Rect?

    override init() {
        super.init()
        image.contentsGravity = .resize
        image.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        addSublayer(image)
        outline.fillColor = nil
        outline.strokeColor = UIColor(red: 0x9A / 255, green: 0xA0 / 255, blue: 0xA6 / 255, alpha: 1).cgColor
        outline.lineWidth = 1
        addSublayer(outline)
        symbol.contentsGravity = .resizeAspect
        addSublayer(symbol)
        contentsGravity = .resize
        actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ picture: ItemPicture, item: Item) {
        self.item = item
        self.picture = picture
        switch picture {
        case .image(let picture, let bounds):
            image.contents = picture
            pictureBounds = bounds
            outline.isHidden = true
            symbol.isHidden = true
        case .placeholder(let reason):
            image.contents = nil
            pictureBounds = nil
            outline.isHidden = false
            symbol.isHidden = false
            let name = reason == .loading ? "icloud.and.arrow.down" : "exclamationmark.triangle"
            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            symbol.contents = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.systemGray, renderingMode: .alwaysOriginal).cgImage
        }
    }

    /// Puts the item at `frame` (page points) turned by `rotation`, at `zoom`.
    func place(frame: Rect, rotation: Double?, zoom: CGFloat) {
        let bounds = ItemFrames.bounds(frame, rotation: rotation)
        let z = Double(zoom)
        self.frame = CGRect(x: bounds.x * z, y: bounds.y * z, width: bounds.w * z, height: bounds.h * z)
        // The placeholder: the rotated frame and both diagonals, in this layer's coordinates.
        let corners = ItemFrames.corners(frame, rotation: rotation).map {
            CGPoint(x: ($0.x - bounds.x) * z, y: ($0.y - bounds.y) * z)
        }
        let path = UIBezierPath()
        path.move(to: corners[0])
        for p in corners.dropFirst() { path.addLine(to: p) }
        path.close()
        path.move(to: corners[0]); path.addLine(to: corners[2])
        path.move(to: corners[1]); path.addLine(to: corners[3])
        outline.frame = self.bounds
        outline.path = path.cgPath
        // The picture was drawn for `item`'s frame: it follows a moved or resized frame proportionally.
        if let pb = pictureBounds, let drawn = item {
            let base = ItemFrames.bounds(drawn.frame, rotation: drawn.rotation)
            let sx = base.w > 0 ? bounds.w / base.w : 1, sy = base.h > 0 ? bounds.h / base.h : 1
            image.frame = CGRect(x: (pb.x - base.x) * sx * z, y: (pb.y - base.y) * sy * z, width: pb.w * sx * z, height: pb.h * sy * z)
        } else {
            image.frame = self.bounds
        }
        let side = min(28, self.bounds.width / 2, self.bounds.height / 2)
        symbol.frame = CGRect(x: self.bounds.midX - side / 2, y: self.bounds.midY - side / 2, width: side, height: side)
    }
}
