import Foundation
import Sempere

/// How a formula is typeset for a Markdown text box (the app's SwiftMath, `MathTypesetter`): whether the source has a problem
/// (nothing is drawn for it), and its render as PDF data with the entry that describes it.
public struct FormulaTypesetting: Sendable {
    public var problem: @Sendable (String) -> String?
    public var formula: @MainActor @Sendable (MathContent) throws -> (data: Data, formula: TypesetFormula)

    public init(problem: @escaping @Sendable (String) -> String?,
                formula: @escaping @MainActor @Sendable (MathContent) throws -> (data: Data, formula: TypesetFormula)) {
        self.problem = problem
        self.formula = formula
    }
}

/// Markdown text boxes on the open note (format.md §8.2.4 "Markdown text",
/// §8.5.4): the editor writes the source; before the delta, every formula of
/// the source that has no typeset rendering in the box yet is typeset (`FormulaTypesetting`) and its
/// render written as a blob, so every other renderer (the CLI, the web viewer, exports) draws it. The box
/// is then laid out as the canvas does (`NoteCanvas.relayout`, the frame's height) and
/// written in one delta like any text edit.
extension NoteEditorModel {
    /// `content` (a Markdown box) ready to write at `frame`'s width: the
    /// formulas its source uses, typeset (renders written first), the ones it
    /// no longer uses dropped, and the stored layout and frame height of its
    /// rendered text. A formula that cannot be typeset is left to be drawn
    /// as its source. A formula used twice (same display, size, colour and source) is typeset once, and a
    /// box keeps at most `TextContent.Limits.formulas` of them.
    public func preparedMarkdown(_ content: TextContent, frame: Rect,
                                 typesetting: FormulaTypesetting) async throws -> (content: TextContent, frame: Rect) {
        guard canEditItems else { throw ItemError.notEditable }
        var out = content
        var entries = MarkdownText.usedFormulas(content)
        var seen = Set<String>()
        for f in MarkdownPlan(content).formulas {
            let key = "\(f.display)|\(InkJSON.round3(f.size))|\(f.color.hex)|\(f.latex)"
            guard seen.insert(key).inserted,
                  !entries.contains(where: { $0.draws(latex: f.latex, display: f.display, size: f.size, color: f.color) }),
                  typesetting.problem(f.latex) == nil,
                  let typeset = try? typesetting.formula(MathContent(latex: f.latex, display: f.display, size: f.size,
                                                                     color: f.color)),
                  typeset.formula.math.render != nil else { continue }
            let stored = try await storeBlob(typeset.data, type: MathContent.renderType)
            var entry = typeset.formula
            entry.math.render = stored
            entries.append(entry)
            if entries.count >= TextContent.Limits.formulas { break }
        }
        out.math = entries.isEmpty ? nil : entries
        return Canvas.relayout(out, frame: frame)
    }
}
