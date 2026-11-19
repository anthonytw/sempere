import Foundation
import Sempere

// Opt-in Spotlight indexing, the part that needs no platform (docs/design/1.3-spotlight.md §3): the per-vault,
// per-device switch, the removal bookkeeping and the index protocol the app implements with Core Spotlight
// (`SpotlightIndexer`, the only file that imports it). What is donated is `SpotlightPlanner` (Sempere); the model's
// hooks are `AppModel+Spotlight`.

/// The Core Spotlight calls, as the model needs them. The app's `CoreSpotlightIndex`; tests use a fake.
public protocol SpotlightIndexing: Sendable {
    /// Adds or replaces items (by `id`).
    func index(_ items: [SpotlightItem]) async throws
    /// Removes items by identifier.
    func delete(ids: [String]) async throws
    /// Removes everything of one vault (its domain).
    func deleteDomain(vault: UUID) async throws
    /// Removes everything the named index holds.
    func deleteAll() async throws
}

/// An index that holds nothing (tests that do not look at Spotlight, a platform without it).
public struct NoSpotlightIndex: SpotlightIndexing {
    public init() {}
    public func index(_ items: [SpotlightItem]) async throws {}
    public func delete(ids: [String]) async throws {}
    public func deleteDomain(vault: UUID) async throws {}
    public func deleteAll() async throws {}
}

/// How much of a vault is in Spotlight (the two switches).
public enum SpotlightMode: String, Sendable, Equatable {
    case off
    /// Titles, notebooks, tags and dates.
    case metadata
    /// And note text: recognized handwriting, typed text, PDF text and transcripts.
    case text

    public var isOn: Bool { self != .off }
    public var includesText: Bool { self == .text }
}

/// Why the switch cannot be on for the open vault (§3.1).
public enum SpotlightEligibility: Equatable, Sendable {
    case eligible
    /// No vault is open and unlocked.
    case notUnlocked
    /// This device holds no key for the vault (opened with the recovery key or a passphrase copy).
    case noDeviceKeys
    /// The device list does not check.
    case listNotTrusted
    /// This device was removed from the vault.
    case removed
    /// The demo vault.
    case demo
}

/// Why a switch was turned off by the app (shown once, as a notice).
public enum SpotlightNotice: Equatable, Sendable {
    case deviceRemoved
    case listNotTrusted
    /// This device no longer holds the vault's keys.
    case unavailable
}

/// A link that could not be followed.
public enum NoteLinkProblem: Equatable, Sendable {
    /// The vault or the note is not on this device any more.
    case notOnThisDevice
}

/// A link to one note, for Spotlight results and the Ask citations (docs/design/1.3-spotlight.md §3.5,
/// 1.3-ask.md §3.7). Never a URL: nothing outside the app can build one that opens a note.
public struct NoteLink: Hashable, Sendable {
    public var vaultId: UUID
    public var noteId: UUID
    /// The page to show; nil opens the note where it starts.
    public var page: UUID?

    public init(vaultId: UUID, noteId: UUID, page: UUID? = nil) {
        self.vaultId = vaultId; self.noteId = noteId; self.page = page
    }

    /// From a Spotlight `CSSearchableItemActivityIdentifier` (`<vaultId>/<noteId>`).
    public init?(spotlightIdentifier: String) {
        guard let ids = SpotlightPlanner.parse(identifier: spotlightIdentifier) else { return nil }
        self.init(vaultId: ids.vault, noteId: ids.note)
    }

    /// The item identifier Spotlight knows the note by.
    public var spotlightIdentifier: String { SpotlightPlanner.identifier(vault: vaultId, note: noteId) }
}

/// What `AppModel.open(_:)` did with a link.
public enum NoteLinkOutcome: Equatable, Sendable {
    /// The note is shown.
    case opened
    /// Kept as `pendingNoteLink` until the vault is open, unlocked and listed: the caller opens the vault.
    case needsVault
    /// Kept until the open vault's list is in.
    case waiting
    /// Not on this device: the model reports `noteLinkProblem` and removes the stale Spotlight item.
    case gone
}

/// The per-device Spotlight records (`UserDefaults`, never synced: docs/settings-sync.md §5.3) and the removals that
/// must survive a failure.
@MainActor
public final class SpotlightManager {
    public let index: any SpotlightIndexing
    private let defaults: any KeyValueStore

    static let vaultsKey = "Sempere.spotlight.vaults"
    static let pendingKey = "Sempere.spotlight.pendingDeletions"
    static func modeKey(_ vault: UUID) -> String { "Sempere.spotlight.\(vault.uuidString.lowercased())" }

    public init(index: any SpotlightIndexing, defaults: any KeyValueStore) {
        self.index = index
        self.defaults = defaults
    }

    /// The vault's switches on this device.
    public func mode(for vault: UUID) -> SpotlightMode {
        defaults.string(forKey: Self.modeKey(vault)).flatMap(SpotlightMode.init(rawValue:)) ?? .off
    }

    /// The vaults whose switch is on.
    public var vaultsOn: [UUID] {
        (defaults.object(forKey: Self.vaultsKey) as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Records the switches (nothing else: the model donates or removes).
    func record(_ mode: SpotlightMode, for vault: UUID) {
        var on = vaultsOn.filter { $0 != vault }
        if mode.isOn {
            defaults.set(mode.rawValue, forKey: Self.modeKey(vault))
            on.append(vault)
            setPending(pendingDeletions.filter { $0 != vault })
        } else {
            defaults.removeObject(forKey: Self.modeKey(vault))
        }
        defaults.set(on.map { $0.uuidString.lowercased() }, forKey: Self.vaultsKey)
    }

    /// Vaults whose removal failed and is retried at the next launch (ids only: no note data).
    public var pendingDeletions: [UUID] {
        (defaults.object(forKey: Self.pendingKey) as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    private func setPending(_ ids: [UUID]) {
        if ids.isEmpty { defaults.removeObject(forKey: Self.pendingKey) } else {
            defaults.set(ids.map { $0.uuidString.lowercased() }, forKey: Self.pendingKey)
        }
    }

    /// Removes everything of `vault` from the index; a failure puts it on the retry list. True: it is gone.
    @discardableResult
    public func removeDomain(_ vault: UUID) async -> Bool {
        do {
            try await index.deleteDomain(vault: vault)
            setPending(pendingDeletions.filter { $0 != vault })
            return true
        } catch {
            if !pendingDeletions.contains(vault) { setPending(pendingDeletions + [vault]) }
            return false
        }
    }

    /// Retries the removals that failed (launch).
    public func retryPending() async {
        for vault in pendingDeletions { await removeDomain(vault) }
    }

    /// After a switch went off: when no vault has it on, the whole named index goes (§3.4).
    public func clearIndexIfNoneOn() async {
        guard vaultsOn.isEmpty else { return }
        try? await index.deleteAll()
    }

    /// A vault removed from this device: its items, its record, and the index when it was the last.
    public func vaultRemoved(_ vault: UUID) async {
        record(.off, for: vault)
        await removeDomain(vault)
        await clearIndexIfNoneOn()
    }
}
