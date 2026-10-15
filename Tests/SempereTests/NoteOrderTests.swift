import Foundation
@testable import Sempere
import XCTest

/// `NoteOrder`: the note list's sorting (app and `notes list --sort`), and `NoteAttachments`.
final class NoteOrderTests: XCTestCase {
    private func note(_ n: Int, _ title: String, created: TimeInterval?, modified: TimeInterval?,
                      favorite: Bool = false) -> NoteSummary {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
        var s = NoteSummary(id: id, title: title, tags: [], notebook: nil, deleted: false, pages: 1, strokes: 0,
                            modified: modified.map(Date.init(timeIntervalSince1970:)), problem: nil)
        s.created = created.map(Date.init(timeIntervalSince1970:))
        s.favorite = favorite
        return s
    }

    private lazy var notes = [
        note(1, "Note 10", created: 100, modified: 900),
        note(2, "note 2", created: 300, modified: 500, favorite: true),
        note(3, "Alpha", created: 200, modified: 700),
        note(4, "Beta", created: nil, modified: nil, favorite: true),
        note(5, "Alpha", created: 200, modified: 700),
    ]

    private func titles(_ order: NoteOrder) -> [String] {
        order.sorted(notes).map { "\($0.title)#\($0.id.uuidString.suffix(1))" }
    }

    func testTitleIsFinderOrderWithTheIdBreakingTies() {
        XCTAssertEqual(titles(NoteOrder(.title)), ["Alpha#3", "Alpha#5", "Beta#4", "note 2#2", "Note 10#1"])
    }

    func testModifiedIsNewestFirstWithUndatedNotesLast() {
        XCTAssertEqual(titles(NoteOrder(.modified)), ["Note 10#1", "Alpha#3", "Alpha#5", "note 2#2", "Beta#4"])
    }

    func testCreatedIsNewestFirstWithUndatedNotesLast() {
        XCTAssertEqual(titles(NoteOrder(.created)), ["note 2#2", "Alpha#3", "Alpha#5", "Note 10#1", "Beta#4"])
    }

    func testFavoritesFirstKeepsTheOrderInsideEachGroup() {
        XCTAssertEqual(titles(NoteOrder(.title, favoritesFirst: true)), ["Beta#4", "note 2#2", "Alpha#3", "Alpha#5", "Note 10#1"])
        XCTAssertEqual(titles(NoteOrder(.modified, favoritesFirst: true)), ["note 2#2", "Beta#4", "Note 10#1", "Alpha#3", "Alpha#5"])
        XCTAssertEqual(titles(NoteOrder(.created, favoritesFirst: true)), ["note 2#2", "Beta#4", "Alpha#3", "Alpha#5", "Note 10#1"])
    }

    func testTheOrderDoesNotDependOnTheInput() {
        for key in NoteOrder.Key.allCases {
            for first in [false, true] {
                let order = NoteOrder(key, favoritesFirst: first)
                XCTAssertEqual(order.sorted(notes).map(\.id), order.sorted(notes.reversed()).map(\.id), "\(key) \(first)")
            }
        }
    }

    func testAttachmentKindsOfAState() throws {
        var state = NoteState(meta: NoteMeta(created: Date()))
        XCTAssertEqual(NoteAttachments(state: state), [])
        state.pages = [Page(order: "a")]
        func item(_ kind: ItemKind) -> Item {
            Item(kind: kind, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a")
        }
        state.pages[0].items = [item(.text), item(.image), item(.math)]
        XCTAssertEqual(NoteAttachments(state: state), [.images, .math])
        state.pages[0].items.append(item(.pdfPage))
        state.pages[0].items.append(item(.video))
        state.pages[0].items.append(item(ItemKind(rawValue: "hologram")))
        XCTAssertEqual(NoteAttachments(state: state).names, ["image", "math", "video", "pdf"])
        state.pages[0].items.append(item(.audio))
        XCTAssertEqual(NoteAttachments(state: state).names, ["image", "math", "video", "audio", "pdf"])
    }
}
