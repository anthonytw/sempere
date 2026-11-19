import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// What a voice note shows as its title while it stores none (format.md §8.3.1 `captureInfo`, §16.8).
final class NoteDisplayTitleTests: VaultTestCase {
    let started = Date(timeIntervalSince1970: 1_794_857_520)   // 2026-11-16 19:32 UTC, 14:32 in New York
    let english = Locale(identifier: "en_US")
    let spanish = Locale(identifier: "es_ES")

    func origin(_ source: String? = "phone") -> VoiceOrigin {
        VoiceOrigin(started: started, tz: "America/New_York", source: source)
    }

    func testABlankTitleShowsTheSourceAndLocaleDefault() {
        let phone = NoteDisplayTitle.resolve(stored: "", origin: origin("phone"), generated: nil, locale: english)
        XCTAssertTrue(phone.hasPrefix("Voice note "), phone)
        XCTAssertTrue(phone.contains("2026") && phone.contains("2:32"), "the capture's own zone, not the reader's: " + phone)
        let watch = NoteDisplayTitle.resolve(stored: "  ", origin: origin("watch"), generated: nil, locale: english)
        XCTAssertTrue(watch.hasPrefix("Watch voice note "), watch)
        let es = NoteDisplayTitle.resolve(stored: "", origin: origin("phone"), generated: nil, words: .builtIn(locale: spanish), locale: spanish)
        XCTAssertTrue(es.hasPrefix("Nota de voz "), es)
        XCTAssertTrue(es.contains("14:32"), es)
        XCTAssertTrue(NoteDisplayTitle.resolve(stored: "", origin: origin(nil), generated: nil, locale: english).hasPrefix("Voice note "),
                      "no source: the plain words")
        XCTAssertEqual(NoteDisplayTitle.resolve(stored: "", origin: nil, generated: nil), "", "no voice recording: the caller says Untitled")
    }

    func testAGeneratedTitleReplacesABlankOrDefaultTitleButNeverAUsersTitle() {
        let g = "2026-11-16 14.32 Spring lab"
        XCTAssertEqual(NoteDisplayTitle.resolve(stored: "", origin: origin(), generated: g), g)
        // Notes of 1.0 through 1.2 stored their default.
        for stored in ["Voice note 2026-11-16 14:32", "Watch voice note 2026-11-16 14:32", "Nota de voz 2026-11-16 14:32",
                       "Nota de voz 16 nov 2026, 14:32", "Voice note Nov 16, 2026 at 2:32 PM"] {
            XCTAssertEqual(NoteDisplayTitle.resolve(stored: stored, origin: origin(), generated: g), g, stored)
            XCTAssertEqual(NoteDisplayTitle.resolve(stored: stored, origin: origin(), generated: nil), stored,
                           "a stored default with nothing generated shows as stored")
        }
        for stored in ["Groceries", "Lecture 3", "Call w/ Ana, Nov 16 2026 9:32"] {
            XCTAssertEqual(NoteDisplayTitle.resolve(stored: stored, origin: origin(), generated: g), stored, "a user's title wins")
        }
        XCTAssertEqual(NoteDisplayTitle.resolve(stored: "Voice note 2026-11-16 14:32", origin: nil, generated: g),
                       "Voice note 2026-11-16 14:32", "a title that merely looks like a default on a note with no voice recording is the user's")
        XCTAssertEqual(NoteDisplayTitle.resolve(stored: "", origin: nil, generated: g), "")
    }

    /// A title ending in a date stamp is a stored default only when the stamp is the capture's start: exactly in the
    /// capture's zone when it kept one, else in some zone within 14 hours whose minute agrees modulo 15.
    func testADateStampedRenameStaysTheUsersTitle() {
        let g = "Generated"
        XCTAssertEqual(NoteDisplayTitle.resolve(stored: "Lab 2026-10-01 09:00", origin: origin(), generated: g), "Lab 2026-10-01 09:00")
        XCTAssertFalse(NoteDisplayTitle.isStoredDefault("Lab 2026-10-01 09:00", origin: origin()))
        XCTAssertFalse(NoteDisplayTitle.isStoredDefault("Lab 2026-10-01 09:00", origin: VoiceOrigin(started: started)))
        // With the zone: only the capture's own clock.
        XCTAssertTrue(NoteDisplayTitle.isStoredDefault("Voice note 2026-11-16 14:32", origin: origin()))
        XCTAssertFalse(NoteDisplayTitle.isStoredDefault("Voice note 2026-11-16 19:32", origin: origin()), "UTC is not New York")
        // Without one (a note adopted before 1.3): any zone, whole, half or quarter hours from UTC, within 14 hours.
        let old = VoiceOrigin(started: started)
        for stamp in ["2026-11-16 14:32", "2026-11-16 19:32", "2026-11-17 01:02", "2026-11-17 01:17", "2026-11-16 05:32", "2026-11-17 09:32"] {
            XCTAssertTrue(NoteDisplayTitle.isStoredDefault("Voice note " + stamp, origin: old), stamp)
        }
        for stamp in ["2026-11-16 14:35", "2026-11-17 10:32", "2026-11-16 05:02", "2026-11-15 19:32"] {
            XCTAssertFalse(NoteDisplayTitle.isStoredDefault("Voice note " + stamp, origin: old), stamp)
        }
    }

    func testCaptureInfoReadsMalformedValuesAsAbsent() throws {
        let good = try JSONDecoder().decode(CaptureInfo.self, from: Data(#"{"tz":"Europe/Madrid","source":"watch"}"#.utf8))
        XCTAssertEqual(good, CaptureInfo(tz: "Europe/Madrid", source: "watch"))
        let bad = try JSONDecoder().decode(CaptureInfo.self, from: Data(#"{"tz":"Mars/Olympus","source":"fridge"}"#.utf8))
        XCTAssertTrue(bad.isEmpty)
        let wrongType = try JSONDecoder().decode(CaptureInfo.self, from: Data(#"{"tz":5,"source":["phone"]}"#.utf8))
        XCTAssertTrue(wrongType.isEmpty)
    }

    func testARecordingKeepsItsCaptureInfoAndAnOlderOneHasNone() throws {
        let ref = BlobRef(content: Data("a".utf8), type: "audio/mp4")
        var r = Recording(blob: ref, started: started)
        r.captureInfo = CaptureInfo(tz: "America/New_York", source: "phone")
        let back = try InkJSON.decoder().decode(Recording.self, from: try InkJSON.encoder().encode(r))
        XCTAssertEqual(back.captureInfo, r.captureInfo)
        let plain = try InkJSON.decoder().decode(Recording.self, from: try InkJSON.encoder().encode(Recording(blob: ref, started: started)))
        XCTAssertNil(plain.captureInfo)
        // An immutable field: a `setRecording` may not name it.
        XCTAssertThrowsError(try RecordingChange(field: "captureInfo", value: .object(["tz": .string("UTC")])))
    }

    /// A capture stores no title; adoption puts its zone and source on the recording, and the summary carries them for the list.
    func testAdoptionStoresNoTitleAndKeepsTheCaptureInfo() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let id = pqIdentity()
        let vault = try makeVault(id)
        let profile = try vault.captureProfile(device: DeviceID("0badf00d")!)
        let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let capture = UUID()
        let writer = try CaptureWriter(profile: profile)
        try CaptureWriter.store(try writer.seal(audio: audio, started: started, source: "watch",
                                                timeZone: TimeZone(identifier: "Asia/Tokyo")!, id: capture), in: vault.inboxURL)
        let r = vault.adoptCapture(capture, deviceState: tmp.appendingPathComponent("dev.json"), app: "test/1")
        XCTAssertNil(r.error)
        let note = CaptureAdoption.ids(for: capture).note
        let state = try vault.reconstruct(noteId: note)
        XCTAssertEqual(state.meta.title, "")
        XCTAssertEqual(state.recordings.first?.captureInfo, CaptureInfo(tz: "Asia/Tokyo", source: "watch"))
        let summary = try XCTUnwrap(vault.summaries(of: [note], cache: nil).first)
        XCTAssertEqual(summary.voice, VoiceOrigin(started: started, tz: "Asia/Tokyo", source: "watch"))
        XCTAssertTrue(summary.displayTitle(locale: english).hasPrefix("Watch voice note "))
        // The title the user types afterwards is what is shown.
        _ = try vault.apply(NoteOps.rename(to: "Standup", state: state), to: note, deviceState: tmp.appendingPathComponent("dev.json"), app: "test/1")
        let renamed = try XCTUnwrap(vault.summaries(of: [note], cache: nil).first)
        XCTAssertEqual(renamed.displayTitle(generated: "Generated"), "Standup")
    }

    /// A capture of 1.0 through 1.2 has no `tz` or `source`: it still reads, and adopts with no capture info.
    func testAnOlderManifestHasNoCaptureInfo() throws {
        let ref = BlobRef(content: Data("a".utf8), type: "audio/mp4")
        let m = CaptureManifest(id: UUID(), device: "0badf00d", vault: UUID(), created: started, started: started,
                                title: "Voice note 2026-11-16 14:32", notebook: nil, audio: ref, recipient: String(repeating: "a", count: 64))
        XCTAssertNil(m.captureInfo)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try InkJSON.encoder().encode(m)) as? [String: Any])
        XCTAssertNil(obj["tz"]); XCTAssertNil(obj["source"])
        obj["tz"] = "nonsense"; obj["source"] = 7
        let back = try InkJSON.decoder().decode(CaptureManifest.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.captureInfo, "values of another shape read as absent")
    }
}
