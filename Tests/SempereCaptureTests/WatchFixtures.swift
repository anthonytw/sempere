import Age
import Foundation
import Sempere
import SempereCapture
import TempDirSupport
import VaultTestSupport
import XCTest

/// ADTS streams for tests: real headers, deterministic payloads (the muxer never decodes).
enum ADTS {
    /// A 7 byte header (9 with `crc`) for a frame of `length` bytes in all.
    static func header(length: Int, rateIndex: Int = 6, channels: Int = 1, profile: Int = 1, crc: Bool = false,
                       blocks: Int = 0) -> [UInt8] {
        var h: [UInt8] = [
            0xFF, crc ? 0xF0 : 0xF1,
            UInt8((profile << 6) | (rateIndex << 2) | ((channels >> 2) & 1)),
            UInt8(((channels & 3) << 6) | ((length >> 11) & 3)),
            UInt8((length >> 3) & 0xFF),
            UInt8(((length & 7) << 5) | 0x1F),
            UInt8(0xFC | blocks),
        ]
        if crc { h += [0xAB, 0xCD] }
        return h
    }

    /// One frame with `payload` bytes after its header.
    static func frame(payload: Int, seed: UInt8 = 0, rateIndex: Int = 6, channels: Int = 1, profile: Int = 1, crc: Bool = false,
                      blocks: Int = 0) -> Data {
        let headerSize = crc ? 9 : 7
        var d = Data(header(length: headerSize + payload, rateIndex: rateIndex, channels: channels, profile: profile, crc: crc,
                            blocks: blocks))
        d.append(contentsOf: (0..<payload).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 7) })
        return d
    }

    /// A stream of `count` frames of 20 to 60 payload bytes.
    static func stream(frames count: Int, seed: UInt8 = 1, rateIndex: Int = 6) -> Data {
        var d = Data()
        for i in 0..<count { d.append(frame(payload: 20 + (i * 13) % 41, seed: seed &+ UInt8(i & 0x3F), rateIndex: rateIndex)) }
        return d
    }

    /// The payloads (frames without headers) of a stream of `stream(frames:seed:)`.
    static func payloads(frames count: Int, seed: UInt8 = 1) -> Data {
        var d = Data()
        for i in 0..<count {
            let n = 20 + (i * 13) % 41
            let s = seed &+ UInt8(i & 0x3F)
            d.append(contentsOf: (0..<n).map { UInt8(truncatingIfNeeded: Int(s) &+ $0 &* 7) })
        }
        return d
    }
}

/// A vault, its capture profile and a watch's provisioning identity, made once per process (key generation is slow).
enum WatchFixture {
    struct Template: Sendable {
        let url: URL
        let identity: NativeIdentity
        let profile: CaptureProfile
    }

    static let template: Result<Template, any Error> = Result {
        let identity = try NativeIdentity.generate(.postQuantum)
        let dir = TestTemp.root.appendingPathComponent("watch-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.sempere", isDirectory: true)
        let vault = try TestVaults.create(at: url, identities: [identity])
        return Template(url: url, identity: identity, profile: try vault.captureProfile(device: DeviceID("0badf00d")!))
    }

    static let watchKey = Result { try NativeIdentity.generate(.postQuantum) }

    static var profile: CaptureProfile { get throws { try template.get().profile } }

    static func payload(seq: Int = 1, profile: CaptureProfile? = nil, name: String = "sample") throws -> WatchProfilePayload {
        WatchProfilePayload(profile: try profile ?? Self.profile, vaultName: name, seq: seq, issued: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// A sealed capture of `audio` under the fixture profile.
    static func sealed(audio: Data = Data("AUDIO".utf8), id: UUID = UUID(), profile: CaptureProfile? = nil) throws -> SealedCapture {
        try CaptureWriter(profile: try profile ?? Self.profile).seal(audio: audio, started: Date(timeIntervalSince1970: 1_800_000_000),
                                                                      id: id)
    }
}
