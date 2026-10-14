import XCTest
@testable import Sempere

final class RecordingFormatTests: XCTestCase {
    func testDefaultIsAACMono48kHz64kbps() {
        let f = RecordingFormat.default
        XCTAssertEqual(f.codec, .aac)
        XCTAssertEqual(f.bitRate, 64_000)
        XCTAssertEqual(f.sampleRate, 48_000)
        XCTAssertEqual(f.channels, 1)
        XCTAssertEqual(f.codec.rawValue, "aac")
        XCTAssertEqual(f.bytesPerHour, 28_800_000)
        XCTAssertEqual(f.sizePerHourText, "29 MB per hour")
        XCTAssertEqual(f.normalized(), f)
    }

    func testNormalizedKeepsOnlyOfferedChoices() {
        XCTAssertEqual(RecordingFormat(codec: .aac, bitRate: 70_000, sampleRate: 24_000, channels: 5).normalized(),
                       RecordingFormat(codec: .aac, bitRate: 64_000, sampleRate: 48_000, channels: 2))
        // Every choice of the Settings panel (docs/attachments.md §15) is kept as it is.
        XCTAssertEqual(RecordingFormat(codec: .aac, bitRate: 24_000, sampleRate: 22_050, channels: 1).normalized(),
                       RecordingFormat(codec: .aac, bitRate: 24_000, sampleRate: 22_050, channels: 1))
        XCTAssertEqual(RecordingFormat(codec: .heAAC, bitRate: 64_000, sampleRate: 32_000, channels: 1).normalized(),
                       RecordingFormat(codec: .heAAC, bitRate: 64_000, sampleRate: 32_000, channels: 1))
        XCTAssertEqual(RecordingFormat(codec: .alac, bitRate: 64_000, sampleRate: 44_100, channels: 0).normalized(),
                       RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 44_100, channels: 1))
        XCTAssertEqual(RecordingFormat(codec: .heAAC, bitRate: 128_000, sampleRate: 16_000, channels: 1).normalized(),
                       RecordingFormat(codec: .heAAC, bitRate: 64_000, sampleRate: 48_000, channels: 1))
        XCTAssertEqual(RecordingFormat(codec: .heAAC, bitRate: nil, sampleRate: 48_000, channels: 1).normalized().bitRate, 32_000)
        XCTAssertEqual(RecordingFormat.Codec(rawValue: "he-aac"), .heAAC)
    }

    func testSizePerHourForEachCodec() {
        XCTAssertEqual(RecordingFormat(codec: .heAAC, bitRate: 32_000, sampleRate: 48_000, channels: 1).bytesPerHour, 14_400_000)
        // ALAC: about half of 16-bit PCM.
        XCTAssertEqual(RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 48_000, channels: 1).bytesPerHour, 172_800_000)
        XCTAssertEqual(RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 48_000, channels: 1).sizePerHourText, "173 MB per hour")
    }
}

final class RecordingTimelineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testPositionFollowsTheWallClockWhileRecording() {
        var tl = RecordingTimeline()
        XCTAssertNil(tl.position(at: at(0)))
        tl.resume(at: at(0))
        XCTAssertEqual(tl.started, at(0))
        XCTAssertNil(tl.position(at: at(-1)), "before the first sample: not linked")
        XCTAssertEqual(tl.position(at: at(12.345))!, 12.345, accuracy: 1e-6)
        XCTAssertEqual(tl.link(UUID(), at: at(12.3456))?.at, 12.346)
    }

    /// An interruption (a call) pauses the audio: strokes after it map to
    /// audio time, not wall time, within 0.1 s (attachments.md §14 E4).
    func testInterruptionPausesTheAudioTimeline() {
        var tl = RecordingTimeline()
        tl.resume(at: at(0))
        tl.pause(at: at(10))          // interruption began
        XCTAssertFalse(tl.isRunning)
        XCTAssertEqual(tl.position(at: at(15))!, 10, accuracy: 1e-9, "during the pause: where the audio resumes")
        tl.resume(at: at(30))         // interruption ended: 20 s of wall time not recorded
        XCTAssertEqual(tl.position(at: at(35))!, 15, accuracy: 0.1)
        XCTAssertEqual(tl.audioLength(at: at(40)), 20, accuracy: 1e-9)
        tl.pause(at: at(40)); tl.resume(at: at(41)); tl.stop(at: at(50))
        XCTAssertEqual(tl.position(at: at(45))!, 24, accuracy: 1e-9)
        XCTAssertEqual(tl.audioLength(at: at(100)), 29, accuracy: 1e-9)
        XCTAssertNil(tl.position(at: at(51)), "after stop: not linked")
        XCTAssertEqual(tl.runs.count, 3)
        tl.resume(at: at(60))
        XCTAssertEqual(tl.runs.count, 3, "no resume after stop")
    }

    func testDoublePauseAndResumeAreIgnored() {
        var tl = RecordingTimeline()
        tl.pause(at: at(1))
        XCTAssertTrue(tl.runs.isEmpty)
        tl.resume(at: at(0)); tl.resume(at: at(5))
        XCTAssertEqual(tl.runs.count, 1)
        tl.pause(at: at(6)); tl.pause(at: at(8))
        XCTAssertEqual(tl.audioLength(at: at(9)), 6, accuracy: 1e-9)
    }

    func testClockGoingBackwardsNeverOverlapsRuns() {
        var tl = RecordingTimeline()
        tl.resume(at: at(0)); tl.pause(at: at(10))
        tl.resume(at: at(5))   // wall clock set back
        XCTAssertEqual(tl.runs[1].wallStart, at(10))
        XCTAssertEqual(tl.position(at: at(12))!, 12, accuracy: 1e-9)
    }
}

final class RecordingSyncTests: XCTestCase {
    let rec = UUID()

    func stroke(_ pts: [(Double, Double)], at: Double?, rec r: UUID? = nil, width: Double = 2,
                transform: Transform? = nil) -> Stroke {
        Stroke(ink: Ink(tool: .pen, color: .black, width: width),
               points: pts.map { StrokePoint(x: $0.0, y: $0.1, w: width, h: width) },
               transform: transform, rec: at.map { RecordingLink(id: r ?? rec, at: $0) })
    }

    func state(_ recordings: [Recording]) -> NoteState {
        NoteState(deleted: false, meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), pages: [], recordings: recordings)
    }

    func recording(id: UUID, duration: Double? = 60, parent: UUID? = nil) -> Recording {
        Recording(id: id, blob: BlobRef(content: Data([1]), type: "audio/mp4"), started: Date(timeIntervalSince1970: 0),
                  duration: duration, parent: parent)
    }

    func testHitFindsTheNearestStrokeWithinTolerance() {
        let a = stroke([(0, 0), (100, 0)], at: 5)
        let b = stroke([(0, 20), (100, 20)], at: 9)
        XCTAssertEqual(RecordingSync.hit(x: 50, y: 4, in: [a, b]).map(\.id), [a.id])
        XCTAssertEqual(RecordingSync.hit(x: 50, y: 10, in: [a, b]).count, 2)
        XCTAssertEqual(RecordingSync.hit(x: 50, y: 18, in: [a, b], tolerance: 5).map(\.id), [b.id])
        XCTAssertTrue(RecordingSync.hit(x: 300, y: 300, in: [a, b]).isEmpty)
        // The transform moves the stroke on the page.
        let moved = stroke([(0, 0), (10, 0)], at: 1, transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 200, ty: 200))
        XCTAssertEqual(RecordingSync.hit(x: 205, y: 200, in: [moved], tolerance: 2).map(\.id), [moved.id])
        XCTAssertTrue(RecordingSync.hit(x: 5, y: 0, in: [moved], tolerance: 2).isEmpty)
    }

    func testSeekTargetUsesTheEarliestLinkMinusLeadIn() {
        let s = state([recording(id: rec, duration: 30)])
        let target = RecordingSync.seekTarget(for: [stroke([(0, 0)], at: 10), stroke([(0, 0)], at: 7.5)], in: s)
        XCTAssertEqual(target?.recording.id, rec)
        XCTAssertEqual(target?.time, 5.5)
        XCTAssertEqual(RecordingSync.seekTarget(for: [stroke([(0, 0)], at: 1)], in: s)?.time, 0)
        XCTAssertEqual(RecordingSync.seekTarget(for: [stroke([(0, 0)], at: 90)], in: s)?.time, 30, "clamped to the duration")
        XCTAssertNil(RecordingSync.seekTarget(for: [stroke([(0, 0)], at: nil)], in: s))
        XCTAssertNil(RecordingSync.seekTarget(for: [stroke([(0, 0)], at: 3, rec: UUID())], in: s), "a missing recording is ignored")
    }

    func testLinksFollowARestoredRecordingsParent() {
        let restored = UUID()
        let s = state([recording(id: restored, parent: rec)])
        XCTAssertEqual(RecordingSync.seekTarget(for: [stroke([(0, 0)], at: 10)], in: s)?.recording.id, restored)
        let strokes = [stroke([(0, 0)], at: 10), stroke([(0, 0)], at: 10, rec: UUID())]
        XCTAssertEqual(RecordingSync.linked(strokes, to: restored, in: s).map(\.id), [strokes[0].id])
    }

    func testHighlightedStrokesAreThoseDrawnInTheWindowBeforeThePosition() {
        let s = state([recording(id: rec)])
        let early = stroke([(0, 0)], at: 1), mid = stroke([(0, 0)], at: 9), late = stroke([(0, 0)], at: 12)
        let other = stroke([(0, 0)], at: 9, rec: UUID())
        XCTAssertEqual(RecordingSync.highlighted([early, mid, late, other], recording: rec, at: 10, in: s), [mid.id])
        XCTAssertEqual(RecordingSync.highlighted([early, mid, late], recording: rec, at: .nan, in: s), [])
    }

    func testBoxIncludesHalfTheWidth() {
        let b = RecordingSync.box(of: stroke([(10, 10), (20, 30)], at: nil, width: 4))
        XCTAssertEqual(b, Recognition.Box(x: 8, y: 8, w: 14, h: 24))
        XCTAssertNil(RecordingSync.box(of: stroke([], at: nil)))
    }
}

final class TranscriptBuilderTests: XCTestCase {
    func w(_ t: String, _ s: Double, _ e: Double, _ c: Double? = 0.9) -> RecognizedSpan {
        RecognizedSpan(text: t, start: s, end: e, confidence: c)
    }

    func testWordsAreGroupedAtPausesAndSentences() {
        let segs = TranscriptBuilder.segments(fromWords: [
            w("Today", 0.5, 0.8), w("we", 0.8, 0.9), w("start.", 0.9, 1.6),
            w("Linear", 1.7, 2.0, 0.5), w("maps", 2.0, 2.4, 0.7),
            w("next", 4.0, 4.3),   // after a pause
        ])
        XCTAssertEqual(segs.map(\.text), ["Today we start.", "Linear maps", "next"])
        XCTAssertEqual(segs[1].confidence!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(segs[0].words?.map(\.t), ["Today", "we", "start."])
        let t = TranscriptBuilder.transcript(recording: UUID(), engine: "apple-sfspeech-26.7", language: "en-US",
                                             created: Date(timeIntervalSince1970: 0), segments: segs)
        XCTAssertNil(t.validationError)
        let decoded = try? Transcript.decode(try t.encoded())
        XCTAssertEqual(decoded, t)
    }

    func testLongSpeechIsCutIntoBoundedSegments() {
        let words = (0..<100).map { i in w("w\(i)", Double(i) * 0.5, Double(i) * 0.5 + 0.4) }
        let segs = TranscriptBuilder.segments(fromWords: words)
        XCTAssertTrue(segs.allSatisfy { $0.end - $0.start <= TranscriptBuilder.maxSegmentSeconds })
        XCTAssertEqual(segs.flatMap { $0.words ?? [] }.count, 100)
    }

    /// Whatever a recogniser returns (overlaps, NaN, confidences outside
    /// 0…1, words outside their phrase) becomes a valid transcript.
    func testHostileRecogniserOutputIsSanitized() {
        let phrases: [(text: String, start: Double, end: Double, confidence: Double?, words: [RecognizedSpan])] = [
            ("second", 5, 3, 2, [w("second", 4, 6, -1)]),
            ("first", 0, 10, nil, [w("a", 2, 1), w("b", .nan, 3), w("c", 1, .infinity), w(" ", 1, 2)]),
            ("", .nan, 1, nil, []),
            ("third", 9, 12, 0.5, [w("third", 11, 13)]),
        ]
        let segs = TranscriptBuilder.segments(fromPhrases: phrases)
        let t = Transcript(recording: UUID(), engine: "x", language: "en", created: Date(), segments: segs)
        XCTAssertNil(t.validationError)
        XCTAssertEqual(segs.map(\.text), ["first", "second", "third"])
        XCTAssertNoThrow(try Transcript.decode(try t.encoded()))
    }

    func testPlainTextAndPositionLookup() {
        let segs = TranscriptBuilder.segments(fromWords: [w("Hello", 0, 0.5), w("there.", 0.5, 1.2), w("Bye", 3700, 3701)])
        let t = TranscriptBuilder.transcript(recording: UUID(), engine: "e", language: "en", segments: segs)
        XCTAssertEqual(t.plainText, "[0:00] Hello there.\n[1:01:40] Bye\n")
        XCTAssertEqual(t.position(at: 0.7)?.segment, 0)
        XCTAssertEqual(t.position(at: 0.7)?.word, 1)
        XCTAssertNil(t.position(at: 2))
        XCTAssertEqual(t.position(at: 3700.5)?.segment, 1)
        XCTAssertNil(t.position(at: .nan))
    }
}

final class TranscriptionLanguageTests: XCTestCase {
    func testTags() {
        XCTAssertEqual(TranscriptionLanguage.tag("en_US"), "en-US")
        XCTAssertEqual(TranscriptionLanguage.tag("zh-Hans_CN"), "zh-Hans-CN")
        XCTAssertEqual(TranscriptionLanguage.tag("es_ES@calendar=gregorian"), "es-ES")
        XCTAssertNil(TranscriptionLanguage.tag(""))
        XCTAssertNil(TranscriptionLanguage.tag("1x"))
        XCTAssertNil(TranscriptionLanguage.tag("en--US"))
    }

    func testNoteLanguageWinsOverTheDevice() {
        XCTAssertEqual(TranscriptionLanguage.choose(note: "es-ES", device: "en_US"), "es-ES")
        XCTAssertEqual(TranscriptionLanguage.choose(note: nil, device: "en_US"), "en-US")
        XCTAssertEqual(TranscriptionLanguage.choose(requested: "fr", note: "es", device: "en_US"), "fr")
        XCTAssertEqual(TranscriptionLanguage.choose(note: "bad tag!", device: "en_GB"), "en-GB")
    }

    func testMatchingSupportedLocales() {
        let supported = ["en_US", "en_GB", "es_MX", "es_ES", "de_DE"]
        XCTAssertEqual(TranscriptionLanguage.choose(note: "EN-gb", device: "en_US", supported: supported), "en-GB")
        XCTAssertEqual(TranscriptionLanguage.choose(note: "es", device: "en_MX", supported: supported), "es-MX",
                       "same language, the device's region")
        XCTAssertEqual(TranscriptionLanguage.choose(note: "es", device: "en_US", supported: supported), "es-ES",
                       "else the first by tag")
        XCTAssertEqual(TranscriptionLanguage.choose(note: "en-AU", device: "en_AU", supported: supported), "en-GB")
        XCTAssertNil(TranscriptionLanguage.choose(note: "ja", device: "ja_JP", supported: supported))
    }

    func testEngineNames() {
        XCTAssertEqual(TranscriptionEngine.speechTranscriber.name(osMajor: 26, osMinor: 7), "apple-speechtranscriber-26.7")
        XCTAssertEqual(TranscriptionEngine.sfSpeech.name(osMajor: 26, osMinor: 0), "apple-sfspeech-26.0")
    }
}
