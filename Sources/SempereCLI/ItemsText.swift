import ArgumentParser
import Foundation
import Sempere
import SempereRender

/// `sempere items text`: replace a text box's text, as the app's editor does
/// when it closes (one delta: the `text` register and, when the lines'
/// height changes, the frame).
struct ItemsText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Replace a text box's text, as Markdown or plain styled text (one delta).",
        discussion: """
            The text is the argument, or read from --file (- for standard input). A Markdown box (format.md \\
            §8.2.4 "Markdown text") gets the new Markdown source and keeps its style and the typeset formulas \\
            the new source still uses; a plain box gets the text as one run in the box's style (run styles are \\
            dropped). --markdown turns a plain box into a Markdown box (in its font, size, colour, alignment, \\
            direction and language), --no-markdown a Markdown box into a plain one. The text is laid out again \\
            with the CLI's fonts (line breaks, and the height of the lines) unless --no-breaks. Nothing is \\
            written when nothing changes.
            """
    )

    @Argument(help: ArgumentHelp("Note id or title.", valueName: "id|title"))
    var note: String

    @Argument(help: ArgumentHelp("Text box id or prefix.", valueName: "item"))
    var item: String

    @Argument(help: ArgumentHelp("The new text (or use --file).", valueName: "text"))
    var text: String?

    @Option(name: .long, help: ArgumentHelp("Read the text from this UTF-8 file; - is standard input.", valueName: "file"))
    var file: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Make it a Markdown box (--markdown) or a plain one (--no-markdown).")
    var markdown: Bool?

    @Flag(name: .customLong("no-breaks"), help: "Store no line breaks: each renderer wraps the text itself.")
    var noBreaks = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if (text == nil) == (file == nil) { throw ValidationError("give the text as an argument, or --file PATH (not both)") }
    }

    func run() throws {
        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let string = try text ?? readBoxText(file ?? "")
        let r = try editNote(vault, id) { state in
            try requireLive(state)
            let (page, found) = try findItem(item, in: state)
            guard found.kind == .text, let old = found.text else { throw CLIError.failure("\(item) is not a text box") }
            var new = try translating { try Self.replaced(old, with: string, markdown: markdown ?? old.isMarkdown) }
            var frame = found.frame
            if !noBreaks {
                var laid = found
                laid.text = new
                laid = laidOutText(laid, keepHeight: false)
                new = laid.text ?? new
                frame = laid.frame
            }
            return try translating { try NoteOps.setText(found.id, to: new, frame: frame, on: page)?.ops ?? [] }
        }
        try reportEdit(vault, id, r, output: output, done: "Changed the text", unchanged: "The text box already says that.")
    }

    /// `old` with the text `string`: Markdown source (keeping the formulas
    /// it still uses) or one plain run, in the box's style.
    static func replaced(_ old: TextContent, with string: String, markdown: Bool) throws -> TextContent {
        if markdown {
            var style = TextStyle(font: old.font.effective, size: old.size, color: old.color, align: old.align, lang: old.lang)
            style.bold = false
            var out = old.isMarkdown ? try MarkdownText.replacingSource(old, with: string)
                : try MarkdownText.content(string, style: style)
            out.dir = old.dir
            out.family = old.family
            let used = MarkdownText.usedFormulas(out)
            out.math = used.isEmpty ? nil : used
            return out
        }
        var out = try NoteOps.text(string, style: TextStyle(font: old.font, size: old.size, color: old.color, align: old.align,
                                                            lang: old.lang))
        out.dir = old.dir
        out.family = old.family
        out.extra = old.extra
        return out
    }
}
