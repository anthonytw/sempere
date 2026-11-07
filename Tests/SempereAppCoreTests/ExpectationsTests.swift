import Foundation
import Sempere
import SempereAppCore
import Testing

/// The key notice, the quick tour and About (`Expectations.swift`): what this device remembers, when a notice
/// shows by itself, the tour's pages and About's texts. The wording and the bundled texts: the app's
/// `ExpectationsTests`.
struct ExpectationsTests {
    private func memory() -> OnboardingMemory {
        OnboardingMemory(defaults: MemoryKeyValueStore())
    }

    // MARK: Per-device memory

    @Test func tourIsSeenOncePerDevice() throws {
        let m = memory()
        #expect(!m.tourSeen)
        m.markTourSeen()
        #expect(m.tourSeen)
        // A later tour version shows again.
        m.defaults.set(OnboardingMemory.tourVersion - 1, forKey: OnboardingMemory.tourSeenKey)
        #expect(!m.tourSeen)
    }

    @Test func keyNoticeIsPerVaultAndKey() throws {
        let m = memory()
        let vault = UUID(), other = UUID()
        #expect(!m.keyNoticeAcknowledged(vault: vault, recipient: "age1pq1aaa"))
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1aaa")
        #expect(m.keyNoticeAcknowledged(vault: vault, recipient: "age1pq1aaa"))
        // A new key for the same vault, or another vault: shown again.
        #expect(!m.keyNoticeAcknowledged(vault: vault, recipient: "age1pq1bbb"))
        #expect(!m.keyNoticeAcknowledged(vault: other, recipient: "age1pq1aaa"))
        // Acknowledging twice keeps one entry.
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1aaa")
        #expect((m.defaults.object(forKey: OnboardingMemory.keyNoticeKey) as? [String])?.count == 1)
    }

    @Test func keyNoticeStoresNeitherTheVaultIdNorTheKey() throws {
        let m = memory()
        let vault = UUID()
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1secretlookingrecipient")
        let stored = try #require((m.defaults.object(forKey: OnboardingMemory.keyNoticeKey) as? [String])).joined()
        #expect(!stored.contains(vault.uuidString.lowercased()))
        #expect(!stored.contains("age1pq1"))
    }

    @Test func keyNoticeMemoryIsBounded() throws {
        let m = memory()
        let first = UUID()
        m.acknowledgeKeyNotice(vault: first, recipient: nil)
        for _ in 0..<OnboardingMemory.keyNoticeLimit { m.acknowledgeKeyNotice(vault: UUID(), recipient: nil) }
        #expect((m.defaults.object(forKey: OnboardingMemory.keyNoticeKey) as? [String])?.count == OnboardingMemory.keyNoticeLimit)
        #expect(!m.keyNoticeAcknowledged(vault: first, recipient: nil), "the oldest goes first")
    }

    // MARK: Policy

    @Test func keyNoticeComesBeforeTheTourAndNeitherRepeats() throws {
        let m = memory()
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
        let m = memory()
        #expect(OnboardingPolicy.next(unlocked: false, vault: UUID(), recipient: nil, memory: m, automatic: true) == nil)
        #expect(OnboardingPolicy.next(unlocked: true, vault: nil, recipient: nil, memory: m, automatic: true) == nil)
        #expect(OnboardingPolicy.next(unlocked: true, vault: UUID(), recipient: nil, memory: m, automatic: false) == nil)
    }

    @Test func aNewKeyOnAKnownDeviceShowsTheNoticeButNotTheTour() throws {
        let m = memory()
        let vault = UUID()
        m.acknowledgeKeyNotice(vault: vault, recipient: "age1pq1old")
        m.markTourSeen()
        #expect(OnboardingPolicy.next(unlocked: true, vault: vault, recipient: "age1pq1new", memory: m, automatic: true) == .keyNotice)
    }

    // MARK: Tour

    @Test func tourHasSixPagesAndTheFirstLeadsToTheKeyNotice() {
        for isMac in [false, true] {
            let pages = QuickTour.pages(isMac: isMac)
            #expect(pages.map(\.topic) == TourPage.Topic.allCases)
            #expect(Set(pages.map(\.id)).count == 6)
            #expect(pages.map(\.offersKeyNotice) == [true, false, false, false, false, false])
            #expect(pages.allSatisfy { $0.isMac == isMac })
        }
    }

    // MARK: About

    @Test func versionTextShowsVersionAndBuild() {
        #expect(AboutInfo.versionText(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]) == "1.2 (34)")
        #expect(AboutInfo.versionText(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "1.2"]) == "1.2")
        #expect(AboutInfo.versionText(info: [:]) == "?")
        #expect(!AboutInfo.versionText().isEmpty)
    }

    /// The privacy policy as the app shows it: without the maintainers' note, its lists as items.
    @Test func privacyPolicyParagraphsAndLists() {
        let text = "# Policy\n\nThis page is the Privacy Policy URL of the listing.\n\n- one\n  more\n- two\n"
        #expect(AboutInfo.privacyPolicyParagraphs(text) == ["# Policy", "- one\n  more\n- two"])
        #expect(AboutInfo.listItems("- a\n  b\n- c") == ["a b", "c"])
        #expect(AboutInfo.listItems("Plain text") == nil)
    }

    @Test func paragraphsSplitOnBlankLines() {
        #expect(AboutInfo.paragraphs("a\nb\n\n\nc\n  \nd\n") == ["a\nb", "c", "d"])
        #expect(AboutInfo.paragraphs("") == [])
    }
}
