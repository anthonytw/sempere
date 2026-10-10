import Foundation
import Sempere
import SempereRender

/// Markdown text boxes on the open note (format.md §8.2.4 "Markdown text",
/// §8.5.4): the editor writes the source; before the delta, every formula of
/// the source that has no typeset rendering in the box yet is typeset with
/// SwiftMath (`MathTypesetter.formula`) and its render written as a blob, so
/// every other renderer (the CLI, the web viewer, exports) draws it. The box
/// is then laid out with the app's fonts (`layout`, the frame's height) and
/// written in one delta like any text edit.
extension NoteEditor {
    /// `content` (a Markdown box) ready to write at `frame`'s width: the
    /// formulas its source uses, typeset (renders written first), the ones it
    /// no longer uses dropped, and the stored layout and frame height of its
    /// rendered text. A formula SwiftMath cannot typeset is left to be drawn
    /// as its source.
    func preparedMarkdown(_ content: TextContent, frame: Rect) async throws -> (content: TextContent, frame: Rect) {
        guard canEditItems else { throw ItemError.notEditable }
        var out = content
        var entries = MarkdownText.usedFormulas(content)
        var seen = Set<String>()
        for f in MarkdownPlan(content).formulas {
            let key = "\(f.display)|\(InkJSON.round3(f.size))|\(f.color.hex)|\(f.latex)"
            guard seen.insert(key).inserted,
                  !entries.contains(where: { $0.draws(latex: f.latex, display: f.display, size: f.size, color: f.color) }),
                  MathTypesetter.problem(f.latex) == nil,
                  let typeset = try? MathTypesetter.formula(MathContent(latex: f.latex, display: f.display, size: f.size,
                                                                        color: f.color)),
                  let ref = typeset.formula.math.render else { continue }
            guard let writer = attachmentWriter else { throw ItemError.notEditable }
            try await prepareBlobWrite?(ref)
            let stored = try await writer.addBlob(typeset.data, type: MathContent.renderType)
            var entry = typeset.formula
            entry.math.render = stored
            entries.append(entry)
            if entries.count >= TextContent.Limits.formulas { break }
        }
        out.math = entries.isEmpty ? nil : entries
        return TextKitBreaks.relayout(out, frame: frame)
    }
}
