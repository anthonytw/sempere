import CoreSpotlight
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// What the app's Core Spotlight adapter makes of the package's plan (docs/design/1.3-spotlight.md §3.2, §3.3), seen through a
/// fake backend: the system index itself is not touched.
final class FakeSearchableIndex: SearchableIndexBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var indexed: [CSSearchableItem] = []
    private(set) var identifiers: [String] = []
    private(set) var domains: [String] = []
    private(set) var clearedAll = 0

    func index(_ items: [CSSearchableItem]) async throws { lock.withLock { indexed += items } }
    func delete(identifiers: [String]) async throws { lock.withLock { self.identifiers += identifiers } }
    func delete(domains: [String]) async throws { lock.withLock { self.domains += domains } }
    func deleteAll() async throws { lock.withLock { clearedAll += 1 } }
}

struct SpotlightIndexerTests {
    let vault = UUID(), note = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func item(text: String? = nil) -> SpotlightItem {
        SpotlightItem(vaultId: vault, noteId: note, title: "Lecture", contentDescription: "School · 2023-11-14",
                      keywords: ["exam"], modified: now, textContent: text)
    }

    @Test func aDonationCarriesTheMetadataAndNoPicture() async throws {
        let fake = FakeSearchableIndex()
        let index = CoreSpotlightIndex(backend: fake, now: { now })
        try await index.index([item()])
        let donated = try #require(fake.indexed.first)
        #expect(donated.uniqueIdentifier == "\(vault.uuidString.lowercased())/\(note.uuidString.lowercased())")
        #expect(donated.domainIdentifier == "io.github.anthonytw.sempere.\(vault.uuidString.lowercased())")
        let a = donated.attributeSet
        #expect(a.title == "Lecture")
        #expect(a.contentDescription == "School · 2023-11-14")
        #expect(a.keywords == ["exam"])
        #expect(a.contentModificationDate == now)
        #expect(a.textContent == nil)
        #expect(a.thumbnailData == nil && a.thumbnailURL == nil)
        let expiry = try #require(donated.expirationDate)
        #expect(abs(expiry.timeIntervalSince(now) - 30 * 86_400) < 3 * 3_600, "about 30 days (a DST shift aside)")
    }

    @Test func textIsDonatedOnlyWhenTheItemHasIt() async throws {
        let fake = FakeSearchableIndex()
        try await CoreSpotlightIndex(backend: fake).index([item(text: "whole note text")])
        #expect(fake.indexed.first?.attributeSet.textContent == "whole note text")
    }

    @Test func removalsGoByIdentifierDomainAndAll() async throws {
        let fake = FakeSearchableIndex()
        let index = CoreSpotlightIndex(backend: fake)
        try await index.delete(ids: ["a/b"])
        try await index.deleteDomain(vault: vault)
        try await index.deleteAll()
        #expect(fake.identifiers == ["a/b"])
        #expect(fake.domains == ["io.github.anthonytw.sempere.\(vault.uuidString.lowercased())"])
        #expect(fake.clearedAll == 1)
    }

    @Test func theSystemIndexIsTheNamedOneAndTheCatalystFallbackExists() {
        // Both initializers exist on iOS 27 and Mac Catalyst 27: a Mac takes the plain named one (no data protection).
        #expect(CoreSpotlightIndex.indexName == "sempere")
        _ = CoreSpotlightIndex.systemIndex()
    }

    @Test func aSpotlightIdentifierBecomesALink() {
        let link = NoteLink(spotlightIdentifier: "\(vault.uuidString)/\(note.uuidString)".lowercased())
        #expect(link == NoteLink(vaultId: vault, noteId: note))
        #expect(CSSearchableItemActionType.isEmpty == false)
    }

    /// The real system index in the test host (docs/design/1.3-spotlight.md §7): one fixture note is donated, found with a
    /// `CSSearchQuery`, and gone after its domain is deleted. A named index of the test's own, never the app's.
    @Test func theSystemIndexFindsADonatedNoteAndForgetsItWithItsDomain() async throws {
        let backend = CSSearchableIndex(name: "sempere-test-\(UUID().uuidString.prefix(8))")
        let index = CoreSpotlightIndex(backend: backend)
        let word = "zyxquartz\(Int.random(in: 100_000...999_999))"
        let donated = SpotlightItem(vaultId: vault, noteId: note, title: "Fixture \(word)", contentDescription: "Test", keywords: [],
                                    modified: now, textContent: nil)
        do {
            try await index.index([donated])
        } catch let error as NSError where error.domain == CSIndexErrorDomain
            && error.code == CSIndexError.Code.remoteConnectionError.rawValue {
            // The ad-hoc signed, sandboxed test host cannot reach the Spotlight daemon on every machine: the real index
            // is then a by-hand check (docs/mac.md "Spotlight"); the adapter's mapping above is tested regardless.
            print("SpotlightIndexerTests: the system index is unreachable here (\(error.code)); real-index check skipped")
            return
        }
        let found = await Self.waitFor(word, in: backend, expecting: 1)
        try await index.deleteDomain(vault: vault)
        let gone = await Self.waitFor(word, in: backend, expecting: 0)
        try? await backend.deleteAllSearchableItems()
        #expect(found, "the donated note is found")
        #expect(gone, "and not found after its domain is deleted")
    }

    static func waitFor(_ word: String, in index: CSSearchableIndex, expecting count: Int) async -> Bool {
        for _ in 0..<40 {
            let query = CSSearchQuery(queryString: "title == \"*\(word)*\"c", queryContext: nil)
            let n = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
                let hits = Counter()
                query.foundItemsHandler = { items in hits.add(items.count) }
                query.completionHandler = { _ in done.resume(returning: hits.value) }
                query.start()
            }
            if (count == 0) == (n == 0) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add(_ k: Int) { lock.withLock { n += k } }
        var value: Int { lock.withLock { n } }
    }
}
