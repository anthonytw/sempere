import Foundation
import XCTest
@testable import Sempere

/// `math` items (format.md §8.2.8): the JSON shape, validation, the one
/// `math` register and its merge, the typesetting limits of `MathSource`,
/// and the `NoteOps` builders the app and the CLI share.
final class MathItemTests: VaultTestCase {
    let page = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let render = BlobRef(sha256: String(repeating: "cd", count: 32), size: 5120, type: "application/pdf")

    func equation(_ latex: String = "\\frac{a}{b}", rendered: Bool = true) -> MathContent {
        MathContent(latex: latex, display: true, size: 20, color: Color(r: 0x1A, g: 0x1A, b: 0x1A),
                    render: rendered ? render : nil, renderSize: rendered ? Size(w: 40, h: 50) : nil,
                    engine: rendered ? "swiftmath-1.7.3" : nil)
    }

    func item(_ content: MathContent, id: UUID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!) -> Item {
        .math(id: id, content, frame: Rect(x: 72, y: 300, w: 40, h: 50), z: "a3")
    }

    // MARK: JSON

    func testMathItemJSONShapeAndRoundTrip() throws {
        let it = item(equation())
        let json = String(decoding: try InkJSON.encoder().encode(it), as: UTF8.self)
        XCTAssertTrue(json.contains(##""kind":"math""##), json)
        XCTAssertTrue(json.contains(##""math":{"color":"#1A1A1AFF","display":true,"engine":"swiftmath-1.7.3","latex":"\\frac{a}{b}","render":{"##), json)
        XCTAssertTrue(json.contains(##""renderSize":[40,50],"size":20}"##), json)
        XCTAssertEqual(try InkJSON.decoder().decode(Item.self, from: Data(json.utf8)), it)
        XCTAssertTrue(ItemKind.math.isDefined)
        XCTAssertEqual(it.registers.keys.sorted(), ["frame", "math", "rotation", "z"])
    }

    func testUnknownFieldsOfMathAreKept() throws {
        let json = ##"{"id":"00000000-0000-4000-8000-0000000000b1","kind":"math","frame":[1,2,3,4],"z":"a","##
            + ##""math":{"latex":"x","display":false,"size":12,"color":"#000000FF","future":[1,true]},"other":7}"##
        let it = try InkJSON.decoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(it.math?.extra["future"], .array([.number(1), .bool(true)]))
        XCTAssertEqual(it.extra["other"], .number(7))
        let again = try InkJSON.decoder().decode(Item.self, from: try InkJSON.encoder().encode(it))
        XCTAssertEqual(again, it)
    }

    func testInvalidMathItemsAreRejected() throws {
        let base = ##"{"id":"00000000-0000-4000-8000-0000000000b1","kind":"math","frame":[1,2,3,4],"z":"a""##
        let bad = [
            base + "}",                                                                   // no math
            base + ##","math":{"latex":"x","display":true,"size":0,"color":"#000000FF"}}"##,    // size out of range
            base + ##","math":{"latex":"x","display":"yes","size":12,"color":"#000000FF"}}"##, // display not a bool
            base + ##","math":{"latex":"x","display":true,"size":12,"color":"red"}}"##,         // colour
            base + ##","math":{"latex":"x","display":true,"size":12,"color":"#000000FF","render":"##
                + ##"{"sha256":"\##(String(repeating: "cd", count: 32))","size":5,"type":"application/pdf"}}}"##,   // render without size
            base + ##","math":{"latex":"x","display":true,"size":12,"color":"#000000FF","renderSize":[1,1]}}"##, // size without render
            base + ##","math":{"latex":"x","display":true,"size":12,"color":"#000000FF","renderSize":[1,1],"render":"##
                + ##"{"sha256":"\##(String(repeating: "cd", count: 32))","size":5,"type":"image/png"}}}"##,         // not a PDF
            base + ##","math":{"latex":"a\u0001b","display":true,"size":12,"color":"#000000FF"}}"##,          // control character
            base + ##","math":{"latex":"\##(String(repeating: "x", count: MathSource.maxBytes + 1))","display":true,"size":12,"color":"#000000FF"}}"##,
        ]
        for (i, json) in bad.enumerated() {
            XCTAssertThrowsError(try InkJSON.decoder().decode(Item.self, from: Data(json.utf8)), "case \(i)")
        }
        // At the limit is fine, and so is an empty source (it draws nothing).
        for latex in [String(repeating: "x", count: MathSource.maxBytes), ""] {
            let ok = base + ##","math":{"latex":"\##(latex)","display":true,"size":12,"color":"#000000FF"}}"##
            XCTAssertNoThrow(try InkJSON.decoder().decode(Item.self, from: Data(ok.utf8)))
        }
        // A writer cannot write an invalid value either.
        var broken = item(equation())
        broken.math?.renderSize = nil
        XCTAssertThrowsError(try InkJSON.encoder().encode(broken))
        XCTAssertThrowsError(try InkJSON.encoder().encode(Op.setItem(page: page, itemId: broken.id, change: .math(broken.math!))))
    }

    func testSetItemMath() throws {
        let value = try JSONValue(encoding: equation("y"))
        XCTAssertEqual(try ItemChange(field: "math", value: value), .math(equation("y")))
        XCTAssertThrowsError(try ItemChange(field: "math", value: .null)) { XCTAssertEqual($0 as? ItemChangeError, .nullNotAllowed("math")) }
        XCTAssertThrowsError(try ItemChange(field: "math", value: .string("y"))) { XCTAssertEqual($0 as? ItemChangeError, .invalidValue("math")) }
        // `math` on another kind is an unknown field there, kept as JSON.
        var text = Item.text(TextContent(size: 12, color: .black, runs: []), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a")
        text.apply(.math(equation("y")))
        XCTAssertNil(text.math)
        XCTAssertEqual(text.extra["math"], value)
    }

    // MARK: Merge

    /// The whole value is one register: concurrent edits never pair one
    /// device's source with the other's rendering.
    func testConcurrentMathEditsKeepOneWholeValue() throws {
        var log = LogBuilder()
        let it = item(equation("a"))
        let base = log.delta(devA, 0, NoteOps.newNote(title: "M", pageId: page) + [.addItem(page: page, item: it)])
        let a = log.delta(devA, 10, [.setItem(page: page, itemId: it.id, change: .math(equation("b")))])
        let b = log.delta(devB, 20, [.setItem(page: page, itemId: it.id, change: .math(equation("c", rendered: false)))])
        for order in [[base, a, b], [base, b, a], [b, base, a]] {
            let s = try NoteReducer.reconstruct(order)
            XCTAssertEqual(s.pages[0].items.first?.math, equation("c", rendered: false))
        }
        // Through a snapshot of the side that lost.
        let snapA = try log.snapshot(devA, 15, from: [base, a])
        XCTAssertEqual(try NoteReducer.reconstruct([snapA, b]).pages[0].items.first?.math, equation("c", rendered: false))
        let snapB = try log.snapshot(devB, 25, from: [base, b])
        XCTAssertEqual(try NoteReducer.reconstruct([snapB, a]).pages[0].items.first?.math, equation("c", rendered: false))
    }

    /// A reader that predates math items saw `math` as an unknown field and
    /// register of an unknown kind; the value it re-emits reads the same now.
    func testOlderSnapshotOfAnUnknownMathKindStillReads() throws {
        let json = ##"{"id":"00000000-0000-4000-8000-0000000000b1","kind":"math","frame":[1,2,3,4],"z":"a","##
            + ##""math":{"latex":"x^2","display":true,"size":12,"color":"#000000FF"},"clocks":{"math":"17596320000000003-a1b2c3d4"}}"##
        let it = try InkJSON.decoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(it.math?.latex, "x^2")
        XCTAssertEqual(it.clocks?["math"], "17596320000000003-a1b2c3d4")
    }

    func testBlobReferencesIncludeTheRender() throws {
        var log = LogBuilder()
        let it = item(equation())
        let base = log.delta(devA, 0, NoteOps.newNote(title: "M", pageId: page) + [.addItem(page: page, item: it)])
        let s = try NoteReducer.reconstruct([base])
        XCTAssertEqual(s.blobReferences, [render])
        XCTAssertEqual(NoteOps.blobs(of: [it, it]), [render])
        XCTAssertEqual(item(equation(rendered: false)).blobReferences, [])
    }

    func testSearchTextIncludesTheSource() throws {
        var p = Page(id: page, order: "a")
        p.items = [item(equation("\\alpha + \\beta"))]
        XCTAssertEqual(PageText.texts(of: [p]).first?.text, "\\alpha + \\beta")
    }

    // MARK: Typesetting limits (format.md §8.2.8)

    func testSourceChecks() {
        let ok = ["x", "\\frac{a}{b}", "\\left( x \\right)", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
                  "\\{ x \\}", "\\left\\{ x \\right.", "é^{2}", "∑_{i=1}^{n} i", "a_{b_{c_{d}}}"]
        for s in ok { XCTAssertNil(MathSource.check(s), s) }
        XCTAssertEqual(MathSource.check(""), .empty)
        XCTAssertEqual(MathSource.check(" \n\t"), .empty)
        XCTAssertNil(MathSource.check("", allowEmpty: true))
        XCTAssertEqual(MathSource.check("{x"), .unbalanced("a { is never closed"))
        XCTAssertEqual(MathSource.check("x}"), .unbalanced("} without an opening"))
        XCTAssertEqual(MathSource.check("\\left( x"), .unbalanced("a \\left has no \\right"))
        XCTAssertEqual(MathSource.check("\\left( x }"), .unbalanced("} closes a different group"))
        XCTAssertEqual(MathSource.check("\\begin{matrix} x"), .unbalanced("a \\begin has no \\end"))
        XCTAssertEqual(MathSource.check("x \\end{matrix}"), .unbalanced("\\end without an opening"))
        if case .invalid? = MathSource.check("a\u{1}") {} else { XCTFail("control character") }
    }

    func testNestingLimit() {
        let n = MathSource.maxDepth
        XCTAssertNil(MathSource.check(String(repeating: "{", count: n) + "x" + String(repeating: "}", count: n)))
        XCTAssertEqual(MathSource.check(String(repeating: "{", count: n + 1) + "x" + String(repeating: "}", count: n + 1)), .tooDeep)
        // A run of commands counts like nesting: each takes the next as its argument.
        XCTAssertNil(MathSource.check(String(repeating: "\\sqrt", count: n) + "x"))
        XCTAssertEqual(MathSource.check(String(repeating: "\\sqrt", count: n + 1) + "x"), .tooDeep)
        XCTAssertEqual(MathSource.check(String(repeating: "^", count: n + 1)), .tooDeep)
        // Runs inside groups add up; a token in between ends a run.
        let half = String(repeating: "\\sqrt", count: n / 2)
        XCTAssertEqual(MathSource.check(half + "{" + half + "x}"), .tooDeep)
        XCTAssertNil(MathSource.check(String(repeating: "\\alpha x ", count: 500)))
        XCTAssertNil(MathSource.check(String(repeating: "{x}", count: 1000)))
    }

    /// Arguments a typesetter parses recursively but that hide behind a
    /// closed group: each chain of about a thousand passed with depth 2,
    /// though SwiftMath (like iosMath) recurses once per link.
    func testNestingHiddenBehindArgumentsIsCounted() {
        let n = MathSource.maxDepth
        // The second argument of each \frac is the next \frac.
        XCTAssertEqual(MathSource.check(String(repeating: "\\frac{x}", count: 1000) + "x"), .tooDeep)
        XCTAssertNil(MathSource.check(String(repeating: "\\frac{x}", count: n - 1) + "x"))
        // A \sqrt degree is parsed up to its ], and the radicand follows.
        XCTAssertEqual(MathSource.check(String(repeating: "\\sqrt[", count: 1100) + "x" + String(repeating: "]", count: 1100)),
                       .tooDeep)
        XCTAssertEqual(MathSource.check(String(repeating: "\\sqrt[a]", count: 1000) + "x"), .tooDeep)
        // Infix fractions: the rest of the group is the denominator.
        XCTAssertEqual(MathSource.check(String(repeating: "a\\over ", count: 1100) + "b"), .tooDeep)
        XCTAssertNil(MathSource.check(String(repeating: "a\\over ", count: n) + "b"))
        XCTAssertNil(MathSource.check(String(repeating: "{a\\over b}", count: 500)))
        // Brackets are plain characters elsewhere, and inside a group.
        for s in ["[0, 1)", "\\sqrt[3]{x} + [a]", "\\sqrt{[}", "\\sqrt[{]}]{x}", "\\frac{a}{b} + \\frac{c}{d}"] {
            XCTAssertNil(MathSource.check(s), s)
        }
        XCTAssertEqual(MathSource.check("\\sqrt[3 x"), .unbalanced("a \\sqrt[ has no ]"))
        XCTAssertEqual(MathSource.check("\\sqrt[3}"), .unbalanced("} closes a different group"))
    }

    func testTokenLimit() {
        let n = MathSource.maxTokens
        XCTAssertNil(MathSource.check(String(repeating: "x", count: n)))
        XCTAssertEqual(MathSource.check(String(repeating: "x", count: n + 1)), .tooManyTokens)
        XCTAssertNil(MathSource.check(String(repeating: "x ", count: n)))     // white space is free
        XCTAssertNil(MathSource.check(String(repeating: "é", count: n)))      // a character is one token, not its bytes
    }

    /// The check is linear: the largest valid sources take no time.
    func testCheckIsFastOnLargeInputs() {
        let inputs = [String(repeating: "{", count: 8192), String(repeating: "\\", count: 8192),
                      String(repeating: "\\a", count: 4096), String(repeating: "x", count: 8192)]
        let t0 = Date()
        for s in inputs { _ = MathSource.check(s) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }

    // MARK: NoteOps

    func testNoteOpsMathNormalisesAndChecks() throws {
        let m = try NoteOps.math("e\u{301}^{2}\r\n+1", display: false, size: 14, color: .black)
        XCTAssertEqual(m.latex, "\u{e9}^{2}\n+1")
        XCTAssertFalse(m.display)
        XCTAssertThrowsError(try NoteOps.math("{")) { XCTAssertEqual($0 as? AttachmentOpsError, .invalidMath("a { is never closed")) }
        XCTAssertThrowsError(try NoteOps.math("  "))
        XCTAssertThrowsError(try NoteOps.math("x", size: 0))
    }

    func testPlaceMathFrames() throws {
        let p = Page(id: page, order: "a")
        let size = PageSize(width: 612, height: 792)
        // Without a render: estimated from the source, at the margin.
        let est = try NoteOps.placeMath(equation("abcd", rendered: false), on: p, pageSize: size)
        XCTAssertEqual(est.item.frame, Rect(x: 36, y: 36, w: 48, h: 32))
        XCTAssertEqual(est.ops, [.addItem(page: page, item: est.item)])
        // A very long source stays inside the page.
        let long = try NoteOps.placeMath(equation(String(repeating: "x", count: 500), rendered: false), on: p, pageSize: size)
        XCTAssertEqual(long.item.frame.w, 540)
        // With a render: its size; --width scales it.
        XCTAssertEqual(try NoteOps.placeMath(equation(), on: p, pageSize: size, at: (10, 20)).item.frame, Rect(x: 10, y: 20, w: 40, h: 50))
        XCTAssertEqual(try NoteOps.placeMath(equation(), on: p, pageSize: size, width: 80).item.frame, Rect(x: 36, y: 36, w: 80, h: 100))
        XCTAssertThrowsError(try NoteOps.placeMath(equation(), on: p, pageSize: size, width: -1))
    }

    func testSetMathKeepsTheFrameScale() throws {
        var p = Page(id: page, order: "a")
        var it = item(equation())
        it.frame = Rect(x: 10, y: 20, w: 80, h: 100)   // twice the render's size
        p.items = [it]
        // A new render: same corner, its size times 2.
        var new = equation("y")
        new.render = BlobRef(sha256: String(repeating: "ef", count: 32), size: 9, type: "application/pdf")
        new.renderSize = Size(w: 30, h: 10)
        let edit = try XCTUnwrap(try NoteOps.setMath(it.id, to: new, on: p))
        XCTAssertEqual(edit.ops, [.setItem(page: page, itemId: it.id, change: .math(new)),
                                  .setItem(page: page, itemId: it.id, change: .frame(Rect(x: 10, y: 20, w: 60, h: 20)))])
        XCTAssertEqual(edit.page.items[0].frame, Rect(x: 10, y: 20, w: 60, h: 20))
        // Without a render the frame stays.
        let plain = try XCTUnwrap(try NoteOps.setMath(it.id, to: equation("y", rendered: false), on: p))
        XCTAssertEqual(plain.ops.count, 1)
        // From no render to a render: scale 1.
        XCTAssertEqual(NoteOps.mathFrame(Rect(x: 1, y: 2, w: 300, h: 40), from: equation(rendered: false), to: new),
                       Rect(x: 1, y: 2, w: 30, h: 10))
        // Nothing changes, nothing is written; not a math item, nil.
        XCTAssertNil(try NoteOps.setMath(it.id, to: equation(), on: p))
        XCTAssertNil(try NoteOps.setMath(UUID(), to: equation(), on: p))
    }

    func testTypesetsLike() {
        XCTAssertTrue(equation().typesetsLike(equation(rendered: false)))
        var other = equation()
        other.display = false
        XCTAssertFalse(equation().typesetsLike(other))
        XCTAssertEqual(equation().withoutRender, equation(rendered: false))
    }
}
