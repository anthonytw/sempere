import Foundation
import XCTest
@testable import Sempere

/// Encodings checked byte-for-byte against hand-written JSON in the shape of
/// docs/format.md §5.1–§5.5 (the encoder sorts keys).
final class RevisionJSONTests: XCTestCase {
    let page = UUID(uuidString: "7E57C0DE-0000-4000-8000-000000000001")!
    let gone = UUID(uuidString: "7E57C0DE-0000-4000-8000-000000000002")!

    func date(_ s: String) throws -> Date {
        try InkJSON.decoder().decode([Date].self, from: Data(#"["\#(s)"]"#.utf8))[0]
    }

    func testDeltaMatchesSpecJSON() throws {
        let rev = Revision(noteId: testNote, device: DeviceID("a1b2c3d4")!, seq: 12, hlc: HLC("17596320000000003")!,
                           wall: try date("2026-10-04T16:20:00.123Z"), app: "sempere-ios/0.1",
                           body: .delta(ops: [.addPage(Page(id: page, order: "a0")), .setMeta(.title("Lecture 3")),
                                              .deleteNote]))
        let expected = #"{"app":"sempere-ios/0.1","device":"a1b2c3d4","hlc":"17596320000000003","#
            + #""noteId":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","#
            + #""ops":[{"op":"addPage","page":{"id":"7e57c0de-0000-4000-8000-000000000001","order":"a0","strokes":[]}},"#
            + #"{"field":"title","op":"setMeta","value":"Lecture 3"},{"op":"deleteNote"}],"#
            + #""seq":12,"type":"delta","wall":"2026-10-04T16:20:00.123Z"}"#
        let data = try InkJSON.encoder().encode(rev)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: Data(expected.utf8)), rev)
        XCTAssertEqual(rev.name.filename, "17596320000000003-a1b2c3d4-12.delta.age")
    }

    func testSnapshotMatchesSpecJSON() throws {
        let state = NoteState(
            deleted: false,
            meta: NoteMeta(title: "Lecture 3", tags: ["math", "fall"], notebook: "School", favorite: false,
                           created: try date("2026-10-04T16:20:00Z"), paper: .ruled, pageSize: .letter),
            pages: [Page(id: page, order: "a0", orderClock: "17596320000000001-a1b2c3d4")],
            clocks: ["title": "17596320000000002-99ee00ff"],
            tombstones: Tombstones(strokes: [gone]),
            tagSet: TagSet(instances: [.init(tag: "math", origin: Origin("17596320000000003-a1b2c3d4-12-0")!),
                                       .init(tag: "fall", origin: Origin("17596320000000003-a1b2c3d4-12-1")!)]))
        let rev = Revision(noteId: testNote, device: DeviceID("a1b2c3d4")!, seq: 17, hlc: HLC("17596320000000009")!,
                           wall: try date("2026-10-04T16:20:00.500Z"), app: "sempere-ios/0.1",
                           body: .snapshot(included: Included([DeviceID("a1b2c3d4")!: .init(upTo: 12, extra: [15, 16]),
                                                               DeviceID("99ee00ff")!: .init(upTo: 3)]),
                                           state: state))
        let expected = #"{"app":"sempere-ios/0.1","device":"a1b2c3d4","hlc":"17596320000000009","#
            + #""included":{"99ee00ff":{"extra":[],"upTo":3},"a1b2c3d4":{"extra":[15,16],"upTo":12}},"#
            + #""noteId":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","seq":17,"#
            + #""state":{"clocks":{"title":"17596320000000002-99ee00ff"},"deleted":false,"#
            + #""meta":{"created":"2026-10-04T16:20:00.000Z","favorite":false,"notebook":"School","#
            + #""pageSize":{"height":792,"infinite":false,"width":612},"#
            + ##""paper":{"background":"#FFFFFFFF","kind":"ruled","lineColor":"#D0D8E8FF","spacing":24},"##
            + #""tags":["math","fall"],"title":"Lecture 3"},"#
            + #""pages":[{"id":"7e57c0de-0000-4000-8000-000000000001","order":"a0","#
            + #""orderClock":"17596320000000001-a1b2c3d4","strokes":[]}],"#
            + #""tagSet":{"instances":[{"origin":"17596320000000003-a1b2c3d4-12-0","tag":"math"},"#
            + #"{"origin":"17596320000000003-a1b2c3d4-12-1","tag":"fall"}],"removed":[]},"#
            + #""tombstones":{"strokes":["7e57c0de-0000-4000-8000-000000000002"]}},"#
            + #""type":"snapshot","wall":"2026-10-04T16:20:00.500Z"}"#
        let data = try InkJSON.encoder().encode(rev)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: Data(expected.utf8)), rev)
        XCTAssertEqual(rev.name.filename, "17596320000000009-a1b2c3d4-17.snapshot.age")
    }

    func testOptionalStateFieldsOmittedWhenEmpty() throws {
        let state = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)),
                              pages: [Page(id: page, order: "a0")], clocks: [:], tombstones: Tombstones())
        let json = String(decoding: try InkJSON.encoder().encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("clocks"), json)
        XCTAssertFalse(json.contains("tombstones"), json)
        XCTAssertFalse(json.contains("orderClock"), json)
        // Pre-amendment snapshots (no clocks/tombstones) still decode.
        let back = try InkJSON.decoder().decode(NoteState.self, from: Data(json.utf8))
        XCTAssertNil(back.clocks)
        XCTAssertNil(back.tombstones)
        XCTAssertNil(back.pages[0].orderClock)
    }

    func testRejectsUnknownTypeAndBadFields() {
        let good = #"{"app":"x","device":"a1b2c3d4","hlc":"17596320000000003","noteId":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","ops":[],"seq":1,"type":"delta","wall":"2026-10-04T16:20:00Z"}"#
        XCTAssertNoThrow(try InkJSON.decoder().decode(Revision.self, from: Data(good.utf8)))
        for (from, to) in [(#""type":"delta""#, #""type":"patch""#), (#""hlc":"17596320000000003""#, #""hlc":"1""#),
                           (#""device":"a1b2c3d4""#, #""device":"A1B2C3D4""#), (#""seq":1"#, #""seq":0"#)] {
            let bad = good.replacingOccurrences(of: from, with: to)
            XCTAssertThrowsError(try InkJSON.decoder().decode(Revision.self, from: Data(bad.utf8)), to)
        }
    }
}
