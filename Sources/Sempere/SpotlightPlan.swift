import Foundation

/// What one note would be donated to Core Spotlight as (docs/design/1.3-spotlight.md §3.2): a plain value with
/// no CoreSpotlight type, so the rules of what leaves the vault are one piece of Foundation-only code that the app
/// and `sempere spotlight plan` both run, and Linux tests pin.
public struct SpotlightItem: Hashable, Sendable {
    /// `<vaultId>/<noteId>`, lowercase: the item's `uniqueIdentifier`.
    public var id: String
    public var vaultId: UUID
    public var noteId: UUID
    /// `io.github.anthonytw.sempere.<vaultId>`: removes everything of one vault in one call.
    public var domain: String
    /// The note title ("Untitled note" when blank).
    public var title: String
    public var contentDescription: String
    /// The note's tags.
    public var keywords: [String]
    public var modified: Date?
    /// Matched by Spotlight, never shown: only with Include Note Text.
    public var textContent: String?

    public init(vaultId: UUID, noteId: UUID, title: String, contentDescription: String, keywords: [String],
                modified: Date?, textContent: String?) {
        self.vaultId = vaultId; self.noteId = noteId
        self.id = SpotlightPlanner.identifier(vault: vaultId, note: noteId)
        self.domain = SpotlightPlanner.domain(vault: vaultId)
        self.title = title; self.contentDescription = contentDescription; self.keywords = keywords
        self.modified = modified; self.textContent = textContent
    }

    /// A value that changes when anything donated changes (in-process only: `Hasher` is seeded per run).
    public var fingerprint: Int { hashValue }
}

/// What to donate, from the two switches and the device.
public struct SpotlightOptions: Sendable {
    /// Include Note Text: recognized handwriting, typed text, PDF text, equations' source and transcripts.
    public var includeText: Bool
    /// The vault's name, shown in `contentDescription` only when two or more vaults of the device have the
    /// switch on (decision 3): nil otherwise.
    public var vaultName: String?
    /// "Untitled note", localized by the app.
    public var untitled: String
    /// How the modified date reads (the app passes a localized one).
    public var dateText: @Sendable (Date) -> String

    public init(includeText: Bool = false, vaultName: String? = nil, untitled: String = "Untitled note",
                dateText: @escaping @Sendable (Date) -> String = SpotlightPlanner.isoDay) {
        self.includeText = includeText; self.vaultName = vaultName; self.untitled = untitled; self.dateText = dateText
    }
}

/// The result of planning a vault.
public struct SpotlightPlan: Sendable {
    public var items: [SpotlightItem]
    /// Notes left out because the vault has more than `SpotlightPlanner.maxNotes` (the oldest by modified date).
    public var omitted: Int

    public init(items: [SpotlightItem], omitted: Int = 0) { self.items = items; self.omitted = omitted }
}

/// What an incremental update changes.
public struct SpotlightChange: Equatable, Sendable {
    public var upserts: [SpotlightItem]
    public var deletes: [String]
    public var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }
}

extension Transcript {
    /// The transcript's text, one segment per line: what Spotlight's Include Note Text donates.
    public var spotlightText: String { segments.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// The rules of what is donated (§3.2, §6) and the incremental diff (§3.3).
public enum SpotlightPlanner {
    /// 20,000 text characters per item.
    public static let maxTextCharacters = 20_000
    /// 140 characters of text in the description.
    public static let descriptionTextCharacters = 140
    /// 50,000 notes per vault.
    public static let maxNotes = 50_000
    /// Items per call to the index.
    public static let batchSize = 200
    /// Items expire this long after the last unlock that renewed them (the backstop for every removal).
    public static let expiryDays = 30

    public static func identifier(vault: UUID, note: UUID) -> String {
        "\(vault.uuidString.lowercased())/\(note.uuidString.lowercased())"
    }

    public static func domain(vault: UUID) -> String { "io.github.anthonytw.sempere.\(vault.uuidString.lowercased())" }

    /// The ids of a note and its vault from an item identifier (a `CSSearchableItemActivityIdentifier`).
    public static func parse(identifier: String) -> (vault: UUID, note: UUID)? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let v = UUID(uuidString: String(parts[0])), let n = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        return (v, n)
    }

    /// `yyyy-MM-dd` in UTC.
    public static func isoDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The items for `notes` of vault `vaultId`: no deleted note, none of `notDownloaded` (a partial copy's
    /// notes not fetched yet), never a thumbnail. `transcripts` holds each note's transcript texts, which the
    /// caller supplies only when the user's `search.transcripts` allows them in search (a transcript is a blob,
    /// not part of `NoteSummary`); they are used only with `includeText`.
    public static func plan(vaultId: UUID, notes: [NoteSummary], options: SpotlightOptions,
                            transcripts: [UUID: [String]] = [:], notDownloaded: Set<UUID> = []) -> SpotlightPlan {
        var eligible = notes.filter { !$0.deleted && !notDownloaded.contains($0.id) }
        eligible.sort { a, b in
            let (x, y) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
            return x != y ? x > y : a.id.uuidString < b.id.uuidString
        }
        let omitted = max(0, eligible.count - maxNotes)
        if omitted > 0 { eligible.removeLast(omitted) }
        let items = eligible.map { item(vaultId: vaultId, note: $0, options: options, transcripts: transcripts[$0.id] ?? []) }
        return SpotlightPlan(items: items, omitted: omitted)
    }

    static func item(vaultId: UUID, note: NoteSummary, options: SpotlightOptions, transcripts: [String]) -> SpotlightItem {
        var text: String?
        if options.includeText {
            let joined = (note.pageTexts.map(\.text) + transcripts).filter { !$0.isEmpty }.joined(separator: "\n")
            if !joined.isEmpty { text = String(joined.prefix(maxTextCharacters)) }
        }
        var parts: [String] = []
        if let name = options.vaultName, !name.isEmpty { parts.append(name) }
        if let notebook = note.notebook, !notebook.isEmpty { parts.append(notebook) }
        if let text {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            parts.append(String(flat.prefix(descriptionTextCharacters)).trimmingCharacters(in: .whitespaces))
        } else if let modified = note.modified {
            parts.append(options.dateText(modified))
        }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpotlightItem(vaultId: vaultId, noteId: note.id, title: title.isEmpty ? options.untitled : note.title,
                             contentDescription: parts.joined(separator: " · "), keywords: note.tags,
                             modified: note.modified, textContent: text)
    }

    /// The fingerprints of items, by id (`diff`'s `old`).
    public static func fingerprints(_ items: [SpotlightItem]) -> [String: Int] {
        Dictionary(items.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { _, b in b })
    }

    /// What changes between what was donated (`old`) and `new`: items whose title, tags, notebook, date or text
    /// changed or that are new are upserted; ids no longer in `new` (deleted, purged, past the cap) are deleted.
    /// A restored note is new again, so it is re-donated.
    public static func diff(old: [String: Int], new: [SpotlightItem]) -> SpotlightChange {
        let upserts = new.filter { old[$0.id] != $0.fingerprint }
        let keep = Set(new.map(\.id))
        return SpotlightChange(upserts: upserts, deletes: old.keys.filter { !keep.contains($0) }.sorted())
    }
}
