import Foundation
import XCTest

@testable import Sempere

/// `audio` items (format.md §8.2.9): a recording of the note placed on a
/// page. The item's wire form, its immutable `recording`, merge and
/// snapshots, the recording it shows (through a restored copy's `parent`),
/// the placement and removal builders, and the card's layout and label.
final class AudioItemTests: XCTestCase {
    static let recID = UUID(uuidString: "0d9e5c1a-0000-4000-8000-000000000001")!
    static let itemID = UUID(uuidString: "6f1c2d4e-0000-4000-8000-000000000003")!
    static let audio = BlobRef(sha256: String(repeating: "ab", count: 32), size: 28_311, type: "audio/mp4")

    static func recording(id: UUID = recID, title: String? = "Lecture 3", duration: Double? = 75.4,
                          parent: UUID? = nil) -> Recording {
        var r = Recording(id: id, blob: audio, started: Date(timeIntervalSince1970: 1_800_000_000), duration: duration,
                          title: title)
        r.parent = parent
        return r
    }

    func item(recording: UUID = recID) -> Item {
        Item.audio(id: Self.itemID, recording: recording, frame: Rect(x: 72, y: 144, w: 300, h: 96), z: "a3")
    }

    // MARK: Model

    func testRoundTripAndWireForm() throws {
        let json = try InkJSON.encoder().encode(item())
        let s = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(s.contains("\"kind\":\"audio\""), s)
        XCTAssertTrue(s.contains("\"recording\":\"0d9e5c1a-0000-4000-8000-000000000001\""), s)
        XCTAssertFalse(s.contains("blob"))
        XCTAssertEqual(try InkJSON.decoder().decode(Item.self, from: json), item())
        XCTAssertTrue(ItemKind.audio.isDefined)
        XCTAssertNil(item().validationError)
    }

    func testInvalidAudioItemsAreRejectedAndOtherKindsKeepTheField() throws {
        let base = #"{"id":"6f1c2d4e-0000-4000-8000-000000000003","kind":"audio","frame":[0,0,10,10],"z":"a""#
        XCTAssertNoThrow(try InkJSON.decoder().decode(Item.self, from: Data((base + #","recording":"0d9e5c1a-0000-4000-8000-000000000001"}"#).utf8)))
        for bad in [base + "}", base + #","recording":"not a uuid"}"#, base + #","recording":7}"#, base + #","recording":null}"#] {
            XCTAssertThrowsError(try InkJSON.decoder().decode(Item.self, from: Data(bad.utf8)), bad)
        }
        // `recording` on a text item is an unknown field there: kept, re-emitted.
        let text = #"{"id":"6f1c2d4e-0000-4000-8000-000000000003","kind":"text","frame":[0,0,10,10],"z":"a","#
            + ##""text":{"font":"sans","size":12,"color":"#000000FF","runs":[]},"recording":"x"}"##
        let decoded = try InkJSON.decoder().decode(Item.self, from: Data(text.utf8))
        XCTAssertNil(decoded.recording)
        XCTAssertEqual(decoded.extra["recording"], .string("x"))
        XCTAssertTrue(String(decoding: try InkJSON.encoder().encode(decoded), as: UTF8.self).contains("\"recording\":\"x\""))
        // A typed `recording` on another kind does not encode (it is no field of that kind).
        var wrong = Item.text(TextContent(size: 12, color: .black, runs: []), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a")
        wrong.recording = Self.recID
        XCTAssertNotNil(wrong.validationError)
    }

    func testRecordingIsImmutable() throws {
        XCTAssertThrowsError(try ItemChange(field: "recording", value: .string(Self.recID.uuidString.lowercased()))) {
            XCTAssertEqual($0 as? ItemChangeError, .immutableField("recording"))
        }
        XCTAssertNil(item().registers["recording"])
        XCTAssertEqual(Set(item().registers.keys), ["frame", "rotation", "z"])
        XCTAssertFalse(item().hasSameImmutableFields(as: item(recording: UUID())))
        XCTAssertTrue(item().hasSameImmutableFields(as: item()))
    }

    func testMergesAndSurvivesSnapshots() throws {
        var log = LogBuilder()
        let page = UUID()
        let a = item()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: page, order: "a0")), .addRecording(Self.recording()),
                                     .addItem(page: page, item: a)])
        let moved = Rect(x: 10, y: 20, w: 200, h: 64)
        let d2 = log.delta(devB, 10, [.setItem(page: page, itemId: a.id, change: .frame(moved))])
        for order in [[d1, d2], [d2, d1]] {
            let state = try NoteReducer.reconstruct(order)
            XCTAssertEqual(state.pages[0].items.map(\.frame), [moved])
            XCTAssertEqual(state.recording(shownBy: state.pages[0].items[0])?.id, Self.recID)
        }
        let snap = try log.snapshot(devB, 30, from: [d1, d2])
        let state = try NoteReducer.reconstruct([snap])
        XCTAssertEqual(state.pages[0].items[0].recording, Self.recID)
        XCTAssertEqual(state.pages[0].items[0].kind, .audio)
    }

    // MARK: Which recording an item shows

    func testRecordingShownFollowsARestoredCopysParent() {
        let restored = Self.recording(id: UUID(), parent: Self.recID)
        var state = NoteState(meta: NoteMeta(created: Date()), pages: [Page(order: "a", items: [item()])],
                              recordings: [restored])
        XCTAssertEqual(state.recording(shownBy: item())?.id, restored.id)
        XCTAssertEqual(state.audioItems(showing: restored.id).map(\.item.id), [Self.itemID])
        state.recordings = []
        XCTAssertNil(state.recording(shownBy: item()), "missing")
        XCTAssertNil(state.recording(shownBy: Item.text(TextContent(size: 1, color: .black, runs: []),
                                                         frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a")))
    }

    // MARK: Builders

    func testPlaceRecordingDefaults() throws {
        let page = Page(id: UUID(), order: "a0")
        let recs = [Self.recording()]
        let top = try NoteOps.placeRecording(Self.recID, recordings: recs, on: page, pageSize: .letter).item
        XCTAssertEqual(top.kind, .audio)
        XCTAssertEqual(top.recording, Self.recID)
        XCTAssertEqual(top.frame, Rect(x: (612 - 300) / 2, y: 36, w: 300, h: 96))
        XCTAssertNil(top.validationError)
        // Where the user is looking: centred across the visible part, a margin below its top.
        let seen = try NoteOps.placeRecording(Self.recID, recordings: recs, on: page, pageSize: .letter,
                                              visible: Rect(x: 0, y: 1000, w: 400, h: 500)).item
        XCTAssertEqual(seen.frame, Rect(x: 50, y: 1036, w: 300, h: 96))
        // A narrow view: narrower card.
        let narrow = try NoteOps.placeRecording(Self.recID, recordings: recs, on: page, pageSize: .letter,
                                                visible: Rect(x: 0, y: 0, w: 200, h: 80)).item
        XCTAssertEqual(narrow.frame.w, 128)
        XCTAssertEqual(narrow.frame.y, 0, "no room below the margin: the top of the view")
        let given = try NoteOps.placeRecording(Self.recID, recordings: recs, on: page, pageSize: .letter,
                                               frame: Rect(x: 1, y: 2, w: 3, h: 4)).item
        XCTAssertEqual(given.frame, Rect(x: 1, y: 2, w: 3, h: 4))
        let at = try NoteOps.placeRecording(Self.recID, recordings: recs, on: page, pageSize: .letter, at: (5, 6), width: 250).item
        XCTAssertEqual(at.frame, Rect(x: 5, y: 6, w: 250, h: 96))
        XCTAssertThrowsError(try NoteOps.placeRecording(UUID(), recordings: recs, on: page, pageSize: .letter)) {
            guard case .noSuchRecording = $0 as? AttachmentOpsError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try NoteOps.placeRecording(Self.recID, recordings: recs, on: page, pageSize: .letter, width: -1))
        // Above the page's other content items.
        var busy = page
        busy.items = [top]
        let second = try NoteOps.placeRecording(Self.recID, recordings: recs, on: busy, pageSize: .letter).item
        XCTAssertTrue(Item.drawsBefore(top, second))
    }

    func testRemoveRecordingRemovesItsItemsOnEveryPage() {
        let other = UUID()
        let p1 = Page(id: UUID(), order: "a", items: [item()])
        let keep = Item.audio(recording: other, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "b")
        let second = Item.audio(recording: Self.recID, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "c")
        let p2 = Page(id: UUID(), order: "b", items: [keep, second])
        let state = NoteState(meta: NoteMeta(created: Date()), pages: [p1, p2],
                              recordings: [Self.recording(), Self.recording(id: other)])
        let ops = NoteOps.removeRecording(Self.recID, in: state)
        XCTAssertEqual(ops, [.removeItem(page: p1.id, itemId: Self.itemID), .removeItem(page: p2.id, itemId: second.id),
                             .removeRecording(recordingId: Self.recID)])
        XCTAssertEqual(NoteOps.removeRecording(UUID(), in: state), [])
        XCTAssertEqual(NoteOps.copyableToOtherNote([item(), keep, p1.items[0]]).count, 0)
    }

    // MARK: The card

    func testCardLayout() throws {
        let card = AudioCard(frame: Rect(x: 72, y: 144, w: 300, h: 96))
        XCTAssertEqual(card.padding, 8)
        XCTAssertEqual(card.iconSize, 24)
        XCTAssertEqual(card.iconCenter.x, 72 + 8 + 12)
        XCTAssertEqual(card.iconCenter.y, 144 + 8 + 12)
        XCTAssertEqual(card.labelFrame, Rect(x: 72 + 16 + 24, y: 152, w: 300 - 24 - 24, h: 80))
        XCTAssertEqual(card.labelBottom, 144 + 96 - 8)
        // Small frames: p = 0.1 m, d = m − 2p.
        let small = AudioCard(frame: Rect(x: 0, y: 0, w: 20, h: 10))
        XCTAssertEqual(small.padding, 1)
        XCTAssertEqual(small.iconSize, 8)
        XCTAssertEqual(try XCTUnwrap(small.labelFrame).w, 20 - 3 - 8, accuracy: 1e-9)
        XCTAssertNil(AudioCard(frame: Rect(x: 0, y: 0, w: 10, h: 10)).labelFrame)
    }

    func testLabel() throws {
        let t = Transcript(recording: Self.recID, engine: "test", language: "es-ES", created: Date(),
                           segments: [.init(start: 0, end: 1, text: "Hola\n a  todos."), .init(start: 1, end: 2, text: "Bien.")])
        let label = AudioCard.label(Self.recording(title: "Clase 1"), transcript: t)
        XCTAssertEqual(label.string, "Clase 1 · 1:15\nHola a todos. Bien.")
        XCTAssertTrue(label.runs[0].b)
        XCTAssertEqual(label.runs[2].size, AudioCard.transcriptSize)
        XCTAssertEqual(label.runs[2].lang, "es-ES")
        XCTAssertNil(label.limitViolation)
        XCTAssertNoThrow(try InkJSON.encoder().encode(label))
        // No title, no duration, no transcript; titles of one line, cut.
        XCTAssertEqual(AudioCard.label(Self.recording(title: "  ", duration: nil), transcript: nil).string, "Recording")
        XCTAssertEqual(AudioCard.label(Self.recording(title: "a\nb\u{7}c", duration: 3_725), transcript: nil).string,
                       "a b c · 1:02:05")
        XCTAssertEqual(AudioCard.title(Self.recording(title: String(repeating: "x", count: 5_000))).count, AudioCard.titleLimit)
        // A long transcript is cut to its first 2 000 scalars.
        let long = Transcript(recording: Self.recID, engine: "t", language: "", created: Date(),
                              segments: (0..<1_000).map { .init(start: Double($0), end: Double($0) + 1, text: "word word") })
        let excerpt = try XCTUnwrap(AudioCard.excerpt(long))
        XCTAssertEqual(excerpt.unicodeScalars.count, AudioCard.transcriptLimit)
        XCTAssertNil(AudioCard.label(Self.recording(), transcript: long).runs[2].lang)
        XCTAssertNil(AudioCard.excerpt(Transcript(recording: Self.recID, engine: "t", language: "", created: Date(), segments: [])))
    }
}

/// The app's play control on a card: the icon and its badge, turned with the item.
final class AudioCardControlTests: XCTestCase {
    func testBadgeAndHitTest() {
        let card = AudioCard(frame: Rect(x: 0, y: 0, w: 300, h: 96))
        let badge = card.badge(rotation: nil)
        XCTAssertEqual(badge.center.x, 20 + 9.6, accuracy: 1e-9)
        XCTAssertEqual(badge.center.y, 20 + 9.6, accuracy: 1e-9)
        XCTAssertEqual(badge.diameter, 14.4, accuracy: 1e-9)
        XCTAssertTrue(card.controlContains(x: 20, y: 20, rotation: nil))           // the icon's centre
        XCTAssertTrue(card.controlContains(x: 32, y: 32, rotation: nil))           // on the badge, outside the icon
        XCTAssertFalse(card.controlContains(x: 150, y: 50, rotation: nil))         // the label
        XCTAssertFalse(card.controlContains(x: 33, y: 20, rotation: nil))
        XCTAssertTrue(card.controlContains(x: 33, y: 20, rotation: nil, slack: 2))
        // A half turn puts the icon at the opposite corner.
        XCTAssertTrue(card.controlContains(x: 280, y: 76, rotation: 180))
        XCTAssertFalse(card.controlContains(x: 20, y: 20, rotation: 180))
        let turned = card.badge(rotation: 180)
        XCTAssertEqual(turned.center.x, 300 - 29.6, accuracy: 1e-9)
        XCTAssertEqual(turned.center.y, 96 - 29.6, accuracy: 1e-9)
        XCTAssertFalse(card.controlContains(x: .nan, y: 0, rotation: nil))
    }
}
