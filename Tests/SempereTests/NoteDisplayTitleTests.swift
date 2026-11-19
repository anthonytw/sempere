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

/// The default title's formatters are made once per (locale, time zone) and used from any thread.
extension NoteDisplayTitleTests {
    func testDefaultTitlesAreStableAcrossLocalesZonesAndThreads() async {
        let ny = origin("phone"), tokyo = VoiceOrigin(started: started, tz: "Asia/Tokyo", source: "phone")
        let want = [NoteDisplayTitle.defaultTitle(for: ny, locale: english), NoteDisplayTitle.defaultTitle(for: tokyo, locale: english),
                    NoteDisplayTitle.defaultTitle(for: ny, locale: spanish)]
        XCTAssertEqual(Set(want).count, 3, "each (locale, zone) pair formats on its own: \(want)")
        XCTAssertTrue(want[0].contains("2:32") && want[1].contains("4:32"), "\(want)")
        let (e, s) = (english, spanish), (n, t, st) = (ny, tokyo, started)
        await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<50).flatMap { _ in
                        [NoteDisplayTitle.defaultTitle(for: n, locale: e), NoteDisplayTitle.defaultTitle(for: t, locale: e),
                         NoteDisplayTitle.defaultTitle(for: VoiceOrigin(started: st, tz: "America/New_York", source: "phone"), locale: s)]
                    }
                }
            }
            for await titles in group {
                for (i, title) in titles.enumerated() { XCTAssertEqual(title, want[i % 3]) }
            }
        }
    }

    /// Ask's label words leave out a voice note's default title whether it is made up or was stored by 1.0 through 1.2,
    /// while display still shows the stored one (`showsDefault` is false for it).
    func testAStoredDefaultOfAnOlderNoteIsNoChosenTitle() throws {
        let start = try XCTUnwrap(RFC3339.parse("2026-10-07T14:32:00Z"))
        let legacy = VoiceOrigin(started: start)   // adopted before 1.3: no zone
        let stored = "Voice note 2026-10-07 14:32"
        XCTAssertTrue(NoteDisplayTitle.isUnchosen(stored: stored, origin: legacy, generated: nil))
        XCTAssertFalse(NoteDisplayTitle.showsDefault(stored: stored, origin: legacy, generated: nil), "display is unchanged")
        XCTAssertEqual(NoteDisplayTitle.resolve(stored: stored, origin: legacy, generated: nil), stored)
        XCTAssertTrue(NoteDisplayTitle.isUnchosen(stored: "", origin: legacy, generated: nil))
        XCTAssertFalse(NoteDisplayTitle.isUnchosen(stored: stored, origin: legacy, generated: "2026-10-07 14.32 Lab"), "a derived title counts")
        XCTAssertFalse(NoteDisplayTitle.isUnchosen(stored: "Lab", origin: legacy, generated: nil), "the user's title counts")
        XCTAssertFalse(NoteDisplayTitle.isUnchosen(stored: stored, origin: nil, generated: nil), "no voice note: the stored title is chosen")
        var s = NoteSummary(id: UUID(), title: stored, tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0, modified: nil, problem: nil)
        s.voice = legacy
        XCTAssertTrue(s.hasUnchosenTitle())
    }

    func testShowsDefaultOnlyForTheMadeUpTitle() {
        XCTAssertTrue(NoteDisplayTitle.showsDefault(stored: "", origin: origin(), generated: nil))
        XCTAssertFalse(NoteDisplayTitle.showsDefault(stored: "", origin: origin(), generated: "2026-11-16 14.32 Lab"), "a derived title")
        XCTAssertFalse(NoteDisplayTitle.showsDefault(stored: "Lab", origin: origin(), generated: nil), "the user's title")
        XCTAssertFalse(NoteDisplayTitle.showsDefault(stored: "", origin: nil, generated: nil), "no voice recording: Untitled")
        XCTAssertFalse(NoteDisplayTitle.showsDefault(stored: "Voice note 2026-11-16 14:32", origin: origin(), generated: nil),
                       "a stored default shows as stored, which is the title the note has")
    }
}

/// What exports, Spotlight and `resolveNote` name a voice note by (format.md §16.8).
extension NoteDisplayTitleTests {
    func testShowingATitleNamesTheExportAndBlankChangesNothing() {
        let id = UUID()
        let s = NoteSummary(id: id, title: "", tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0, modified: nil, problem: nil)
        XCTAssertEqual(ExportName.stem(title: s.showing(title: "Voice note Nov 16").title, noteId: id), "Voice-note-Nov-16-\(id.uuidString.lowercased().prefix(8))")
        XCTAssertEqual(s.showing(title: "").title, "")
        XCTAssertEqual(s.showing(title: nil).title, "")
        XCTAssertEqual(s.showing(title: "  ").title, "")
    }

    func testFindTakesTheShownTitleAndACollisionWithAStoredTitleIsAmbiguous() throws {
        let origin = VoiceOrigin(started: started, tz: "America/New_York", source: "phone")
        func summary(_ title: String) -> NoteSummary {
            var s = NoteSummary(id: UUID(), title: title, tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0, modified: nil, problem: nil)
            s.voice = origin
            return s
        }
        let voice = summary(""), named = summary("Lab")
        let shown: ([NoteSummary]) -> [UUID: String] = { notes in Dictionary(uniqueKeysWithValues: notes.map { ($0.id, "Voice note X") }) }
        XCTAssertEqual(try NoteSummary.find("voice note x", in: [voice, named], shown: shown).id, voice.id)
        XCTAssertEqual(try NoteSummary.find("Lab", in: [voice, named], shown: shown).id, named.id)
        XCTAssertThrowsError(try NoteSummary.find("voice note x", in: [voice, named]))
        // One note's stored title that is another's shown title: ambiguous, both listed, never a silent pick.
        let typed = summary("Voice note X")
        XCTAssertThrowsError(try NoteSummary.find("Voice note X", in: [voice, typed, named], shown: shown)) { error in
            guard case NoteSummary.LookupError.ambiguous(_, let ids)? = error as? NoteSummary.LookupError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(Set(ids), [voice.id, typed.id])
        }
        XCTAssertEqual(try NoteSummary.find("Voice note X", in: [voice, typed, named]).id, typed.id, "without shown titles: the stored one")
    }
}

/// What a web page share shows as a voice note's title (docs/design/1.3-share.md): the capture's date and time only when
/// the share includes dates.
extension NoteDisplayTitleTests {
    func share(stored: String = "", origin: VoiceOrigin?, generated: String? = nil,
               format: String = VoiceNoteTitleFormat.defaultFormat, dates: Bool) -> String {
        NoteDisplayTitle.shareTitle(stored: stored, origin: origin, generated: generated, format: format, includeDates: dates,
                                    locale: english)
    }

    func testAShareWithDatesShowsTheShownTitle() {
        XCTAssertEqual(share(origin: origin(), dates: true),
                       NoteDisplayTitle.resolve(stored: "", origin: origin(), generated: nil, locale: english))
        XCTAssertEqual(share(origin: origin(), generated: "2026-11-16 14.32 Lab", dates: true), "2026-11-16 14.32 Lab")
        XCTAssertEqual(share(stored: "Voice note 2026-11-16 14:32", origin: origin(), dates: true), "Voice note 2026-11-16 14:32")
    }

    func testAShareWithoutDatesLeavesTheCaptureTimeOut() {
        XCTAssertEqual(share(origin: origin(), dates: false), "Voice note")
        XCTAssertEqual(share(origin: origin("watch"), dates: false), "Watch voice note")
        XCTAssertEqual(NoteDisplayTitle.shareTitle(stored: "", origin: origin(), generated: nil, format: "{slug}", includeDates: false,
                                                   locale: spanish), "Nota de voz", "the localized bare words")
        XCTAssertEqual(share(stored: "Voice note 2026-11-16 14:32", origin: origin(), dates: false), "Voice note",
                       "a default stored before 1.3 holds the capture time too")
        // A derived title: kept when its format has no date or time, else the bare words.
        XCTAssertEqual(share(origin: origin(), generated: "2026-11-16 14.32 Lab", dates: false), "Voice note")
        XCTAssertEqual(share(origin: origin(), generated: "Lab (14.32)", format: "{slug} ({time})", dates: false), "Voice note")
        XCTAssertEqual(share(origin: origin(), generated: "Lab", format: "{slug}", dates: false), "Lab")
        XCTAssertEqual(share(origin: origin(), generated: "2026-11-16 Lab", format: "{slug}", dates: false), "Voice note",
                       "a fallback title of another format that holds the capture's date")
        // A title the user entered, and a note that is no voice note, are kept.
        XCTAssertEqual(share(stored: "Lab 2026-10-01 09:00", origin: origin(), generated: "x", dates: false), "Lab 2026-10-01 09:00")
        XCTAssertEqual(share(stored: "Physics", origin: nil, dates: false), "Physics")
        XCTAssertEqual(share(stored: "", origin: nil, dates: false), "")
    }
}
