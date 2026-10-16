#if DEBUG
import Foundation
import Sempere
import SwiftUI
import Testing
import UIKit
@testable import SempereApp

/// Layout check for localization (docs/localization.md "Checking layouts"), in process: the main
/// screens of the demo vault (library, locked, note, tags, paper picker, Settings), hosted in a
/// window 700 × 800 points (narrower than an iPad mini in portrait) and 1280 × 800, in the
/// double-length, right-to-left and Spanish pseudo-languages (`PseudoLanguage`). Fails when a
/// control or label leaves the window sideways or a single-line label is cut off
/// (`LayoutCheck`), and attaches a picture of each failing screen. Runs in the Mac Catalyst
/// hosted unit tests (`scripts/app.sh test-mac`, the PR gate), needs no screen focus and no UI
/// automation, and takes under a minute.
@MainActor
@Suite(.serialized)
struct PseudoLanguageLayoutTests {
    enum Screen: String, CaseIterable, Sendable {
        case library, locked, note, tags, paper, settings
    }

    /// The Mac window sizes `scripts/app.sh pseudo-mac` checks: 700 × 800 (narrower than an iPad mini
    /// in portrait) and 1280 × 800.
    nonisolated static let sizes = [CGSize(width: 700, height: 800), CGSize(width: 1280, height: 800)]

    /// The demo vault (`DemoVault`, the one `SEMPERE_DEMO` opens), built once per run.
    private static var demo: DemoVault.Built?

    static func demoVault() async throws -> DemoVault.Built {
        if let demo { return demo }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SemperePseudoLayout", isDirectory: true)
        let built = try await DemoVault.build(in: dir)
        demo = built
        return built
    }

    /// Mac Catalyst only. On the iPad simulator the in-process accessibility tree came back
    /// incomplete (3 to 5 elements for the library and tags screens, where the Mac lists 30 to 50),
    /// so a pass there would prove nothing; the iPad's layouts stay with `scripts/app.sh pseudo`
    /// (`local-ci.sh --release`, CI on `main`). The fixture test below runs on both.
    @Test(.enabled(if: ProcessInfo.processInfo.isMacCatalystApp, "Mac Catalyst only: the iPad keeps scripts/app.sh pseudo"),
          arguments: Screen.allCases, PseudoLanguage.allCases)
    func screenFits(_ screen: Screen, in language: PseudoLanguage) async throws {
        guard let restoreAccessibility = InProcessAccessibility.enable() else {
            Issue.record("no in-process accessibility switch: nothing can be checked")
            return
        }
        defer { restoreAccessibility() }
        let restoreLanguage = language.apply()
        defer { restoreLanguage() }
        let built = try await Self.demoVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        defer { model.close() }
        try await model.openVault(at: built.url)
        if screen != .locked { _ = try await model.unlock(identityText: built.identityText) }
        switch screen {
        case .tags: model.sidebarSelection = .tag("lecture")
        case .note: model.selectedNoteID = built.notes["respiration"]
        case .paper: model.selectedNoteID = built.notes["atlas"]
        default: break
        }
        if model.selectedNoteID != nil { await model.showSelectedNote() }
        let library = VaultLibrary(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("recents.json"))
        let keys = RememberedKeys(store: FakeKeyStore())
        let suite = "SemperePseudoLayout-\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        storage.set(screen == .paper ? "detailOnly" : "all", forKey: ColumnLayout.key)

        let root = RootView().appEnvironment(model: model, library: library, keys: keys).defaultAppStorage(storage)
        let view: AnyView
        switch screen {
        case .settings:
            view = AnyView(root.sheet(isPresented: .constant(true)) {
                SettingsView().appEnvironment(model: model, library: library, keys: keys).defaultAppStorage(storage)
            })
        case .paper:
            let editor = try #require(model.editor, "the paper picker's note is open")
            let page = try #require(editor.currentPage)
            view = AnyView(root.sheet(isPresented: .constant(true)) {
                PaperPickerView(paper: editor.displayedPaper(of: page),
                                purpose: .page(number: editor.pageIndex + 1, count: editor.pages.count),
                                onPreview: { _ in }, onChoose: { _, _ in })
                    .appEnvironment(model: model, library: library, keys: keys)
            })
        default:
            view = AnyView(root)
        }
        for size in Self.sizes {
            let name = "\(language.rawValue)/\(screen.rawValue)@\(Int(size.width))x\(Int(size.height))"
            try await Self.check(view, size: size, language: language, sheet: [.locked, .paper, .settings].contains(screen),
                                 name: name, expectMoreThan: 8)
        }
    }

    /// Hosts `view`, settles it and records every problem `LayoutCheck` finds.
    static func check(_ view: some View, size: CGSize, language: PseudoLanguage?, sheet: Bool, name: String,
                      expectMoreThan minimum: Int) async throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let clock = ContinuousClock()
        let start = clock.now
        let host = try await LayoutHost(view, size: size, language: language)
        defer { host.close() }
        let elements = try await host.settle(sheet: sheet)
        let problems = LayoutCheck.problems(elements, bounds: host.window.bounds)
        let took = clock.now - start
        let ms = Int(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
        print("PSEUDO-LAYOUT \(name): \(elements.count) elements, \(problems.count) problems, \(ms) ms")
        if ProcessInfo.processInfo.environment["SEMPERE_PSEUDO_LAYOUT_DUMP"] != nil {
            for e in elements { print("PSEUDO-LAYOUT   \(e.isStaticText ? "text" : "elem") “\(e.label)” \(LayoutCheck.rounded(e.frame))") }
        }
        #expect(elements.count > minimum, "\(name): only \(elements.count) accessibility elements: the screen did not come up")
        for problem in problems { Issue.record("\(name): \(problem)") }
        if !problems.isEmpty, let png = host.png() {
            Attachment.record(png, named: name.replacingOccurrences(of: "/", with: "-") + ".png")
        }
    }

    // MARK: - The check catches what it should

    /// A label with room for its English text only, and a row wider than the window.
    struct ClippingFixture: View {
        /// The English text's width at the body style, plus a little.
        static var englishWidth: CGFloat {
            let font = UIFont.preferredFont(forTextStyle: .body)
            return ("Recently Deleted" as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 6
        }

        var overflow = false

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recently Deleted")
                    .lineLimit(1)
                    .frame(width: Self.englishWidth, alignment: .leading)
                Text(verbatim: "Sempere")
                if overflow {
                    // Laid out in 300 points, drawn in its full width: past the window's trailing edge.
                    Text(verbatim: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3))
                        .fixedSize()
                        .frame(width: 300, alignment: .leading)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    /// The fixed-width label fits in English and is reported as cut off in the double-length
    /// and Spanish pseudo-languages; a row wider than the window is reported in every language.
    nonisolated static let fixtureLanguages: [PseudoLanguage?] = [nil, .double, .rtl, .es]

    @Test(arguments: fixtureLanguages)
    func theCheckCatchesClipping(_ language: PseudoLanguage?) async throws {
        guard let restoreAccessibility = InProcessAccessibility.enable() else {
            Issue.record("no in-process accessibility switch")
            return
        }
        defer { restoreAccessibility() }
        let restoreLanguage = language?.apply()
        defer { restoreLanguage?() }
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let size = CGSize(width: 700, height: 800)
        for overflow in [false, true] {
            let host = try await LayoutHost(ClippingFixture(overflow: overflow), size: size, language: language)
            defer { host.close() }
            let elements = try await host.settle()
            let problems = LayoutCheck.problems(elements, bounds: host.window.bounds)
            let label = try #require(elements.first { $0.label != "Sempere" && !$0.label.hasPrefix("The quick") }?.label,
                                     "the fixture's label is listed: \(elements)")
            let truncated = problems.contains { $0.hasPrefix("truncated: “\(label)”") }
            let sideways = problems.contains { $0.hasPrefix("off the window sideways") }
            switch language {
            case nil, .rtl?:
                #expect(label == "Recently Deleted")
                #expect(!truncated, "\(language?.rawValue ?? "en"): \(problems)")
            case .double?:
                #expect(label.count > "Recently Deleted".count * 2 - 2, "doubled: \(label)")
                #expect(truncated, "double: \(problems)")
            case .es?:
                #expect(label == "Eliminadas recientemente")
                #expect(truncated, "es: \(problems)")
            }
            #expect(sideways == overflow, "\(language?.rawValue ?? "en") overflow \(overflow): \(problems)")
            if language == .rtl {
                // Mirrored: the leading label sits on the right.
                let sempere = try #require(elements.first { $0.label == "Sempere" })
                #expect(sempere.frame.minX > size.width / 2, "right to left: \(LayoutCheck.rounded(sempere.frame))")
            }
        }
    }

    /// A catalog plural ("\(n) notes", whose form the count picks) is doubled once in the double-length
    /// language, like any other string: it used to stay single length through `String(localized:)` and
    /// SwiftUI's `Text`. Spanish and English plurals are untouched by the override.
    @Test(arguments: [1, 3])
    func aPluralIsDoubledOnce(_ count: Int) async throws {
        guard let restoreAccessibility = InProcessAccessibility.enable() else {
            Issue.record("no in-process accessibility switch")
            return
        }
        defer { restoreAccessibility() }
        let english = Locale(identifier: "en")
        let single = String(localized: "\(count) notes", locale: english)
        #expect(single == (count == 1 ? "1 note" : "\(count) notes"))
        let restoreLanguage = PseudoLanguage.double.apply()
        defer { restoreLanguage() }
        // The same count picks the same form; each form's text appears twice (the copy loses its `%`).
        let twice = String(localized: "\(count) notes", locale: english)
        let word = count == 1 ? "note" : "notes"
        #expect(twice == "\(count) \(word) lld \(word)", "doubled once: \(twice)")
        // SwiftUI's own lookup (what a `Text` in a view reaches) does the same.
        let host = try await LayoutHost(Text("\(count) notes"), size: CGSize(width: 600, height: 200), language: .double)
        defer { host.close() }
        let labels = try await host.settle().map(\.label)
        #expect(labels == [twice], "SwiftUI: \(labels)")
    }
}
#endif
