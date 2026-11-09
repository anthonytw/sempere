import Foundation
import Sempere
import SempereAppCore

extension FormulaTypesetting {
    /// Formulas typeset with SwiftMath (`MathTypesetter`).
    static let swiftMath = FormulaTypesetting(problem: { MathTypesetter.problem($0) },
                                              formula: { try MathTypesetter.formula($0) })
}

extension NoteEditor {
    /// `content` (a Markdown box) ready to write at `frame`'s width, its formulas typeset with SwiftMath
    /// (`MathTypesetter`); the rules are `preparedMarkdown(_:frame:typesetting:)` (`SempereAppCore`).
    func preparedMarkdown(_ content: TextContent, frame: Rect) async throws -> (content: TextContent, frame: Rect) {
        try await preparedMarkdown(content, frame: frame, typesetting: .swiftMath)
    }
}
