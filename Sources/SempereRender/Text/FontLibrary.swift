import Foundation
import Sempere

/// A font face loaded for text, with how it was found.
public struct FontFace: Sendable {
    public let font: OpenTypeFont
    /// The file it came from (identifies the face across runs and exports).
    public let url: URL
    public let faceIndex: Int

    /// A face loaded from somewhere other than a font file: `url` must name
    /// it uniquely (two faces with the same `url` and `faceIndex` must hold
    /// the same font), as exports share one subset per name. The app's
    /// CoreText shaper passes fonts built with `OutlineFont`.
    public init(font: OpenTypeFont, url: URL, faceIndex: Int) {
        self.font = font
        self.url = url
        self.faceIndex = faceIndex
    }

    /// A key unique per face.
    var key: String { url.path + "#\(faceIndex)" }
}

/// The fonts an export may draw text with (docs/attachments.md §6): the
/// bundled generic families (`sans`, `serif`, `mono`, with bold and italic
/// faces) and font packs: any OpenType or TrueType font (including
/// collections) under `$SEMPERE_FONT_DIR`, `$XDG_DATA_HOME/sempere/fonts`
/// (default `~/.local/share/sempere/fonts`) and the system font directories.
/// Packs are scanned only when a character needs them, once per library.
///
/// Thread-safe; one library can serve every export of a process.
public final class FontLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private let bundledDirectory: URL?
    private let packDirectories: [URL]
    private var loaded: [String: FontFace?] = [:]
    private var packs: [PackEntry]?
    /// `fallback`'s answers: its choice depends only on these inputs and the
    /// packs, which are scanned once, so entries never go stale.
    private var fallbacks: [FallbackKey: FontFace?] = [:]
    /// Cleared when it reaches this many entries (distinct characters × styles).
    static let maxCachedFallbacks = 65_536

    /// What a pack scan keeps per face: its names and cmap, not its bytes.
    private struct PackEntry {
        var url: URL
        var face: Int
        var family: String
        var subfamily: String
        var weight: Int
        var italic: Bool
        var cmap: CharacterMap
        /// "family subfamily", lowercased, and what `fallback` looks for in it.
        var name: String
        var isSerif: Bool
        var isMono: Bool
        var isNoto: Bool

        init(url: URL, face: Int, family: String, subfamily: String, weight: Int, italic: Bool, cmap: CharacterMap) {
            self.url = url
            self.face = face
            self.family = family
            self.subfamily = subfamily
            self.weight = weight
            self.italic = italic
            self.cmap = cmap
            name = (family + " " + subfamily).lowercased()
            isSerif = name.contains("serif") || name.contains("mincho") || name.contains("ming") || name.contains("song")
            isMono = name.contains("mono")
            isNoto = name.contains("noto")
        }
    }

    private struct FallbackKey: Hashable {
        var scalar: UInt32
        var region: String?
        var generic: TextContent.Font
        var bold: Bool
        var italic: Bool
    }

    /// - Parameters:
    ///   - bundled: the directory of the bundled Noto fonts (`SempereFonts.directory`).
    ///   - packs: font-pack directories, searched in order (`defaultPackDirectories()`).
    public init(bundled: URL?, packs: [URL]) {
        bundledDirectory = bundled
        packDirectories = packs
    }

    /// `$SEMPERE_FONT_DIR`, `$XDG_DATA_HOME/sempere/fonts` (or
    /// `~/.local/share/sempere/fonts`), then the system's font directories.
    public static func defaultPackDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var dirs: [String] = []
        if let d = environment["SEMPERE_FONT_DIR"], !d.isEmpty { dirs.append(d) }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let xdg = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        dirs.append(xdg + "/sempere/fonts")
        dirs += [home + "/.local/share/fonts", home + "/.fonts", "/usr/local/share/fonts", "/usr/share/fonts",
                 home + "/Library/Fonts", "/Library/Fonts", "/System/Library/Fonts"]
        return dirs.map { URL(fileURLWithPath: $0) }
    }

    // MARK: Bundled families

    /// The bundled face for a generic family and style, or nil when the
    /// bundled fonts are missing. Mono has no italic faces: the regular or
    /// bold face is returned and the caller slants it.
    public func bundledFace(_ family: TextContent.Font, bold: Bool, italic: Bool) -> FontFace? {
        guard let dir = bundledDirectory else { return nil }
        let base: String
        switch family.effective {
        case .serif: base = "NotoSerif"
        case .mono: base = "NotoSansMono"
        default: base = "NotoSans"
        }
        var style = bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular")
        if base == "NotoSansMono" { style = bold ? "Bold" : "Regular" }
        return load(dir.appendingPathComponent("\(base)-\(style).ttf"), face: 0)
    }

    /// Loads (once) face `face` of a font file.
    func load(_ url: URL, face: Int) -> FontFace? {
        let key = url.path + "#\(face)"
        lock.lock()
        if let f = loaded[key] { lock.unlock(); return f }
        lock.unlock()
        let f = (try? OpenTypeFont(contentsOf: url, face: face)).map { FontFace(font: $0, url: url, faceIndex: face) }
        lock.lock()
        loaded[key] = f
        lock.unlock()
        return f
    }

    // MARK: Font packs

    /// A pack face covering `scalar`, preferring the family that matches
    /// `lang` (Chinese, Japanese and Korean share code points), then `generic`
    /// (serif/mono), then the weight and slant asked for.
    public func fallback(for scalar: UInt32, lang: String?, generic: TextContent.Font, bold: Bool, italic: Bool) -> FontFace? {
        let wanted = Self.cjkRegion(lang: lang, scalar: scalar)
        let key = FallbackKey(scalar: scalar, region: wanted, generic: generic.effective, bold: bold, italic: italic)
        lock.lock()
        if let f = fallbacks[key] { lock.unlock(); return f }
        lock.unlock()
        let entries = scanPacks()
        var best: (score: Int, entry: PackEntry)?
        let region = wanted.map { " " + $0 }
        for (order, e) in entries.enumerated() where e.cmap.glyph(scalar) != 0 {
            var score = -order   // earlier directories (SEMPERE_FONT_DIR) win ties
            if let region, e.name.contains(region) { score += 100_000 }
            if (key.generic == .serif) == e.isSerif { score += 10_000 }
            if (key.generic == .mono) == e.isMono { score += 5_000 }
            if (e.weight >= 600) == bold { score += 2_000 }
            if e.italic == italic { score += 1_000 }
            if e.isNoto { score += 500 }
            if score > (best?.score ?? Int.min) { best = (score, e) }
        }
        let face = best.flatMap { load($0.entry.url, face: $0.entry.face) }
        lock.lock()
        if fallbacks.count >= Self.maxCachedFallbacks { fallbacks.removeAll() }
        fallbacks[key] = face
        lock.unlock()
        return face
    }

    /// The CJK region suffix Noto CJK families use (`jp`, `kr`, `sc`, `tc`,
    /// `hk`) for a language tag, or for kana / Hangul without one.
    static func cjkRegion(lang: String?, scalar: UInt32) -> String? {
        if let l = lang?.lowercased() {
            if l.hasPrefix("ja") { return "jp" }
            if l.hasPrefix("ko") { return "kr" }
            if l.hasPrefix("zh") {
                if l.contains("hk") || l.contains("mo") { return "hk" }
                if l.contains("hant") || l.contains("tw") { return "tc" }
                return "sc"
            }
        }
        switch scalar {
        case 0x3040...0x30FF, 0x31F0...0x31FF: return "jp"
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return "kr"
        default: return nil
        }
    }

    /// Every face under the pack directories (names and cmaps), scanned once.
    private func scanPacks() -> [PackEntry] {
        lock.lock()
        if let p = packs { lock.unlock(); return p }
        lock.unlock()
        var out: [PackEntry] = []
        var seen = Set<String>()
        let fm = FileManager.default
        var files = 0
        for dir in packDirectories {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                guard files < 20_000 else { break }
                let ext = url.pathExtension.lowercased()
                guard ["ttf", "otf", "ttc", "otc"].contains(ext) else { continue }
                let real = url.resolvingSymlinksInPath().path
                guard seen.insert(real).inserted else { continue }
                files += 1
                // Regular files only, never more than a font may be (a FIFO would block forever).
                guard let data = try? BoundedRead.contents(of: url, maxBytes: OpenTypeFont.maxFileBytes) else { continue }
                let bytes = [UInt8](data)
                let faces = (try? OpenTypeFont.faceCount(bytes)) ?? 0
                for face in 0..<min(faces, 64) {
                    guard let f = try? OpenTypeFont(data: bytes, face: face) else { continue }
                    out.append(PackEntry(url: url, face: face, family: f.family, subfamily: f.subfamily,
                                         weight: f.weight, italic: f.italic, cmap: f.cmap))
                }
            }
        }
        lock.lock()
        packs = out
        lock.unlock()
        return out
    }
}
