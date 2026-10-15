import XCTest
@testable import Sempere

/// New items placed without a frame land below the page's items, never on
/// them (TestFlight 1.0.0: a second recording's card and a second clip landed
/// on the first): `NoteOps.unoccupied`, used by the builders' default
/// placements, which the app and the CLI share.
final class ItemSpotTests: XCTestCase {
    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, background: Bool = false) -> Item {
        Item(kind: .image, layer: background ? .background : .content, frame: Rect(x: x, y: y, w: w, h: h), z: "a")
    }

    func testAFreeSpotStaysWhereItIs() {
        let frame = Rect(x: 100, y: 36, w: 200, h: 100)
        XCTAssertEqual(NoteOps.unoccupied(frame, among: [], pageSize: .letter), frame)
        XCTAssertEqual(NoteOps.unoccupied(frame, among: [box(400, 36, 100, 100)], pageSize: .letter), frame, "beside it, not on it")
    }

    func testItGoesBelowEveryItemItWouldCover() {
        let frame = Rect(x: 100, y: 36, w: 200, h: 100)
        let first = box(150, 30, 100, 80)        // covered: bottom 110
        let second = box(0, 120, 400, 50)        // covered after the first move: bottom 170
        let moved = NoteOps.unoccupied(frame, among: [first, second], pageSize: .letter)
        XCTAssertEqual(moved, Rect(x: 100, y: 170 + NoteOps.stackGap, w: 200, h: 100))
        let lowest = NoteOps.unoccupied(frame, among: [second, first, box(120, 60, 10, 10)], pageSize: .letter)
        XCTAssertEqual(lowest.y, 170 + NoteOps.stackGap, "the order of the items does not matter")
    }

    func testBackgroundsAndTurnedItems() {
        let frame = Rect(x: 100, y: 36, w: 200, h: 100)
        let pdf = box(0, 0, 612, 792, background: true)
        XCTAssertEqual(NoteOps.unoccupied(frame, among: [pdf], pageSize: .letter), frame, "a PDF page under the ink is not in the way")
        var turned = box(300, 0, 100, 20)        // turned 90°: its bounds reach x 340...360, y -40...60
        turned.rotation = 90
        XCTAssertEqual(NoteOps.unoccupied(frame, among: [turned], pageSize: .letter), frame, "turned, its bounds start at x 340: clear")
        turned.frame = Rect(x: 250, y: 0, w: 100, h: 20)   // bounds x 290...310: covered
        XCTAssertGreaterThan(NoteOps.unoccupied(frame, among: [turned], pageSize: .letter).y, 36)
    }

    func testNoRoomOnAFinitePageKeepsTheFrame() {
        let frame = Rect(x: 100, y: 600, w: 200, h: 100)
        let blocker = box(0, 590, 612, 150)       // below it would end at 752 + 12 + 100 > 792
        XCTAssertEqual(NoteOps.unoccupied(frame, among: [blocker], pageSize: .letter), frame)
        var infinite = PageSize.letter
        infinite.infinite = true
        XCTAssertEqual(NoteOps.unoccupied(frame, among: [blocker], pageSize: infinite).y, 740 + NoteOps.stackGap,
                       "an infinite page has room below")
        let bad = Rect(x: .nan, y: 0, w: 1, h: 1)
        XCTAssertTrue(NoteOps.unoccupied(bad, among: [blocker], pageSize: .letter).x.isNaN, "not finite: unchanged")
    }

    func testTheBuildersPlaceBelowTheLastItem() throws {
        let recording = Recording(id: UUID(), blob: BlobRef(content: Data("a".utf8), type: "audio/mp4"),
                                  started: Date(timeIntervalSince1970: 0), duration: 1)
        var page = Page(id: UUID(), order: "a0")
        let first = try NoteOps.placeRecording(recording.id, recordings: [recording], on: page, pageSize: .letter).item
        page.items = [first]
        let second = try NoteOps.placeRecording(recording.id, recordings: [recording], on: page, pageSize: .letter).item
        XCTAssertEqual(second.frame.y, first.frame.y + first.frame.h + NoteOps.stackGap)
        XCTAssertEqual(second.frame.x, first.frame.x)
        let given = try NoteOps.placeRecording(recording.id, recordings: [recording], on: page, pageSize: .letter,
                                               at: (first.frame.x, first.frame.y)).item
        XCTAssertEqual(given.frame.y, first.frame.y, "a position the caller gave is kept")

        let blob = BlobRef(content: Data("i".utf8), type: "image/png")
        var p = Page(id: UUID(), order: "a0")
        let a = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 100, h: 50), on: p, pageSize: .letter).item
        p.items = [a]
        let b = try NoteOps.placeImage(blob: blob, pixelSize: Size(w: 100, h: 50), on: p, pageSize: .letter).item
        XCTAssertGreaterThanOrEqual(b.frame.y, a.frame.y + a.frame.h)
    }
}
