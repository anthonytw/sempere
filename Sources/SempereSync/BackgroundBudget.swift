import Foundation

/// One (vault, target) pair a background task may run (docs/design/device-first-sync.md §4.2).
public struct BackgroundRunCandidate: Sendable, Equatable {
    public var vaultID: UUID
    public var targetID: UUID
    /// The vault has local changes this target has not confirmed.
    public var hasUnconfirmed: Bool
    /// The vault is the one open in the app.
    public var isOpenVault: Bool
    /// When a run of this pair last succeeded; nil: never.
    public var lastSuccess: Date?
    /// When a background task last ran this pair, whatever came of it; nil: never.
    public var lastTried: Date?

    public init(vaultID: UUID, targetID: UUID, hasUnconfirmed: Bool, isOpenVault: Bool, lastSuccess: Date?,
                lastTried: Date? = nil) {
        self.vaultID = vaultID
        self.targetID = targetID
        self.hasUnconfirmed = hasUnconfirmed
        self.isOpenVault = isOpenVault
        self.lastSuccess = lastSuccess
        self.lastTried = lastTried
    }
}

/// How a background task's time is shared among every vault and target (docs/design/device-first-sync.md
/// §4.2, "Background budget"). Pure: the coordinator asks it for the order and for each run's time bound.
///
/// - Order: pairs whose vault has local changes no target confirmed first, then the open vault's, then the
///   rest. Within each tier the pair a background task tried least recently goes first (never tried first),
///   then the oldest last success (never first). Trying a pair moves it to the back of its tier, so the start
///   rotates from task to task: a pair that keeps failing, or one that never fits the time left, does not
///   keep the others behind it (the coordinator keeps `lastTried` across launches).
/// - Each run gets `remaining / runs left`, at least `minimumRun`; when less than `minimumRun` is left, the
///   remaining runs wait for the next task.
public enum BackgroundBudget {
    /// The shortest bound a background run is given.
    public static let minimumRun: TimeInterval = 5
    /// The time a `BGAppRefreshTask` shares out (iOS gives about 30 s; some is kept for the task's own end).
    public static let refreshTime: TimeInterval = 25

    /// The candidates in the order they run.
    public static func order(_ candidates: [BackgroundRunCandidate]) -> [BackgroundRunCandidate] {
        func tier(_ c: BackgroundRunCandidate) -> Int { c.hasUnconfirmed ? 0 : (c.isOpenVault ? 1 : 2) }
        return candidates.sorted { a, b in
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            let ta = a.lastTried ?? .distantPast, tb = b.lastTried ?? .distantPast
            if ta != tb { return ta < tb }
            let sa = a.lastSuccess ?? .distantPast, sb = b.lastSuccess ?? .distantPast
            if sa != sb { return sa < sb }
            if a.vaultID != b.vaultID { return a.vaultID.uuidString < b.vaultID.uuidString }
            return a.targetID.uuidString < b.targetID.uuidString
        }
    }

    /// The time bound of the next run, with `remaining` seconds left in the task and `runsLeft` runs to go
    /// (this one included); nil when the run does not fit and waits for the next task.
    public static func runTime(remaining: TimeInterval, runsLeft: Int, minimum: TimeInterval = minimumRun) -> TimeInterval? {
        guard runsLeft > 0, remaining >= minimum else { return nil }
        return max(remaining / Double(runsLeft), minimum)
    }
}
