import Foundation

// MARK: - Recordings on the page (docs/format.md §8.2.9)
//
// An `audio` item shows one of the note's recordings on a page: the app places
// one when a recording stops, the CLI with `items place-recording` or
// `attach recording --place`. The item holds only the recording's id; title,
// duration and transcript are the recording's. The card every renderer draws
// (`AudioCard`) is defined here once, so the exporters, the app and the web
// viewer lay it out the same way.

extension NoteState {
    /// The recording an `audio` item shows (format.md §8.2.9): the one with
    /// its id, else one restored from it (its `parent` names it, §5.7), else
    /// nil (the recording is missing).
    public func recording(shownBy item: Item) -> Recording? {
        guard item.kind == .audio, let id = item.recording else { return nil }
        return recording(for: RecordingLink(id: id, at: 0))
    }

    /// Every live `audio` item that shows `recording` (directly or through a
    /// restored copy's `parent`), with its page, in page and drawing order.
    public func audioItems(showing recording: UUID) -> [(page: UUID, item: Item)] {
        var out: [(UUID, Item)] = []
        for page in pages {
            for item in page.items.sorted(by: Item.drawsBefore) where item.kind == .audio {
                if item.recording == recording || self.recording(shownBy: item)?.id == recording {
                    out.append((page.id, item))
                }
            }
        }
        return out
    }
}

extension NoteOps {
    /// The size of a newly placed `audio` item, in points: room for the
    /// title line and two or three lines of transcript.
    public static let audioItemSize = Size(w: 300, h: 96)

    /// Places recording `recording` (already in the note) on `page` as an
    /// `audio` item (format.md §8.2.9). Without `frame` the card is
    /// `audioItemSize` (narrower on a narrow page): inside `visible` (the part
    /// of the page the user sees, page coordinates) centred across it and a
    /// margin below its top, else centred across the page a margin from its
    /// top; `at` sets the top-left corner and `width` the width instead.
    ///
    /// - Throws: `AttachmentOpsError.noSuchRecording` when `recordings` has
    ///   no such recording, `.pageFull`, `.invalidFrame`.
    public static func placeRecording(_ recording: UUID, recordings: [Recording], on page: Page, pageSize: PageSize,
                                      frame: Rect? = nil, visible: Rect? = nil, at origin: (x: Double, y: Double)? = nil,
                                      width: Double? = nil, rec: RecordingLink? = nil, id: UUID = UUID(),
                                      extraZ: [String] = []) throws -> ItemPlacement {
        guard recordings.contains(where: { $0.id == recording }) else {
            throw AttachmentOpsError.noSuchRecording(recording.uuidString.lowercased())
        }
        guard page.items.count < Limits.itemsPerPage else { throw AttachmentOpsError.pageFull }
        let rect: Rect
        if let frame {
            rect = frame
        } else {
            if let width { guard width.isFinite, width > 0 else { throw AttachmentOpsError.invalidFrame("width must be positive") } }
            let area = visible.flatMap { $0.hasPositiveSize && [$0.x, $0.y, $0.w, $0.h].allSatisfy(\.isFinite) ? $0 : nil }
                ?? Rect(x: 0, y: 0, w: pageSize.width, h: pageSize.sheetHeight)
            let w = width ?? max(1, min(audioItemSize.w, area.w - 2 * Limits.margin, pageSize.width - 2 * Limits.margin))
            let h = audioItemSize.h
            let x = origin?.x ?? area.x + (area.w - w) / 2
            let y = origin?.y ?? area.y + min(Limits.margin, max(0, area.h - h))
            rect = Rect(x: InkJSON.round3(x), y: InkJSON.round3(y), w: InkJSON.round3(w), h: InkJSON.round3(h))
        }
        try validate(frame: rect)
        let item = Item.audio(id: id, recording: recording, frame: rect, z: topZ(of: page, layer: .content, extra: extraZ),
                              rec: rec)
        return ItemPlacement(page: page.id, item: item)
    }

    /// The ops that remove recording `id` and, in the same delta, every
    /// `audio` item of `state` that shows it (format.md §8.2.9). Empty when the
    /// note has no such recording.
    public static func removeRecording(_ id: UUID, in state: NoteState) -> [Op] {
        guard state.recordings.contains(where: { $0.id == id }) else { return [] }
        let items: [Op] = state.audioItems(showing: id).map { .removeItem(page: $0.page, itemId: $0.item.id) }
        return items + [.removeRecording(recordingId: id)]
    }

    /// `items` without `audio` items: what may be copied into another note,
    /// where the recordings they show do not exist.
    public static func copyableToOtherNote(_ items: [Item]) -> [Item] {
        items.filter { $0.kind != .audio }
    }
}

/// The card an `audio` item is drawn as (format.md §8.2.9), in frame
/// coordinates before the item's rotation: padding, icon and label box, and
/// the label's text. Shared by every renderer.
public struct AudioCard: Hashable, Sendable {
    /// The card's fill, `#F1F3F4FF`.
    public static let fill = Color(r: 0xF1, g: 0xF3, b: 0xF4, a: 0xFF)
    /// The card's 1 pt outline, `#DADCE0FF`.
    public static let outline = Color(r: 0xDA, g: 0xDC, b: 0xE0, a: 0xFF)
    /// The icon's disc, `#1A73E8FF`.
    public static let iconFill = Color(r: 0x1A, g: 0x73, b: 0xE8, a: 0xFF)
    /// The title line's colour, `#202124FF`.
    public static let titleColor = Color(r: 0x20, g: 0x21, b: 0x24, a: 0xFF)
    /// The transcript's colour, `#5F6368FF`.
    public static let transcriptColor = Color(r: 0x5F, g: 0x63, b: 0x68, a: 0xFF)
    /// Title and duration size, points.
    public static let titleSize = 12.0
    /// Transcript size, points.
    public static let transcriptSize = 10.0
    /// Most Unicode scalars of transcript the label holds.
    public static let transcriptLimit = 2_000
    /// Most Unicode scalars of the title the label holds.
    public static let titleLimit = 200
    /// The title shown for a recording without one.
    public static let untitled = "Recording"

    /// The item's frame.
    public var frame: Rect
    /// `p = min(8, 0.1 · min(w, h))`.
    public var padding: Double
    /// `d = min(24, min(w, h) − 2p)`; the icon is drawn only when positive.
    public var iconSize: Double

    public init(frame: Rect) {
        self.frame = frame
        let m = min(frame.w, frame.h)
        padding = min(8, 0.1 * m)
        iconSize = min(24, m - 2 * padding)
    }

    /// The icon disc's centre, page coordinates before rotation.
    public var iconCenter: (x: Double, y: Double) {
        (frame.x + padding + iconSize / 2, frame.y + padding + iconSize / 2)
    }

    /// The label's text box, or nil when it has no room.
    public var labelFrame: Rect? {
        let d = max(iconSize, 0)
        let r = Rect(x: frame.x + 2 * padding + d, y: frame.y + padding, w: frame.w - 3 * padding - d, h: frame.h - 2 * padding)
        return r.w > 0 && r.h > 0 ? r : nil
    }

    /// The bottom a label line may reach: lines below it are not drawn.
    public var labelBottom: Double { frame.y + frame.h - padding }

    /// Where an app draws the card's play/pause control: a disc of diameter
    /// `0.6 d` centred at `(cx + 0.4 d, cy + 0.4 d)`, over the icon's lower
    /// right, turned with the item's `rotation` (degrees) about the frame's
    /// centre. Not part of the format: exports draw only the icon.
    public func badge(rotation: Double?) -> (center: (x: Double, y: Double), diameter: Double) {
        let d = max(iconSize, 0)
        let (cx, cy) = iconCenter
        return (turned(x: cx + 0.4 * d, y: cy + 0.4 * d, degrees: rotation ?? 0), 0.6 * d)
    }

    /// Whether the page point (`x`, `y`) is on the card's play control: the
    /// icon or its badge, widened by `slack` points (a finger's or pointer's
    /// tolerance), for an item turned by `rotation` degrees.
    public func controlContains(x: Double, y: Double, rotation: Double?, slack: Double = 0) -> Bool {
        guard iconSize > 0, x.isFinite, y.isFinite else { return false }
        let p = turned(x: x, y: y, degrees: -(rotation ?? 0))   // into the frame's own axes
        let (cx, cy) = iconCenter
        let d = iconSize
        func within(_ ox: Double, _ oy: Double, _ r: Double) -> Bool {
            let dx = p.x - ox, dy = p.y - oy
            return dx * dx + dy * dy <= (r + slack) * (r + slack)
        }
        return within(cx, cy, d / 2) || within(cx + 0.4 * d, cy + 0.4 * d, 0.3 * d)
    }

    /// (`x`, `y`) turned by `degrees` clockwise (y down) about the frame's centre.
    private func turned(x: Double, y: Double, degrees: Double) -> (x: Double, y: Double) {
        guard degrees != 0, degrees.isFinite else { return (x, y) }
        // Reduced to one turn first: `1e308 * .pi` is infinite and its cos and sin NaN.
        let r = ItemFrames.radians(degrees), c = cos(r), s = sin(r)
        let mx = frame.x + frame.w / 2, my = frame.y + frame.h / 2
        let dx = x - mx, dy = y - my
        return (mx + dx * c - dy * s, my + dx * s + dy * c)
    }

    /// The recording's title as the card shows it.
    public static func title(_ recording: Recording) -> String {
        let t = recording.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A title is any string a writer stored: the card shows its start.
        return t.isEmpty ? untitled : String(String.UnicodeScalarView(t.unicodeScalars.prefix(titleLimit)))
    }

    /// `m:ss` (or `h:mm:ss`), nil without a finite duration.
    public static func duration(_ recording: Recording) -> String? {
        guard let d = recording.duration, d.isFinite else { return nil }
        return Transcript.clock(d)
    }

    /// The transcript's segments joined by single spaces, cut to
    /// `transcriptLimit` scalars; nil when empty.
    public static func excerpt(_ transcript: Transcript) -> String? {
        var out = String.UnicodeScalarView()
        var count = 0
        for segment in transcript.segments {
            let text = segment.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !text.isEmpty else { continue }
            for s in ((out.isEmpty ? "" : " ") + text).unicodeScalars {
                guard count < transcriptLimit else { return String(out) }
                out.append(s)
                count += 1
            }
        }
        return out.isEmpty ? nil : String(out)
    }

    /// The label's text box content (format.md §8.2.9): the title in bold,
    /// ` · ` and the duration, then the transcript's excerpt on the next line.
    public static func label(_ recording: Recording, transcript: Transcript?) -> TextContent {
        var runs = [TextRun(oneLine(title(recording)), b: true)]
        if let d = duration(recording) { runs.append(TextRun(" · " + d)) }
        if let transcript, let text = excerpt(transcript) {
            runs.append(TextRun("\n" + oneLine(text), color: transcriptColor, size: transcriptSize,
                                lang: transcript.language.isEmpty ? nil : transcript.language))
        }
        return TextContent(font: .sans, size: titleSize, color: titleColor, align: .start, dir: .auto, runs: runs)
    }

    /// `s` on one line: line breaks, tabs and other controls as spaces
    /// (a text run holds no C0 control but `\n` and `\t`, §8.2.4).
    static func oneLine(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0
        }))
    }
}
