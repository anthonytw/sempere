import Foundation
import SempereSync
import Testing

/// The background budget (docs/design/device-first-sync.md §4.2): order, per-run bounds and fairness.
struct BackgroundBudgetTests {
    static func candidate(_ vault: UUID = UUID(), unconfirmed: Bool = false, open: Bool = false,
                          success: TimeInterval? = nil, tried: TimeInterval? = nil) -> BackgroundRunCandidate {
        BackgroundRunCandidate(vaultID: vault, targetID: UUID(), hasUnconfirmed: unconfirmed, isOpenVault: open,
                               lastSuccess: success.map { Date(timeIntervalSince1970: $0) },
                               lastTried: tried.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func unconfirmedThenOpenThenOldestSuccess() {
        let recent = Self.candidate(success: 300), old = Self.candidate(success: 100), never = Self.candidate()
        let open = Self.candidate(open: true, success: 50)
        let dirty = Self.candidate(unconfirmed: true, success: 400)
        let order = BackgroundBudget.order([recent, open, old, dirty, never])
        #expect(order.map(\.targetID) == [dirty, open, never, old, recent].map(\.targetID))
    }

    @Test func runTimesShareTheRemainingTimeWithAFloor() {
        #expect(BackgroundBudget.runTime(remaining: 25, runsLeft: 5) == 5)
        #expect(BackgroundBudget.runTime(remaining: 24, runsLeft: 2) == 12)
        #expect(BackgroundBudget.runTime(remaining: 12, runsLeft: 4) == 5)   // the floor
        #expect(BackgroundBudget.runTime(remaining: 4.9, runsLeft: 1) == nil)   // waits for the next task
        #expect(BackgroundBudget.runTime(remaining: 30, runsLeft: 0) == nil)
    }

    /// Ten vaults never succeed and only five runs fit a task: trying a pair moves it back, so the next task
    /// reaches the other five and none starves.
    @Test func triedPairsGoToTheBack() {
        var all = (0..<10).map { _ in Self.candidate() }
        var reached = Set<UUID>()
        for task in 0..<2 {
            var remaining = BackgroundBudget.refreshTime
            let order = BackgroundBudget.order(all)
            for (i, c) in order.enumerated() {
                guard let t = BackgroundBudget.runTime(remaining: remaining, runsLeft: order.count - i) else { break }
                reached.insert(c.targetID)
                remaining -= t   // every run uses its whole bound (a hung server)
                if let k = all.firstIndex(where: { $0.targetID == c.targetID }) {
                    all[k].lastTried = Date(timeIntervalSince1970: Double(task * 100 + i))
                }
            }
        }
        #expect(reached == Set(all.map(\.targetID)))
    }

    @Test func tryingNeverMovesAPairOutOfItsTier() {
        let dirty = (0..<3).map { Self.candidate(unconfirmed: true, tried: 100 + Double($0)) }
        let rest = (0..<3).map { _ in Self.candidate() }
        let order = BackgroundBudget.order(rest + dirty)
        #expect(order.prefix(3).map(\.targetID) == dirty.map(\.targetID))
    }
}
