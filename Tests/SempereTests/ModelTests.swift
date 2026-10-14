import Foundation
import XCTest
@testable import Sempere

final class ModelTests: XCTestCase {
    func testStrokeRoundTripUsesWireShape() throws {
        let id = UUID(uuidString: "0D1C6A1E-9A44-4A6C-8A6B-0E2A0E9B1F3C")!
        let s = Stroke(id: id, ink: Ink(tool: .pen, color: Color(hex: "#1A1A1AFF")!, width: 2.5),
                       points: [StrokePoint(x: 1.23456, y: 2, w: 3, h: 3)])
        let data = try InkJSON.encoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"id\":\"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c\""), json)
        XCTAssertTrue(json.contains("\"points\":[[1.235,2,0,3,3,1,0,0,1.571]]"), json)
        XCTAssertFalse(json.contains("transform"), "identity transform is omitted")
        let back = try InkJSON.decoder().decode(Stroke.self, from: data)
        XCTAssertEqual(back.id, id)
        XCTAssertEqual(back.ink.tool, .pen)
        XCTAssertEqual(back.points.count, 1)
    }

    func testUnknownToolDecodesAsPen() throws {
        let data = Data(##"{"tool":"laser","color":"#000000FF","width":1}"##.utf8)
        XCTAssertEqual(try InkJSON.decoder().decode(Ink.self, from: data).tool, .pen)
    }

    func testOpsRoundTrip() throws {
        let page = UUID()
        let ops: [Op] = [
            .addPage(Page(id: page, order: "a0")),
            .addStroke(page: page, stroke: Stroke(ink: Ink(tool: .marker, color: .black, width: 4),
                                                   points: [StrokePoint(x: 0, y: 0, w: 4, h: 4, al: 1.571)])),
            .removeStroke(page: page, strokeId: UUID()),
            .setPageOrder(pageId: page, order: "a1"),
            .setPageRecognition(pageId: page, recognition: Recognition(
                engine: "pencilkit-27.0", text: "Lecture 3",
                words: [.init(text: "Lecture", box: .init(x: 52.5, y: 40, w: 96.25, h: 30.5))])),
            .setPageRecognition(pageId: page, recognition: nil),
            .setMeta(.title("Lecture 3")),
            .addTag("math"), .addTag("fall"),
            .setMeta(.notebook(nil)),
            .setMeta(.favorite(true)),
            .setMeta(.paper(.ruled)),
            .setMeta(.pageSize(.a4)),
            .removePage(pageId: page),
            .deleteNote, .restoreNote,
        ]
        let data = try InkJSON.encoder().encode(ops)
        let back = try InkJSON.decoder().decode([Op].self, from: data)
        XCTAssertEqual(back, ops)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#"{"field":"notebook","op":"setMeta","value":null}"#), json)
        XCTAssertTrue(json.contains(#""words":[{"box":[52.5,40,96.25,30.5],"t":"Lecture"}]"#), json)
        XCTAssertTrue(json.contains(#""op":"setPageRecognition","pageId":"\#(page.uuidString.lowercased())","recognition":null}"#), json)
    }

    func testFormatExampleStateDecodes() throws {
        let json = """
        {"deleted":false,
         "meta":{"title":"Lecture 3","tags":["math","fall"],"notebook":"School","favorite":false,
                 "created":"2026-10-04T16:20:00Z",
                 "paper":{"kind":"ruled","spacing":24,"background":"#FFFFFFFF","lineColor":"#D0D8E8FF"},
                 "pageSize":{"width":612,"height":792,"infinite":false}},
         "pages":[{"id":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","order":"a0","strokes":[]}],
         "tagSet":{"instances":[{"tag":"math","origin":"17596320000000000-aaaaaaaa-1-0"},
                                {"tag":"fall","origin":"17596320000000000-aaaaaaaa-1-1"}],"removed":[]}}
        """
        let state = try InkJSON.decoder().decode(NoteState.self, from: Data(json.utf8))
        XCTAssertEqual(state.meta.title, "Lecture 3")
        XCTAssertEqual(state.meta.paper.kind, .ruled)
        XCTAssertEqual(state.pages.first?.order, "a0")
        let re = try InkJSON.encoder().encode(state)
        XCTAssertTrue(String(decoding: re, as: UTF8.self).contains("\"created\":\"2026-10-04T16:20:00.000Z\""))
    }
}
