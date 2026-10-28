import Foundation

/// One page's recognition, valid for the strokes whose digest it carries.
public struct RecognitionJob: Hashable, Sendable {
    public var page: UUID
    /// `RecognitionBasis.digest` of the page's strokes when it was read.
    public var digest: String
    /// Nil clears the page's recognition (a page left without strokes).
    public var recognition: Recognition?

    public init(page: UUID, digest: String, recognition: Recognition?) {
        self.page = page; self.digest = digest; self.recognition = recognition
    }

    /// The `setPageRecognition` ops that `jobs` still stand for in `current`:
    /// each page is written only if its strokes are still the ones that were
    /// read (another device may have edited the note meanwhile). A deleted or
    /// missing note gets none.
    public static func ops(for jobs: [RecognitionJob], in current: NoteState?) -> [Op] {
        guard let current, !current.deleted else { return [] }
        return jobs.compactMap { job -> Op? in
            guard let page = current.pages.first(where: { $0.id == job.page }),
                  RecognitionBasis.digest(of: page) == job.digest else { return nil }
            return .setPageRecognition(pageId: job.page, recognition: job.recognition)
        }
    }

    /// `ops(for:in:)`, followed by the `setMeta` of `meta.recognized` that
    /// puts the note in "Recently Recognized" on every device (format.md
    /// §5.4) when the run read it at `at` and wrote at least one page.
    public static func ops(for jobs: [RecognitionJob], in current: NoteState?, recordedAt at: Date) -> [Op] {
        let pages = ops(for: jobs, in: current)
        guard let current, !pages.isEmpty else { return pages }
        return pages + RecentlyRecognized.record(at: at, pages: current.pages.count, read: pages.count)
    }
}

/// "Recently Recognized": the notes a vault-wide recognition run (the app's
/// "Recognize All Notes", `sempere recognize`) read in the last 7 days, from
/// each note's `meta.recognized` register (format.md §5.4), so every device
/// lists the same notes. Pure.
public enum RecentlyRecognized {
    /// How long a note stays listed.
    public static let window: TimeInterval = 7 * 86_400
    /// How far in the future a run may be stamped and still count (another
    /// device's clock may run ahead a little; a wildly wrong one is ignored).
    public static let clockSkew: TimeInterval = 86_400

    /// The op that records a run at `at` over a note of `pages` pages, `read`
    /// of them written; none when the counts break the bounds.
    public static func record(at: Date, pages: Int, read: Int) -> [Op] {
        RecognitionRecord(at: at, pages: pages, read: min(read, pages)).map { [.setMeta(.recognized($0))] } ?? []
    }

    /// Whether `record` is within the last `window` at `now`.
    public static func isRecent(_ record: RecognitionRecord?, now: Date, window: TimeInterval = window) -> Bool {
        guard let at = record?.at else { return false }
        return at >= now.addingTimeInterval(-window) && at <= now.addingTimeInterval(clockSkew)
    }

    /// When `notes(_:now:)` next changes by the clock alone: the earliest
    /// time after `now` a recent run leaves the window, or a run stamped
    /// further ahead than `clockSkew` comes in. Nil when no note's run will
    /// (a list shown at `now` stays right until notes change).
    public static func nextChange(_ notes: [NoteSummary], now: Date, window: TimeInterval = window) -> Date? {
        var next: Date?
        for note in notes where !note.deleted {
            guard let at = note.recognized?.at else { continue }
            let leaves = at.addingTimeInterval(window), enters = at.addingTimeInterval(-clockSkew)
            for t in [enters, leaves] where t > now { next = min(next ?? t, t) }
        }
        return next
    }

    /// The live notes of `notes` read recently, newest run first (then by id).
    public static func notes(_ notes: [NoteSummary], now: Date, window: TimeInterval = window) -> [NoteSummary] {
        notes.filter { !$0.deleted && isRecent($0.recognized, now: now, window: window) }
            .sorted {
                let a = $0.recognized?.at ?? .distantPast, b = $1.recognized?.at ?? .distantPast
                return a != b ? a > b : $0.id.uuidString < $1.id.uuidString
            }
    }
}

/// A note the app's "Recognize All Notes" changed: what the results list
/// shows ("Recognized 12 notes", each with its title and pages read).
public struct RecognizedNote: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// Pages the note has.
    public var pages: Int
    /// Pages whose recognition the run wrote.
    public var pagesRecognized: Int

    public init(id: UUID, title: String, pages: Int, pagesRecognized: Int) {
        self.id = id; self.title = title; self.pages = pages; self.pagesRecognized = pagesRecognized
    }
}
