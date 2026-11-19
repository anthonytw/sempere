import CoreSpotlight
import Foundation
import Sempere
import SempereAppCore
import UniformTypeIdentifiers

// The only file (with `SpotlightActivity.swift`) that imports Core Spotlight (docs/design/1.3-spotlight.md §3.3):
// `SpotlightIndexing` implemented over a named `CSSearchableIndex`. What is donated is decided in the package
// (`SpotlightPlanner`); this maps a `SpotlightItem` to a searchable item and makes the calls. `NoCloudTests` allows
// the framework only under `Apps/Sempere/SempereApp/Spotlight/`.

/// The calls Core Spotlight is made through, so a test can see them without the system index.
protocol SearchableIndexBackend: Sendable {
    func index(_ items: [CSSearchableItem]) async throws
    func delete(identifiers: [String]) async throws
    func delete(domains: [String]) async throws
    func deleteAll() async throws
}

extension CSSearchableIndex: SearchableIndexBackend {
    func index(_ items: [CSSearchableItem]) async throws { try await indexSearchableItems(items) }
    func delete(identifiers: [String]) async throws { try await deleteSearchableItems(withIdentifiers: identifiers) }
    func delete(domains: [String]) async throws { try await deleteSearchableItems(withDomainIdentifiers: domains) }
    func deleteAll() async throws { try await deleteAllSearchableItems() }
}

struct CoreSpotlightIndex: SpotlightIndexing {
    /// The named index of the app's items.
    static let indexName = "sempere"

    private let backend: any SearchableIndexBackend
    private let now: @Sendable () -> Date

    init(backend: any SearchableIndexBackend = CoreSpotlightIndex.systemIndex(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.now = now
    }

    /// `CSSearchableIndex(name:protectionClass:)` exists on iOS 27 and Mac Catalyst 27, but a Mac has no data
    /// protection classes (CLAUDE.md, the `BlobCache` note): there it is the plain named index, and the opt-in
    /// sheet and docs/security.md say its files are readable whenever the account is. On an iPhone or iPad the
    /// class is `.complete`: the index is unreadable while the device is locked.
    static func systemIndex() -> CSSearchableIndex {
        Platform.isMac ? CSSearchableIndex(name: indexName)
            : CSSearchableIndex(name: indexName, protectionClass: .complete)
    }

    func index(_ items: [SpotlightItem]) async throws {
        let expires = Calendar.current.date(byAdding: .day, value: SpotlightPlanner.expiryDays, to: now())
            ?? now().addingTimeInterval(30 * 86_400)
        try await backend.index(items.map { Self.searchableItem($0, expires: expires) })
    }

    func delete(ids: [String]) async throws { try await backend.delete(identifiers: ids) }
    func deleteDomain(vault: UUID) async throws { try await backend.delete(domains: [SpotlightPlanner.domain(vault: vault)]) }
    func deleteAll() async throws { try await backend.deleteAll() }

    /// What one note is donated as: title, description, tags, date and (only with Include Note Text) its text.
    /// No thumbnail, ever; no activity, so no Handoff, prediction or public indexing (D4, D5).
    static func searchableItem(_ item: SpotlightItem, expires: Date) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = item.title
        attributes.displayName = item.title
        attributes.contentDescription = item.contentDescription
        attributes.keywords = item.keywords
        attributes.contentModificationDate = item.modified
        attributes.textContent = item.textContent
        let searchable = CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: item.domain, attributeSet: attributes)
        searchable.expirationDate = expires
        return searchable
    }
}
