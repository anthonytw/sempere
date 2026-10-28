import Foundation
import XCTest
@testable import Sempere

/// The Markdown dialect of text boxes (format.md §8.5.4).
final class MarkdownTests: XCTestCase {
    /// The blocks as compact strings: kind and drawn text with styles.
    private func describe(_ source: String) -> [String] {
        let doc = MarkdownDocument(source)
        var out: [String] = []
        func text(_ atoms: [MarkdownAtom]) -> String {
            var s = ""
            var style: MarkdownStyle = []
            for a in atoms {
                if a.style != style {
                    s += "{" + name(a.style) + "}"
                    style = a.style
                }
                switch a.kind {
                case .char(let c): s.unicodeScalars.append(c)
                case .formula(let latex, let display): s += display ? "[$$\(latex)$$]" : "[$\(latex)$]"
                case .lineBreak: s += "⏎"
                }
            }
            return s
        }
        func name(_ st: MarkdownStyle) -> String {
            var n = ""
            if st.contains(.bold) { n += "b" }
            if st.contains(.italic) { n += "i" }
            if st.contains(.strike) { n += "s" }
            if st.contains(.code) { n += "c" }
            if st.contains(.link) { n += "l" }
            return n
        }
        func walk(_ entries: [MarkdownEntry], _ prefix: String) {
            for e in entries {
                let gap = e.blankBefore ? "+" : ""
                switch e.block {
                case .paragraph(let a): out.append(prefix + gap + "p:" + text(a))
                case .heading(let l, let a): out.append(prefix + gap + "h\(l):" + text(a))
                case .code(let a): out.append(prefix + gap + "code:" + text(a))
                case .math(let a): out.append(prefix + gap + "math:" + text([a]))
                case .rule: out.append(prefix + gap + "rule")
                case .quote(let inner): out.append(prefix + gap + "quote"); walk(inner, prefix + "> ")
                case .list(let l):
                    out.append(prefix + gap + (l.bullet.map { "ul\(Character($0))" } ?? "ol\(l.start)"))
                    for item in l.items {
                        let task = item.task.map { $0 ? "[x]" : "[ ]" } ?? ""
                        out.append(prefix + "  " + (item.blankBefore ? "+" : "") + "item" + task)
                        walk(item.blocks, prefix + "    ")
                    }
                }
            }
        }
        walk(doc.blocks, "")
        return out
    }

    func testHeadingsParagraphsAndHardBreaks() {
        XCTAssertEqual(describe("# Title #\n\nLine one\nline two  \n## Sub"),
                       ["h1:Title", "+p:Line one⏎line two", "h2:Sub"])
        XCTAssertEqual(describe("#nope\n####### seven"), ["p:#nope⏎####### seven"])
    }

    func testEmphasis() {
        XCTAssertEqual(describe("a **bold** and *it* and ~~gone~~"),
                       ["p:a {b}bold{} and {i}it{} and {s}gone"])
        XCTAssertEqual(describe("***both*** x"), ["p:{bi}both{} x"])
        XCTAssertEqual(describe("snake_case_name and 2 * 3 * 4"), ["p:snake_case_name and 2 * 3 * 4"])
        XCTAssertEqual(describe("**unclosed and *mixed**"), ["p:*{i}unclosed and mixed"])
    }

    func testCodeSpansAndEscapes() {
        XCTAssertEqual(describe("use `a*b*c` and \\*not\\*"), ["p:use {c}a*b*c{} and *not*"])
        XCTAssertEqual(describe("``a ` b`` and `x"), ["p:{c}a ` b{} and `x"])
    }

    func testMath() {
        XCTAssertEqual(describe("Let $f(x) = x^2$ cost $5 and $6"), ["p:Let [$f(x) = x^2$] cost $5 and $6"])
        XCTAssertEqual(describe("inline $$\\sum_i$$ display style"), ["p:inline [$$\\sum_i$$] display style"])
        XCTAssertEqual(describe("$$\n\\int_0^1 x\\,dx\n$$\nafter"), ["math:[$$\\int_0^1 x\\,dx$$]", "p:after"])
        XCTAssertEqual(describe("$$ a^2 $$"), ["math:[$$a^2$$]"])
        XCTAssertEqual(describe("$$x$$ is nice"), ["p:[$$x$$] is nice"])
        XCTAssertEqual(describe("$ x$"), ["p:$ x$"])
    }

    func testLinksAndImages() {
        let doc = MarkdownDocument("see [the *docs*](https://example.org/a_(b) \"t\") and ![alt](x.png) <https://e.org>")
        XCTAssertEqual(doc.links, ["https://example.org/a_(b)", "https://e.org"])
        XCTAssertEqual(describe("see [the *docs*](https://example.org/a_(b) \"t\") and ![alt](x.png) <https://e.org>"),
                       ["p:see {l}the {il}docs{} and alt {l}https://e.org"])
        XCTAssertEqual(describe("[not a link] (x)"), ["p:[not a link] (x)"])
    }

    func testLists() {
        XCTAssertEqual(describe("- one\n- two\n  - nested\n\n- three\n\n1. a\n2. b"),
                       ["ul-", "  item", "    p:one", "  item", "    p:two", "    ul-", "      item", "        p:nested",
                        "  +item", "    p:three", "+ol1", "  item", "    p:a", "  item", "    p:b"])
        XCTAssertEqual(describe("- [ ] todo\n- [x] done\n* other"),
                       ["ul-", "  item[ ]", "    p:todo", "  item[x]", "    p:done", "ul*", "  item", "    p:other"])
        XCTAssertEqual(describe("3) c\n4) d"), ["ol3", "  item", "    p:c", "  item", "    p:d"])
    }

    func testQuotesRulesAndCode() {
        XCTAssertEqual(describe("> quoted *text*\n> > deeper\n\n---\n```swift\nlet a = 1\n  b\n```\nafter"),
                       ["quote", "> p:quoted {i}text", "> quote", "> > p:deeper", "+rule",
                        "code:{c}let a = 1⏎  b", "p:after"])
        XCTAssertEqual(describe("~~~\nunclosed"), ["code:{c}unclosed"])
        XCTAssertEqual(describe("- - -"), ["rule"])
    }

    func testPlainText() {
        let doc = MarkdownDocument("# Title\n\n- **bold** [link](https://x.y)\n- $x^2$\n\n> `code`\n---")
        XCTAssertEqual(doc.plainText, "Title\nbold link\nx^2\ncode")
    }

    func testOffsetsPointAtTheSource() {
        let source = "a **b** $x$\n\n- c"
        let scalars = Array(source.unicodeScalars)
        let doc = MarkdownDocument(source)
        var seen: [Int] = []
        func walk(_ entries: [MarkdownEntry]) {
            for e in entries {
                switch e.block {
                case .paragraph(let atoms):
                    for a in atoms {
                        seen.append(a.offset)
                        if case .char(let c) = a.kind { XCTAssertEqual(scalars[a.offset], c) }
                        if case .formula = a.kind { XCTAssertEqual(scalars[a.offset], "$") }
                    }
                case .list(let l): for i in l.items { walk(i.blocks) }
                default: break
                }
            }
        }
        walk(doc.blocks)
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(Set(seen).count, seen.count)
    }

    func testDeepNestingAndHostileInputStayBounded() {
        let deep = String(repeating: "> ", count: 200) + "x"
        XCTAssertFalse(MarkdownDocument(deep).blocks.isEmpty)
        let lists = (0..<200).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        XCTAssertFalse(MarkdownDocument(lists).blocks.isEmpty)
        // Linear scans: many openers without closers.
        let start = Date()
        for s in [String(repeating: "$1 ", count: 20_000), String(repeating: "[](", count: 20_000),
                  String(repeating: "*a _b ", count: 10_000), String(repeating: "`", count: 30_000) + "x",
                  String(repeating: "<ab:", count: 15_000)] {
            _ = MarkdownDocument(s).plainText
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    /// Matched emphasis nested many times: each match styled every token
    /// between its opener and closer, so a 64 KiB box of `*a *a … a* a*` took
    /// about 40 s to parse (quadratic). Styles are now applied once, from the
    /// matches' ranges, and the nesting still styles what it did.
    func testNestedEmphasisStaysLinear() {
        XCTAssertEqual(describe("*a *b c* d*"), ["p:{i}a b c d"])
        XCTAssertEqual(describe("**a *b ~~c~~ d* e**"), ["p:{b}a {bi}b {bis}c{bi} d{b} e"])
        XCTAssertEqual(describe("_a _b c_ d_"), ["p:{i}a b c d"])
        let n = TextContent.Limits.utf8Bytes - 8
        let start = Date()
        for s in [String(repeating: "*a ", count: n / 6) + String(repeating: "a* ", count: n / 6),
                  String(repeating: "_a ", count: n / 6) + String(repeating: "a_ ", count: n / 6),
                  String(repeating: "~~a ", count: n / 8) + String(repeating: "a~~ ", count: n / 8),
                  "$$\n" + String(repeating: "\n", count: n - 4) + "x"] {
            _ = MarkdownDocument(s).plainText
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        // Every character of the nested case is italic, and nothing else is styled.
        let nested = String(repeating: "*a ", count: 50) + String(repeating: "a* ", count: 50)
        let atoms = MarkdownDocument(nested).blocks.flatMap { e -> [MarkdownAtom] in
            if case .paragraph(let a) = e.block { return a } else { return [] }
        }
        XCTAssertEqual(Set(atoms.map(\.style)), [.italic])
    }

    func testPlanColumnsMarkersAndGaps() {
        let content = TextContent(size: 10, color: .black, runs: [TextRun("# H\n\npara\n- a\n  1. b\n> q\n```\nc\n```")],
                                  markup: .markdown)
        let plan = MarkdownPlan(content)
        XCTAssertEqual(plan.paragraphs.map(\.kind), [.text, .text, .text, .text, .text, .code])
        XCTAssertEqual(plan.paragraphs.map(\.size), [16, 10, 10, 10, 10, 10])
        XCTAssertEqual(plan.paragraphs.map(\.gapBefore), [0, 5, 0, 0, 0, 0])
        XCTAssertEqual(plan.paragraphs.map(\.indent), [0, 0, 16, 32, 10, 5])
        XCTAssertEqual(plan.paragraphs.map(\.marker), [nil, nil, .bullet(ring: false), .ordered("1."), nil, nil])
        XCTAssertEqual(plan.quoteBars, [MarkdownPlan.QuoteBar(x: 2.5, first: 4, last: 4)])
        XCTAssertEqual(plan.paragraphs[5].pad, 2.5)
        XCTAssertTrue(plan.paragraphs[0].atoms.allSatisfy { $0.run.b && $0.run.size == 16 })
    }

    func testFormulasAreBoxesOnlyWithAMatchingEntry() throws {
        let render = BlobRef(sha256: String(repeating: "a", count: 64), size: 100, type: "application/pdf")
        let entry = TypesetFormula(math: MathContent(latex: "x^2", display: false, size: 12, color: .black, render: render,
                                                     renderSize: Size(w: 20, h: 14), engine: "test"), depth: 3)
        var content = TextContent(size: 12, color: .black, runs: [TextRun("a $x^2$ b $y$")], markup: .markdown, math: [entry])
        var plan = MarkdownPlan(content)
        let kinds = plan.paragraphs[0].atoms.map { a -> String in
            switch a.kind {
            case .char(let c): return String(c)
            case .box: return "■"
            case .lineBreak: return "⏎"
            }
        }.joined()
        XCTAssertEqual(kinds, "a ■ b y")
        XCTAssertEqual(plan.paragraphs[0].atoms.last?.run.font, .mono)
        XCTAssertEqual(plan.formulas.map(\.latex), ["x^2", "y"])
        XCTAssertEqual(MarkdownText.usedFormulas(content), [entry])
        // A box of another size draws the formula as its source.
        content.size = 14
        plan = MarkdownPlan(content)
        XCTAssertFalse(plan.paragraphs[0].atoms.contains { if case .box = $0.kind { return true } else { return false } })
        XCTAssertEqual(MarkdownText.usedFormulas(content), [])
    }

    func testFormatRoundTripAndOlderReaders() throws {
        let render = BlobRef(sha256: String(repeating: "b", count: 64), size: 10, type: "application/pdf")
        let source = "# T\n\n$x$"
        let value = TextContent(size: 12, color: .black, runs: [TextRun(source)], markup: .markdown,
                                layout: RenderedLayout(of: MarkdownText.hash(source), breaks: [5]),
                                math: [TypesetFormula(math: MathContent(latex: "x", display: false, size: 12, color: .black,
                                                                        render: render, renderSize: Size(w: 8, h: 10),
                                                                        engine: "e"), depth: 2.5)])
        let data = try JSONEncoder().encode(value)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"markup\":\"markdown\""))
        XCTAssertTrue(json.contains("\"depth\":2.5"))
        XCTAssertEqual(try JSONDecoder().decode(TextContent.self, from: data), value)
        // The item's blobs include the render (collection keeps it).
        let item = Item.text(value, frame: Rect(x: 0, y: 0, w: 100, h: 20), z: "a0")
        XCTAssertEqual(item.blobReferences, [render])
        // Search sees the plain text.
        XCTAssertEqual(MarkdownText.searchText(value), "T\nx")
        // An unknown markup is styled text.
        var other = value
        other.markup = TextMarkup(rawValue: "asciidoc")
        XCTAssertFalse(other.isMarkdown)
        XCTAssertEqual(MarkdownText.searchText(other), source)
        XCTAssertEqual(try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(other)), other)
    }

    func testInvalidFieldsAreRejected() {
        func decode(_ json: String) -> TextContent? {
            try? JSONDecoder().decode(TextContent.self, from: Data(json.utf8))
        }
        let base = ##"{"font":"sans","size":12,"color":"#000000FF","runs":[{"t":"x"}],"markup":"markdown""##
        XCTAssertNotNil(decode(base + "}"))
        XCTAssertNil(decode(base + ##","layout":{"of":"XYZ","breaks":[]}}"##))
        XCTAssertNil(decode(base + ##","layout":{"of":"0000000a","breaks":[3,2]}}"##))
        XCTAssertNotNil(decode(base + ##","layout":{"of":"0000000a","breaks":[2,3]}}"##))
        XCTAssertNil(decode(base + ##","math":[{"latex":"x","display":false,"size":12,"color":"#000000FF"}]}"##))
        XCTAssertNil(decode(base.replacingOccurrences(of: #""markdown""#, with: "3") + "}"))
    }

    func testHashIsFNV1a() {
        XCTAssertEqual(MarkdownText.hash(""), "811c9dc5")
        XCTAssertEqual(MarkdownText.hash("a"), "e40c292c")
        XCTAssertEqual(MarkdownText.hash("é"), MarkdownText.hash("\u{E9}"))
    }

    // MARK: Editing helpers (the app's Markdown bar)

    private func edit(_ action: MarkdownEditing.Action, _ text: String, _ at: Int, _ length: Int = 0) -> String {
        let r = MarkdownEditing.apply(action, to: text, selection: NSRange(location: at, length: length))
        let ns = r.text as NSString
        // The selection shown as [ ].
        return ns.substring(to: r.selection.location) + "[" + ns.substring(with: r.selection) + "]"
            + ns.substring(from: r.selection.location + r.selection.length)
    }

    func testWrapAndUnwrap() {
        XCTAssertEqual(edit(.bold, "a word b", 2, 4), "a **[word]** b")
        XCTAssertEqual(edit(.bold, "a **word** b", 4, 4), "a [word] b")
        XCTAssertEqual(edit(.italic, "ab", 1), "a*[]*b")
        XCTAssertEqual(edit(.strikethrough, "x", 0, 1), "~~[x]~~")
        XCTAssertEqual(edit(.code, "f x", 2, 1), "f `[x]`")
        XCTAssertEqual(edit(.math, "x^2", 0, 3), "$[x^2]$")
        XCTAssertEqual(edit(.link, "see docs", 4, 4), "see [docs]([https://])")
        XCTAssertEqual(edit(.link, "", 0), "[[]](https://)")
        XCTAssertEqual(edit(.displayMath, "ab", 1), "a\n$$\n[]\n$$\nb")
        XCTAssertEqual(edit(.bold, "é 😀", 2, 2), "é **[😀]**")
    }

    func testLinePrefixes() {
        XCTAssertEqual(edit(.bulletList, "one\ntwo", 0, 7), "- [one\n- two]")
        XCTAssertEqual(edit(.bulletList, "- one\n- two", 2, 9), "[one\ntwo]")
        XCTAssertEqual(edit(.numberedList, "a\nb\nc", 0, 5), "1. [a\n2. b\n3. c]")
        XCTAssertEqual(edit(.taskList, "- item", 6), "- [ ] item[]")
        XCTAssertEqual(edit(.quote, "said", 0), "> []said")
        XCTAssertEqual(edit(.heading, "Title", 2), "# Ti[]tle")
        XCTAssertEqual(edit(.heading, "# Title", 4), "## Ti[]tle")
        XCTAssertEqual(edit(.heading, "### Title", 6), "Ti[]tle")
        // Fuzz finds: a line of only #s (a run longer than a heading) loses its marker, the selection stays inside.
        XCTAssertEqual(edit(.heading, "####", 1, 1), "[]")
        XCTAssertEqual(edit(.heading, "##########", 3, 3), "[]")
    }

    func testEveryActionKeepsTheSelectionInsideTheText() {
        for action in MarkdownEditing.Action.allCases {
            for text in ["", "x", "line\n- item\n", "## h"] {
                let n = (text as NSString).length
                for start in 0...n {
                    let r = MarkdownEditing.apply(action, to: text, selection: NSRange(location: start, length: n - start))
                    XCTAssertLessThanOrEqual(r.selection.location + r.selection.length, (r.text as NSString).length, "\(action) \(text)")
                }
            }
        }
    }
}
