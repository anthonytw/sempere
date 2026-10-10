import Foundation
import Sempere

/// A Markdown text box as HTML for the HTML export (format.md §8.5.4 "HTML
/// exports"): the parsed blocks as elements, every text escaped, links only
/// to `http`, `https` and `mailto` destinations, formulas as their source
/// between `\(`…`\)` or `\[`…`\]` in `span class="math"`. Never raw HTML
/// from the source.
public enum MarkdownHTML {
    public static func render(_ source: String) -> String {
        let doc = MarkdownDocument(source)
        var out = ""
        blocks(doc.blocks, doc: doc, into: &out)
        return out
    }

    static func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.unicodeScalars.append(c)
            }
        }
        return o
    }

    /// True for a destination the export links to.
    static func safe(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:")
    }

    static func blocks(_ entries: [MarkdownEntry], doc: MarkdownDocument, into out: inout String) {
        for e in entries {
            switch e.block {
            case .paragraph(let a): out += "<p>" + inline(a, doc: doc) + "</p>\n"
            case .heading(let level, let a): out += "<h\(level)>" + inline(a, doc: doc) + "</h\(level)>\n"
            case .code(let a): out += "<pre><code>" + inline(a, doc: doc, code: true) + "</code></pre>\n"
            case .math(let a): out += "<p>" + inline([a], doc: doc) + "</p>\n"
            case .rule: out += "<hr/>\n"
            case .quote(let inner):
                out += "<blockquote>\n"
                blocks(inner, doc: doc, into: &out)
                out += "</blockquote>\n"
            case .list(let list):
                let tag = list.bullet == nil ? "ol" : "ul"
                out += list.bullet == nil && list.start != 1 ? "<ol start=\"\(list.start)\">\n" : "<\(tag)>\n"
                for item in list.items {
                    out += "<li>"
                    if let task = item.task { out += "<input type=\"checkbox\" disabled=\"disabled\"\(task ? " checked=\"checked\"" : "")/> " }
                    var inner = ""
                    blocks(item.blocks, doc: doc, into: &inner)
                    out += inner + "</li>\n"
                }
                out += "</\(tag)>\n"
            }
        }
    }

    static func inline(_ atoms: [MarkdownAtom], doc: MarkdownDocument, code block: Bool = false) -> String {
        var out = ""
        var style: MarkdownStyle = []
        var link: Int?
        func close() {
            if style.contains(.code) && !block { out += "</code>" }
            if style.contains(.strike) { out += "</del>" }
            if style.contains(.italic) { out += "</em>" }
            if style.contains(.bold) { out += "</strong>" }
            if let l = link, l < doc.links.count, safe(doc.links[l]) { out += "</a>" }
            style = []
            link = nil
        }
        func open(_ s: MarkdownStyle, _ l: Int?) {
            if let l, l < doc.links.count, safe(doc.links[l]) { out += "<a href=\"\(esc(doc.links[l]))\">" }
            if s.contains(.bold) { out += "<strong>" }
            if s.contains(.italic) { out += "<em>" }
            if s.contains(.strike) { out += "<del>" }
            if s.contains(.code) && !block { out += "<code>" }
            style = s
            link = l
        }
        for a in atoms {
            let s = a.style.subtracting(.link)
            if s != style || a.link != link {
                close()
                open(s, a.link)
            }
            switch a.kind {
            case .char(let c): out += esc(String(c))
            case .lineBreak: out += block ? "\n" : "<br/>\n"
            case .formula(let latex, let display):
                out += "<span class=\"math\">" + esc(display ? "\\[" + latex + "\\]" : "\\(" + latex + "\\)") + "</span>"
            }
        }
        close()
        return out
    }
}
