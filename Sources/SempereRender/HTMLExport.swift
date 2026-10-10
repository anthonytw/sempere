import Foundation
import Sempere

/// Builds single-file HTML exports: inline SVG pages, no external resources.
/// The output is also well-formed XML (void elements self-closed, no entities
/// but the five predefined ones), which the tests rely on.
public enum HTMLExport {
    private static let style = """
    :root{--bg:#fff;--fg:#1c1c1e;--muted:#6b6b70;--card:#f4f4f6;--line:#d8d8de;--link:#0a55c4}
    @media (prefers-color-scheme:dark){:root{--bg:#161618;--fg:#ececf0;--muted:#9a9aa3;--card:#232327;--line:#3a3a41;--link:#7db3ff}}
    html{background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
    body{margin:0 auto;max-width:56rem;padding:1rem 1rem 3rem}
    a{color:var(--link)}
    h1{margin:.2em 0}
    .meta,.crumb,footer{color:var(--muted);font-size:.9rem}
    .tags{list-style:none;padding:0;display:flex;flex-wrap:wrap;gap:.4rem}
    .tags li{background:var(--card);border:1px solid var(--line);border-radius:1rem;padding:0 .6rem;font-size:.85rem}
    .sheet{background:#fff;border:1px solid var(--line);border-radius:4px;overflow:hidden}
    svg.page-svg{display:block;width:100%;height:auto}
    svg .ocr text{user-select:text;cursor:text}
    details{margin:.5rem 0 1.5rem}
    .md{background:var(--card);border:1px solid var(--line);padding:.2rem .8rem;border-radius:4px;margin:.4rem 0}
    .md blockquote{border-left:3px solid var(--line);margin:0;padding-left:.8rem}
    details pre{white-space:pre-wrap;background:var(--card);border:1px solid var(--line);padding:.6rem;border-radius:4px}
    [hidden]{display:none !important}
    input[type=search]{width:100%;box-sizing:border-box;font:inherit;padding:.5rem .7rem;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:6px}
    ul.notes{list-style:none;padding:0}
    ul.notes li{padding:.35rem 0;border-bottom:1px solid var(--line)}
    footer{margin-top:2rem;border-top:1px solid var(--line);padding-top:.6rem}
    """

    private static func esc(_ s: String) -> String { MarkdownHTML.esc(s) }

    private static func head(_ title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="light dark" />
        <title>\(esc(title))</title>
        <style>
        \(style)
        </style>
        </head>
        <body>

        """
    }

    private static let footer = "<footer>Plaintext export from Sempere: this file is not encrypted.</footer>\n</body>\n</html>\n"

    /// Percent-encodes a relative URL path for an `href`.
    static func href(_ path: String) -> String { esc(MarkdownExport.linkPath(path)) }

    private static func num(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Turns a standalone page SVG (from `SVGWriter`) into an inline element:
    /// no XML prolog or namespace URL, `paper` and `strokes` as classes, and
    /// an invisible selectable layer with the recognised words on top of the
    /// ink. The other ids are unique across pages only when the SVG was
    /// rendered with `pagePrefixedIDs`.
    static func inlineSVG(_ svg: String, page: Page, number: Int) -> String {
        var s = svg
        // The title may span lines (it holds the note title), so cut it by its tags.
        if let open = s.range(of: "<title>"), let close = s.range(of: "</title>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("<?xml") }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: " xmlns=\"http://www.w3.org/2000/svg\"", with: "")
        s = s.replacingOccurrences(of: "<g id=\"paper\">", with: "<g class=\"paper\">")
        s = s.replacingOccurrences(of: "<g id=\"strokes\">", with: "<g class=\"strokes\">")
        s = s.replacingOccurrences(of: "<svg ", with: "<svg class=\"page-svg\" role=\"img\" aria-label=\"Page \(number)\" ")
        var layer = ""
        for w in page.recognition?.words ?? [] {
            let b = w.box
            guard [b.x, b.y, b.w, b.h].allSatisfy(\.isFinite), b.w > 0, b.h > 0, !w.text.isEmpty else { continue }
            layer += "<text x=\"\(num(b.x))\" y=\"\(num(b.y + b.h * 0.85))\" font-size=\"\(num(b.h * 0.8))\" "
            layer += "textLength=\"\(num(b.w))\" lengthAdjust=\"spacingAndGlyphs\">\(esc(w.text))</text>\n"
        }
        if !layer.isEmpty, let end = s.range(of: "</svg>", options: .backwards) {
            s.replaceSubrange(end, with: "<g class=\"ocr\" fill=\"transparent\" font-family=\"sans-serif\">\n\(layer)</g>\n</svg>")
        }
        return s
    }

    /// One note as a complete HTML document.
    ///
    /// - Parameters:
    ///   - svgs: `SVGWriter.export(note:pagePrefixedIDs: true)` pages, one per page of `state`.
    ///   - indexHref: relative link to the index page, nil for none.
    ///   - videos: the note's clips written next to it (`ExportVideos`), with their paths relative to the page.
    public static func notePage(info: ExportNoteInfo, state: NoteState, svgs: [String], indexHref: String?,
                                videos: [(clip: ExportVideos.Clip, path: String)] = []) -> String {
        var h = head(info.displayTitle)
        if let indexHref { h += "<p class=\"crumb\"><a href=\"\(href(indexHref))\">All notes</a></p>\n" }
        h += "<h1>\(esc(info.displayTitle))</h1>\n<p class=\"meta\">"
        var facts: [String] = []
        if let nb = NotebookPath.canonical(info.notebook) { facts.append("Notebook: \(esc(nb))") }
        facts.append("Created \(MarkdownExport.timestamp(info.created))")
        if let m = info.modified { facts.append("modified \(MarkdownExport.timestamp(m))") }
        facts.append("\(info.pages) page\(info.pages == 1 ? "" : "s")")
        h += facts.joined(separator: " · ") + "</p>\n"
        if !info.tags.isEmpty {
            h += "<ul class=\"tags\">" + info.tags.map { "<li>\(esc($0))</li>" }.joined() + "</ul>\n"
        }
        h += "<main>\n"
        for (i, page) in state.pages.enumerated() where i < svgs.count {
            h += "<section class=\"page\" id=\"page-\(i + 1)\">\n<h2>Page \(i + 1)</h2>\n"
            h += "<div class=\"sheet\">\n\(inlineSVG(svgs[i], page: page, number: i + 1))\n</div>\n"
            for (clip, path) in videos where clip.page == i {
                let length = ExportVideos.clock(clip.duration).map { " (\($0))" } ?? ""
                h += "<p class=\"video\"><video controls preload=\"none\" src=\"\(href(path))\"></video><br>"
                h += "<a href=\"\(href(path))\">\(esc(clip.label + length))</a></p>\n"
            }
            if let r = page.recognition, !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                h += "<details><summary>Machine-recognized text (\(esc(r.engine)), may contain errors)</summary>\n"
                h += "<pre>\(esc(r.text))</pre>\n</details>\n"
            }
            let typed = MarkdownExport.typedText(page)
            if !typed.isEmpty {
                h += "<details><summary>Typed text</summary>\n"
                h += typed.map { "<pre>\(esc($0))</pre>\n" }.joined()
                h += "</details>\n"
            }
            let marked = MarkdownExport.markdownBoxes(page)
            if !marked.isEmpty {
                h += "<details open=\"open\"><summary>Text boxes</summary>\n"
                h += marked.map { "<div class=\"md\">\n" + MarkdownHTML.render($0) + "</div>\n" }.joined()
                h += "</details>\n"
            }
            let equations = MarkdownExport.equations(page)
            if !equations.isEmpty {
                h += "<details><summary>Equations (LaTeX)</summary>\n"
                h += equations.map { "<pre class=\"math\">\(esc($0))</pre>\n" }.joined()
                h += "</details>\n"
            }
            h += "</section>\n"
        }
        return h + "</main>\n" + footer
    }

    /// The index page: notes grouped by notebook, with a search box that
    /// filters by title, notebook, tags and recognised text in the browser.
    public static func indexPage(entries: [ExportIndexEntry]) -> String {
        var h = head("Sempere notes")
        h += "<h1>Sempere notes</h1>\n"
        h += "<p><input type=\"search\" id=\"q\" placeholder=\"Search titles, tags and recognized text\" "
        h += "aria-label=\"Search notes\" autocomplete=\"off\" /></p>\n"
        h += "<p class=\"meta\" id=\"count\"></p>\n<main>\n"
        let sorted = entries.sorted {
            let a = (NotebookPath.canonical($0.notebook) ?? "", $0.title.lowercased(), $0.href)
            let b = (NotebookPath.canonical($1.notebook) ?? "", $1.title.lowercased(), $1.href)
            return a < b
        }
        var current: String??
        for e in sorted {
            let nb = NotebookPath.canonical(e.notebook)
            if current == nil || current! != nb {
                if current != nil { h += "</ul>\n</section>\n" }
                h += "<section class=\"nb\">\n<h2>\(esc(nb ?? "No notebook"))</h2>\n<ul class=\"notes\">\n"
                current = .some(nb)
            }
            let hay = ([e.title, nb ?? "", e.tags.joined(separator: " "), e.searchText].joined(separator: " "))
                .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            h += "<li data-text=\"\(esc(hay))\"><a href=\"\(href(e.href))\">\(esc(e.title.isEmpty ? "Untitled" : e.title))</a> "
            h += "<span class=\"meta\">\(e.pages) page\(e.pages == 1 ? "" : "s")"
            if !e.tags.isEmpty { h += " · " + e.tags.map(esc).joined(separator: ", ") }
            h += "</span></li>\n"
        }
        if current != nil { h += "</ul>\n</section>\n" }
        h += "</main>\n<script>\n\(script)\n</script>\n"
        return h + footer
    }

    // No '<' or '&' characters: the page must stay well-formed XML.
    private static let script = """
    (function () {
      var q = document.getElementById('q');
      var count = document.getElementById('count');
      var items = document.querySelectorAll('li[data-text]');
      var sections = document.querySelectorAll('section.nb');
      function run() {
        var words = q.value.toLowerCase().split(/\\s+/).filter(Boolean);
        var shown = 0;
        items.forEach(function (li) {
          var hay = li.getAttribute('data-text');
          var ok = words.every(function (w) { return hay.indexOf(w) !== -1; });
          li.hidden = !ok;
          if (ok) { shown += 1; }
        });
        sections.forEach(function (s) {
          s.hidden = s.querySelectorAll('li:not([hidden])').length === 0;
        });
        count.textContent = shown + ' of ' + items.length + ' notes';
      }
      q.addEventListener('input', run);
      run();
    })();
    """
}
