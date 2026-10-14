import Foundation
import XCTest

/// Guards the app's String Catalogs (`docs/localization.md`, task L). The app only builds in the CI
/// `app` job, so the rules that can be checked without Xcode are checked here, in every `swift test`
/// (Linux included): the catalog is complete, Spanish has plural rules for every counted string, the
/// placeholders agree, and no user-visible string literal in `Apps/` bypasses localization.
final class LocalizationCatalogTests: XCTestCase {
    /// Languages that must be complete. Add a code here when a language is added (CONTRIBUTING).
    static let languages = ["es"]

    // MARK: - Locating and loading

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let apps = repo.appendingPathComponent("Apps/Sempere")
    static let localization = apps.appendingPathComponent("Localization")
    /// Source folders whose literals are interface text. Debug, demo and performance code is exempt.
    static let sourceFolders = ["SempereApp", "SempereShared", "SempereWidgets"]
    static let exemptFiles: Set<String> = [
        "DebugLaunch.swift", "DebugProbe.swift", "DemoVault.swift", "DemoHandwriting.swift",
        "DemoLaunch.swift", "Perf.swift",
    ]

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.localization.path),
                          "the app sources are not part of this checkout")
    }

    func catalog(_ name: String) throws -> Catalog {
        try Catalog(url: Self.localization.appendingPathComponent("\(name).xcstrings"))
    }

    func sources() throws -> [(name: String, scan: SwiftScan)] {
        var out: [(String, SwiftScan)] = []
        for folder in Self.sourceFolders {
            let dir = Self.apps.appendingPathComponent(folder)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".swift") && !Self.exemptFiles.contains(name) {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                out.append(("\(folder)/\(name)", SwiftScan(text)))
            }
        }
        return out
    }

    // MARK: - Completeness

    func testCatalogsParse() throws {
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            let c = try catalog(name)
            XCTAssertEqual(c.sourceLanguage, "en", name)
            XCTAssertFalse(c.entries.isEmpty, "\(name) is empty")
        }
    }

    func testEveryKeyHasEveryLanguage() throws {
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            for (key, entry) in try catalog(name).entries where entry.shouldTranslate {
                for lang in Self.languages {
                    switch entry.value(lang) {
                    case .none:
                        XCTFail("\(name): “\(key)” has no \(lang) value")
                    case .plain(let text):
                        XCTAssertFalse(text.isEmpty, "\(name): “\(key)” is empty in \(lang)")
                    case .plural(let forms):
                        XCTAssertFalse(forms.values.contains(""), "\(name): “\(key)” has an empty \(lang) form")
                        XCTAssertTrue(Set(forms.keys).isSuperset(of: Self.pluralCategories(lang)),
                                      "\(name): “\(key)” \(lang) needs \(Self.pluralCategories(lang).sorted()), has \(forms.keys.sorted())")
                    case .device(let forms):
                        XCTAssertNotNil(forms["other"], "\(name): “\(key)” \(lang) device variation needs “other”")
                        XCTAssertFalse(forms.values.contains(""), "\(name): “\(key)” has an empty \(lang) form")
                    }
                }
            }
        }
    }

    /// CLDR plural categories a complete translation provides.
    static func pluralCategories(_ lang: String) -> Set<String> {
        switch lang {
        case "es", "fr", "it", "pt": return ["one", "many", "other"]
        case "ja", "ko", "zh": return ["other"]
        default: return ["one", "other"]
        }
    }

    /// Every entry that varies by number has the English forms too, and no form invents a placeholder.
    func testPluralEntriesAreWellFormed() throws {
        for (key, entry) in try catalog("Localizable").entries where entry.shouldTranslate {
            guard case .plural(let en)? = entry.value("en") else {
                if case .plural? = entry.value("es") {
                    XCTFail("“\(key)” is plural in Spanish but not in English: give the source language its forms")
                }
                continue
            }
            XCTAssertTrue(Set(en.keys).isSuperset(of: ["one", "other"]), "“\(key)” needs en one/other")
            XCTAssertTrue(Specifier.list(in: key).contains { $0.kind == .integer },
                          "“\(key)”: a plural needs an integer placeholder (%lld) to vary by")
        }
    }

    /// The counted strings of the source (an interpolation named `count`, `….count`, …) are plurals.
    func testCountedStringsArePlural() throws {
        let entries = try catalog("Localizable").entries
        var missing: [String] = []
        for (file, scan) in try sources() {
            for lit in scan.literals where lit.isLocalizing {
                guard lit.interpolations.contains(where: Self.looksLikeCount) else { continue }
                guard let key = lit.key, let entry = entries[Self.normalized(key)] ?? entries.first(where: { Self.normalized($0.key) == Self.normalized(key) })?.value
                else { continue } // reported by testSourceLiteralsAreInCatalog
                if case .plural? = entry.value("en") { continue }
                if (entry.comment ?? "").contains("[not-plural]") { continue }
                missing.append("\(file):\(lit.line) “\(key)”")
            }
        }
        XCTAssertTrue(missing.isEmpty, "counted strings without plural variations (add en and es forms, or mark the comment “[not-plural]”):\n" + missing.joined(separator: "\n"))
    }

    static func looksLikeCount(_ expr: String) -> Bool {
        let e = expr.trimmingCharacters(in: .whitespaces)
        if e.hasSuffix(".count") || e.hasSuffix(".count)") || e.hasSuffix("Count") { return true }
        return e == "count"
    }

    func testPlaceholdersAgree() throws {
        for (key, entry) in try catalog("Localizable").entries where entry.shouldTranslate {
            let source = Specifier.list(in: key).map(\.kind).sorted { $0.rawValue < $1.rawValue }
            for lang in Self.languages {
                switch entry.value(lang) {
                case .plain(let text)?:
                    XCTAssertEqual(Specifier.list(in: text).map(\.kind).sorted { $0.rawValue < $1.rawValue }, source,
                                   "“\(key)”: \(lang) changes the placeholders")
                case .device(let forms)?:
                    for (device, text) in forms {
                        XCTAssertEqual(Specifier.list(in: text).map(\.kind).sorted { $0.rawValue < $1.rawValue }, source,
                                       "“\(key)”: \(lang) \(device) changes the placeholders")
                    }
                case .plural(let forms)?:
                    for (category, text) in forms {
                        let used = Specifier.list(in: text).map(\.kind)
                        var pool = source
                        for kind in used {
                            if let i = pool.firstIndex(of: kind) { pool.remove(at: i) } else {
                                XCTFail("“\(key)”: \(lang) \(category) uses a placeholder the source does not have")
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
    }

    /// A Spanish string that is not plural must not make a verb agree with a bare count: “faltan 1”
    /// and “1 de 5 siguen…” are wrong at 1. Reword around the number (“sin listar: %lld”) or add
    /// plural variations.
    func testSpanishVerbsDoNotAgreeWithABareCount() throws {
        let count = #"%(\d\$)?lld"#
        let verbs = #"(faltan|quedan|siguen|son|están|han|se han|no se han)"#
        let patterns = [#"\b\#(verbs) \#(count)"#, #"\#(count)( de \#(count))? \#(verbs)\b"#]
        var bad: [String] = []
        for (key, entry) in try catalog("Localizable").entries where entry.shouldTranslate {
            guard case .plain(let es)? = entry.value("es") else { continue }
            if patterns.contains(where: { es.range(of: $0, options: .regularExpression) != nil }) {
                bad.append("“\(key)” → “\(es)”")
            }
        }
        XCTAssertTrue(bad.isEmpty, "Spanish verbs agreeing with a count in a non-plural string:\n" + bad.joined(separator: "\n"))
    }

    /// A Spanish string longer than twice its source does not fit the double-length layouts that
    /// `scripts/app.sh pseudo` proves (docs/localization.md). Long sentences wrap and are exempt.
    func testShortStringsStayWithinTheDoubleLengthBudget() throws {
        for (key, entry) in try catalog("Localizable").entries where entry.shouldTranslate {
            guard key.count < 40, case .plain(let es)? = entry.value("es") else { continue }
            XCTAssertLessThanOrEqual(es.count, max(2 * key.count, key.count + 12),
                                     "“\(key)” → “\(es)” is too long for its layout")
        }
    }

    /// The English source is American English (docs/localization.md): one spelling per word, so one
    /// catalog entry serves every place that says it. Checks the keys and any English variations.
    func testEnglishIsAmericanSpelling() throws {
        let british = try NSRegularExpression(
            pattern: #"\b(colour[a-z]*|recognis[a-z]*|cancell(ed|ing)|grey(ed)?|licence|centred?|behaviour[a-z]*|favourite[a-z]*|organis[a-z]*)\b"#,
            options: [.caseInsensitive])
        var bad: [String] = []
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            for (key, entry) in try catalog(name).entries {
                var texts = [key]
                switch entry.value("en") {
                case .plain(let text)?: texts.append(text)
                case .plural(let forms)?, .device(let forms)?: texts += forms.values
                case nil: break
                }
                for text in texts where british.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    bad.append("\(name): “\(text)”")
                }
            }
        }
        XCTAssertTrue(bad.isEmpty, "British spellings in the English source:\n" + bad.joined(separator: "\n"))
    }

    // MARK: - Source against catalog

    func testSourceLiteralsAreInCatalog() throws {
        let known = Set(try catalog("Localizable").entries.keys.map(Self.normalized))
        var missing: [String] = []
        for (file, scan) in try sources() {
            for lit in scan.literals where lit.isLocalizing {
                guard let key = lit.key, lit.hasLetters else { continue }
                if !known.contains(Self.normalized(key)) { missing.append("\(file):\(lit.line) “\(key)”") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "\(missing.count) literals are not in Localizable.xcstrings (add them with scripts/l10n.py merge):\n" + missing.joined(separator: "\n"))
    }

    /// Count-like interpolations must be `%lld` in the catalog key, or the lookup silently misses.
    func testCountPlaceholdersAreIntegers() throws {
        let entries = try catalog("Localizable").entries
        var wrong: [String] = []
        for (file, scan) in try sources() {
            for lit in scan.literals where lit.isLocalizing {
                guard let key = lit.key else { continue }
                let norm = Self.normalized(key)
                guard let (catalogKey, _) = entries.first(where: { Self.normalized($0.key) == norm }) else { continue }
                let specs = Specifier.list(in: catalogKey)
                for (i, expr) in lit.interpolations.enumerated() where Self.looksLikeCount(expr) && i < specs.count {
                    if specs[i].kind != .integer { wrong.append("\(file):\(lit.line) “\(catalogKey)”: \(expr) is an Int, the key needs %lld") }
                }
            }
        }
        XCTAssertTrue(wrong.isEmpty, wrong.joined(separator: "\n"))
    }

    /// Literals in a position that shows text without localizing it.
    func testNoLiteralBypassesLocalization() throws {
        var bypass: [String] = []
        for (file, scan) in try sources() {
            for lit in scan.literals where lit.isBypass && lit.hasLetters {
                if lit.lineText.contains("l10n:ignore") { continue }
                if Self.allowedVerbatim.contains(lit.body) { continue }
                bypass.append("\(file):\(lit.line) “\(lit.body)”")
            }
        }
        XCTAssertTrue(bypass.isEmpty, "user-visible literals that skip localization (use String(localized:), or mark a technical string with // l10n:ignore):\n" + bypass.joined(separator: "\n"))
    }

    static let allowedVerbatim: Set<String> = ["Sempere"]

    // MARK: - Info.plist strings and Siri phrases

    func testInfoPlistStringsMatchTheProject() throws {
        let c = try catalog("InfoPlist")
        let pbx = try String(contentsOf: Self.apps.appendingPathComponent("Sempere.xcodeproj/project.pbxproj"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"INFOPLIST_KEY_(NS\w+UsageDescription) = "([^"]*)";"#)
        let ns = pbx as NSString
        var seen: Set<String> = []
        for m in regex.matches(in: pbx, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)), value = ns.substring(with: m.range(at: 2))
            seen.insert(key)
            guard let entry = c.entries[key] else { XCTFail("InfoPlist.xcstrings has no \(key)"); continue }
            XCTAssertEqual(entry.value("en"), .plain(value), "\(key): the English text must equal the project's build setting")
        }
        XCTAssertGreaterThanOrEqual(seen.count, 4)
        let plist = try String(contentsOf: Self.apps.appendingPathComponent("SempereInfo.plist"), encoding: .utf8)
        let types = try NSRegularExpression(pattern: #"<key>UTTypeDescription</key>\s*<string>([^<]*)</string>"#)
        let p = plist as NSString
        let found = types.matches(in: plist, range: NSRange(location: 0, length: p.length)).map { p.substring(with: $0.range(at: 1)) }
        XCTAssertEqual(found.count, 3)
        for description in found {
            XCTAssertNotNil(c.entries[description], "UTTypeDescription “\(description)” is not in InfoPlist.xcstrings")
        }
    }

    func testSiriPhrasesAreLocalized() throws {
        let c = try catalog("AppShortcuts")
        let file = Self.apps.appendingPathComponent("SempereApp/VoiceNoteShortcuts.swift")
        let scan = SwiftScan(try String(contentsOf: file, encoding: .utf8))
        let phrases = scan.literals.map(\.body).filter { $0.contains("\\(.applicationName)") }
        XCTAssertGreaterThanOrEqual(phrases.count, 4)
        for phrase in phrases {
            let key = phrase.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}")
            guard let entry = c.entries[key] else { XCTFail("AppShortcuts.xcstrings has no “\(key)”"); continue }
            if case .plain(let es)? = entry.value("es") {
                XCTAssertTrue(es.contains("${applicationName}"), "“\(key)”: the Spanish phrase needs the app name")
            } else {
                XCTFail("“\(key)” has no Spanish phrase")
            }
        }
    }

    // MARK: - Normal form

    /// The comparison form of a key: placeholders unified, so `%lld` in the catalog matches `\(n)` in code.
    static func normalized(_ key: String) -> String {
        var out = ""
        var i = key.startIndex
        while i < key.endIndex {
            if key[i] == "%", let spec = Specifier.parse(key, at: i) {
                out += spec.isLiteralPercent ? "%%" : "%@"
                i = spec.end
            } else {
                out.append(key[i]); i = key.index(after: i)
            }
        }
        return out
    }
}

// MARK: - Catalog model

struct Catalog {
    enum Value: Equatable {
        case plain(String)
        case plural([String: String])
        case device([String: String])
    }

    struct Entry {
        var comment: String?
        var shouldTranslate: Bool
        var localizations: [String: [String: Any]]

        func value(_ lang: String) -> Value? {
            guard let loc = localizations[lang] else { return nil }
            if let unit = loc["stringUnit"] as? [String: Any], let v = unit["value"] as? String { return .plain(v) }
            if let vars = loc["variations"] as? [String: Any] {
                func forms(_ any: Any?) -> [String: String]? {
                    guard let dict = any as? [String: Any] else { return nil }
                    var out: [String: String] = [:]
                    for (k, v) in dict {
                        guard let unit = (v as? [String: Any])?["stringUnit"] as? [String: Any],
                              let text = unit["value"] as? String else { return nil }
                        out[k] = text
                    }
                    return out
                }
                if let p = forms(vars["plural"]) { return .plural(p) }
                if let d = forms(vars["device"]) { return .device(d) }
            }
            return nil
        }
    }

    var sourceLanguage: String
    var entries: [String: Entry]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceLanguage = root["sourceLanguage"] as? String ?? ""
        entries = strings.mapValues { raw in
            Entry(comment: raw["comment"] as? String,
                  shouldTranslate: (raw["shouldTranslate"] as? Bool) ?? true,
                  localizations: (raw["localizations"] as? [String: [String: Any]]) ?? [:])
        }
    }
}

// MARK: - Format specifiers

struct Specifier {
    enum Kind: Int { case integer, float, object, percent }
    var kind: Kind
    var end: String.Index
    var isLiteralPercent: Bool { kind == .percent }

    /// Parses `%lld`, `%@`, `%1$@`, `%.2f`, `%%` at `index` (which holds a `%`).
    static func parse(_ s: String, at index: String.Index) -> Specifier? {
        var i = s.index(after: index)
        guard i < s.endIndex else { return nil }
        if s[i] == "%" { return Specifier(kind: .percent, end: s.index(after: i)) }
        // optional position `n$`
        var j = i
        while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
        if j > i, j < s.endIndex, s[j] == "$" { i = s.index(after: j) }
        while i < s.endIndex, "-+ #0123456789.".contains(s[i]) { i = s.index(after: i) }
        while i < s.endIndex, "lhqzt".contains(s[i]) { i = s.index(after: i) }
        guard i < s.endIndex else { return nil }
        let kind: Kind
        switch s[i] {
        case "d", "i", "u", "D", "U", "x", "X", "o": kind = .integer
        case "f", "F", "e", "E", "g", "G", "a", "A": kind = .float
        case "@", "s", "S", "c", "C": kind = .object
        default: return nil
        }
        return Specifier(kind: kind, end: s.index(after: i))
    }

    /// The placeholders of a string, in order, without `%%`.
    static func list(in s: String) -> [Specifier] {
        var out: [Specifier] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%", let spec = parse(s, at: i) {
                if !spec.isLiteralPercent { out.append(spec) }
                i = spec.end
            } else {
                i = s.index(after: i)
            }
        }
        return out
    }
}

// MARK: - A small Swift lexer: string literals outside comments

struct SwiftLiteral {
    /// The raw text between the quotes (escapes and interpolations unprocessed).
    var body: String
    var line: Int
    var lineText: String
    /// The code just before the opening quote, comments and earlier string bodies blanked.
    var before: String

    static let localizingSinks: [String] = [
        #"\bText\(\s*$"#, #"\bButton\(\s*$"#, #"\bLabel\(\s*$"#, #"\bToggle\(\s*$"#, #"\bSection\(\s*$"#,
        #"\bPicker\(\s*$"#, #"\bTextField\(\s*$"#, #"\bSecureField\(\s*$"#, #"\bLabeledContent\(\s*$"#,
        #"\bMenu\(\s*$"#, #"\bLink\(\s*$"#, #"\bNavigationLink\(\s*$"#, #"\bShareLink\(\s*$"#,
        #"\bProgressView\(\s*$"#, #"\bStepper\(\s*$"#, #"\bGroupBox\(\s*$"#, #"\bDisclosureGroup\(\s*$"#,
        #"\bContentUnavailableView\(\s*$"#, #"\.navigationTitle\(\s*$"#, #"\.navigationSubtitle\(\s*$"#,
        #"\.alert\(\s*$"#, #"\.confirmationDialog\(\s*$"#, #"\.help\(\s*$"#, #"\.accessibilityLabel\(\s*$"#,
        #"\.accessibilityHint\(\s*$"#, #"\.accessibilityValue\(\s*$"#, #"\.badge\(\s*$"#,
        #"\bString\(\s*localized:\s*$"#, #"\bLocalizedStringResource\(\s*$"#, #"\bLocalizedStringKey\(\s*$"#,
        #"\bNSLocalizedString\(\s*$"#, #"\bIntentDescription\(\s*$"#, #"\.configurationDisplayName\(\s*$"#,
        #"\.displayName\(\s*$"#, #"\bshortTitle:\s*$"#, #"LocalizedStringResource\s*=\s*$"#,
    ]
    /// Positions that show a `String` as is.
    static let bypassSinks: [String] = [
        #"\bText\(\s*verbatim:\s*$"#,
        #"\berrorMessage\s*=\s*$"#, #"\bUIAlertController\(\s*title:\s*$"#, #"\bUIAction\(\s*title:\s*$"#,
        #"\bUIMenu\(\s*title:\s*$"#, #"\bUIBarButtonItem\(\s*title:\s*$"#, #"\bplaceholder\s*=\s*$"#,
        #"\bmessage:\s*$"#,
    ]

    var isLocalizing: Bool { Self.localizingSinks.contains { before.range(of: $0, options: .regularExpression) != nil } }
    var isBypass: Bool { Self.bypassSinks.contains { before.range(of: $0, options: .regularExpression) != nil } }
    var hasLetters: Bool { (key ?? body).unicodeScalars.contains { CharacterSet.letters.contains($0) } }

    /// The expressions of the interpolations, in order.
    var interpolations: [String] { processed.interpolations }
    /// The catalog key Swift would extract: interpolations become `%@`, `%` becomes `%%`, escapes resolve.
    var key: String? { processed.key }

    private var processed: (key: String?, interpolations: [String]) {
        let scalars = Array(body.unicodeScalars)
        var out = String.UnicodeScalarView()
        var exprs: [String] = []
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count {
                let n = scalars[i + 1]
                switch n {
                case "(":
                    var depth = 1, j = i + 2
                    while j < scalars.count, depth > 0 {
                        if scalars[j] == "(" { depth += 1 } else if scalars[j] == ")" { depth -= 1 }
                        j += 1
                    }
                    exprs.append(String(String.UnicodeScalarView(scalars[(i + 2)..<max(i + 2, j - 1)])))
                    out.append(contentsOf: "%@".unicodeScalars)
                    i = j
                    continue
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "'": out.append("'")
                case "0": out.append("\0")
                case "u":
                    if i + 2 < scalars.count, scalars[i + 2] == "{", let close = scalars[(i + 3)...].firstIndex(of: "}"),
                       let v = UInt32(String(String.UnicodeScalarView(scalars[(i + 3)..<close])), radix: 16),
                       let u = Unicode.Scalar(v) {
                        out.append(u); i = close + 1; continue
                    }
                    return (nil, exprs)
                default: return (nil, exprs)
                }
                i += 2
                continue
            }
            if c == "%" { out.append(contentsOf: "%%".unicodeScalars) } else { out.append(c) }
            i += 1
        }
        return (String(out), exprs)
    }
}

struct SwiftScan {
    private(set) var literals: [SwiftLiteral] = []
    private let s: [Unicode.Scalar]
    private var masked: [Unicode.Scalar]
    private var lineStarts: [Int] = [0]

    init(_ text: String) {
        s = Array(text.unicodeScalars)
        masked = s
        for (i, c) in s.enumerated() where c == "\n" { lineStarts.append(i + 1) }
        var i = 0
        while i < s.count { i = step(i) }
    }

    private func line(of index: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    private func text(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(s[range])) }

    /// Advances over one token of code and returns the next index.
    private mutating func step(_ i: Int) -> Int {
        let c = s[i]
        if c == "/", i + 1 < s.count, s[i + 1] == "/" {
            var j = i
            while j < s.count, s[j] != "\n" { masked[j] = " "; j += 1 }
            return j
        }
        if c == "/", i + 1 < s.count, s[i + 1] == "*" {
            var depth = 0, j = i
            while j < s.count {
                if s[j] == "/", j + 1 < s.count, s[j + 1] == "*" { depth += 1; masked[j] = " "; masked[j + 1] = " "; j += 2; continue }
                if s[j] == "*", j + 1 < s.count, s[j + 1] == "/" {
                    depth -= 1; masked[j] = " "; masked[j + 1] = " "; j += 2
                    if depth == 0 { break }
                    continue
                }
                if s[j] != "\n" { masked[j] = " " }
                j += 1
            }
            return j
        }
        if c == "#" {
            var j = i
            while j < s.count, s[j] == "#" { j += 1 }
            if j < s.count, s[j] == "\"" { return scanString(quote: j, hashes: j - i) }
            return i + 1
        }
        if c == "\"" { return scanString(quote: i, hashes: 0) }
        return i + 1
    }

    /// Scans the literal whose opening quote is at `quote`; returns the index after its closing delimiter.
    private mutating func scanString(quote: Int, hashes: Int) -> Int {
        let triple = quote + 2 < s.count && s[quote + 1] == "\"" && s[quote + 2] == "\""
        let open = quote + (triple ? 3 : 1)
        let contextEnd = quote - hashes
        let before = String(String.UnicodeScalarView(masked[max(0, contextEnd - 90)..<contextEnd]))
        var i = open
        var bodyEnd = open
        var closeLen = 1
        scan: while i < s.count {
            let c = s[i]
            if c == "\\" {
                var k = 0
                while k < hashes, i + 1 + k < s.count, s[i + 1 + k] == "#" { k += 1 }
                if k == hashes, i + 1 + k < s.count, s[i + 1 + k] == "(" {
                    var depth = 1, j = i + 2 + k
                    while j < s.count, depth > 0 {
                        if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1 } else if s[j] == "\"" {
                            j = scanString(quote: j, hashes: 0); continue
                        }
                        j += 1
                    }
                    i = j
                    continue
                }
                i += 2 + k
                continue
            }
            if c == "\"" {
                let need = triple ? 3 : 1
                var n = 0
                while n < need, i + n < s.count, s[i + n] == "\"" { n += 1 }
                var h = 0
                while h < hashes, i + n + h < s.count, s[i + n + h] == "#" { h += 1 }
                if n == need, h == hashes { bodyEnd = i; closeLen = need + hashes; break scan }
            }
            if !triple, c == "\n" { bodyEnd = i; closeLen = 0; break scan } // unterminated: give up on this one
            i += 1
        }
        if i >= s.count { bodyEnd = s.count; closeLen = 0 }
        var body = text(open..<bodyEnd)
        if triple {
            var lines = body.components(separatedBy: "\n")
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            if let last = lines.popLast() {
                let indent = last.prefix { $0 == " " || $0 == "\t" }
                body = lines.map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }.joined(separator: "\n")
            }
        }
        let l = line(of: quote)
        let ls = lineStarts[l - 1]
        var le = ls
        while le < s.count, s[le] != "\n" { le += 1 }
        literals.append(SwiftLiteral(body: body, line: l, lineText: text(ls..<le), before: before))
        for j in open..<bodyEnd where masked[j] != "\n" { masked[j] = "_" }
        return min(s.count, bodyEnd + closeLen)
    }
}
