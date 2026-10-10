import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The key notice, the quick tour and About (`Expectations.swift`).
@MainActor
struct ExpectationsTests {
    private func memory() throws -> OnboardingMemory {
        let defaults = try #require(UserDefaults(suiteName: "ExpectationsTests-\(UUID())"))
        return OnboardingMemory(defaults: defaults)
    }

    // MARK: Per-device memory

    @Test func tourIsSeenOncePerDevice() throws {
        let m = try memory()
        #expect(!m.tourSeen)
        m.markTourSeen()
        #expect(m.tourSeen)
        // A later tour version shows again.
        m.defaults.set(OnboardingMemory.tourVersion - 1, forKey: OnboardingMemory.tourSeenKey)
        #expect(!m.tourSeen)
    }

    @Test func keyNoticeIsPerVaultAndKey() throws {
        let m = try memory()
        let vault = UUID(), other = UUID()
        #expect(!m.keyNoticeAcknowledged(vault: vault, recipient: "age1pq1aaa"))
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1aaa")
        #expect(m.keyNoticeAcknowledged(vault: vault, recipient: "age1pq1aaa"))
        // A new key for the same vault, or another vault: shown again.
        #expect(!m.keyNoticeAcknowledged(vault: vault, recipient: "age1pq1bbb"))
        #expect(!m.keyNoticeAcknowledged(vault: other, recipient: "age1pq1aaa"))
        // Acknowledging twice keeps one entry.
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1aaa")
        #expect(m.defaults.stringArray(forKey: OnboardingMemory.keyNoticeKey)?.count == 1)
    }

    @Test func keyNoticeStoresNeitherTheVaultIdNorTheKey() throws {
        let m = try memory()
        let vault = UUID()
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1secretlookingrecipient")
        let stored = try #require(m.defaults.stringArray(forKey: OnboardingMemory.keyNoticeKey)).joined()
        #expect(!stored.contains(vault.uuidString.lowercased()))
        #expect(!stored.contains("age1pq1"))
    }

    @Test func keyNoticeMemoryIsBounded() throws {
        let m = try memory()
        let first = UUID()
        m.acknowledgeKeyNotice(vault: first, recipient: nil)
        for _ in 0..<OnboardingMemory.keyNoticeLimit { m.acknowledgeKeyNotice(vault: UUID(), recipient: nil) }
        #expect(m.defaults.stringArray(forKey: OnboardingMemory.keyNoticeKey)?.count == OnboardingMemory.keyNoticeLimit)
        #expect(!m.keyNoticeAcknowledged(vault: first, recipient: nil), "the oldest goes first")
    }

    // MARK: Policy

    @Test func keyNoticeComesBeforeTheTourAndNeitherRepeats() throws {
        let m = try memory()
        let vault = UUID()
        func next() -> OnboardingStep? {
            OnboardingPolicy.next(unlocked: true, vault: vault, recipient: "age1pq1x", memory: m, automatic: true)
        }
        #expect(next() == .keyNotice)
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1x")
        #expect(next() == .tour)
        m.markTourSeen()
        #expect(next() == nil, "not on every launch")
    }

    @Test func nothingShowsWhileLockedOrWhenScripted() throws {
        let m = try memory()
        #expect(OnboardingPolicy.next(unlocked: false, vault: UUID(), recipient: nil, memory: m, automatic: true) == nil)
        #expect(OnboardingPolicy.next(unlocked: true, vault: nil, recipient: nil, memory: m, automatic: true) == nil)
        #expect(OnboardingPolicy.next(unlocked: true, vault: UUID(), recipient: nil, memory: m, automatic: false) == nil)
    }

    @Test func aNewKeyOnAKnownDeviceShowsTheNoticeButNotTheTour() throws {
        let m = try memory()
        let vault = UUID()
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1old")
        m.markTourSeen()
        #expect(OnboardingPolicy.next(unlocked: true, vault: vault, recipient: "age1pq1new", memory: m, automatic: true) == .keyNotice)
    }

    // MARK: Tour

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

    // MARK: About

    @Test func versionTextShowsVersionAndBuild() {
        #expect(AboutInfo.versionText(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]) == "1.2 (34)")
        #expect(AboutInfo.versionText(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "1.2"]) == "1.2")
        #expect(AboutInfo.versionText(info: [:]) == "?")
        #expect(!AboutInfo.versionText().isEmpty)
    }

    @Test func licenceAndNoticesAreBundled() throws {
        let license = try #require(AboutInfo.text(of: .license), "LICENSE is in the app bundle")
        #expect(license.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(license.contains("15. Disclaimer of Warranty."))
        let exception = try #require(AboutInfo.text(of: .exception))
        #expect(exception.contains("section 7"))
        let notices = try #require(AboutInfo.text(of: .thirdParty))
        for component in SempereAbout.components(for: .app) { #expect(notices.contains(component.name)) }
    }

    @Test func paragraphsSplitOnBlankLines() {
        #expect(AboutInfo.paragraphs("a\nb\n\n\nc\n  \nd\n") == ["a\nb", "c", "d"])
        #expect(AboutInfo.paragraphs("") == [])
    }

    // MARK: Menus

    @Test func aboutTourAndKeyNoticeNeedNoVaultAndNoShortcut() {
        for command in [MenuCommand.showAbout, .showTour, .showKeyNotice] {
            #expect(command.shortcut == nil)
            #expect(MenuLayout.all.contains(command))
            for vault in [MenuCommand.Context.Vault.none, .locked, .unlocked] {
                #expect(command.isEnabled(in: MenuCommand.Context(window: .note, vault: vault)))
            }
            // Never a key command: a UIKeyCommand without a key would take a plain key.
            let item = MacMenus.nativeCommand(command)
            #expect(!(item is UIKeyCommand))
            #expect(item.propertyList as? String == command.rawValue)
            #expect(item.title == command.title)
        }
        #expect(MenuLayout.help.flatMap { $0 } == [.showTour, .showKeyNotice])
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
