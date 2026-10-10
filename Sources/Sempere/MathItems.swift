import Foundation

// MARK: - Math items (docs/format.md §8.2.8)
//
// An equation, stored as LaTeX source with the style it is typeset in and,
// once a typesetter has run, a one-page PDF of the result (`render`) that
// renderers without a typesetter draw. The whole `math` object is one
// register: the rendering belongs to the exact source, style, size and colour
// it was made from.

/// The content of a `math` item (format.md §8.2.8). One register: replaced whole.
public struct MathContent: Hashable, Sendable, Codable {
    /// LaTeX math-mode source without delimiters, at most `MathSource.maxBytes` UTF-8 bytes.
    public var latex: String
    /// Display style (`true`) or text (inline) style (`false`).
    public var display: Bool
    /// Font size of the typeset result in points (1 em): greater than 0, at most 1000.
    public var size: Double
    /// The colour of every mark.
    public var color: Color
    /// The typeset result: a PDF whose first page is the typeset box. Nil until a typesetter ran.
    public var render: BlobRef?
    /// The size in points of `render`'s first (effective) page; set exactly when `render` is.
    public var renderSize: Size?
    /// Informational: the typesetter and version that made `render`.
    public var engine: String?
    /// Unknown fields, re-emitted unchanged.
    public var extra: [String: JSONValue]

    public init(latex: String, display: Bool = true, size: Double = 20, color: Color = .black, render: BlobRef? = nil,
                renderSize: Size? = nil, engine: String? = nil, extra: [String: JSONValue] = [:]) {
        self.latex = latex; self.display = display; self.size = size; self.color = color
        self.render = render; self.renderSize = renderSize; self.engine = engine; self.extra = extra
    }

    /// Media type of a render.
    public static let renderType = "application/pdf"

    /// The reason the value breaks format.md §8.2.8 or §8.4, or nil.
    public var validationError: String? {
        if let why = MathSource.formatViolation(latex) { return why }
        if !TextContent.isValidSize(size) { return "math size out of range" }
        switch (render, renderSize) {
        case (nil, nil): break
        case (let r?, let s?):
            if BlobKind(mediaType: r.type) != .pdf { return "math render is not a PDF" }
            if !s.isPositive { return "math renderSize must be positive" }
        default: return "math render and renderSize go together"
        }
        return nil
    }

    /// The same equation without its rendering: what a writer stores after
    /// changing the source or style without a typesetter.
    public var withoutRender: MathContent {
        var c = self
        c.render = nil; c.renderSize = nil; c.engine = nil
        return c
    }

    /// True when `other` is the same equation as typeset: source, style,
    /// size and colour (the rendering and unknown fields aside).
    public func typesetsLike(_ other: MathContent) -> Bool {
        latex == other.latex && display == other.display && InkJSON.round3(size) == InkJSON.round3(other.size)
            && color == other.color
    }

    static let knownKeys: Set<String> = ["latex", "display", "size", "color", "render", "renderSize", "engine"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        latex = try c.decode(String.self, "latex")
        display = try c.decode(Bool.self, "display")
        size = try c.decode(Double.self, "size")
        color = try c.decode(Color.self, "color")
        render = try c.decodeIfPresent(BlobRef.self, "render")
        renderSize = try c.decodeIfPresent(Size.self, "renderSize")
        engine = try c.decodeIfPresent(String.self, "engine")
        extra = try c.extra(excluding: Self.knownKeys)
        if let why = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let why = validationError {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why))
        }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(latex, "latex")
        try c.encode(display, "display")
        try c.encode(InkJSON.round3(size), "size")
        try c.encode(color, "color")
        try c.encodeIfPresent(render, "render")
        try c.encodeIfPresent(renderSize, "renderSize")
        try c.encodeIfPresent(engine, "engine")
        try c.encodeExtra(extra, excluding: Self.knownKeys)
    }
}

/// Checks of LaTeX sources (format.md §8.2.8 "Limits of typesetting", §9):
/// the format's length rule, and the bounds a source must stay within before
/// any typesetter parses it. Linear in the source, no recursion, no allocation
/// beyond a group stack bounded by `maxDepth`.
public enum MathSource {
    /// Most UTF-8 bytes of a source (format.md §8.4).
    public static let maxBytes = 8_192
    /// Most tokens a typesetter is given.
    public static let maxTokens = 4_096
    /// Deepest nesting a typesetter is given.
    public static let maxDepth = 64

    /// Why a source cannot be typeset.
    public enum Issue: Error, Hashable, Sendable, CustomStringConvertible {
        /// Breaks the format (§8.2.8): too long or a control character.
        case invalid(String)
        /// More than `maxTokens` tokens.
        case tooManyTokens
        /// Nesting deeper than `maxDepth`.
        case tooDeep
        /// A group closed by the wrong kind, closed without being opened, or never closed.
        case unbalanced(String)
        /// Nothing but white space.
        case empty

        public var description: String {
            switch self {
            case .invalid(let why): return why
            case .tooManyTokens: return "the equation has more than \(MathSource.maxTokens) symbols"
            case .tooDeep: return "the equation nests deeper than \(MathSource.maxDepth) levels"
            case .unbalanced(let why): return why
            case .empty: return "the equation is empty"
            }
        }
    }

    /// The reason `latex` breaks the format's rules (length, control
    /// characters), or nil. Such a value makes the revision invalid.
    public static func formatViolation(_ latex: String) -> String? {
        if latex.utf8.count > maxBytes { return "LaTeX source longer than \(maxBytes) bytes" }
        if !TextRun.isValidText(latex) { return "LaTeX source holds a control character" }
        return nil
    }

    private enum Group: Equatable { case brace, left, environment, bracket }

    /// Infix fractions: the rest of their group becomes the denominator, one
    /// level down, and a typesetter parses it recursively (`a \over b \over c`).
    private static let infixCommands: Set<String> = ["over", "atop", "choose", "brack", "brace"]

    /// Why `latex` may not be typeset, or nil when it may (format.md §8.2.8).
    /// Empty sources are refused too (`allowEmpty` lets a renderer draw
    /// nothing instead).
    public static func check(_ latex: String, allowEmpty: Bool = false) -> Issue? {
        if let why = formatViolation(latex) { return .invalid(why) }
        let u = Array(latex.utf8)
        var stack: [(group: Group, base: Int, run: Int)] = []
        var base = 0, run = 0, tokens = 0, maxSeen = 0
        var i = 0
        func isLetter(_ c: UInt8) -> Bool { (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func open(_ g: Group) -> Issue? {
            let level = base + run + 1
            guard level <= maxDepth else { return .tooDeep }
            stack.append((g, base, run))
            base = level
            run = 0
            maxSeen = max(maxSeen, level)
            return nil
        }
        func close(_ g: Group, _ name: String) -> Issue? {
            guard let top = stack.popLast() else { return .unbalanced("\(name) without an opening") }
            guard top.group == g else { return .unbalanced("\(name) closes a different group") }
            base = top.base
            // A group opened inside a run was an argument: the run goes on after
            // it (`\frac{a}\frac{b}…` nests each `\frac` in the one before).
            run = top.run
            return nil
        }
        while i < u.count {
            let c = u[i]
            if isSpace(c) { i += 1; continue }
            // A multi-byte UTF-8 character is one token: skip its continuation bytes.
            var next = i + 1
            while next < u.count, u[next] & 0xC0 == 0x80 { next += 1 }
            tokens += 1
            guard tokens <= maxTokens else { return .tooManyTokens }
            if c == 0x5C {   // backslash: a control sequence
                var j = i + 1
                if j < u.count, isLetter(u[j]) {
                    while j < u.count, isLetter(u[j]) { j += 1 }
                } else if j < u.count {
                    j += 1
                    while j < u.count, u[j] & 0xC0 == 0x80 { j += 1 }
                }
                let name = String(decoding: u[(i + 1)..<j], as: UTF8.self)
                i = j
                switch name {
                case "left": if let e = open(.left) { return e }
                case "right": if let e = close(.left, "\\right") { return e }
                case "begin": if let e = open(.environment) { return e }
                case "end": if let e = close(.environment, "\\end") { return e }
                case _ where infixCommands.contains(name):
                    base += 1
                    run = 0
                    guard base <= maxDepth else { return .tooDeep }
                    maxSeen = max(maxSeen, base)
                default:
                    run += 1
                    guard base + run <= maxDepth else { return .tooDeep }
                    maxSeen = max(maxSeen, base + run)
                    // `\sqrt[n]`: the degree is parsed recursively up to the next `]`.
                    if name == "sqrt", i < u.count, u[i] == 0x5B {
                        tokens += 1
                        guard tokens <= maxTokens else { return .tooManyTokens }
                        if let e = open(.bracket) { return e }
                        i += 1
                    }
                }
                continue
            }
            switch c {
            case 0x7B: if let e = open(.brace) { return e }   // {
            case 0x7D: if let e = close(.brace, "}") { return e }   // }
            case 0x5D where stack.last?.group == .bracket:   // ] ending a \sqrt degree
                if let e = close(.bracket, "]") { return e }
            case 0x5E, 0x5F:   // ^ _
                run += 1
                guard base + run <= maxDepth else { return .tooDeep }
                maxSeen = max(maxSeen, base + run)
            default:
                run = 0
            }
            i = next
        }
        if let top = stack.last {
            switch top.group {
            case .brace: return .unbalanced("a { is never closed")
            case .left: return .unbalanced("a \\left has no \\right")
            case .environment: return .unbalanced("a \\begin has no \\end")
            case .bracket: return .unbalanced("a \\sqrt[ has no ]")
            }
        }
        if tokens == 0, !allowEmpty { return .empty }
        return nil
    }
}

extension Item {
    /// A math item.
    public static func math(id: UUID = UUID(), _ content: MathContent, frame: Rect, z: String,
                            layer: ItemLayer = .content, rec: RecordingLink? = nil) -> Item {
        Item(id: id, kind: .math, layer: layer, frame: frame, z: z, rec: rec, math: content)
    }

    /// Every blob reference the item's own fields hold: `blob`, a video's
    /// `poster` and a math item's `render` (format.md §8.1.1), each once.
    public var blobReferences: [BlobRef] {
        var refs: [BlobRef] = []
        for r in ([blob, poster, math?.render].compactMap({ $0 }) + (text?.math ?? []).compactMap(\.math.render)) where !refs.contains(where: { $0.sha256 == r.sha256 }) {
            refs.append(r)
        }
        return refs
    }
}

extension NoteOps {
    /// A math item's content for `latex`: NFC, `\r\n` and `\r` as `\n`,
    /// checked against format.md §8.2.8 and the typesetting limits (an empty
    /// or unbalanced source is refused).
    public static func math(_ latex: String, display: Bool = true, size: Double = 20,
                            color: Color = .black) throws -> MathContent {
        let normalized = latex.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        if let issue = MathSource.check(normalized) { throw AttachmentOpsError.invalidMath(issue.description) }
        let content = MathContent(latex: normalized, display: display, size: size, color: color)
        if let why = content.validationError { throw AttachmentOpsError.invalidMath(why) }
        return content
    }

    /// The frame a math item gets before any typesetter ran: as many
    /// monospace characters as its longest line at 0.6 em, 1.6 em per line,
    /// within the page's content width. The app replaces it with the
    /// render's size when it typesets (format.md §8.2.8).
    public static func estimatedMathSize(_ content: MathContent, maxWidth: Double) -> Size {
        let lines = content.latex.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map { $0.count }.max() ?? 1
        let w = min(max(Double(longest) * 0.6 * content.size, content.size), max(maxWidth, 1))
        let h = Double(max(lines.count, 1)) * 1.6 * content.size
        return Size(w: InkJSON.round3(w), h: InkJSON.round3(h))
    }

    /// Places a math item on `page`. With a `render` (and `renderSize`) the
    /// frame is the render's size (`width` scales it, keeping the aspect);
    /// without, `estimatedMathSize`. A margin from the top and left, or `at`.
    public static func placeMath(_ content: MathContent, on page: Page, pageSize: PageSize, frame: Rect? = nil,
                                 at origin: (x: Double, y: Double)? = nil, width: Double? = nil,
                                 layer: ItemLayer = .content, rec: RecordingLink? = nil, id: UUID = UUID(),
                                 extraZ: [String] = []) throws -> ItemPlacement {
        guard page.items.count < Limits.itemsPerPage else { throw AttachmentOpsError.pageFull }
        if let why = content.validationError { throw AttachmentOpsError.invalidMath(why) }
        let rect: Rect
        if let frame {
            rect = frame
        } else {
            var natural = content.renderSize ?? estimatedMathSize(content, maxWidth: contentBox(pageSize).w)
            if let width {
                guard width.isFinite, width > 0 else { throw AttachmentOpsError.invalidFrame("width must be positive") }
                natural = Size(w: width, h: width * natural.h / natural.w)
            }
            rect = Rect(x: InkJSON.round3(origin?.x ?? Limits.margin), y: InkJSON.round3(origin?.y ?? Limits.margin),
                        w: InkJSON.round3(natural.w), h: InkJSON.round3(natural.h))
        }
        try validate(frame: rect)
        let item = Item.math(id: id, content, frame: rect, z: topZ(of: page, layer: layer, extra: extraZ), layer: layer, rec: rec)
        return ItemPlacement(page: page.id, item: item)
    }

    /// The frame a math item takes when its content changes from `old` to
    /// `new` (format.md §8.2.8): with a new render, the same top-left corner
    /// and the new render's size times the scale the frame had to the old
    /// render (1 without one); otherwise the frame as it is.
    public static func mathFrame(_ frame: Rect, from old: MathContent?, to new: MathContent) -> Rect {
        guard let size = new.renderSize, new.render != nil, new.render != old?.render else { return frame }
        var scale = 1.0
        if let previous = old?.renderSize, old?.render != nil, previous.w > 0, previous.h > 0 {
            let s = frame.w / previous.w
            if s.isFinite, s > 0 { scale = s }
        }
        return Rect(x: frame.x, y: frame.y, w: InkJSON.round3(size.w * scale), h: InkJSON.round3(size.h * scale))
    }

    /// Changes the math item `id` to `content` (one `setItem(math)`, and a
    /// `setItem(frame)` when a new render moves the frame, `mathFrame`); nil
    /// when there is no such math item or nothing changes.
    public static func setMath(_ id: UUID, to content: MathContent, on page: Page) throws -> ItemEdit? {
        if let why = content.validationError { throw AttachmentOpsError.invalidMath(why) }
        guard let i = page.items.firstIndex(where: { $0.id == id }), page.items[i].kind == .math else { return nil }
        let item = page.items[i]
        let frame = mathFrame(item.frame, from: item.math, to: content)
        var ops: [Op] = []
        var out = page
        if item.math != content {
            ops.append(.setItem(page: page.id, itemId: id, change: .math(content)))
            out.items[i].math = content
        }
        if frame.rounded != item.frame.rounded {
            try validate(frame: frame)
            ops.append(.setItem(page: page.id, itemId: id, change: .frame(frame)))
            out.items[i].frame = frame
        }
        guard !ops.isEmpty else { return nil }
        return ItemEdit(ops: ops, page: out)
    }
}
