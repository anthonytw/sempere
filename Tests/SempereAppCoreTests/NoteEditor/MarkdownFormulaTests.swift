import Foundation
import Sempere
@testable import SempereAppCore
import Testing

extension NoteEditorSuites {
    /// What `preparedMarkdown` decides about a Markdown box's formulas (moved from the app with wave 6 follow-up F1):
    /// the dedupe key, skip-on-problem, the formulas already typeset, and the cap. The typesetter here is a fake that
    /// counts; SwiftMath's own is the app's `MarkdownBoxTests.preparedMarkdownTypesetsFormulasAndWritesTheirRendersFirst`.
    @MainActor
    struct MarkdownFormulaTests {
        typealias F = EditorFixture

        /// A fake typesetter that counts its calls and refuses sources containing "bad".
        final class Typesetter: @unchecked Sendable {
            private let lock = NSLock()
            private var _typeset: [String] = []
            var typeset: [String] { lock.withLock { _typeset } }

            var typesetting: FormulaTypesetting {
                FormulaTypesetting(problem: { $0.contains("bad") ? "unknown command" : nil },
                                   formula: { [self] content in
                    lock.withLock { _typeset.append(content.latex) }
                    let data = Data("pdf-\(content.latex)".utf8)
                    var math = content
                    math.render = BlobRef(content: data, type: MathContent.renderType)
                    math.renderSize = Size(w: 20, h: 10)
                    math.engine = "fake-1"
                    return (data, TypesetFormula(math: math, depth: 2))
                })
            }
        }

        static let frame = Rect(x: 40, y: 40, w: 300, h: 20)

        @Test func aFormulaUsedTwiceIsTypesetOnce() async throws {
            let (editor, _) = try await F.open(try await F.vault(), debounce: .seconds(60))
            let fake = Typesetter()
            let content = try MarkdownText.content("$x^2$ and again $x^2$, and $y$")
            let prepared = try await editor.preparedMarkdown(content, frame: Self.frame, typesetting: fake.typesetting)
            #expect(fake.typeset == ["x^2", "y"])
            #expect(prepared.content.math?.count == 2)
            #expect(prepared.content.math?.allSatisfy { $0.math.render != nil } == true)
        }

        /// The same source in another style is another formula: display, size and colour are in the key.
        @Test func theSameSourceInAnotherStyleIsAnotherFormula() async throws {
            let (editor, _) = try await F.open(try await F.vault(), debounce: .seconds(60))
            let fake = Typesetter()
            let content = try MarkdownText.content("inline $a$\n\n$$a$$")
            _ = try await editor.preparedMarkdown(content, frame: Self.frame, typesetting: fake.typesetting)
            #expect(fake.typeset == ["a", "a"], "one inline, one display")
        }

        @Test func aFormulaWithAProblemIsLeftAsSource() async throws {
            let (editor, _) = try await F.open(try await F.vault(), debounce: .seconds(60))
            let fake = Typesetter()
            let content = try MarkdownText.content("$ok$ then $\\bad$ then $fine$")
            let prepared = try await editor.preparedMarkdown(content, frame: Self.frame, typesetting: fake.typesetting)
            #expect(fake.typeset == ["ok", "fine"], "the formula with a problem is never typeset")
            #expect(prepared.content.math?.map(\.math.latex) == ["ok", "fine"])
        }

        @Test func aFormulaTheTypesetterCannotRenderIsSkippedToo() async throws {
            let (editor, _) = try await F.open(try await F.vault(), debounce: .seconds(60))
            struct Failure: Error {}
            let typesetting = FormulaTypesetting(problem: { _ in nil }, formula: { content in
                if content.latex == "x" { throw Failure() }
                var math = content
                math.render = nil   // a typeset entry without a render is skipped as well
                return (Data(), TypesetFormula(math: math, depth: 0))
            })
            let content = try MarkdownText.content("$x$ and $y$")
            let prepared = try await editor.preparedMarkdown(content, frame: Self.frame, typesetting: typesetting)
            #expect(prepared.content.math == nil, "nothing drawn as a formula: no entries, not an empty list")
        }

        /// Formulas already typeset in the box are kept, not typeset again; the ones the source no longer uses go.
        @Test func formulasAlreadyTypesetAreKeptAndUnusedOnesDrop() async throws {
            let (editor, _) = try await F.open(try await F.vault(), debounce: .seconds(60))
            let fake = Typesetter()
            let first = try await editor.preparedMarkdown(try MarkdownText.content("$a$ $b$"), frame: Self.frame,
                                                          typesetting: fake.typesetting)
            #expect(fake.typeset == ["a", "b"])
            let again = try await editor.preparedMarkdown(first.content, frame: first.frame, typesetting: fake.typesetting)
            #expect(fake.typeset == ["a", "b"], "nothing typeset anew")
            #expect(again.content.math == first.content.math)
            // The source drops `b` and adds `c`.
            var edited = first.content
            edited.runs = [TextRun("$a$ $c$")]
            let next = try await editor.preparedMarkdown(edited, frame: first.frame, typesetting: fake.typesetting)
            #expect(fake.typeset == ["a", "b", "c"])
            #expect(next.content.math?.map(\.math.latex) == ["a", "c"])
        }

        @Test func aBoxKeepsAtMostTheLimitOfFormulas() async throws {
            let (editor, _) = try await F.open(try await F.vault(), debounce: .seconds(60))
            let fake = Typesetter()
            let count = TextContent.Limits.formulas + 5
            let source = (0..<count).map { "$f\($0)$" }.joined(separator: " ")
            let content = try MarkdownText.content(source)
            let prepared = try await editor.preparedMarkdown(content, frame: Self.frame, typesetting: fake.typesetting)
            #expect(prepared.content.math?.count == TextContent.Limits.formulas)
            #expect(fake.typeset.count == TextContent.Limits.formulas, "it stops typesetting at the cap")
        }

        @Test func aReadOnlyNoteTypesetsNothing() async throws {
            let vault = try await F.vault()
            let clock = try DeviceClock(url: F.deviceStateURL(), app: "sempere-test/1")
            let editor = try await TestEditor.open(vault: vault, noteID: F.deleted, clock: clock)   // in Recently Deleted
            #expect(editor.isReadOnly)
            let fake = Typesetter()
            await #expect(throws: TestEditor.ItemError.notEditable) {
                _ = try await editor.preparedMarkdown(try MarkdownText.content("$x$"), frame: Self.frame, typesetting: fake.typesetting)
            }
            #expect(fake.typeset.isEmpty)
        }
    }
}
