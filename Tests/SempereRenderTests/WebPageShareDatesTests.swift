import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// A share made without dates carries no date of its recordings: not the transcript's creation time, not the audio
/// container's times; and no recognizer names (docs/web-viewer.md "Share files").
extension WebPageShareTests {
    static let recordedAudio = T.fixtureSourceDir.appendingPathComponent("audio/recorded-times.m4a")

    /// The `mvhd` creation time (seconds since 1904) of an MP4 file.
    static func movieCreationTime(_ data: Data) throws -> UInt64 {
        let r = try XCTUnwrap(data.range(of: Data("mvhd".utf8)))
        let body = [UInt8](data[r.upperBound..<r.upperBound + 20])
        if body[0] == 1 { return body[4..<12].reduce(0) { $0 << 8 | UInt64($1) } }
        return body[4..<8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func noteWithRecording(audio: Data, type: String = "audio/mp4") throws -> (NoteState, MemoryBlobSource, Transcript) {
        let recID = Self.uuid(950)
        let transcript = Transcript(recording: recID, engine: "SpeechAnalyzer 27.0", language: "es-US",
                                    created: Date(timeIntervalSince1970: 1_790_000_000),
                                    segments: [.init(start: 0, end: 1, text: "hola")])
        let tBytes = try transcript.encoded()
        var state = try T.loadSampleNote()
        state.pages[0].recognition = Recognition(engine: "vision-SECRETOS-27.1", text: "hello")
        state.recordings = [Recording(id: recID, blob: BlobRef(content: audio, type: type),
                                      started: Date(timeIntervalSince1970: 1_790_000_100), title: "Lecture",
                                      transcript: BlobRef(content: tBytes, type: "application/json"))]
        state.pages[0].items = [Item(id: Self.uuid(951), kind: .audio, frame: Rect(x: 0, y: 0, w: 100, h: 40), z: "a",
                                     recording: recID)]
        return (state, MemoryBlobSource([audio, tBytes]), transcript)
    }

    func sharedRecording(_ parsed: Parsed) throws -> (audio: Data, transcript: Transcript) {
        let recs = try XCTUnwrap((parsed.json["note"] as? [String: Any])?["recordings"] as? [[String: Any]])
        let rec = try XCTUnwrap(recs.first)
        let blob = try XCTUnwrap((rec["blob"] as? [String: Any])?["sha256"] as? String)
        let tr = try XCTUnwrap((rec["transcript"] as? [String: Any])?["sha256"] as? String)
        return (try XCTUnwrap(parsed.blobs[blob]), try Transcript.decode(try XCTUnwrap(parsed.blobs[tr])))
    }

    func testAShareWithoutDatesCarriesNoDateOfItsRecordings() throws {
        let audio = try Data(contentsOf: Self.recordedAudio)
        XCTAssertNotEqual(try Self.movieCreationTime(audio), 0, "the fixture is dated as a recording is")
        let (state, blobs, stored) = try noteWithRecording(audio: audio)
        let (_, parsed) = try share(state, blobs) { $0.includeAudio = true }
        let shared = try sharedRecording(parsed)
        XCTAssertEqual(shared.transcript.created, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(shared.transcript.engine, "")
        XCTAssertEqual(shared.transcript.language, stored.language, "the page shows the language")
        XCTAssertEqual(shared.transcript.segments, stored.segments)
        XCTAssertEqual(try Self.movieCreationTime(shared.audio), 0)
        XCTAssertEqual(shared.audio.count, audio.count)
        XCTAssertEqual(try AudioProbe.probe(shared.audio), try AudioProbe.probe(audio), "it plays as before")
        XCTAssertNil(shared.audio.range(of: Data("udta".utf8)), "its tags are blanked")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: parsed.json, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRETOS"), "no recognizer name or system version")
        XCTAssertFalse(json.contains("2026-"), "no date in the payload")
    }

    func testAShareWithDatesKeepsThemButNoRecognizerName() throws {
        let audio = try Data(contentsOf: Self.recordedAudio)
        let (state, blobs, stored) = try noteWithRecording(audio: audio)
        let (_, parsed) = try share(state, blobs) { $0.includeAudio = true; $0.includeDates = true }
        let shared = try sharedRecording(parsed)
        XCTAssertEqual(shared.transcript.created, stored.created)
        XCTAssertEqual(shared.transcript.engine, "")
        XCTAssertEqual(shared.audio, audio, "the audio as stored")
    }

    /// Audio that is not an MP4 is shared as stored (docs/web-viewer.md says what it may carry); an MP4 whose boxes do
    /// not read is left out with a notice, never shared with its dates.
    func testOtherContainersAsStoredAndAnUnreadableMP4LeftOut() throws {
        let mp3 = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let (state, blobs, _) = try noteWithRecording(audio: mp3, type: "audio/mpeg")
        let shared = try sharedRecording(try share(state, blobs) { $0.includeAudio = true }.1)
        XCTAssertEqual(shared.audio, mp3)
        let (bad, badBlobs, _) = try noteWithRecording(audio: mp3)
        let (result, parsed) = try share(bad, badBlobs) { $0.includeAudio = true }
        XCTAssertNil((parsed.json["note"] as? [String: Any])?["recordings"])
        XCTAssertTrue(result.skipped.contains { $0.contains("Lecture") && $0.contains("dates") }, "\(result.skipped)")
    }
}
