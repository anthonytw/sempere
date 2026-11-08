import Foundation
import Sempere

// What the app's item layer decides before it draws an item through `ItemRaster` (the app's `ItemRendering`,
// `ItemLayerView`): how sharp, what a picture depends on, and which blobs it reads. Pure, tested on Linux.

/// How sharp the item layer draws: pixels per page point as a power of two
/// at or above what the screen shows (zoom × screen scale), so zooming in
/// redraws an item only when it crosses a step. Pure, tested.
public enum ItemScale {
    public static let minimum = 1.0
    public static let maximum = 16.0

    public static func bucket(zoom: Double, screenScale: Double) -> Double {
        let want = zoom * screenScale
        guard want.isFinite, want > 0 else { return minimum }
        let step = pow(2, (log2(want)).rounded(.up))
        return min(max(step, minimum), maximum)
    }
}

/// Everything a picture depends on: when it changes, the item is drawn again.
public struct ItemRenderKey: Hashable, Sendable {
    /// The item without its snapshot-only fields.
    public var item: Item
    public var scale: Double
    /// Background items are filled with the paper (format.md §8.2.3).
    public var paper: Paper?
    /// An `audio` item: the recording it shows (title, duration and
    /// transcript are drawn, format.md §8.2.9); nil when it is missing.
    public var recording: Recording?

    public init(_ item: Item, scale: Double, paper: Paper, recording: Recording? = nil) {
        var plain = item
        plain.origin = nil
        plain.clocks = nil
        self.item = plain
        self.scale = scale
        self.paper = item.layer.isBackground ? paper : nil
        if item.kind == .audio, var r = recording {
            r.origin = nil
            r.clocks = nil
            self.recording = r
        }
    }
}

extension ItemRaster {
    /// The blobs drawing `item` reads (fetched before it is drawn): a video's poster only (the clip is read when
    /// it plays, format.md §8.2.7), a Markdown text box's formula renders (§8.5.4), else every blob it names.
    public static func drawnBlobs(of item: Item) -> [BlobRef] {
        if item.kind == .video { return item.poster.map { [$0] } ?? [] }
        if let text = item.text, text.isMarkdown { return MarkdownText.usedFormulas(text).compactMap(\.math.render) }
        return item.blobReferences
    }
}
