import Foundation
import XCTest

/// Every window of the app gets the whole app environment. A view that reads
/// an `@Environment` object its window was not given traps at once ("No
/// Observable object of type AppModel found"), and a shipped build did on the
/// Mac. The app only builds in the CI `app` job, so this reads the sources
/// (on Linux too, in every `swift test`): every scene the app declares
/// (`WindowGroup`, `Window`, `Settings`, …) must put the `AppModel`, the
/// `VaultLibrary` and the `RememberedKeys` of the `App` into its root view's
/// environment, either through `.environment(…)` each or through the shared
/// `appEnvironment(model:library:keys:)` modifier, which must itself inject
/// all three. A new window cannot miss one. No view may read the three with
/// a plain `@Environment(X.self)` either: the wrappers fall back instead of
/// trapping (`AppModelEnvironment.swift`).
final class AppSceneEnvironmentTests: XCTestCase {
    static let appSources = LocalizationCatalogTests.apps.appendingPathComponent("SempereApp")

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.appSources.path),
                          "the app sources are not part of this checkout")
    }

    func testEveryWindowGetsTheAppEnvironment() throws {
        let sources = try Self.loadSources()
        let report = try SceneEnvironmentCheck(sources: sources).run()
        XCTAssertGreaterThanOrEqual(report.scenes.count, 4, "library, note, Settings and Vault Keys at least: \(report.scenes)")
        XCTAssertEqual(report.problems, [], "every scene injects AppModel, VaultLibrary and RememberedKeys")
    }

    /// The crash that shipped came from a list row inside a window, not from a
    /// window's root: a plain `@Environment(AppModel.self)` traps whenever SwiftUI
    /// updates that view outside the window's environment. Views read the app-wide
    /// objects through `@AppModelEnvironment` / `@AppEnvironmentObject` (CLAUDE.md).
    func testNoViewReadsAnAppObjectWithAPlainEnvironment() throws {
        let reads = SceneEnvironmentCheck(sources: try Self.loadSources()).plainEnvironmentReads()
        XCTAssertEqual(reads, [], "use @AppModelEnvironment / @AppEnvironmentObject instead")
    }

    // MARK: - The checker on synthetic sources

    static let goodApp = """
        @main
        struct DemoApp: App {
            @State private var model: AppModel
            @State private var library = VaultLibrary()
            @State private var keys: RememberedKeys
            var body: some Scene {
                WindowGroup { content }   // "WindowGroup { Nothing() }" in a comment
                WindowGroup("Note", id: "note", for: NoteWindowValue.self) { $value in
                    if let value { NoteWindowView(value: value).appEnvironment(model: model, library: library, keys: keys) }
                }
                Settings {
                    SettingsView().environment(model).environment(library).environment(keys)
                }
            }
            private var content: some View {
                RootView().appEnvironment(model: model, library: library, keys: keys)
            }
        }
        """
    static let goodModifier = """
        struct AppEnvironment: ViewModifier {
            let model: AppModel
            let library: VaultLibrary
            let keys: RememberedKeys
            func body(content: Content) -> some View {
                content.environment(model).environment(library).environment(keys)
            }
        }
        extension View {
            func appEnvironment(model: AppModel, library: VaultLibrary, keys: RememberedKeys) -> some View {
                modifier(AppEnvironment(model: model, library: library, keys: keys))
            }
        }
        """

    func testTheCheckerAcceptsAnAppThatInjectsEverything() throws {
        let report = try SceneEnvironmentCheck(sources: ["App.swift": Self.goodApp, "Env.swift": Self.goodModifier]).run()
        XCTAssertEqual(report.scenes.count, 3)
        XCTAssertEqual(report.problems, [])
    }

    func testTheCheckerFindsAWindowMissingAnObject() throws {
        let app = Self.goodApp.replacingOccurrences(of: ".environment(library).environment(keys)", with: ".environment(library)")
        let report = try SceneEnvironmentCheck(sources: ["App.swift": app, "Env.swift": Self.goodModifier]).run()
        XCTAssertEqual(report.problems.count, 1, "\(report.problems)")
        XCTAssertTrue(report.problems.first?.contains("RememberedKeys") == true, "\(report.problems)")
    }

    func testTheCheckerFindsAWindowWithoutAnyEnvironment() throws {
        let app = Self.goodApp.replacingOccurrences(of: "Settings {", with: "Window(\"Keys\", id: \"keys\") { KeysWindowView() }\n        Settings {")
        let report = try SceneEnvironmentCheck(sources: ["App.swift": app, "Env.swift": Self.goodModifier]).run()
        XCTAssertEqual(report.scenes.count, 4)
        XCTAssertEqual(report.problems.count, 1, "\(report.problems)")
    }

    func testTheCheckerFindsAModifierThatDropsAnObject() throws {
        let modifier = Self.goodModifier.replacingOccurrences(of: ".environment(keys)", with: "")
        let report = try SceneEnvironmentCheck(sources: ["App.swift": Self.goodApp, "Env.swift": modifier]).run()
        // The two scenes that use the modifier; the one with `.environment` each is fine.
        XCTAssertEqual(report.problems.count, 2, "\(report.problems)")
    }

    func testTheCheckerFindsAScenesOutsideTheAppStruct() throws {
        let other = "extension DemoApp { var extra: some Scene { WindowGroup(id: \"x\") { Text(\"x\") } } }"
        let report = try SceneEnvironmentCheck(sources: ["App.swift": Self.goodApp, "Env.swift": Self.goodModifier,
                                                         "Extra.swift": other]).run()
        XCTAssertEqual(report.scenes.count, 4)
        XCTAssertEqual(report.problems.count, 1, "\(report.problems)")
    }

    func testTheCheckerFindsAPlainEnvironmentRead() {
        let view = """
            struct Row: View {
                @Environment(AppModel.self) private var model
                @Environment(RememberedKeys.self) var keys: RememberedKeys
                @Environment(AppModel.self) private var injected: AppModel?
                @AppModelEnvironment private var wrapped
                // @Environment(VaultLibrary.self) private var library
                let note = "@Environment(VaultLibrary.self) var library"
                @Environment(WindowUI.self) private var ui
            }
            """
        XCTAssertEqual(SceneEnvironmentCheck(sources: ["Row.swift": view]).plainEnvironmentReads(),
                       ["Row.swift:2", "Row.swift:3"])
    }

    func testTheCheckerFailsWithoutAnApp() {
        XCTAssertThrowsError(try SceneEnvironmentCheck(sources: ["Env.swift": Self.goodModifier]).run())
    }

    static func loadSources() throws -> [String: String] {
        var out: [String: String] = [:]
        let names = try FileManager.default.contentsOfDirectory(atPath: appSources.path)
        for name in names where name.hasSuffix(".swift") {
            out[name] = try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
        }
        return out
    }
}

/// Reads Swift sources textually (comments and string contents blanked) and
/// checks each scene's root view for the app environment.
struct SceneEnvironmentCheck {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Report { var scenes: [String] = []; var problems: [String] = [] }

    /// The environment objects, by type.
    static let types = ["AppModel", "VaultLibrary", "RememberedKeys"]
    /// Scene types that take a content closure.
    static let sceneTypes = ["WindowGroup", "Window", "UtilityWindow", "DocumentGroup", "Settings", "MenuBarExtra"]

    /// File name → code with comments and string literal contents blanked
    /// (the same length in characters as the source).
    let code: [String: String]
    let sources: [String: String]

    init(sources: [String: String]) {
        self.sources = sources
        code = sources.mapValues(Self.mask)
    }

    func run() throws -> Report {
        guard let (appFile, appBody) = appStruct() else { throw Failure(description: "no `struct …: App` in the sources") }
        // The App's property names for each environment type.
        var names: [String: String] = [:]
        for type in Self.types {
            let decl = "@State\\s+(?:private\\s+)?var\\s+(\\w+)\\s*(?::\\s*\(type)\\b|=\\s*\(type)\\s*\\()"
            guard let name = Self.firstGroup(decl, in: appBody) else {
                throw Failure(description: "\(appFile): the App keeps no @State \(type)")
            }
            names[type] = name
        }
        let modifierInjects = Set(modifierTypes())
        var report = Report()
        for (file, text) in code.sorted(by: { $0.key < $1.key }) {
            for scene in scenes(in: text) {
                // The head as written (titles are blanked in `text`).
                let original = Array(sources[file] ?? text)
                let head = String(original[scene.head]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                let label = "\(file): \(head.trimmingCharacters(in: .whitespaces))"
                report.scenes.append(label)
                let content = expand(scene.content, appBody: appBody)
                var missing: [String] = []
                for type in Self.types {
                    let name = names[type] ?? type
                    let direct = Self.matches("\\.environment\\(\\s*(?:self\\.)?\(name)\\s*\\)", in: content)
                    let shared = Self.matches("\\.appEnvironment\\([^)]*\\b\(Self.label(type)):\\s*(?:self\\.)?\(name)\\b", in: content)
                        && modifierInjects.contains(type)
                    if !direct && !shared { missing.append(type) }
                }
                if !missing.isEmpty { report.problems.append("\(label) does not inject \(missing.joined(separator: ", "))") }
            }
        }
        return report
    }

    /// `file:line` of every plain `@Environment(X.self)` read of an app-wide
    /// object (comments and strings skipped). The optional form (`: AppModel?`,
    /// which the wrappers use) never traps and is allowed.
    func plainEnvironmentReads() -> [String] {
        let pattern = "@Environment\\(\\s*(?:\(Self.types.joined(separator: "|")))\\.self\\s*\\)\\s*"
            + "(?:(?:private|fileprivate|internal)\\s+)?var\\s+\\w+(\\s*:\\s*\\w+\\s*\\?)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["bad pattern"] }
        var out: [String] = []
        for (file, text) in code.sorted(by: { $0.key < $1.key }) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where match.range(at: 1).location == NSNotFound {
                let line = ns.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
                out.append("\(file):\(line)")
            }
        }
        return out
    }

    /// `appEnvironment(model:library:keys:)`'s argument label for an environment type.
    static func label(_ type: String) -> String {
        switch type {
        case "AppModel": return "model"
        case "VaultLibrary": return "library"
        default: return "keys"
        }
    }

    /// The `@main` App struct: its file and body.
    private func appStruct() -> (String, String)? {
        for (file, text) in code.sorted(by: { $0.key < $1.key }) {
            guard let range = text.range(of: "struct\\s+\\w+\\s*:\\s*App\\s*\\{", options: .regularExpression) else { continue }
            let open = text.index(before: range.upperBound)
            if let body = Self.braced(text, from: open) { return (file, body) }
        }
        return nil
    }

    /// The environment types the `appEnvironment` modifier injects (empty without one).
    private func modifierTypes() -> [String] {
        for text in code.values {
            guard let range = text.range(of: "func\\s+appEnvironment\\s*\\(", options: .regularExpression),
                  let open = text[range.upperBound...].firstIndex(of: "{"),
                  let body = Self.braced(text, from: open) else { continue }
            var injected = body
            // `modifier(SomeModifier(…))`: that modifier's struct is where the work is.
            if let name = Self.firstGroup("modifier\\(\\s*(\\w+)\\s*\\(", in: body) {
                for other in code.values {
                    guard let s = other.range(of: "struct\\s+\(name)\\b[^{]*\\{", options: .regularExpression),
                          let structBody = Self.braced(other, from: other.index(before: s.upperBound)) else { continue }
                    injected += structBody
                }
            }
            // `.environment(model)` where `model` is a property or parameter of that type.
            return Self.types.filter { type in
                let property = Self.firstGroup("(?:let|var)\\s+(\\w+)\\s*:\\s*\(type)\\b", in: injected)
                    ?? Self.firstGroup("(\\w+)\\s*:\\s*\(type)\\b", in: injected)
                guard let property else { return false }
                return Self.matches("\\.environment\\(\\s*(?:self\\.)?\(property)\\s*\\)", in: injected)
            }
        }
        return []
    }

    /// Every scene declaration: its head (`WindowGroup("Note", …)`) and content closure.
    private func scenes(in text: String) -> [(head: Range<Int>, content: String)] {
        var out: [(Range<Int>, String)] = []
        let pattern = "(?<![\\w.])(\(Self.sceneTypes.joined(separator: "|")))\\s*(?=[({<])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let start = Range(match.range, in: text) else { continue }
            var i = start.upperBound
            // Generic arguments, then the argument list, then the trailing closure.
            if i < text.endIndex, text[i] == "<", let close = Self.balanced(text, from: i, open: "<", close: ">") {
                i = text.index(after: close)
            }
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            if i < text.endIndex, text[i] == "(", let close = Self.balanced(text, from: i, open: "(", close: ")") {
                i = text.index(after: close)
            }
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "{", let body = Self.braced(text, from: i) else {
                // A type mention (`Settings` the enum case, say) rather than a scene with content.
                continue
            }
            let from = text.distance(from: text.startIndex, to: start.lowerBound)
            out.append((from..<(from + text.distance(from: start.lowerBound, to: i)), body))
        }
        return out
    }

    /// `content` with each App property it names (`libraryContent`) inlined, a few levels deep.
    private func expand(_ content: String, appBody: String) -> String {
        var text = content
        var seen: Set<String> = []
        for _ in 0..<4 {
            var added = ""
            for name in Self.allGroups("\\b([a-z]\\w*)\\b", in: text) where !seen.contains(name) {
                guard let range = appBody.range(of: "var\\s+\(name)\\s*:\\s*some\\s+View\\s*\\{", options: .regularExpression),
                      let body = Self.braced(appBody, from: appBody.index(before: range.upperBound)) else { continue }
                seen.insert(name)
                added += "\n" + body
            }
            if added.isEmpty { break }
            text += added
        }
        return text
    }

    // MARK: - Text helpers

    /// The text inside the braces opening at `open`, or nil if they never close.
    static func braced(_ text: String, from open: String.Index) -> String? {
        guard let close = balanced(text, from: open, open: "{", close: "}") else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    /// The index of the delimiter closing the one at `from`.
    static func balanced(_ text: String, from: String.Index, open: Character, close: Character) -> String.Index? {
        var depth = 0
        var i = from
        while i < text.endIndex {
            if text[i] == open { depth += 1 } else if text[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        allGroups(pattern, in: text).first
    }

    static func allGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// Blanks comments and the contents of string literals (quotes kept), so
    /// braces and words inside them are not code.
    static func mask(_ source: String) -> String {
        let s = Array(source)
        var out = s
        var i = 0
        func blank(_ k: Int) { if out[k] != "\n" { out[k] = " " } }
        while i < s.count {
            if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { blank(i); i += 1 }
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                var depth = 0
                while i < s.count {
                    if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" { depth += 1; blank(i); blank(i + 1); i += 2; continue }
                    if s[i] == "*", i + 1 < s.count, s[i + 1] == "/" {
                        depth -= 1; blank(i); blank(i + 1); i += 2
                        if depth == 0 { break }
                        continue
                    }
                    blank(i); i += 1
                }
            } else if s[i] == "\"" {
                let triple = i + 2 < s.count && s[i + 1] == "\"" && s[i + 2] == "\""
                i += triple ? 3 : 1
                while i < s.count {
                    if s[i] == "\\" {
                        // An interpolation stays code: its parentheses balance on their own.
                        if i + 1 < s.count, s[i + 1] == "(" , let close = closeParen(s, from: i + 1) {
                            i = close + 1; continue
                        }
                        blank(i); if i + 1 < s.count { blank(i + 1) }
                        i += 2; continue
                    }
                    if triple, s[i] == "\"", i + 2 < s.count, s[i + 1] == "\"", s[i + 2] == "\"" { i += 3; break }
                    if !triple, s[i] == "\"" { i += 1; break }
                    if !triple, s[i] == "\n" { break }
                    blank(i); i += 1
                }
            } else {
                i += 1
            }
        }
        return String(out)
    }

    private static func closeParen(_ s: [Character], from: Int) -> Int? {
        var depth = 0
        var i = from
        while i < s.count {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }
}
