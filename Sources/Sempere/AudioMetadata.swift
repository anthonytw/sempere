import Foundation

/// Removing the dates and tags of an MP4 / M4A recording's container, for a share made without dates
/// (docs/web-viewer.md "Share files"): the creation and modification times of `mvhd`, of every track's `tkhd` and of
/// every `mdhd` become zero, and the tag boxes (`udta`, `meta` and XMP `uuid` at the top level, in `moov` or in a
/// `trak`) become `free` boxes of the same length with zeroed bodies. Nothing moves, so sample offsets stay valid and
/// the audio plays as before.
///
/// Every byte is untrusted (format.md §9): each box must fit its parent, nesting and the number of boxes are bounded,
/// and nothing is read past the data. A file it cannot read whole is refused (nil), never half done.
public enum AudioMetadata {
    /// The media types this removes metadata from (writers store `audio/mp4`).
    public static let mp4Types: Set<String> = ["audio/mp4", "audio/x-m4a", "audio/m4a"]
    /// Most boxes visited in one file.
    static let maxBoxes = 100_000

    /// `data` with its container's times zeroed and its tag boxes blanked, or nil when it is not an MP4 file whose
    /// boxes all read (no `ftyp` first, no single `moov`, a box that overruns its parent, an unknown header version).
    public static func scrubbed(_ data: Data) -> Data? {
        guard let edits = scrubbingEdits(data) else { return nil }
        var out = data
        ByteEdit.apply(edits, to: &out, at: 0)
        return out
    }

    /// The edits `scrubbed` makes, as file offsets into `data`; nil when `scrubbed` is.
    public static func scrubbingEdits(_ data: Data) -> [ByteEdit]? {
        var walker = Walker(data: data)
        let size = UInt64(data.count)
        guard let top = walker.children(of: 0..<size, top: true), let first = top.first, first.type == "ftyp" else { return nil }
        let moovs = top.filter { $0.type == "moov" }
        guard moovs.count == 1, let moov = moovs.first else { return nil }
        var edits: [ByteEdit] = []
        for box in top where walker.isTag(box) { edits += blank(box) }
        guard let movie = walker.children(of: moov.body, top: false) else { return nil }
        for box in movie {
            switch box.type {
            case "mvhd":
                guard let e = walker.times(box) else { return nil }
                edits.append(e)
            case "trak":
                guard let track = walker.children(of: box.body, top: false) else { return nil }
                for part in track {
                    switch part.type {
                    case "tkhd":
                        guard let e = walker.times(part) else { return nil }
                        edits.append(e)
                    case "mdia":
                        guard let media = walker.children(of: part.body, top: false) else { return nil }
                        for m in media where m.type == "mdhd" {
                            guard let e = walker.times(m) else { return nil }
                            edits.append(e)
                        }
                    default:
                        if walker.isTag(part) { edits += blank(part) }
                    }
                }
            default:
                if walker.isTag(box) { edits += blank(box) }
            }
        }
        return edits
    }

    /// The edits that make `box` a `free` box with a zeroed body.
    static func blank(_ box: VideoBox) -> [ByteEdit] {
        var out = [ByteEdit(range: box.offset + 4..<box.offset + 8, bytes: Data("free".utf8))]
        if box.length > box.header { out.append(ByteEdit(range: box.body)) }
        return out
    }

    private struct Walker {
        let data: Data
        var visited = 0

        /// `count` bytes at `offset`, or nil when they are not all there.
        func bytes(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            let size = UInt64(data.count)
            guard offset <= size, UInt64(count) <= size - offset else { return nil }
            let start = data.startIndex + Int(offset)
            return [UInt8](data[start..<start + count])
        }

        /// The boxes directly inside `range`; nil when one does not fit it. At the top level a last `mdat` that runs
        /// past the end (a recording cut short in its samples) ends the list.
        mutating func children(of range: Range<UInt64>, top: Bool) -> [VideoBox]? {
            var out: [VideoBox] = []
            var pos = range.lowerBound
            while range.upperBound - pos >= 8 {
                visited += 1
                guard visited <= AudioMetadata.maxBoxes, let head = bytes(pos, 8) else { return nil }
                var length = UInt64(VideoProbe.be32(head, 0))
                let type = VideoProbe.fourcc(head, 4)
                var header: UInt64 = 8
                if length == 1 {
                    guard range.upperBound - pos >= 16, let wide = bytes(pos + 8, 8) else { return nil }
                    length = VideoProbe.be64(wide, 0)
                    header = 16
                } else if length == 0 {
                    length = range.upperBound - pos
                }
                guard length >= header else { return nil }
                guard length <= range.upperBound - pos else {
                    if top, type == "mdat" { break }
                    return nil
                }
                out.append(VideoBox(type: type, offset: pos, length: length, header: header))
                pos += length
            }
            return out
        }

        /// Whether `box` holds tags: `udta`, `meta`, or an XMP `uuid`.
        func isTag(_ box: VideoBox) -> Bool {
            switch box.type {
            case "udta", "meta": return true
            case "uuid":
                guard box.length - box.header >= 16, let user = bytes(box.offset + box.header, 16) else { return false }
                return user == VideoProbe.xmpUUID
            default: return false
            }
        }

        /// The edit that zeroes a full box's creation and modification times (`mvhd`, `tkhd`, `mdhd`: version 0 has
        /// 4-byte times, version 1 8-byte ones, right after the version and flags); nil for a short box or another
        /// version.
        func times(_ box: VideoBox) -> ByteEdit? {
            let body = box.body
            guard body.upperBound - body.lowerBound >= 4, let version = bytes(body.lowerBound, 1)?.first else { return nil }
            let width: UInt64
            switch version {
            case 0: width = 8
            case 1: width = 16
            default: return nil
            }
            guard body.upperBound - body.lowerBound >= 4 + width else { return nil }
            return ByteEdit(range: body.lowerBound + 4..<body.lowerBound + 4 + width)
        }
    }
}
