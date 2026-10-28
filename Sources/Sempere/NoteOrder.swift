import Foundation

/// How a note listing is ordered: the app's note list and `sempere notes list --sort`.
///
/// One rule for both (CLI first): dates newest first, titles in Finder order
/// (`localizedStandardCompare`), ties broken by id so the order is stable.
/// With `favoritesFirst` the favorites come before the other notes, each group
/// in the chosen order.
public struct NoteOrder: Hashable, Sendable {
    /// The field a listing is sorted by.
    public enum Key: String, CaseIterable, Hashable, Sendable {
        /// The date of the last edit (`NoteSummary.modified`, `ModifiedDate`), newest first.
        case modified
        /// When the note was created (`meta.created`, `NoteSummary.created`), newest first.
        case created
        /// The title, A to Z.
        case title
    }

    public var key: Key
    /// Favorites (`meta.favorite`) before the other notes, whatever the key.
    public var favoritesFirst: Bool

    public init(_ key: Key = .modified, favoritesFirst: Bool = false) {
        self.key = key
        self.favoritesFirst = favoritesFirst
    }

    /// `notes` in this order.
    public func sorted(_ notes: [NoteSummary]) -> [NoteSummary] {
        notes.sorted(by: precedes)
    }

    /// Whether `a` comes before `b`.
    public func precedes(_ a: NoteSummary, _ b: NoteSummary) -> Bool {
        if favoritesFirst, a.favorite != b.favorite { return a.favorite }
        switch key {
        case .title:
            let c = a.title.localizedStandardCompare(b.title)
            if c != .orderedSame { return c == .orderedAscending }
        case .modified:
            if let r = Self.newerFirst(a.modified, b.modified) { return r }
        case .created:
            if let r = Self.newerFirst(a.created, b.created) { return r }
        }
        return a.id.uuidString < b.id.uuidString
    }

    /// Newest first, notes without the date last; nil when the dates do not decide.
    private static func newerFirst(_ a: Date?, _ b: Date?) -> Bool? {
        switch (a, b) {
        case let (a?, b?) where a != b: return a > b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return nil
        }
    }
}

/// The kinds of attachments a note holds, for the icons of a note listing
/// (`NoteSummary.attachments`) and `notes list --json`.
public struct NoteAttachments: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Image items (format.md §8.2.5).
    public static let images = NoteAttachments(rawValue: 1 << 0)
    /// PDF page items (§8.2.6).
    public static let pdf = NoteAttachments(rawValue: 1 << 1)
    /// Video items (§8.2.7).
    public static let video = NoteAttachments(rawValue: 1 << 2)
    /// Equations: math items (§8.2.8).
    public static let math = NoteAttachments(rawValue: 1 << 3)
    /// Recordings (§8.3) or audio cards (§8.2.9).
    public static let audio = NoteAttachments(rawValue: 1 << 4)

    /// Every kind with its name (`notes list --json`), in the order a listing shows them.
    public static let named: [(kind: NoteAttachments, name: String)] = [
        (.images, "image"), (.math, "math"), (.video, "video"), (.audio, "audio"), (.pdf, "pdf"),
    ]

    /// The names of the kinds present, in `named` order.
    public var names: [String] { Self.named.filter { contains($0.kind) }.map(\.name) }

    /// What `state` holds (live items of every page, and its recordings).
    public init(state: NoteState) {
        var kinds: NoteAttachments = []
        for page in state.pages {
            for item in page.items {
                switch item.kind {
                case .image: kinds.insert(.images)
                case .pdfPage: kinds.insert(.pdf)
                case .video: kinds.insert(.video)
                case .math: kinds.insert(.math)
                case .audio: kinds.insert(.audio)
                default: break
                }
            }
        }
        if !state.recordings.isEmpty { kinds.insert(.audio) }
        self = kinds
    }
}
