import Foundation
import Sempere

// ADTS (the crash-safe segments a voice note records, `CaptureSegments.segmentExtension`) to MPEG-4 audio, in pure Swift
// (docs/design/1.1-watch.md §3.5, D4). watchOS has no `AVAssetExportSession`, `AVAssetWriter`, `AVAssetReader` or
// AudioToolbox, and transcoding through `AVAudioFile` would encode a second lossy generation, so the watch remuxes: ADTS
// frames stand alone, so each is copied as one MP4 sample behind a fresh `moov`. The same frame walk says what a segment
// holds (`ADTSToMP4.audio(in:)`), so the watch needs no AVFoundation probe.
//
// The input is untrusted (a damaged or half-written segment): every header is checked, the work is bounded by the input's
// size, and anything wrong is a typed `ADTSError`, never a trap.

/// Why bytes are not ADTS this muxer remuxes.
public enum ADTSError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No bytes, or no whole frame.
    case noFrames
    /// A frame header at `offset` does not start with the sync word, or has a reserved field (layer, sample rate index).
    case badHeader(offset: Int)
    /// A frame's length at `offset` is shorter than its header, or runs past the input.
    case badFrameLength(offset: Int)
    /// Fewer than a header's bytes remain at `offset`.
    case truncatedHeader(offset: Int)
    /// Only AAC-LC, one raw data block per frame and a channel configuration of 1 to 7 are muxed.
    case unsupported(String)
    /// A frame at `offset` differs in profile, sample rate or channels from the first.
    case parametersChanged(offset: Int)
    /// More input than `ADTSToMP4.maxInputBytes`.
    case tooLarge(Int)
    /// More frames than `ADTSToMP4.maxFrames`.
    case tooManyFrames

    public var description: String {
        switch self {
        case .noFrames: return "no AAC frame"
        case .badHeader(let o): return "not an ADTS frame header at byte \(o)"
        case .badFrameLength(let o): return "the ADTS frame at byte \(o) has an impossible length"
        case .truncatedHeader(let o): return "the ADTS stream ends inside a frame header at byte \(o)"
        case .unsupported(let why): return "unsupported AAC stream: \(why)"
        case .parametersChanged(let o): return "the audio format changes at byte \(o)"
        case .tooLarge(let n): return "more than \(n >> 20) MiB of audio"
        case .tooManyFrames: return "more than \(ADTSToMP4.maxFrames) audio frames"
        }
    }
}

/// Remuxes ADTS segments into one MPEG-4 audio file.
public enum ADTSToMP4 {
    /// The most input one remux takes (a 60 minute note at 32 kbit/s is 14 MB; a phone's 64 kbit/s hour 29 MB).
    public static let maxInputBytes = 128 << 20
    /// The most frames one file has: 2,000,000 of 1024 samples is under 2^31, so the sample counts fit the 32 bit `Int` of the
    /// Apple Watch's arm64_32 (and an MP4 box's 32 bit fields), and is over 23 hours at 24 kHz.
    public static let maxFrames = 2_000_000

    /// What the frame walk found.
    public struct Info: Equatable, Sendable {
        public var frames: Int
        public var sampleRate: Int
        public var channels: Int
        /// Seconds: `frames` of 1024 samples.
        public var duration: Double
        /// Average bits per second, from the sizes of the frames.
        public var bitRate: Int

        /// The recording's informational fields in a capture's manifest (format.md §8.3.1).
        public var audioInfo: AudioInfo {
            AudioInfo(duration: duration, codec: "aac", sampleRate: sampleRate, channels: channels, bitRate: bitRate)
        }
    }

    /// What to do with bytes after the last whole frame (a segment the app died while writing).
    public enum Tail: Sendable {
        /// Anything but whole frames to the end is an error.
        case strict
        /// A final frame that is cut off is dropped, as a crash leaves it. Junk before the end is still an error.
        case dropPartial
    }

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    /// Samples per AAC frame.
    static let frameSamples = 1024
    /// Frames of one chunk (`stsc`), about three seconds at 24 kHz.
    static let framesPerChunk = 64

    /// One frame's place in its segment.
    struct Frame {
        var segment: Int
        var offset: Int
        var length: Int
    }

    /// The parameters every frame must share.
    struct Params: Equatable {
        var objectType: Int
        var rateIndex: Int
        var channelConfig: Int
    }

    /// Walks the frames of one segment. Throws on junk; see `Tail`.
    static func walk(_ data: Data, segment: Int, tail: Tail, params: inout Params?, into frames: inout [Frame]) throws {
        let base = data.startIndex
        let end = data.count
        var o = 0
        while o < end {
            guard end - o >= 7 else {
                if tail == .dropPartial { return }
                throw ADTSError.truncatedHeader(offset: o)
            }
            // 12 sync bits, ID (1), layer (2, always 0), protection_absent (1); then profile (2), rate index (4), private (1),
            // channel configuration (3, across two bytes), 4 flags, the 13 bit frame length, 11 bits of buffer fullness and
            // number_of_raw_data_blocks (2).
            let b0 = data[base + o], b1 = data[base + o + 1], b2 = data[base + o + 2], b3 = data[base + o + 3]
            let b4 = data[base + o + 4], b5 = data[base + o + 5], b6 = data[base + o + 6]
            guard b0 == 0xFF, b1 & 0xF0 == 0xF0, b1 & 0x06 == 0 else { throw ADTSError.badHeader(offset: o) }
            let headerSize = b1 & 1 == 1 ? 7 : 9   // protection_absent clear: a CRC follows
            let objectType = Int(b2 >> 6) + 1
            let rateIndex = Int((b2 >> 2) & 0x0F)
            let channelConfig = Int(((b2 & 1) << 2) | (b3 >> 6))
            guard rateIndex < sampleRates.count else { throw ADTSError.badHeader(offset: o) }
            let length = (Int(b3 & 3) << 11) | (Int(b4) << 3) | Int(b5 >> 5)
            guard length > headerSize else { throw ADTSError.badFrameLength(offset: o) }
            guard length <= end - o else {
                if tail == .dropPartial { return }
                throw ADTSError.badFrameLength(offset: o)
            }
            let rawBlocks = Int(b6 & 3)
            guard rawBlocks == 0 else { throw ADTSError.unsupported("\(rawBlocks + 1) raw data blocks in a frame") }
            guard objectType == 2 else { throw ADTSError.unsupported("AAC profile \(objectType) (only AAC-LC)") }
            guard (1...7).contains(channelConfig) else { throw ADTSError.unsupported("channel configuration \(channelConfig)") }
            let p = Params(objectType: objectType, rateIndex: rateIndex, channelConfig: channelConfig)
            if let params, params != p { throw ADTSError.parametersChanged(offset: o) }
            params = p
            guard frames.count < maxFrames else { throw ADTSError.tooManyFrames }
            frames.append(Frame(segment: segment, offset: o + headerSize, length: length - headerSize))
            o += length
        }
    }

    /// What `data` holds as a voice note's segment: nothing (no byte), audio (at least one whole frame; a cut-off last
    /// frame is the crash's and is ignored) or bytes that are not ADTS audio.
    public static func audio(in data: Data) -> CaptureSegments.Audio {
        if data.isEmpty { return .none }
        guard data.count <= maxInputBytes else { return .undecodable }
        var params: Params?
        var frames: [Frame] = []
        do { try walk(data, segment: 0, tail: .dropPartial, params: &params, into: &frames) } catch { return .undecodable }
        return frames.isEmpty ? .undecodable : .audio
    }

    /// The frames of `segments` joined, without writing anything: the length, rate and channels.
    public static func probe(_ segments: [Data], tail: Tail = .strict) throws -> Info {
        try plan(segments, tail: tail).info
    }

    /// An MPEG-4 audio file of the frames of `segments`, in order (each segment is one ADTS stream; all must share the
    /// format), and what it holds.
    public static func remux(_ segments: [Data], tail: Tail = .strict) throws -> (data: Data, info: Info) {
        let p = try plan(segments, tail: tail)
        return (try mux(p, segments), p.info)
    }

    /// `remux` of one stream.
    public static func remux(_ data: Data, tail: Tail = .strict) throws -> (data: Data, info: Info) {
        try remux([data], tail: tail)
    }

    struct Plan {
        var frames: [Frame]
        var params: Params
        var info: Info
        var payload: Int
    }

    static func plan(_ segments: [Data], tail: Tail) throws -> Plan {
        // Summed as Int64: segment counts could wrap a 32 bit `Int` (arm64_32).
        let total = segments.reduce(Int64(0)) { $0 + Int64($1.count) }
        guard total <= Int64(maxInputBytes) else { throw ADTSError.tooLarge(maxInputBytes) }
        var params: Params?
        var frames: [Frame] = []
        for (i, s) in segments.enumerated() {
            try walk(s, segment: i, tail: tail, params: &params, into: &frames)
        }
        guard let params, !frames.isEmpty else { throw ADTSError.noFrames }
        let payload = frames.reduce(0) { $0 + $1.length }
        let rate = sampleRates[params.rateIndex]
        let duration = Double(frames.count * frameSamples) / Double(rate)
        let bitRate = duration > 0 ? Int((Double(payload) * 8 / duration).rounded()) : 0
        let channels = params.channelConfig == 7 ? 8 : params.channelConfig
        return Plan(frames: frames, params: params,
                    info: Info(frames: frames.count, sampleRate: rate, channels: channels, duration: duration, bitRate: bitRate),
                    payload: payload)
    }

    // MARK: Boxes

    private struct Writer {
        var bytes = Data()
        mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
        mutating func u16(_ v: Int) { u8(v >> 8); u8(v) }
        mutating func u32(_ v: Int) { u16(v >> 16); u16(v) }
        mutating func fourCC(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
        mutating func zeros(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
        mutating func append(_ d: Data) { bytes.append(d) }
    }

    /// A box: size, type, body.
    private static func box(_ type: String, _ body: (inout Writer) -> Void) -> Data {
        var inner = Writer()
        body(&inner)
        var w = Writer()
        w.u32(8 + inner.bytes.count)
        w.fourCC(type)
        w.append(inner.bytes)
        return w.bytes
    }

    private static func fullBox(_ type: String, version: Int = 0, flags: Int = 0, _ body: (inout Writer) -> Void) -> Data {
        box(type) { w in
            w.u8(version); w.u8(flags >> 16); w.u8(flags >> 8); w.u8(flags)
            body(&w)
        }
    }

    /// The `esds` descriptors for AAC-LC at `rateIndex` with `channelConfig`.
    private static func esds(_ p: Params, bitRate: Int) -> Data {
        fullBox("esds") { w in
            // AudioSpecificConfig: object type (5 bits), rate index (4), channel configuration (4), three zero flags.
            let asc = (p.objectType << 11) | (p.rateIndex << 7) | (p.channelConfig << 3)
            // DecoderSpecificInfo: tag 5, length 2, the config.
            var dsi = Writer(); dsi.u8(0x05); dsi.u8(2); dsi.u16(asc)
            // DecoderConfigDescriptor: tag 4; 0x40 = MPEG-4 audio, 0x15 = audio stream, buffer size, max and average bit rate.
            var dcd = Writer()
            dcd.u8(0x40); dcd.u8(0x15); dcd.u8(0); dcd.u16(0x0600)
            dcd.u32(max(bitRate, 0)); dcd.u32(max(bitRate, 0))
            dcd.append(dsi.bytes)
            // SLConfigDescriptor: tag 6, length 1, predefined 2 (MP4).
            let sl = Data([0x06, 0x01, 0x02])
            // ES_Descriptor: tag 3; ES_ID 0, no flags.
            var es = Writer()
            es.u16(0); es.u8(0)
            es.u8(0x04); es.u8(dcd.bytes.count); es.append(dcd.bytes)
            es.append(sl)
            w.u8(0x03); w.u8(es.bytes.count); w.append(es.bytes)
        }
    }

    /// `moov` for `plan`, whose first chunk's data starts at `dataOffset`.
    private static func moov(_ plan: Plan, dataOffset: Int) -> Data {
        let info = plan.info
        let rate = info.sampleRate
        let samples = plan.frames.count * frameSamples
        let timescale = rate
        let chunks = (plan.frames.count + framesPerChunk - 1) / framesPerChunk
        // Chunk offsets: the frames of each chunk are consecutive in `mdat`.
        var offsets: [Int] = []
        var at = dataOffset
        for (i, f) in plan.frames.enumerated() {
            if i % framesPerChunk == 0 { offsets.append(at) }
            at += f.length
        }
        let mvhd = fullBox("mvhd") { w in
            w.u32(0); w.u32(0); w.u32(timescale); w.u32(samples)
            w.u32(0x0001_0000); w.u16(0x0100); w.zeros(10)
            for v in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { w.u32(v) }
            w.zeros(24)
            w.u32(2)   // next track id
        }
        let tkhd = fullBox("tkhd", flags: 7) { w in
            w.u32(0); w.u32(0); w.u32(1); w.u32(0); w.u32(samples)
            w.zeros(8); w.u16(0); w.u16(0); w.u16(0x0100); w.u16(0)
            for v in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { w.u32(v) }
            w.u32(0); w.u32(0)
        }
        let mdhd = fullBox("mdhd") { w in
            w.u32(0); w.u32(0); w.u32(timescale); w.u32(samples)
            w.u16(0x55C4)   // language "und"
            w.u16(0)
        }
        let hdlr = fullBox("hdlr") { w in
            w.u32(0); w.fourCC("soun"); w.zeros(12)
            w.fourCC("SoundHandler"); w.u8(0)
        }
        let smhd = fullBox("smhd") { w in w.u16(0); w.u16(0) }
        let dinf = box("dinf") { w in
            w.append(fullBox("dref") { w in
                w.u32(1)
                w.append(fullBox("url ", flags: 1) { _ in })
            })
        }
        let mp4a = box("mp4a") { w in
            w.zeros(6); w.u16(1)            // reserved, data reference index
            w.zeros(8)                      // version, revision, vendor
            w.u16(info.channels); w.u16(16) // channel count, sample size
            w.u16(0); w.u16(0)              // compression id, packet size
            w.u32(min(rate, 0xFFFF) << 16)  // sample rate, 16.16
            w.append(esds(plan.params, bitRate: info.bitRate))
        }
        let stsd = fullBox("stsd") { w in w.u32(1); w.append(mp4a) }
        let stts = fullBox("stts") { w in w.u32(1); w.u32(plan.frames.count); w.u32(frameSamples) }
        let stsc = fullBox("stsc") { w in
            // Full chunks of `framesPerChunk`, then the shorter last one.
            let rest = plan.frames.count % framesPerChunk
            let shortLast = chunks > 1 && rest != 0
            w.u32(shortLast ? 2 : 1)
            w.u32(1); w.u32(chunks == 1 ? plan.frames.count : framesPerChunk); w.u32(1)
            if shortLast { w.u32(chunks); w.u32(rest); w.u32(1) }
        }
        let stsz = fullBox("stsz") { w in
            w.u32(0); w.u32(plan.frames.count)
            for f in plan.frames { w.u32(f.length) }
        }
        let stco = fullBox("stco") { w in
            w.u32(offsets.count)
            for o in offsets { w.u32(o) }
        }
        let stbl = box("stbl") { w in for b in [stsd, stts, stsc, stsz, stco] { w.append(b) } }
        let minf = box("minf") { w in for b in [smhd, dinf, stbl] { w.append(b) } }
        let mdia = box("mdia") { w in for b in [mdhd, hdlr, minf] { w.append(b) } }
        let trak = box("trak") { w in for b in [tkhd, mdia] { w.append(b) } }
        return box("moov") { w in for b in [mvhd, trak] { w.append(b) } }
    }

    private static func mux(_ plan: Plan, _ segments: [Data]) throws -> Data {
        let ftyp = box("ftyp") { w in
            w.fourCC("M4A "); w.u32(0)
            for brand in ["M4A ", "mp42", "isom"] { w.fourCC(brand) }
        }
        // `moov` first, so the file plays while it downloads. Its size does not depend on the offsets' values.
        let moovSize = moov(plan, dataOffset: 0).count
        let dataOffset = ftyp.count + moovSize + 8
        let mdatSize = 8 + plan.payload
        // The input is bounded far below 2^31 (`maxInputBytes`), so offsets and sizes fit every `Int`.
        var out = Data()
        out.reserveCapacity(dataOffset + plan.payload)
        out.append(ftyp)
        out.append(moov(plan, dataOffset: dataOffset))
        var w = Writer()
        w.u32(mdatSize); w.fourCC("mdat")
        out.append(w.bytes)
        for f in plan.frames {
            let s = segments[f.segment]
            let from = s.startIndex + f.offset
            out.append(s[from..<from + f.length])
        }
        return out
    }
}
