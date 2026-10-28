import Foundation
import XCTest
@testable import Sempere

final class PaperModelTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let p2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!

    private func decode(_ json: String) throws -> Paper {
        try InkJSON.decoder().decode(Paper.self, from: Data(json.utf8))
    }

    private func encode(_ p: Paper) throws -> String {
        String(decoding: try InkJSON.encoder().encode(p), as: UTF8.self)
    }

    func testDefaultPaperDecodesAndEncodesUnchanged() throws {
        let json = ##"{"background":"#FFFFFFFF","kind":"ruled","lineColor":"#D0D8E8FF","spacing":24}"##
        let p = try decode(json)
        XCTAssertEqual(p, Paper(kind: .ruled, spacing: 24))
        XCTAssertEqual(try encode(p), json)          // no new keys for a default paper
        for kind in ["blank", "grid", "dot"] {
            let j = ##"{"background":"#FFFFFFFF","kind":"\##(kind)","lineColor":"#D0D8E8FF","spacing":30}"##
            XCTAssertEqual(try encode(try decode(j)), j)
        }
    }

    func testMissingFieldsTakeTheKindsDefaults() throws {
        let p = try decode(#"{"kind":"marginRuled"}"#)
        XCTAssertEqual(p.marginLeft, 72)
        XCTAssertEqual(p.spacing, 24)
        XCTAssertEqual(p.lineWidth, 0.5)
        XCTAssertEqual(try decode(#"{"kind":"staff"}"#).staffSpacing, 7)
    }

    func testUnknownKindDegradesToBlank() throws {
        let p = try decode(##"{"kind":"hexagons","spacing":10,"background":"#FFF8E1FF"}"##)
        XCTAssertEqual(p.kind, .blank)
        XCTAssertEqual(p.background, Paper.cream)
        // A note whose paper is unknown still opens.
        let meta = try InkJSON.decoder().decode(NoteMeta.self, from: Data(
            #"{"title":"x","tags":[],"favorite":false,"created":"2026-10-04T16:20:00Z","paper":{"kind":"future"},"pageSize":{"width":612,"height":792,"infinite":false}}"#.utf8))
        XCTAssertEqual(meta.paper.kind, .blank)
    }

    /// Regression: a new note never writes paper outside the valid ranges.
    func testNewNoteWritesValidPaper() {
        let ops = NoteOps.newNote(title: "x", paper: Paper(kind: .grid, spacing: 1, lineWidth: 99, marginTop: .nan))
        let paper = ops.compactMap { op -> Paper? in
            if case .setMeta(.paper(let p)) = op { return p }
            return nil
        }
        XCTAssertEqual(paper.count, 1)
        XCTAssertTrue(paper[0].isValid)
        XCTAssertEqual(paper[0].spacing, Paper.Limits.spacing.lowerBound)
        XCTAssertEqual(paper[0].kind, .grid)
    }

    /// Regression: a snapshot (or restore) written by this reader must not turn
    /// a newer app's paper kind into `blank`.
    func testUnknownKindSurvivesARewrite() throws {
        let json = ##"{"background":"#FFF8E1FF","kind":"hexagons","lineColor":"#D0D8E8FF","spacing":10}"##
        let p = try decode(json)
        XCTAssertEqual(p.kind, .blank)
        XCTAssertEqual(p.kindName, "hexagons")
        XCTAssertEqual(try encode(p), json)
        XCTAssertEqual(try encode(p.validated()), json)
        XCTAssertNotEqual(p, Paper(kind: .blank, spacing: 10, background: Paper.cream))

        // Through an op and the note's metadata (what a snapshot writes).
        let meta = NoteMeta(title: "x", created: Date(timeIntervalSince1970: 0), paper: p)
        let metaBack = try InkJSON.decoder().decode(NoteMeta.self, from: try InkJSON.encoder().encode(meta))
        XCTAssertEqual(metaBack.paper.kindName, "hexagons")
        let op = try InkJSON.decoder().decode(Op.self, from: Data(
            ##"{"op":"setMeta","field":"paper","value":\##(json)}"##.utf8))
        guard case .setMeta(.paper(let fromOp)) = op else { return XCTFail("not a paper op") }
        XCTAssertEqual(fromOp.kindName, "hexagons")
        let reencoded = try InkJSON.decoder().decode(Op.self, from: try InkJSON.encoder().encode(op))
        XCTAssertEqual(reencoded, op)

        // Choosing a kind replaces the unknown one.
        var chosen = p
        chosen.kind = .grid
        XCTAssertEqual(chosen.kindName, "grid")
        XCTAssertEqual(try decode(try encode(chosen)).kind, .grid)
    }

    func testFullPaperRoundTrips() throws {
        let p = Paper(kind: .cornell, spacing: 30, background: Paper.cream, lineColor: Color(r: 1, g: 2, b: 3, a: 128),
                      lineWidth: 1.25, dotRadius: 1.5, marginLeft: 50, marginTop: 40, marginColor: .black,
                      cueWidth: 200, summaryHeight: 90, staffSpacing: 9, staffGap: 50)
        XCTAssertEqual(try decode(try encode(p)), p)
    }

    func testValidationClampsToLimits() {
        var p = Paper(kind: .ruled, spacing: 1, lineWidth: 99, dotRadius: 0, marginLeft: -3, marginTop: 1e9,
                      cueWidth: 1, summaryHeight: 1e6, staffSpacing: 100, staffGap: 0)
        XCTAssertFalse(p.isValid)
        p = p.validated()
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(p.spacing, Paper.Limits.spacing.lowerBound)
        XCTAssertEqual(p.lineWidth, Paper.Limits.lineWidth.upperBound)
        XCTAssertEqual(p.dotRadius, Paper.Limits.dotRadius.lowerBound)
        XCTAssertEqual(p.marginLeft, 0)
        XCTAssertEqual(p.marginTop, Paper.Limits.margin.upperBound)
        XCTAssertEqual(p.staffGap, Paper.Limits.staffGap.lowerBound)
        XCTAssertEqual(Paper(kind: .dot, spacing: .nan, lineWidth: .infinity).validated().spacing, 24)
        for kind in PaperKind.allCases { XCTAssertTrue(Paper.template(kind).isValid, "\(kind)") }
        // `rendered()` leaves spacing alone: spacing below 4 draws no ruling (format.md §5.4.2).
        XCTAssertEqual(Paper(kind: .ruled, spacing: 1).rendered().spacing, 1)
    }

    func testSetPagePaperOpRoundTrips() throws {
        let ops: [Op] = [.setPagePaper(pageId: p1, paper: Paper(kind: .staff)), .setPagePaper(pageId: p1, paper: nil)]
        let data = try InkJSON.encoder().encode(ops)
        XCTAssertEqual(try InkJSON.decoder().decode([Op].self, from: data), ops)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""op":"setPagePaper","pageId":"\#(p1.uuidString.lowercased())","paper":null}"#))
    }

    func testPagePaperLWW() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addPage(Page(id: p2, order: "b"))])
        XCTAssertNil(try NoteReducer.reconstruct([add]).pages[0].paper)
        XCTAssertNil(try NoteReducer.reconstruct([add]).pages[0].paperClock)
        let grid = Paper(kind: .grid), dots = Paper(kind: .dot), staff = Paper(kind: .staff)
        let a = log.delta(devA, 100, [.setPagePaper(pageId: p1, paper: grid)])
        let b = log.delta(devB, 150, [.setPagePaper(pageId: p1, paper: dots)])
        let c = log.delta(devC, 120, [.setPagePaper(pageId: p1, paper: staff)])
        let state = try NoteReducer.reconstruct([c, b, add, a])
        XCTAssertEqual(state.pages[0].paper, dots)
        XCTAssertEqual(state.pages[0].paperClock, Stamp(hlc: b.hlc, device: devB).description)
        XCTAssertNil(state.pages[1].paper)
        XCTAssertEqual(try NoteReducer.reconstruct([add, a, b, c]), state)

        // Clearing wins by clock and records it.
        let clear = log.delta(devA, 200, [.setPagePaper(pageId: p1, paper: nil)])
        let cleared = try NoteReducer.reconstruct([add, a, b, clear])
        XCTAssertNil(cleared.pages[0].paper)
        XCTAssertNotNil(cleared.pages[0].paperClock)

        // Through a snapshot: a late older write loses, a late newer one wins.
        let snap = try log.snapshot(devB, 300, from: [add, a, b])
        let lateOld = log.delta(devC, 50, [.setPagePaper(pageId: p1, paper: staff)])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateOld]).pages[0].paper, dots)
        let lateNew = log.delta(devC, 250, [.setPagePaper(pageId: p1, paper: staff)])
        XCTAssertEqual(try NoteReducer.reconstruct([lateNew, snap]).pages[0].paper, staff)
        // A note-level paper change does not touch a page's own paper.
        let meta = log.delta(devA, 400, [.setMeta(.paper(Paper(kind: .isoDot)))])
        let both = try NoteReducer.reconstruct([snap, meta])
        XCTAssertEqual(both.meta.paper.kind, .isoDot)
        XCTAssertEqual(both.pages[0].paper, dots)
    }

    func testRestoreSetsPagePaperBack() throws {
        var log = LogBuilder()
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .setPagePaper(pageId: p1, paper: Paper(kind: .grid))])
        let d1 = log.delta(devA, 100, [.setPagePaper(pageId: p1, paper: Paper(kind: .staff))])
        let target = try NoteReducer.reconstruct([d0])
        let current = try NoteReducer.reconstruct([d0, d1])
        let ops = NoteHistory.restoreOps(current: current, target: target)
        XCTAssertEqual(ops, [.setPagePaper(pageId: p1, paper: Paper(kind: .grid))])
        XCTAssertEqual(RestoreSummary(ops).pagePaperChanges, 1)
    }
}

final class SetPaperOpsTests: XCTestCase {
    let a = Page(order: "a"), b = Page(order: "b", paper: Paper(kind: .staff)), c = Page(order: "c")
    let meta = NoteMeta(created: Date(timeIntervalSince1970: 0), paper: .ruled)

    func testThisPageOnlyGetsItsOwnPaper() {
        let grid = Paper(kind: .grid)
        XCTAssertEqual(NoteOps.setPaper(grid, scope: .page(a.id), note: meta, pages: [a, b, c]),
                       [.setPagePaper(pageId: a.id, paper: grid)])
        // Already showing it: nothing to write.
        XCTAssertEqual(NoteOps.setPaper(.ruled, scope: .page(a.id), note: meta, pages: [a, b, c]), [])
        XCTAssertEqual(NoteOps.setPaper(Paper(kind: .staff), scope: .page(b.id), note: meta, pages: [a, b, c]), [])
        XCTAssertEqual(NoteOps.setPaper(grid, scope: .page(UUID()), note: meta, pages: [a]), [])
    }

    func testAllPagesSetsTheNotePaperAndClearsOverrides() {
        let grid = Paper(kind: .grid)
        XCTAssertEqual(NoteOps.setPaper(grid, scope: .allPages, note: meta, pages: [a, b, c]),
                       [.setMeta(.paper(grid)), .setPagePaper(pageId: b.id, paper: nil)])
        // Same note paper: only the overrides are cleared.
        XCTAssertEqual(NoteOps.setPaper(.ruled, scope: .allPages, note: meta, pages: [a, b]),
                       [.setPagePaper(pageId: b.id, paper: nil)])
        XCTAssertEqual(NoteOps.setPaper(.ruled, scope: .allPages, note: meta, pages: [a, c]), [])
    }

    func testPaperIsClampedBeforeItIsWritten() {
        let wild = Paper(kind: .ruled, spacing: 1, lineWidth: 50)
        let ops = NoteOps.setPaper(wild, scope: .allPages, note: meta, pages: [a])
        XCTAssertEqual(ops, [.setMeta(.paper(wild.validated()))])
    }
}
