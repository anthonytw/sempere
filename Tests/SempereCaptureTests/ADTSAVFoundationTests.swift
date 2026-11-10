#if canImport(AVFoundation)
import AVFoundation
import Foundation
@testable import Sempere
@testable import SempereCapture
import TempDirSupport
import XCTest

/// The muxer's output against the system's reader (docs/design/1.1-watch.md §5): AVFoundation opens it, reads the right
/// duration and decodes it. The ADTS comes from the AAC packets of a real recording (`tone-aac.m4a`).
final class ADTSAVFoundationTests: XCTestCase {
    static let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/audio/tone-aac.m4a")

    /// The fixture's AAC packets, each behind an ADTS header, and the fixture's own duration.
    func adts(from url: URL) async throws -> (data: Data, duration: Double, sampleRate: Int, channels: Int) {
        let asset = AVURLAsset(url: url)
        let tracks0 = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks0.first)
        let duration = try await asset.load(.duration).seconds
        let formats = try await track.load(.formatDescriptions)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(formats[0])).pointee
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rateIndex = try XCTUnwrap(rates.firstIndex(of: Int(asbd.mSampleRate)), "fixture rate \(asbd.mSampleRate)")
        let channels = Int(asbd.mChannelsPerFrame)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var stream = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var packets: UnsafePointer<AudioStreamPacketDescription>?
            var bytes = 0
            XCTAssertEqual(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &packets,
                                                                           sizeOut: &bytes), 0)
            let list = try XCTUnwrap(packets)
            var raw = Data(count: CMBlockBufferGetDataLength(block))
            XCTAssertEqual(raw.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count,
                                                                                  destination: $0.baseAddress!) }, 0)
            for i in 0..<bytes / MemoryLayout<AudioStreamPacketDescription>.stride {
                let d = list[i]
                let packet = raw[Int(d.mStartOffset)..<Int(d.mStartOffset) + Int(d.mDataByteSize)]
                stream.append(contentsOf: ADTS.header(length: 7 + packet.count, rateIndex: rateIndex, channels: channels))
                stream.append(packet)
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return (stream, duration, Int(asbd.mSampleRate), channels)
    }

    func testAVFoundationReadsTheMuxedFileWithTheRightDuration() async throws {
        let source = try await adts(from: Self.tone)
        XCTAssertFalse(source.data.isEmpty)
        XCTAssertEqual(ADTSToMP4.audio(in: source.data), .audio)
        let (mp4, info) = try ADTSToMP4.remux(source.data)
        XCTAssertEqual(info.sampleRate, source.sampleRate)
        XCTAssertEqual(info.channels, source.channels)

        let url = makeScratch("adts-av").appendingPathExtension("m4a")
        try mp4.write(to: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        // About the duration of the recording the packets came from (`tone-aac.m4a`; its edit list also trims the encoder's
        // end padding, which is under two frames).
        XCTAssertEqual(duration, source.duration, accuracy: 0.05)
        // `info.duration` counts every frame; the system takes the encoder's 2112 priming samples off any AAC file that has
        // no edit list saying otherwise, as it does for the original.
        XCTAssertEqual(info.duration - duration, 2112 / Double(info.sampleRate), accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)

        // It decodes: every frame comes out as PCM.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, info.duration, accuracy: 0.1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var frames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            frames += Int(buffer.frameLength)
        }
        XCTAssertEqual(frames, Int(file.length))
        // And the player opens it.
        XCTAssertNoThrow(try AVAudioPlayer(contentsOf: url))
        // Segments cut in two join to the same duration.
        let half = source.data.count / 2
        // Cut at a frame boundary by walking the headers.
        var cut = 0
        while cut < half {
            let length = (Int(source.data[cut + 3] & 3) << 11) | (Int(source.data[cut + 4]) << 3) | Int(source.data[cut + 5] >> 5)
            cut += length
        }
        let joined = try ADTSToMP4.remux([Data(source.data[..<cut]), Data(source.data[cut...])])
        XCTAssertEqual(joined.info.frames, info.frames)
        XCTAssertEqual(joined.data, mp4)
    }
}
#endif
