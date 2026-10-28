import Foundation

/// What a video clip's container says about itself (format.md §8.2.7): the
/// fields of a `video` item, and where its location and device metadata lie.
public struct VideoInfo: Hashable, Sendable {
    /// `video/mp4` or `video/quicktime`, from the `ftyp` major brand.
    public var mediaType: String
    /// Seconds: the `mvhd` duration, else the video track's `mdhd`.
    public var duration: Double
    /// The display size in pixels: the video track's `tkhd` size (the sample
    /// entry's when that is zero), swapped for a rotation of 90 or 270.
    public var pixelSize: Size
    /// 0, 90, 180 or 270: the clockwise rotation of the track matrix.
    public var rotation: Int
    /// `h264` or `hevc`.
    public var codec: String
    /// The first sound track's sample entry (`aac` for `mp4a`), nil without one.
    public var audioCodec: String?
    /// True when `moov` comes before the first `mdat` ("fast start").
    public var fastStart: Bool
    /// The location and device metadata (`VideoMetadata`), in file order:
    /// the `udta` and `meta` boxes directly inside `moov` or a `trak`, a
    /// top-level `meta`, and XMP `uuid` boxes (`VideoProbe.xmpUUID`, which may
    /// hold `exif:GPS…`) at the top level or directly inside `moov` or a `trak`.
    public var metadataBoxes: [VideoBox]

    public init(mediaType: String, duration: Double, pixelSize: Size, rotation: Int, codec: String,
                audioCodec: String? = nil, fastStart: Bool = true, metadataBoxes: [VideoBox] = []) {
        self.mediaType = mediaType; self.duration = duration; self.pixelSize = pixelSize; self.rotation = rotation
        self.codec = codec; self.audioCodec = audioCodec; self.fastStart = fastStart; self.metadataBoxes = metadataBoxes
    }
}

/// A box of the file: where it starts, its length and its header's length.
public struct VideoBox: Hashable, Sendable {
    /// The box's four-character type.
    public var type: String
    /// Offset of its first byte (the size field).
    public var offset: UInt64
    /// Total length, header included.
    public var length: UInt64
    /// Header length: 8, or 16 with a 64-bit size.
    public var header: UInt64

    /// The body: everything after the header.
    public var body: Range<UInt64> { offset + header..<offset + length }
}

/// Why a file is not a video clip `video` items take (format.md §8.2.7).
public enum VideoProbeError: Error, Hashable, Sendable {
    /// Not an MP4 or QuickTime file (no `ftyp` or QuickTime box first).
    case notVideo
    /// No `moov` box (a recording that never finished, or `moov` past the size limit).
    case noMovie
    /// A movie without a video track.
    case noVideoTrack
    /// The video track's codec is not H.264 or HEVC (the fourcc names it).
    case unsupportedCodec(String)
    /// A fragmented MP4 (`mvex`): its samples are not in the `moov` sample table.
    case fragmented
    /// A box lies about its size or nests too deeply (the string says where).
    case malformed(String)
}

extension VideoProbeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notVideo: return "not an MP4 or QuickTime video file (.mp4, .m4v, .mov)"
        case .noMovie: return "the video has no movie header (moov); was the recording finished?"
        case .noVideoTrack: return "the file has no video track"
        case .unsupportedCodec(let fourcc):
            return "the video is coded as \(fourcc.isEmpty ? "an unknown codec" : "'\(fourcc)'"), not H.264 or HEVC: convert it first "
                + "(ffmpeg -i IN -c:v libx264 -c:a aac OUT.mp4)"
        case .fragmented: return "fragmented MP4 is not supported: remux it first (ffmpeg -i IN -c copy OUT.mp4)"
        case .malformed(let why): return "damaged video file (\(why))"
        }
    }
}

/// A reader for the box structure of an MP4 / QuickTime file: the movie and
/// track headers, the first video and sound sample entries, and where the
/// metadata boxes are. It reads box headers and a few small boxes (at most
/// `maxLeafBytes` each), never the samples or the sample tables, so a 1 GiB
/// clip costs a few hundred reads of at most 4 KiB.
///
/// Every byte is untrusted (format.md §9): sizes are checked against their
/// parent before use, nesting depth and the number of boxes visited are
/// bounded, and integer arithmetic never overflows (sizes near 2^64 included).
public enum VideoProbe {
    /// Most boxes visited in the whole file.
    static let maxBoxes = 20_000
    /// Deepest nesting followed (moov/trak/mdia/minf/stbl/stsd is 6).
    static let maxDepth = 8
    /// Most bytes read of one leaf box (`mvhd`, `tkhd`, `mdhd`, `hdlr`, `stsd`).
    static let maxLeafBytes = 4096
    /// Brands QuickTime files carry as their major brand.
    static let quickTimeBrand = "qt  "
    /// Boxes an old QuickTime file may start with (no `ftyp`).
    static let quickTimeFirst: Set<String> = ["moov", "wide", "free", "skip", "mdat"]
    /// Containers walked on the way to the sample entries.
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    /// The usertype of an XMP `uuid` box (Adobe XMP, ISO 16684-1): BE7ACFCB-97A9-42E8-9C71-999491E3AFAC.
    static let xmpUUID: [UInt8] = [0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
                                   0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC]

    /// The video file at `url`.
    public static func probe(file url: URL) throws -> VideoInfo {
        try reading(file: url, probe(size:read:))
    }

    /// The video file held in `data`.
    public static func probe(_ data: Data) throws -> VideoInfo {
        try reading(data, probe(size:read:))
    }

    /// `probe(size, read)` over the regular file at `url` (`AudioProbe` reads files the same way).
    static func reading<T>(file url: URL, _ probe: (UInt64, (UInt64, Int) throws -> Data) throws -> T) throws -> T {
        let handle = try BoundedRead.openRegularFile(url)
        defer { try? handle.close() }
        let size: UInt64
        do { size = try handle.seekToEnd() } catch { throw VaultError.io("read \(url.path): \(error)") }
        return try probe(size) { offset, count in
            do {
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: count) ?? Data()
            } catch {
                throw VaultError.io("read \(url.path): \(error)")
            }
        }
    }

    /// `probe(size, read)` over `data`.
    static func reading<T>(_ data: Data, _ probe: (UInt64, (UInt64, Int) throws -> Data) throws -> T) throws -> T {
        try probe(UInt64(data.count)) { offset, count in
            guard offset < UInt64(data.count) else { return Data() }
            let start = data.startIndex + Int(offset)
            return data[start..<start + min(count, data.endIndex - start)]
        }
    }

    /// The file through `read(offset, count)`, which returns at most `count`
    /// bytes (fewer at the end of the file).
    public static func probe(size: UInt64, read: (UInt64, Int) throws -> Data) throws -> VideoInfo {
        try withoutActuallyEscaping(read) { read in
            var walker = Walker(size: size, read: read)
            return try probe(&walker)
        }
    }

    private static func probe(_ walker: inout Walker) throws -> VideoInfo {
        let top = try walker.children(of: 0..<walker.size, depth: 0)
        guard let first = top.first else { throw VideoProbeError.notVideo }
        var mediaType = "video/quicktime"
        if first.type == "ftyp" {
            let brand = try walker.bytes(first, max: 8)
            if brand.count >= 4, String(decoding: brand.prefix(4), as: UTF8.self) != quickTimeBrand { mediaType = "video/mp4" }
        } else if !quickTimeFirst.contains(first.type) {
            throw VideoProbeError.notVideo
        }
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw VideoProbeError.noMovie }
        // A second moov is not walked, so whatever metadata it carries would
        // stay: refused (format.md §8.2.7 "holds one moov").
        guard top.filter({ $0.type == "moov" }).count == 1 else { throw VideoProbeError.malformed("more than one moov") }
        let firstMdat = top.first { $0.type == "mdat" }
        var info = try walker.movie(moov)
        info.mediaType = mediaType
        info.fastStart = firstMdat.map { moov.offset < $0.offset } ?? true
        var topMetadata: [VideoBox] = []
        for box in top {
            if box.type == "meta" || box.type == "udta" {   // udta at the top level carries ©xyz like moov's
                topMetadata.append(box)
            } else if try walker.isXMP(box) {
                topMetadata.append(box)
            }
        }
        if !topMetadata.isEmpty { info.metadataBoxes = (info.metadataBoxes + topMetadata).sorted { $0.offset < $1.offset } }
        return info
    }

    // MARK: - Walking boxes

    private struct Track {
        var handler = ""
        var tkhdSize: (w: Double, h: Double)?
        var rotation = 0
        var mediaDuration: Double?
        var entry = ""
        var entrySize: (w: Double, h: Double)?
    }

    private struct Walker {
        let size: UInt64
        let read: (UInt64, Int) throws -> Data
        var visited = 0

        init(size: UInt64, read: @escaping (UInt64, Int) throws -> Data) {
            self.size = size; self.read = read
        }

        /// The boxes directly inside `range`. A box of size 0 runs to the end of `range`.
        mutating func children(of range: Range<UInt64>, depth: Int) throws -> [VideoBox] {
            guard depth <= VideoProbe.maxDepth else { throw VideoProbeError.malformed("boxes nested too deeply") }
            var out: [VideoBox] = []
            var pos = range.lowerBound
            while range.upperBound - pos >= 8 {
                visited += 1
                guard visited <= VideoProbe.maxBoxes else { throw VideoProbeError.malformed("too many boxes") }
                let head = [UInt8](try read(pos, 16))
                guard head.count >= 8 else { throw VideoProbeError.malformed("truncated box header") }
                var length = UInt64(be32(head, 0))
                let type = fourcc(head, 4)
                var header: UInt64 = 8
                if length == 1 {
                    guard head.count >= 16, range.upperBound - pos >= 16 else {
                        throw VideoProbeError.malformed("truncated box header")
                    }
                    length = be64(head, 8); header = 16
                } else if length == 0 {
                    length = range.upperBound - pos
                }
                guard length >= header else { throw VideoProbeError.malformed("box '\(type)' smaller than its header") }
                guard length <= range.upperBound - pos else {
                    // The last top-level box of a file cut short (mdat of a recording that stopped): keep what
                    // came before (without a moov it is `noMovie`). Anything inside a box must fit it.
                    // Only mdat may be cut short: any other truncated box could hold metadata that would be
                    // kept unread (security review 2026-10, V2).
                    // A first box that overruns is no video at all (`notVideo`).
                    if depth == 0, type == "mdat" || out.isEmpty { break }
                    throw VideoProbeError.malformed("box '\(type)' overruns its parent")
                }
                out.append(VideoBox(type: type, offset: pos, length: length, header: header))
                pos += length
            }
            return out
        }

        /// Whether `box` (a `uuid` box) carries the XMP usertype.
        func isXMP(_ box: VideoBox) throws -> Bool {
            guard box.type == "uuid", box.length - box.header >= 16 else { return false }
            return try bytes(box, max: 16) == VideoProbe.xmpUUID
        }

        /// The first `max` bytes of `box`'s body (all of it when shorter).
        func bytes(_ box: VideoBox, max: Int = VideoProbe.maxLeafBytes) throws -> [UInt8] {
            let n = Int(min(UInt64(max), box.length - box.header))
            let d = [UInt8](try read(box.offset + box.header, n))
            guard d.count == n else { throw VideoProbeError.malformed("box '\(box.type)' cut off") }
            return d
        }

        mutating func movie(_ moov: VideoBox) throws -> VideoInfo {
            var movieDuration: Double?
            var metadata: [VideoBox] = []
            var video: Track?
            var audio: Track?
            for box in try children(of: moov.body, depth: 1) {
                switch box.type {
                case "mvhd": movieDuration = VideoProbe.duration(try bytes(box))
                case "mvex": throw VideoProbeError.fragmented
                case "udta", "meta": metadata.append(box)
                case "uuid": if try isXMP(box) { metadata.append(box) }
                case "trak":
                    let (track, meta) = try self.track(box)
                    metadata += meta
                    if track.handler == "vide", video == nil { video = track }
                    if track.handler == "soun", audio == nil { audio = track }
                default: break
                }
            }
            guard let video else { throw VideoProbeError.noVideoTrack }
            let codec: String
            switch video.entry {
            case "avc1", "avc3": codec = "h264"
            case "hvc1", "hev1": codec = "hevc"
            default: throw VideoProbeError.unsupportedCodec(video.entry)
            }
            var size = video.tkhdSize ?? (0, 0)
            if !(size.w >= 1 && size.h >= 1), let e = video.entrySize { size = e }
            guard size.w >= 1, size.h >= 1 else { throw VideoProbeError.malformed("the video track has no size") }
            if video.rotation == 90 || video.rotation == 270 { size = (size.h, size.w) }
            let seconds = [movieDuration, video.mediaDuration].compactMap { $0 }.first { $0 > 0 }
                ?? movieDuration ?? video.mediaDuration ?? 0
            var audioCodec: String?
            if let audio { audioCodec = audio.entry == "mp4a" ? "aac" : (audio.entry.isEmpty ? nil : audio.entry) }
            return VideoInfo(mediaType: "", duration: InkJSON.round3(seconds), pixelSize: Size(w: size.w, h: size.h),
                             rotation: video.rotation, codec: codec, audioCodec: audioCodec,
                             metadataBoxes: metadata.sorted { $0.offset < $1.offset })
        }

        mutating func track(_ trak: VideoBox) throws -> (Track, [VideoBox]) {
            var t = Track()
            var meta: [VideoBox] = []
            for box in try children(of: trak.body, depth: 2) {
                switch box.type {
                case "tkhd":
                    let d = try bytes(box)
                    (t.tkhdSize, t.rotation) = VideoProbe.trackHeader(d)
                case "udta", "meta": meta.append(box)
                case "uuid": if try isXMP(box) { meta.append(box) }
                case "mdia":
                    for part in try children(of: box.body, depth: 3) {
                        switch part.type {
                        case "hdlr":
                            let d = try bytes(part, max: 12)
                            if d.count >= 12 { t.handler = fourcc(d, 8) }
                        case "mdhd": t.mediaDuration = VideoProbe.duration(try bytes(part))
                        case "minf":
                            for m in try children(of: part.body, depth: 4) where m.type == "stbl" {
                                for s in try children(of: m.body, depth: 5) where s.type == "stsd" {
                                    (t.entry, t.entrySize) = VideoProbe.sampleEntry(try bytes(s))
                                }
                            }
                        default: break
                        }
                    }
                default: break
                }
            }
            return (t, meta)
        }
    }

    // MARK: - Leaf boxes

    /// `mvhd` / `mdhd`: seconds; nil when short, the timescale is 0 or the duration is "unknown" (all ones).
    static func duration(_ d: [UInt8]) -> Double? {
        guard d.count >= 4 else { return nil }
        let scale: UInt32, ticks: UInt64
        if d[0] == 1 {
            guard d.count >= 32 else { return nil }
            scale = be32(d, 20); ticks = be64(d, 24)
            guard ticks != UInt64.max else { return nil }
        } else {
            guard d.count >= 20 else { return nil }
            scale = be32(d, 12); ticks = UInt64(be32(d, 16))
            guard ticks != UInt64(UInt32.max) else { return nil }
        }
        guard scale > 0 else { return nil }
        let seconds = Double(ticks) / Double(scale)
        return seconds.isFinite ? seconds : nil
    }

    /// `tkhd`: the width and height (16.16, integer part) and the matrix's rotation.
    static func trackHeader(_ d: [UInt8]) -> ((w: Double, h: Double)?, Int) {
        // version 0: flags(3) times(8) id(4) reserved(4) duration(4); version 1 has 8-byte times and duration.
        guard let version = d.first else { return (nil, 0) }
        let matrix = version == 1 ? 52 : 40
        guard d.count >= matrix + 44 else { return (nil, 0) }
        let a = Int32(bitPattern: be32(d, matrix)), b = Int32(bitPattern: be32(d, matrix + 4))
        let w = Double(be32(d, matrix + 36) >> 16), h = Double(be32(d, matrix + 40) >> 16)
        return ((w, h), rotation(a: a, b: b))
    }

    /// The clockwise rotation, a multiple of 90°, closest to the matrix's
    /// first column `(a, b)` (QuickTime: x' = a·x + c·y + tx, y' = b·x + d·y + ty).
    static func rotation(a: Int32, b: Int32) -> Int {
        if a == 0 && b == 0 { return 0 }
        if abs(Int64(a)) >= abs(Int64(b)) { return a > 0 ? 0 : 180 }
        return b > 0 ? 90 : 270
    }

    /// `stsd`: the first sample entry's fourcc and, for a visual entry, its size.
    static func sampleEntry(_ d: [UInt8]) -> (String, (w: Double, h: Double)?) {
        // version/flags (4), entry count (4), then the entry: size (4), type (4), 6 reserved, data reference (2),
        // and for visual entries version, revision, vendor, temporal and spatial quality (16), width (2), height (2).
        guard d.count >= 16 else { return ("", nil) }
        let type = fourcc(d, 12)
        guard d.count >= 16 + 28 else { return (type, nil) }
        return (type, (Double(be16(d, 16 + 24)), Double(be16(d, 16 + 26))))
    }

    static func be16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }

    static func be32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func be64(_ d: [UInt8], _ i: Int) -> UInt64 { UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4)) }

    /// Four bytes as text; bytes outside printable ASCII become `?` (QuickTime's `©xyz` included).
    static func fourcc(_ d: [UInt8], _ i: Int) -> String {
        String(d[i..<i + 4].map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" })
    }
}

// MARK: - Metadata removal (format.md §8.2.7)

/// A change to a file's bytes made while it is streamed: the bytes of
/// `range` replaced by `bytes` (zeros when nil; `bytes` is as long as the range otherwise).
public struct ByteEdit: Hashable, Sendable {
    public var range: Range<UInt64>
    public var bytes: Data?

    public init(range: Range<UInt64>, bytes: Data? = nil) { self.range = range; self.bytes = bytes }

    /// Applies `edits` to `piece`, which starts at file offset `offset`.
    public static func apply(_ edits: [ByteEdit], to piece: inout Data, at offset: UInt64) {
        guard !edits.isEmpty, !piece.isEmpty else { return }
        let end = offset + UInt64(piece.count)
        for e in edits where e.range.lowerBound < end && e.range.upperBound > offset {
            let lo = max(e.range.lowerBound, offset), hi = min(e.range.upperBound, end)
            let start = piece.startIndex + Int(lo - offset)
            let count = Int(hi - lo)
            if let bytes = e.bytes {
                let from = bytes.startIndex + Int(lo - e.range.lowerBound)
                piece.replaceSubrange(start..<start + count, with: bytes[from..<from + count])
            } else {
                piece.resetBytes(in: start..<start + count)
            }
        }
    }
}

/// Removing a clip's location and device metadata in place (format.md §8.2.7).
public enum VideoMetadata {
    /// The edits that turn each of `info`'s metadata boxes into a `free` box
    /// of the same length with a zeroed body. Nothing moves, so sample
    /// offsets stay valid.
    public static func strippingEdits(_ info: VideoInfo) -> [ByteEdit] {
        info.metadataBoxes.flatMap { box -> [ByteEdit] in
            var out = [ByteEdit(range: box.offset + 4..<box.offset + 8, bytes: Data("free".utf8))]
            if box.length > box.header { out.append(ByteEdit(range: box.body)) }
            return out
        }
    }
}

extension VideoMetadata {
    /// Removes the location and device metadata of the clip at `url` in place
    /// (the same edits as `strippingEdits`, written over the file: its length
    /// and every sample stay as they are). Returns the number of boxes blanked;
    /// a file the probe does not take is left as it is (0).
    @discardableResult
    public static func strip(fileAt url: URL) throws -> Int {
        guard let info = try? VideoProbe.probe(file: url), !info.metadataBoxes.isEmpty else { return 0 }
        let handle: FileHandle
        do { handle = try FileHandle(forUpdating: url) } catch { throw VaultError.io("open \(url.path): \(error)") }
        defer { try? handle.close() }
        let zeros = Data(count: 1 << 16)
        do {
            for edit in strippingEdits(info) {
                try handle.seek(toOffset: edit.range.lowerBound)
                if let bytes = edit.bytes {
                    try handle.write(contentsOf: bytes)
                } else {
                    var left = edit.range.upperBound - edit.range.lowerBound
                    while left > 0 {
                        let n = Int(min(left, UInt64(zeros.count)))
                        try handle.write(contentsOf: zeros.prefix(n))
                        left -= UInt64(n)
                    }
                }
            }
            try handle.synchronize()
        } catch {
            throw VaultError.io("write \(url.path): \(error)")
        }
        return info.metadataBoxes.count
    }
}
