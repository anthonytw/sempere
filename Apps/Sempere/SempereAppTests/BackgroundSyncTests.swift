import BackgroundTasks
import Foundation
import Sempere
import Testing
@testable import SempereApp

// Fakes for the background-time and task-scheduler seams (`BackgroundTargetsTests`).

/// `beginBackgroundTask` faked: records what was begun and ended, and lets a
/// test expire the time iOS gave.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskRunning {
    var grant = true
    private(set) var begun: [BackgroundTaskToken] = []
    private(set) var ended: [BackgroundTaskToken] = []
    private var expiry: (@MainActor @Sendable () -> Void)?
    private var next = 1

    func begin(name: String, expired: @escaping @MainActor @Sendable () -> Void) -> BackgroundTaskToken? {
        guard grant else { return nil }
        let token = BackgroundTaskToken(raw: next)
        next += 1
        begun.append(token)
        expiry = expired
        return token
    }

    func end(_ token: BackgroundTaskToken) { ended.append(token) }

    /// iOS takes the background time back.
    func expire() { expiry?() }
}

@MainActor
final class FakeSyncScheduler: BackgroundSyncScheduling {
    private(set) var requests: [BackgroundSyncRequest] = []
    func schedule(_ request: BackgroundSyncRequest) { requests.append(request) }
}
