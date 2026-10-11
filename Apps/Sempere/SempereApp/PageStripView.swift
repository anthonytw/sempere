import Sempere
import PencilKit
import SwiftUI
import UIKit

/// The pages of a paged note as thumbnails, top to bottom: tap to show a
/// page, drag to reorder, swipe or context menu to delete, duplicate or add a
/// page after it. Every gesture is one delta through `NoteEditor`.
struct PageStripView: View {
    let editor: NoteEditor
    /// Called after a thumbnail was tapped (the phone closes its sheet).
    var onPicked: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: editor.pageIndex) { _, index in
                    // The current page follows the canvas's scroll: keep its thumbnail in view.
                    guard editor.pages.indices.contains(index) else { return }
                    withAnimation { proxy.scrollTo(editor.pages[index].id) }
                }
        }
    }

    private var list: some View {
        List {
            ForEach(Array(editor.pages.enumerated()), id: \.element.id) { index, page in
                Button {
                    editor.selectPage(index)
                    onPicked()
                } label: {
                    PageStripRow(editor: editor, page: page, number: index + 1, selected: index == editor.pageIndex)
                }
                .buttonStyle(.plain)
                .listRowBackground(index == editor.pageIndex ? SwiftUI.Color.accentColor.opacity(0.15) : nil)
                .contextMenu {
                    if !editor.isReadOnly {
                        Button("Add Page After", systemImage: "doc.badge.plus") { editor.insertPage(at: index + 1) }
                        Button("Duplicate", systemImage: "plus.square.on.square") { editor.duplicatePage(page.id) }
                        Button("Delete", systemImage: "trash", role: .destructive) { editor.deletePage(page.id) }
                            .disabled(!editor.canDeletePage)
                    }
                }
                .accessibilityIdentifier("pageStrip.\(index + 1)")
            }
            .onMove { from, to in
                guard let first = from.first, from.count == 1 else { return }
                editor.movePage(from: first, to: PageStrip.targetIndex(from: first, toOffset: to))
            }
            .onDelete { offsets in
                for i in offsets.sorted(by: >) where editor.pages.indices.contains(i) {
                    editor.deletePage(editor.pages[i].id)
                }
            }
            .moveDisabled(editor.isReadOnly)
            .deleteDisabled(!editor.canDeletePage)
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            if !editor.isReadOnly {
                VStack(spacing: 6) {
                    if !editor.deletedPages.isEmpty {
                        Button("Undo Delete Page", systemImage: "arrow.uturn.backward") { editor.undoDeletePage() }
                            .help("Bring back the page deleted last")
                    }
                    Button("Add Page at End", systemImage: "doc.badge.plus") { editor.addPage() }
                        .help("Add a page at the end of the note")
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }
}

private struct PageStripRow: View {
    let editor: NoteEditor
    let page: Page
    let number: Int
    let selected: Bool
    @Environment(\.displayScale) private var displayScale
    /// The last thumbnail rendered for this row, shown until the next one lands.
    @State private var rendered: UIImage?
    private let width: CGFloat = 120

    var body: some View {
        let paper = editor.displayedPaper(of: page)
        let height = CGFloat(PageStrip.thumbnailHeight(width: Double(width), pageSize: editor.pageSize))
        let size = CGSize(width: width, height: height)
        let pageSize = editor.pageSize
        let scale = displayScale
        // Keyed on the page's ink revision (and stored stroke count, which changes when a note
        // opened from the cache is read), so no row flattens its strokes to build the key.
        let key = PageThumbnail.key("\(editor.sessionID)-\(page.id)-\(editor.inkRevisions[page.id] ?? 0)-\(page.strokes.count)",
                                    paper: paper, pageSize: pageSize, size: size, scale: scale)
        VStack(spacing: 4) {
            Image(uiImage: PageThumbnail.cached(key) ?? rendered ?? PaperImage.image(for: paper, size: size, scale: scale))
                .resizable()
                .frame(width: width, height: height)
                .overlay(Rectangle().stroke(selected ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary.opacity(0.5),
                                            lineWidth: selected ? 2 : 1))
            Text(verbatim: "\(number)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: key) {
            if let hit = PageThumbnail.cached(key) {
                rendered = hit
                return
            }
            // A page being written on renders once the pen rests, not after every stroke.
            if rendered != nil {
                do { try await Task.sleep(for: PageThumbnail.settle) } catch { return }
            }
            let source = editor.thumbnailSource(of: page)
            let image = await PageThumbnail.render(source, paper: paper, pageSize: pageSize, size: size, scale: scale)
            guard !Task.isCancelled else { return }
            PageThumbnail.store(image, for: key)
            rendered = image
        }
    }
}

/// A page drawn small: paper (`PaperImage`) and ink (PencilKit's own
/// rendering, light appearance, as on the canvas). With a `key` (the page and
/// its ink revision), images are cached, so a stroke redraws only its page.
@MainActor
enum PageThumbnail {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    /// How long a changed page's thumbnail waits before it is drawn again.
    static let settle = Duration.milliseconds(400)

    /// The ink a thumbnail draws: the drawing a canvas shows (as it is), or
    /// stored strokes (converted when drawn).
    enum Source: @unchecked Sendable {
        case drawing(PKDrawing)
        case strokes([Stroke])
    }

    static func key(_ key: String, paper: Paper, pageSize: PageSize, size: CGSize, scale: CGFloat) -> NSString {
        "\(key)|\(paper)|\(pageSize)|\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
    }

    static func cached(_ key: NSString) -> UIImage? { cache.object(forKey: key) }

    static func store(_ image: UIImage, for key: NSString) { cache.setObject(image, forKey: key) }

    static func image(strokes: [Stroke], paper: Paper, pageSize: PageSize, size: CGSize, scale: CGFloat,
                      key: String? = nil) -> UIImage {
        let full = key.map { Self.key($0, paper: paper, pageSize: pageSize, size: size, scale: scale) }
        if let full, let hit = cache.object(forKey: full) { return hit }
        let image = draw(.strokes(strokes), background: PaperImage.image(for: paper, size: size, scale: scale),
                         pageSize: pageSize, size: size, scale: scale)
        if let full { cache.setObject(image, forKey: full) }
        return image
    }

    /// The thumbnail of `source`, its ink converted and drawn off the main actor.
    static func render(_ source: Source, paper: Paper, pageSize: PageSize, size: CGSize, scale: CGFloat) async -> UIImage {
        let background = PaperImage.image(for: paper, size: size, scale: scale)
        let box = SendableImage(background)
        return await Task.detached(priority: .utility) {
            SendableImage(draw(source, background: box.image, pageSize: pageSize, size: size, scale: scale))
        }.value.image
    }

    /// Most pixels a thumbnail's ink is drawn with.
    nonisolated static let maxInkPixels: CGFloat = 4_000_000

    /// The scale the ink of a `page`-sized page is drawn at for a thumbnail
    /// `width` points wide, at most `maxInkPixels` for the page: a stored page
    /// size is not validated (a width of 0.001 asked PencilKit for a bitmap
    /// of about 10^15 pixels).
    nonisolated static func inkScale(page: CGSize, width: CGFloat, scale: CGFloat) -> CGFloat {
        let want = scale * width / page.width
        let area = page.width * page.height
        guard want.isFinite, want > 0, area.isFinite, area > 0 else { return 1 }
        return min(want, (maxInkPixels / area).squareRoot())
    }

    /// Draws the ink of `source` over `background`. Runs on any thread.
    nonisolated private static func draw(_ source: Source, background: UIImage, pageSize: PageSize, size: CGSize,
                                         scale: CGFloat) -> UIImage {
        let page = CGRect(x: 0, y: 0, width: CGFloat(pageSize.width.isFinite && pageSize.width > 0 ? pageSize.width : 612),
                          height: CGFloat(pageSize.sheetHeight))
        let drawing: PKDrawing? = switch source {
        case .drawing(let d): d.strokes.isEmpty ? nil : d
        case .strokes(let strokes): strokes.isEmpty ? nil : PKDrawing(strokes: strokes.map(StrokeConversion.pkStroke))
        }
        var ink: UIImage?
        if let drawing {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: page, scale: inkScale(page: page.size, width: size.width, scale: scale))
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            background.draw(in: CGRect(origin: .zero, size: size))
            ink?.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// An image handed between actors (immutable once made).
private struct SendableImage: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}
