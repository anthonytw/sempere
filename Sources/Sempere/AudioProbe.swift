import Foundation

/// What a recording's audio file says about itself (format.md §8.3.1): the
/// informational fields of a `Recording`.
public struct AudioInfo: Hashable, Sendable {
    /// Seconds: the sound track's `mdhd` duration, the movie's `mvhd` when
    /// that is absent or 0.
    public var duration: Double?
    /// `aac`, `he-aac` or `alac`; nil for a sample format this reader does not name.
    public var codec: String?
    /// Hz.
    public var sampleRate: Int?
    public var channels: Int?
    /// Average bits per second.
    public var bitRate: Int?

    public init(duration: Double? = nil, codec: String? = nil, sampleRate: Int? = nil, channels: Int? = nil,
                bitRate: Int? = nil) {
        self.duration = duration; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.bitRate = bitRate
    }
}

/// Why a file is not an MPEG-4 audio file this reader understands.
public enum AudioProbeError: Error, Hashable, Sendable {
    /// No `ftyp` box first: not an MP4 / M4A file.
    case notMP4
    /// An MP4 without a sound track.
    case noAudioTrack
    /// A box lies about its size or nests too deeply (the string says where).
    case malformed(String)
}

extension AudioProbeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notMP4: return "not an MPEG-4 audio file (.m4a)"
        case .noAudioTrack: return "the MPEG-4 file has no audio track"
        case .malformed(let why): return "damaged MPEG-4 file (\(why))"
        }
    }
}

/// A small reader for the header of an MPEG-4 audio file (`ftyp`, then
/// `moov` with a `soun` track): duration, codec, sample rate, channels and
/// average bit rate for `Recording`. It reads only the box headers and the
/// `moov` box (at most `maxMoovBytes`), never the samples.
///
/// Every byte is untrusted (format.md §9): sizes are checked against the
/// file's size before anything is allocated, nesting and box counts are
/// bounded, and the work is linear in the size of `moov`.
public enum AudioProbe {
    /// Largest `moov` box read. A 10-hour recording has a sample table of about 1 MB.
    public static let maxMoovBytes = 64 << 20
    static let maxDepth = 8
    static let maxBoxes = 100_000

    /// The audio file at `url`.
    public static func probe(file url: URL) throws -> AudioInfo {
        try VideoProbe.reading(file: url, probe(size:read:))
    }

    /// The audio file held in `data`.
    public static func probe(_ data: Data) throws -> AudioInfo {
        try VideoProbe.reading(data, probe(size:read:))
    }

    static func probe(size: UInt64, read: (UInt64, Int) throws -> Data) throws -> AudioInfo {
        var pos: UInt64 = 0
        var first = true
        var boxes = 0
        while pos + 8 <= size {
            boxes += 1
            guard boxes <= maxBoxes else { throw AudioProbeError.malformed("too many top-level boxes") }
            let head = [UInt8](try read(pos, 16))
            guard head.count >= 8 else { throw AudioProbeError.malformed("truncated box header") }
            var length = UInt64(be32(head, 0))
            let type = String(decoding: head[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if length == 1 {
                guard head.count >= 16 else { throw AudioProbeError.malformed("truncated box header") }
                length = be64(head, 8); header = 16
            } else if length == 0 {
                length = size - pos
            }
            if first {
                guard type == "ftyp" else { throw AudioProbeError.notMP4 }
                first = false
            }
            guard length >= header else { throw AudioProbeError.malformed("box \(type) smaller than its header") }
            if type == "moov" {
                guard length <= UInt64(maxMoovBytes), length <= size - pos else {
                    throw AudioProbeError.malformed("moov box too large or cut off")
                }
                let body = [UInt8](try read(pos + header, Int(length - header)))
                guard UInt64(body.count) == length - header else { throw AudioProbeError.malformed("moov box cut off") }
                return try parseMoov(body, fileSize: size)
            }
            // Past the end (a recording cut off inside mdat): nothing more to find.
            // `size - pos` (pos < size here), never `pos + length`: a 64-bit size may be near 2^64.
            guard length <= size - pos else { break }
            pos += length
        }
        if first { throw AudioProbeError.notMP4 }
        throw AudioProbeError.malformed("no moov box (an unfinished recording?)")
    }

    // MARK: - moov

    private struct Box {
        var type: String
        var body: Range<Int>
    }

    private static func be16(_ d: [UInt8], _ i: Int) -> Int { VideoProbe.be16(d, i) }
    private static func be32(_ d: [UInt8], _ i: Int) -> UInt32 { VideoProbe.be32(d, i) }
    private static func be64(_ d: [UInt8], _ i: Int) -> UInt64 { VideoProbe.be64(d, i) }

    /// The boxes directly inside `range` of `d`.
    private static func children(_ d: [UInt8], _ range: Range<Int>, budget: inout Int) throws -> [Box] {
        var out: [Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            budget -= 1
            guard budget >= 0 else { throw AudioProbeError.malformed("too many boxes") }
            var length = Int(clamping: be32(d, pos))
            let type = String(decoding: d[pos + 4..<pos + 8], as: UTF8.self)
            var header = 8
            if length == 1 {
                guard pos + 16 <= range.upperBound else { throw AudioProbeError.malformed("truncated box header") }
                length = Int(clamping: be64(d, pos + 8)); header = 16
            } else if length == 0 {
                length = range.upperBound - pos
            }
            guard length >= header, length <= range.upperBound - pos else {
                throw AudioProbeError.malformed("box \(type) overruns its parent")
            }
            out.append(Box(type: type, body: pos + header..<pos + length))
            pos += length
        }
        return out
    }

    private static func parseMoov(_ d: [UInt8], fileSize: UInt64) throws -> AudioInfo {
        var budget = maxBoxes
        let top = try children(d, 0..<d.count, budget: &budget)
        var movieDuration: Double?
        var info: AudioInfo?
        var mediaDuration: Double?
        for box in top {
            if box.type == "mvhd" { movieDuration = header(d, box.body) }
            guard box.type == "trak", info == nil else { continue }
            let mdia = try children(d, box.body, budget: &budget).first { $0.type == "mdia" }
            guard let mdia else { continue }
            let parts = try children(d, mdia.body, budget: &budget)
            guard let hdlr = parts.first(where: { $0.type == "hdlr" }), hdlr.body.count >= 12,
                  String(decoding: d[hdlr.body.lowerBound + 8..<hdlr.body.lowerBound + 12], as: UTF8.self) == "soun"
            else { continue }
            if let mdhd = parts.first(where: { $0.type == "mdhd" }) { mediaDuration = header(d, mdhd.body) }
            let minf = try parts.first { $0.type == "minf" }.map { try children(d, $0.body, budget: &budget) } ?? []
            let stbl = try minf.first { $0.type == "stbl" }.map { try children(d, $0.body, budget: &budget) } ?? []
            let stsd = stbl.first { $0.type == "stsd" }
            info = try stsd.map { try sampleEntry(d, $0.body, budget: &budget) } ?? AudioInfo()
        }
        guard var found = info else { throw AudioProbeError.noAudioTrack }
        // The sound track's `mdhd` (what plays), the movie's `mvhd` when it is absent or 0.
        found.duration = ([mediaDuration, movieDuration].compactMap { $0 }.first { $0 > 0 } ?? mediaDuration ?? movieDuration)
            .map { InkJSON.round3($0) }
        if let seconds = found.duration, seconds > 0 {
            // Average over the whole file: the container's own overhead is a fraction of a percent.
            let bits = Double(fileSize) * 8 / seconds
            if bits.isFinite, bits < Double(Int32.max) { found.bitRate = Int(bits.rounded()) }
        }
        return found
    }

    /// `mvhd` / `mdhd`: the duration in seconds (`VideoProbe.duration`: nil
    /// when the box is short, the timescale is 0 or the duration is "unknown").
    private static func header(_ d: [UInt8], _ body: Range<Int>) -> Double? {
        VideoProbe.duration(Array(d[body.lowerBound..<min(body.upperBound, body.lowerBound + 32)]))
    }

    /// `stsd`: the first sample entry (`mp4a`, `alac`, ...).
    private static func sampleEntry(_ d: [UInt8], _ body: Range<Int>, budget: inout Int) throws -> AudioInfo {
        // version/flags (4) and the entry count (4), then the entries.
        guard body.count >= 8 else { return AudioInfo() }
        let entries = try children(d, body.lowerBound + 8..<body.upperBound, budget: &budget)
        guard let entry = entries.first, entry.body.count >= 28 else { return AudioInfo() }
        let b = entry.body.lowerBound
        var info = AudioInfo()
        // 6 reserved + data reference index (2), then version (2), revision (2), vendor (4),
        // channels (2), sample size (2), compression id (2), packet size (2), sample rate 16.16.
        info.channels = be16(d, b + 16)
        info.sampleRate = be16(d, b + 24)
        if info.channels == 0 { info.channels = nil }
        if info.sampleRate == 0 { info.sampleRate = nil }
        switch entry.type {
        case "alac":
            info.codec = "alac"
        case "mp4a":
            info.codec = "aac"
            // Children follow the 28-byte fixed part (version 0 entries).
            let inner = try children(d, entry.body.lowerBound + 28..<entry.body.upperBound, budget: &budget)
            if let esds = inner.first(where: { $0.type == "esds" }), let type = audioObjectType(d, esds.body),
               type == 5 || type == 29 {
                info.codec = "he-aac"
            }
        default:
            break
        }
        return info
    }

    /// The audio object type in the AudioSpecificConfig of an `esds` box, nil if it cannot be found.
    private static func audioObjectType(_ d: [UInt8], _ body: Range<Int>) -> Int? {
        var i = body.lowerBound + 4   // version and flags
        // Walk the descriptors: ES (0x03) holds DecoderConfig (0x04) holds DecoderSpecificInfo (0x05).
        func readLength() -> Int? {
            var length = 0
            for _ in 0..<4 {
                guard i < body.upperBound else { return nil }
                let b = d[i]; i += 1
                length = length << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { return length }
            }
            return nil
        }
        while i < body.upperBound {
            let tag = d[i]; i += 1
            guard let length = readLength(), i + length <= body.upperBound else { return nil }
            switch tag {
            case 0x03: i += 3   // ES id (2) and flags (1), no optional fields written by AVFoundation
            case 0x04: i += 13  // object type, stream type, buffer size, max and average bit rate
            case 0x05:
                guard length >= 1, i < body.upperBound else { return nil }
                let type = Int(d[i] >> 3)
                return type == 31 && i + 1 < body.upperBound ? 32 + Int((d[i] & 7) << 3 | d[i + 1] >> 5) : type
            default: i += length
            }
        }
        return nil
    }
}
