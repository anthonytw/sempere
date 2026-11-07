import Foundation
import Sempere
import SempereAppCore
import Testing
import UIKit
@testable import SempereApp

/// The key notice, the quick tour and About in the app: the tour's wording, the bundled texts, the menus and
/// sheets. The logic (memory, policy, About's texts): `ExpectationsTests` in SempereAppCoreTests.
@MainActor
struct ExpectationsTests {
    // MARK: Tour

    /// The tour's wording (`Expectations+Text.swift`): a symbol, a title and two lines per page.
    @Test func tourHasSixPagesOfTwoLines() {
        for isMac in [false, true] {
            let pages = QuickTour.pages(isMac: isMac)
            #expect(pages.count == 6)
            #expect(Set(pages.map(\.id)).count == pages.count)
            for page in pages {
                #expect(!page.symbol.isEmpty && !page.title.isEmpty)
                #expect(page.lines.count == 2)
                #expect(page.lines.allSatisfy { !$0.isEmpty })
            }
            #expect(pages.first?.offersKeyNotice == true, "the first page leads to About Your Key")
            #expect(pages.first?.lines.joined().contains("no warranty") == true)
        }
        // The Mac page mentions mouse and trackpad smoothing.
        #expect(QuickTour.pages(isMac: true)[1].lines[1].contains("trackpad"))
        #expect(!QuickTour.pages(isMac: false)[1].lines[1].contains("trackpad"))
    }

    // MARK: About (the bundled texts; the rest: SempereAppCoreTests)

    @Test func licenceAndNoticesAreBundled() throws {
        let license = try #require(AboutInfo.text(of: .license), "LICENSE is in the app bundle")
        #expect(license.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(license.contains("15. Disclaimer of Warranty."))
        let exception = try #require(AboutInfo.text(of: .exception))
        #expect(exception.contains("section 7"))
        let notices = try #require(AboutInfo.text(of: .thirdParty))
        for component in SempereAbout.components(for: .app) { #expect(notices.contains(component.name)) }
    }

    /// Offline audit A-P6: the privacy policy reads without a network, as published, without the maintainers' note.
    @Test func thePrivacyPolicyIsBundled() throws {
        let policy = try #require(AboutInfo.text(of: .privacyPolicy), "the privacy policy is in the app bundle")
        #expect(policy.hasPrefix("# Sempere Privacy Policy"))
        let shown = AboutInfo.privacyPolicyParagraphs(policy)
        #expect(shown.count == AboutInfo.paragraphs(policy).count - 1, "only the note to maintainers is left out")
        #expect(!shown.joined().contains("release-check"))
        #expect(shown.contains { $0.hasPrefix("## Network connections") })
        // Lists render as items, a continued line joined to its item.
        let list = try #require(shown.compactMap(AboutInfo.listItems).first { $0.count == 3 })
        #expect(list.allSatisfy { !$0.hasPrefix("- ") && !$0.contains("\n") })
    }

    // MARK: Menus

    /// Never a key command: a UIKeyCommand without a key would take a plain key (no vault and no shortcut:
    /// `MenuCommandTests.aboutTourAndKeyNoticeNeedNoVaultAndNoShortcut`, SempereAppCoreTests).
    @Test func aboutTourAndKeyNoticeAreNativeItemsWithoutAKey() {
        for command in [MenuCommand.showAbout, .showTour, .showKeyNotice] {
            let item = MacMenus.nativeCommand(command)
            #expect(!(item is UIKeyCommand))
            #expect(item.propertyList as? String == command.rawValue)
            #expect(item.title == command.title)
        }
    }

    @Test func commandsOpenTheirSheetInTheWindow() {
        let model = AppModel()
        let ui = WindowUI()
        #expect(WindowCommands.perform(.showAbout, model: model, ui: ui, exportIDs: []))
        #expect(ui.expectations == .about)
        #expect(WindowCommands.perform(.showTour, model: model, ui: ui, exportIDs: []))
        #expect(ui.expectations == .tour(firstRun: false))
        #expect(WindowCommands.perform(.showKeyNotice, model: model, ui: ui, exportIDs: []))
        #expect(ui.expectations == .keyNotice(firstRun: false))
    }
}
