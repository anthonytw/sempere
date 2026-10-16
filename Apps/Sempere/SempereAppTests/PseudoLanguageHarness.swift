#if DEBUG
import Foundation
import ObjectiveC
import SwiftUI
import UIKit
@testable import SempereApp

/// The in-process pseudo-language layout check (docs/localization.md "Checking layouts",
/// `PseudoLanguageLayoutTests`): puts a view in a test window of the test host's scene in
/// one of the three pseudo-languages, lets it settle, and lists what runs off the window sideways
/// and which single-line labels are cut off, with the same criteria as the UI test
/// `PseudoLanguageUITests`.
///
/// How each language is reached without relaunching the app:
///
/// - `double`: `LanguageOverride.doubles`, which doubles what every bundle's lookups return, as
///   `-NSDoubleLocalizedStrings YES` does (the app's strings, UIKit's and SwiftUI's own). Setting that
///   default in process reaches `NSLocalizedString` but not SwiftUI's `Text`, so the lookups are
///   doubled here instead. A catalog plural (`%#@…@`) is looked up in a copy of the bundle whose
///   `.stringsdict` variants are doubled (`PluralDoubling`), so it is doubled once, after the count
///   has chosen its form.
/// - `rtl`: the window's `layoutDirection` trait and SwiftUI's `layoutDirection`, so UIKit and
///   SwiftUI both lay out right to left. Text is not forced to run right to left
///   (`NSForceRightToLeftWritingDirection`), which changes no widths.
/// - `es`: SwiftUI's `locale` (the literals in views) plus `LanguageOverride`, which answers every
///   bundle's `localizedString(forKey:value:table:)` lookups in Spanish (`String(localized:)`, UIKit's
///   own titles). Dates and numbers formatted in code with `Locale.current` stay English.
enum PseudoLanguage: String, CaseIterable, Sendable {
    case double, rtl, es

    /// Puts the language in place for the process; the returned closure takes it out again.
    @MainActor func apply() -> () -> Void {
        switch self {
        case .double:
            LanguageOverride.install()
            LanguageOverride.doubles = true
            return { LanguageOverride.doubles = false }
        case .rtl:
            return {}
        case .es:
            LanguageOverride.install()
            LanguageOverride.language = "es"
            return { LanguageOverride.language = nil }
        }
    }

    /// The view as this language shows it.
    @MainActor func environment<V: View>(_ view: V) -> AnyView {
        switch self {
        case .double: AnyView(view)
        case .rtl: AnyView(view.environment(\.layoutDirection, .rightToLeft))
        case .es: AnyView(view.environment(\.locale, Locale(identifier: "es_ES")))
        }
    }

    /// The window as this language shows it.
    @MainActor func configure(_ window: UIWindow) {
        if self == .rtl { window.traitOverrides.layoutDirection = .rightToLeft }
    }
}

/// Rewrites every `NSBundle` string lookup while a pseudo-language is in place: answers it in
/// `language` (`PseudoLanguage.es`) or doubles it (`doubles`, `PseudoLanguage.double`). Installed
/// once; does nothing while neither is set.
///
/// It replaces `localizedStringForKey:value:table:` (what `NSLocalizedString` and UIKit call), the
/// two `…localizations:` forms (what `String(localized:)` calls), which answer in `language`, and
/// the forms SwiftUI's `Text` reaches with the localization its `locale` picked (attributed, for
/// Markdown), which are only doubled. Only the outermost lookup on a thread doubles, since one
/// form calls another. A lookup that answers a plural (`%#@…@`: an object that carries the plural
/// rules, so a doubled copy of its text would lose them) is asked again of a bundle whose
/// `.stringsdict` has every form doubled (`PluralDoubling`).
enum LanguageOverride {
    nonisolated(unsafe) static var language: String?
    nonisolated(unsafe) static var doubles = false
    nonisolated(unsafe) private static var installed = false

    private typealias Lookup4 = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSArray?) -> AnyObject
    private typealias Lookup3 = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> AnyObject
    private typealias LookupIn = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSString?) -> AnyObject
    private typealias LookupPrivate = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSArray?,
                                                      UnsafeMutableRawPointer?, Bool) -> AnyObject
    private static let depthKey = "SemperePseudoLookupDepth"

    /// `text` twice, as `-NSDoubleLocalizedStrings YES` shows it (“Settings Settings”). The copy
    /// drops `%` so a format string keeps one set of specifiers; a catalog plural or variable
    /// string (`%#@…@`, whose forms are chosen when it is formatted) is not doubled here: its
    /// lookup is redone in a bundle with doubled forms (`PluralDoubling`).
    static func doubled(_ text: String) -> String? {
        if text.isEmpty || text.contains("%#@") { return nil }
        return "\(text) \(text.replacingOccurrences(of: "%", with: ""))"
    }

    /// A lookup's result (a string or, for SwiftUI's Markdown-aware lookups, an attributed string), doubled.
    static func doubled(_ result: AnyObject) -> AnyObject {
        if let attributed = result as? NSAttributedString {
            // The copy is plain text without specifiers: the original keeps the only format
            // placeholders, which SwiftUI fills from the `Text`'s interpolations.
            guard let twice = doubled(attributed.string) else { return result }
            let out = NSMutableAttributedString(attributedString: attributed)
            out.append(NSAttributedString(string: String(twice.dropFirst(attributed.string.count))))
            return out
        }
        if let string = result as? String, let twice = doubled(string) { return twice as NSString }
        return result
    }

    /// Runs one lookup (`body` gets the bundle to ask), doubling its result if it is the outermost one
    /// on this thread. A plural answer is asked again of the bundle with doubled forms.
    private static func lookup(_ bundle: AnyObject, table: NSString?, _ body: (AnyObject) -> AnyObject) -> AnyObject {
        guard doubles else { return body(bundle) }
        let thread = Thread.current.threadDictionary
        let depth = thread[depthKey] as? Int ?? 0
        thread[depthKey] = depth + 1
        defer { thread[depthKey] = depth }
        let result = body(bundle)
        guard depth == 0 else { return result }
        if isPlural(result), let twice = PluralDoubling.bundle(for: bundle, table: table as String?) {
            let again = body(twice)
            if isPlural(again) { return again }
        }
        return doubled(result)
    }

    /// Whether a lookup's answer is a catalog plural (its text is `%#@name@`).
    static func isPlural(_ result: AnyObject) -> Bool {
        if let attributed = result as? NSAttributedString { return attributed.string.contains("%#@") }
        return (result as? String)?.contains("%#@") ?? false
    }

    private static func replace<F>(_ name: String, as _: F.Type, _ make: (F, Selector) -> Any) -> F? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(Bundle.self, selector) else { return nil }
        let original = unsafeBitCast(method_getImplementation(method), to: F.self)
        method_setImplementation(method, imp_implementationWithBlock(make(original, selector)))
        return original
    }

    static func install() {
        guard !installed else { return }
        installed = true
        let four = NSSelectorFromString("localizedStringForKey:value:table:localizations:")
        let original4 = replace("localizedStringForKey:value:table:localizations:", as: Lookup4.self) { original, selector in
            { (bundle: AnyObject, key: NSString, value: NSString?, table: NSString?, localizations: NSArray?) -> AnyObject in
                lookup(bundle, table: table) { original($0, selector, key, value, table, language.map { [$0] as NSArray } ?? localizations) }
            } as @convention(block) (AnyObject, NSString, NSString?, NSString?, NSArray?) -> AnyObject
        }
        _ = replace("_localizedStringForKey:value:table:localizations:", as: Lookup4.self) { original, selector in
            { (bundle: AnyObject, key: NSString, value: NSString?, table: NSString?, localizations: NSArray?) -> AnyObject in
                lookup(bundle, table: table) { original($0, selector, key, value, table, language.map { [$0] as NSArray } ?? localizations) }
            } as @convention(block) (AnyObject, NSString, NSString?, NSString?, NSArray?) -> AnyObject
        }
        _ = replace("localizedStringForKey:value:table:", as: Lookup3.self) { original, selector in
            { (bundle: AnyObject, key: NSString, value: NSString?, table: NSString?) -> AnyObject in
                lookup(bundle, table: table) { b in
                    if let language, let original4 { return original4(b, four, key, value, table, [language] as NSArray) }
                    return original(b, selector, key, value, table)
                }
            } as @convention(block) (AnyObject, NSString, NSString?, NSString?) -> AnyObject
        }
        // Doubled only: SwiftUI's own lookups, which pick the localization from its `locale`.
        _ = replace("localizedAttributedStringForKey:value:table:", as: Lookup3.self) { original, selector in
            { (bundle: AnyObject, key: NSString, value: NSString?, table: NSString?) -> AnyObject in
                lookup(bundle, table: table) { original($0, selector, key, value, table) }
            } as @convention(block) (AnyObject, NSString, NSString?, NSString?) -> AnyObject
        }
        for name in ["localizedStringForKey:value:table:localization:", "localizedAttributedStringForKey:value:table:localization:"] {
            _ = replace(name, as: LookupIn.self) { original, selector in
                { (bundle: AnyObject, key: NSString, value: NSString?, table: NSString?, localization: NSString?) -> AnyObject in
                    lookup(bundle, table: table) { original($0, selector, key, value, table, localization) }
                } as @convention(block) (AnyObject, NSString, NSString?, NSString?, NSString?) -> AnyObject
            }
        }
        _ = replace("_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:",
                    as: LookupPrivate.self) { original, selector in
            { (bundle: AnyObject, key: NSString, value: NSString?, table: NSString?, localizations: NSArray?,
               localization: UnsafeMutableRawPointer?, plain: Bool) -> AnyObject in
                lookup(bundle, table: table) { original($0, selector, key, value, table, localizations, localization, plain) }
            } as @convention(block) (AnyObject, NSString, NSString?, NSString?, NSArray?, UnsafeMutableRawPointer?, Bool) -> AnyObject
        }
    }
}

/// Bundles whose plural forms are doubled: for a bundle and table, a copy in the temporary folder
/// whose `.stringsdict` files (every language) have every form's text doubled, as `doubled(_:)`
/// does for a plain string (the copy loses its `%`, so a form keeps one set of specifiers). The
/// plural machinery stays the real one: the count picks the form, then the form is doubled once.
enum PluralDoubling {
    nonisolated(unsafe) private static var bundles: [String: Bundle?] = [:]
    private static let lock = NSLock()

    /// The bundle with doubled forms for `table` (`Localizable` by default) of `bundle`, or nil when it has none.
    static func bundle(for bundle: AnyObject, table: String?) -> Bundle? {
        guard let original = bundle as? Bundle, let resources = original.resourcePath else { return nil }
        let name = table?.isEmpty == false ? table! : "Localizable"
        let key = "\(original.bundlePath)|\(name)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[key] { return cached }
        let made = make(from: URL(fileURLWithPath: resources), table: name)
        bundles[key] = made
        return made
    }

    private static func make(from resources: URL, table: String) -> Bundle? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SemperePluralDoubling-\(UUID().uuidString).bundle", isDirectory: true)
        var any = false
        for entry in (try? fm.contentsOfDirectory(atPath: resources.path)) ?? [] where entry.hasSuffix(".lproj") {
            let source = resources.appendingPathComponent(entry).appendingPathComponent("\(table).stringsdict")
            guard let dict = NSDictionary(contentsOf: source) as? [String: Any] else { continue }
            let folder = root.appendingPathComponent(entry, isDirectory: true)
            guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  (try? (doubledEntries(dict) as NSDictionary).write(to: folder.appendingPathComponent("\(table).stringsdict"))) != nil
            else { continue }
            any = true
        }
        guard any else { return nil }
        let info: NSDictionary = ["CFBundleIdentifier": "io.github.anthonytw.sempere.plural-doubling.\(UUID().uuidString)",
                                  "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"]
        _ = try? info.write(to: root.appendingPathComponent("Info.plist"))
        return Bundle(url: root)
    }

    /// Every entry with the text of its forms doubled; the plural machinery's own keys (`NSString…`) and
    /// the format key (which only names the variables) stay.
    static func doubledEntries(_ entries: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in entries {
            guard let entry = value as? [String: Any] else { out[key] = value; continue }
            var copy: [String: Any] = [:]
            for (field, inner) in entry {
                if let variable = inner as? [String: Any] { copy[field] = doubledForms(variable) } else { copy[field] = inner }
            }
            out[key] = copy
        }
        return out
    }

    private static func doubledForms(_ variable: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (form, text) in variable {
            if form.hasPrefix("NSString") { out[form] = text }
            else if let text = text as? String { out[form] = LanguageOverride.doubled(text) ?? text }
            else if let nested = text as? [String: Any] { out[form] = doubledForms(nested) }
            else { out[form] = text }
        }
        return out
    }
}

/// Turns on the app's accessibility elements for the process (SwiftUI builds its accessibility
/// nodes only while an assistive technology or UI automation is listening), and back off.
enum InProcessAccessibility {
    private typealias Getter = @convention(c) () -> Bool
    private typealias Setter = @convention(c) (Bool) -> Void

    /// Turns it on; the returned closure puts the previous setting back. Nil when the
    /// switch is missing (the check then finds no elements and fails).
    static func enable() -> (() -> Void)? {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let get = dlsym(library, "_AXSApplicationAccessibilityEnabled"),
              let set = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else { return nil }
        let setter = unsafeBitCast(set, to: Setter.self)
        let previous = unsafeBitCast(get, to: Getter.self)()
        setter(true)
        return { setter(previous) }
    }
}

/// One accessibility element as the check sees it.
struct LayoutElement: Hashable {
    let label: String
    /// In window coordinates.
    let frame: CGRect
    let isStaticText: Bool
}

@MainActor
enum LayoutCheck {
    /// The accessibility elements under `root`, in `window` coordinates, that a person could reach:
    /// in a view that is not hidden, with a label and a frame whose center is in the window
    /// (the UI test's `isHittable`; a list row scrolled out of sight is not checked).
    static func elements(in window: UIWindow, also extra: [UIView] = []) -> [LayoutElement] {
        var out: [LayoutElement] = []
        var seen = Set<ObjectIdentifier>()
        // Accessibility frames are in screen coordinates: the window's own origin there.
        let origin = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window).origin
        func visit(_ node: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if let view = node as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if node.isAccessibilityElement, node.accessibilityElementsHidden == false {
                let label = node.accessibilityLabel ?? ""
                let frame = node.accessibilityFrame.offsetBy(dx: -origin.x, dy: -origin.y)
                if !label.isEmpty, !frame.isEmpty, window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    out.append(LayoutElement(label: label, frame: frame,
                                             isStaticText: node.accessibilityTraits.contains(.staticText)))
                }
            }
            if node.accessibilityElementsHidden { return }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children = elements
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    children = (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
                }
            }
            if let view = node as? UIView, node.accessibilityElements == nil { children += view.subviews }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        for view in extra { visit(view, depth: 0) }
        return out
    }

    /// What is wrong with `elements` in a window of `bounds`: sideways overflow (vertical
    /// overflow is just scrolling) and cut-off single-line labels.
    static func problems(_ elements: [LayoutElement], bounds: CGRect) -> [String] {
        var problems = Set<String>()
        for element in elements {
            let frame = element.frame
            if frame.minX < bounds.minX - 1 || frame.maxX > bounds.maxX + 1 {
                problems.insert("off the window sideways: “\(element.label)” \(rounded(frame))")
            }
            if element.isStaticText, isTruncated(element.label, in: frame) {
                problems.insert("truncated: “\(element.label)” in \(Int(frame.width.rounded())) pt")
            }
        }
        return problems.sorted()
    }

    /// A one-line label whose frame is narrower than its text at the smallest text style
    /// (`PseudoLanguageUITests.isTruncated`). A lower bound, so it cannot cry wolf: a wrapped
    /// label is taller than a line and exempt.
    static func isTruncated(_ label: String, in frame: CGRect) -> Bool {
        let font = UIFont.preferredFont(forTextStyle: .caption2)
        let size = (label as NSString).size(withAttributes: [.font: font])
        let oneLine = frame.height < size.height * 1.6
        return oneLine && size.width > frame.width + 2
    }

    static func rounded(_ r: CGRect) -> String {
        "(\(Int(r.minX.rounded())), \(Int(r.minY.rounded())), \(Int(r.width.rounded())) × \(Int(r.height.rounded())))"
    }
}

/// A test window of the test host's scene holding a SwiftUI view, as the app's window holds
/// it. It belongs to the scene because a window without one cannot present a sheet on a Mac (the
/// sheet stays 0 × 0) and is never drawn there.
@MainActor
final class LayoutHost {
    let window: UIWindow
    let controller: UIViewController

    init(_ view: some View, size: CGSize, language: PseudoLanguage?) async throws {
        let scene = try await Self.scene()
        let content = view.environment(\.timeZone, Self.utc)
        controller = UIHostingController(rootView: language?.environment(content) ?? AnyView(content))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        language?.configure(window)
        window.rootViewController = controller
        window.isHidden = false
    }

    static let utc = TimeZone(identifier: "UTC") ?? .current

    /// The host app's scene: it connects after launch, later when the app starts in the background.
    static func scene() async throws -> UIWindowScene {
        for _ in 0..<100 {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { return scene }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.featureUnsupported)
    }

    /// Lays out until the elements stop changing (three polls in a row, at least 300 ms, at most
    /// `timeout`) and, with `sheet`, a sheet is up. Returns the elements.
    func settle(sheet: Bool = false, timeout: Duration = .seconds(6)) async throws -> [LayoutElement] {
        let clock = ContinuousClock()
        let start = clock.now
        var last: [LayoutElement] = []
        var stable = 0
        while clock.now - start < timeout {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            controller.presentedViewController?.view.layoutIfNeeded()
            let sheetUp = !sheet || (controller.presentedViewController.map { !$0.view.bounds.isEmpty } ?? false)
            let now = LayoutCheck.elements(in: window, also: presentedViews)
            stable = (now == last && sheetUp && !now.isEmpty) ? stable + 1 : 0
            last = now
            if stable >= 3, clock.now - start > .milliseconds(300) { break }
        }
        return last
    }

    /// The views of the sheets up (on a Mac a sheet is not under the window's own views).
    var presentedViews: [UIView] {
        var views: [UIView] = []
        var next = controller.presentedViewController
        while let presented = next {
            if presented.viewIfLoaded?.window !== window { views.append(presented.view) }
            next = presented.presentedViewController
        }
        return views
    }

    /// A PNG of the window, for the test report.
    func png() -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }.pngData()
    }

    func close() {
        controller.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
#endif
