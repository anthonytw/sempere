import Foundation
import Sempere

// MARK: - Audio items (format.md §8.2.9)

/// An `audio` item ready to draw: the card and icon (page coordinates, the
/// item's rotation applied) and the label laid out in frame coordinates with
/// the rotation to apply to it.
struct AudioCardDraw {
    var shapes: [DrawCommand]
    var label: ShapedText?
    var rotation: Affine
}

/// The recordings of the note being drawn, and their transcripts read once
/// each (format.md §8.3.2), for `audio` items.
final class AudioSources {
    let recordings: NoteState
    let blobs: (any BlobSource)?
    private var transcripts: [String: Result<Transcript, PlaceholderReason>] = [:]

    init(recordings: [Recording], blobs: (any BlobSource)?) {
        self.recordings = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), pages: [], recordings: recordings)
        self.blobs = blobs
    }

    /// The transcript of `recording`, nil without one, or why it cannot be shown.
    func transcript(of recording: Recording) -> Result<Transcript, PlaceholderReason>? {
        guard let ref = recording.transcript else { return nil }
        let key = "\(ref.sha256)-\(recording.id.uuidString)"
        if let r = transcripts[key] { return r }
        let r: Result<Transcript, PlaceholderReason>
        if let blobs {
            r = Result {
                let t = try Transcript.decode(try blobs.data(for: ref, maxBytes: Transcript.maxSize))
                guard t.recording == recording.id else { throw PlaceholderReason.blobUnavailable("the transcript names another recording") }
                return t
            }.mapError { $0 as? PlaceholderReason ?? .blobUnavailable(ImageStore.describe($0)) }
        } else {
            r = .failure(.noBlobSource)
        }
        transcripts[key] = r
        return r
    }
}

enum AudioCards {
    /// The card of `it` (an `audio` item), or `.recordingMissing`. A
    /// transcript that cannot be read is left out of the label with a
    /// warning; without a shaper the card has no label (warned).
    static func resolve(_ it: PreparedItem, sources: AudioSources?, shaper: (any TextShaper)?,
                        report: inout RenderReport) -> Result<AudioCardDraw, PlaceholderReason> {
        guard let sources, let recording = sources.recordings.recording(shownBy: it.item) else {
            return .failure(.recordingMissing)
        }
        let card = AudioCard(frame: it.item.frame)
        let rotation = ItemGeometry.rotate(frame: it.item.frame, degrees: it.item.rotation ?? 0)
        let shapes = self.shapes(card, rotation: rotation)
        let prefix = "page \(it.pageNumber): item \(it.item.id.uuidString.lowercased().prefix(8)): "
        var transcript: Transcript?
        switch sources.transcript(of: recording) {
        case .success(let t)?: transcript = t
        case .failure(let why)?: report.warn(prefix + "the recording's transcript is not shown (\(why))")
        case nil: break
        }
        guard let frame = card.labelFrame else { return .success(AudioCardDraw(shapes: shapes, label: nil, rotation: rotation)) }
        guard shaper != nil else {
            report.warn(prefix + "the recording's title is not drawn: no fonts to lay text out with")
            return .success(AudioCardDraw(shapes: shapes, label: nil, rotation: rotation))
        }
        let text = Item.text(id: it.item.id, AudioCard.label(recording, transcript: transcript), frame: frame, z: it.item.z)
        guard let labelItem = try? PreparedItem(text, pageNumber: it.pageNumber) else {
            return .success(AudioCardDraw(shapes: shapes, label: nil, rotation: rotation))
        }
        switch TextItems.shape(labelItem, shaper: shaper, report: &report) {
        case .success(let (shaped, _)):
            return .success(AudioCardDraw(shapes: shapes, label: clipped(shaped, bottom: card.labelBottom), rotation: rotation))
        case .failure(let why):
            report.warn(prefix + "the recording's title is not drawn (\(why))")
            return .success(AudioCardDraw(shapes: shapes, label: nil, rotation: rotation))
        }
    }

    /// The lines whose bottom (baseline + 0.25 S, §8.5.3) is at or above
    /// `bottom`, stopping at the first that is not (format.md §8.2.9).
    static func clipped(_ shaped: ShapedText, bottom: Double) -> ShapedText {
        var out = shaped
        out.lines = []
        for line in shaped.lines {
            guard line.baseline + 0.25 * line.size <= bottom + 1e-6 else { break }
            out.lines.append(line)
        }
        let lastBaseline = out.lines.last.map(\.baseline) ?? -Double.infinity
        out.decorations = shaped.decorations.filter { $0.y <= lastBaseline + 0.25 * (out.lines.last?.size ?? 0) }
        out.bottom = out.lines.last.map { $0.baseline + 0.25 * $0.size } ?? 0
        return out
    }

    /// The card and the icon (format.md §8.2.9 steps 1–2), through `rotation`.
    static func shapes(_ card: AudioCard, rotation r: Affine) -> [DrawCommand] {
        let f = card.frame
        let corners = [Point(x: f.x, y: f.y), Point(x: f.x + f.w, y: f.y), Point(x: f.x + f.w, y: f.y + f.h),
                       Point(x: f.x, y: f.y + f.h)].map(r.apply)
        var out = [DrawCommand(.path([Subpath(points: corners, closed: true)]), fill: Paint(AudioCard.fill),
                               stroke: Paint(AudioCard.outline), lineWidth: 1)]
        let d = card.iconSize
        guard d > 0, d.isFinite else { return out }
        let (cx, cy) = card.iconCenter
        let white = Paint(r: 255, g: 255, b: 255)
        out.append(DrawCommand(.circle(center: r.apply(Point(x: cx, y: cy)), radius: d / 2), fill: Paint(AudioCard.iconFill)))
        // The capsule: x ± 0.12 d, y from cy − 0.3 d to cy + 0.08 d, semicircular ends.
        let rad = 0.12 * d, top = cy - 0.3 * d + rad, bottom = cy + 0.08 * d - rad
        var capsule: [Point] = []
        let n = 12
        for i in 0...n {   // top end, left to right over the top
            let a = Double.pi + Double.pi * Double(i) / Double(n)
            capsule.append(Point(x: cx + rad * cos(a), y: top + rad * sin(a)))
        }
        for i in 0...n {   // bottom end, right to left under the bottom
            let a = Double.pi * Double(i) / Double(n)
            capsule.append(Point(x: cx + rad * cos(a), y: bottom + rad * sin(a)))
        }
        out.append(DrawCommand(.path([Subpath(points: capsule.map(r.apply), closed: true)]), fill: white))
        let w = 0.06 * d
        var arc: [Point] = []
        for i in 0...n {   // the lower half of a circle of radius 0.2 d about (cx, cy − 0.04 d)
            let a = Double.pi * Double(i) / Double(n)
            arc.append(Point(x: cx + 0.2 * d * cos(a), y: cy - 0.04 * d + 0.2 * d * sin(a)))
        }
        out.append(DrawCommand(.path([Subpath(points: arc.map(r.apply), closed: false)]), stroke: white, lineWidth: w))
        out.append(DrawCommand(.line(from: r.apply(Point(x: cx, y: cy + 0.16 * d)), to: r.apply(Point(x: cx, y: cy + 0.3 * d))),
                               stroke: white, lineWidth: w))
        out.append(DrawCommand(.line(from: r.apply(Point(x: cx - 0.12 * d, y: cy + 0.3 * d)),
                                     to: r.apply(Point(x: cx + 0.12 * d, y: cy + 0.3 * d))), stroke: white, lineWidth: w))
        return out
    }
}
