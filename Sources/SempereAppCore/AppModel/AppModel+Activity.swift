import Foundation
import Sempere

/// "Recently Recognized" (notes a recognition run on any device read in the
/// last 7 days: each note's `meta.recognized`, format.md §5.4, synced with the
/// vault) and the recent searches, remembered per vault on this device
/// (`RecentActivity`, sealed under the vault secret).
extension AppModelCore {
    /// Reads what this device remembers of the open, unlocked vault.
    public func loadActivity() {
        guard let vault, vault.canRead else { return }
        activity = RecentActivity.load(root: activityRoot, vault: vault, now: activityNow())
    }

    /// Stores `activity` for the open vault.
    public func saveActivity() {
        guard let vault, vault.canRead else { return }
        activity.save(root: activityRoot, vault: vault)
    }

    /// Live notes recognized in the last 7 days, newest first: the sidebar
    /// shows "Recently Recognized" only while there are some. Written by this
    /// device's runs and by every other device's (`RecentlyRecognized`).
    public var recentlyRecognizedNotes: [NoteSummary] {
        _ = activityClockTick   // observed: redrawn when a run leaves the window
        return RecentlyRecognized.notes(notes, now: activityNow())
    }

    /// When `recentlyRecognizedNotes` next changes by the clock alone (nil:
    /// not until the notes change). The sidebar waits for it, then calls
    /// `recentlyRecognizedClockChanged`.
    public var recentlyRecognizedNextChange: Date? {
        _ = activityClockTick
        return RecentlyRecognized.nextChange(notes, now: activityNow())
    }

    /// The time `recentlyRecognizedNextChange` named has come: what reads
    /// "Recently Recognized" is drawn again.
    public func recentlyRecognizedClockChanged() {
        activityClockTick &+= 1
        leaveEmptyRecognizedSection()
    }

    /// What the last run read in note `id` ("Read 2 of 5 pages"), while it is recent.
    public func recognizedEntry(for id: UUID) -> RecognizedNote? {
        notesByID[id].flatMap(recognizedEntry(of:))
    }

    /// `recognizedEntry(for:)` of a summary in hand (a list row: no lookup).
    public func recognizedEntry(of note: NoteSummary) -> RecognizedNote? {
        _ = activityClockTick
        guard let run = note.recognized, RecentlyRecognized.isRecent(run, now: activityNow()) else { return nil }
        return RecognizedNote(id: note.id, title: note.title, pages: run.pages, pagesRecognized: run.read)
    }

    /// Leaves "Recently Recognized" for All Notes once it has nothing to show
    /// (the sidebar row is gone).
    public func leaveEmptyRecognizedSection() {
        if sidebarSelection == .recentlyRecognized, recentlyRecognizedNotes.isEmpty { sidebarSelection = .allNotes }
    }

    // MARK: - Recent searches

    /// The recent searches, newest first.
    public var recentSearches: [String] { activity.searches.queries }

    /// Remembers the current query (submitted, or a hit opened from it).
    public func recordSearch() {
        let before = activity.searches
        activity.searches.record(searchText)
        if activity.searches != before { saveActivity() }
    }

    /// Searches `query` again.
    public func rerunSearch(_ query: String) {
        searchText = query
        recordSearch()
    }

    /// Forgets the recent searches ("Clear").
    public func clearRecentSearches() {
        activity.searches.clear()
        saveActivity()
    }
}
