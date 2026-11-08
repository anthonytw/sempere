import Foundation
import SempereAppCore
import UIKit

extension UIApplication.State {
    /// How quick capture and its diagnostics name it (`CaptureAppActivity`).
    var captureActivity: CaptureAppActivity {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .unknown
        }
    }
}

/// Waits for the app to become active, at most `timeout`: true when it is active (at once, if it
/// already is), false when the time ran out. On a notification, never polling: the observer is
/// registered before `isActive` is checked, so an activation in between is not missed. Not
/// cancelled with the task that awaits it (an intent's): it ends by the notification or the timeout.
@MainActor
enum AppActivation {
    static func wait(timeout: Duration, center: NotificationCenter = .default,
                     name: Notification.Name = UIApplication.didBecomeActiveNotification,
                     isActive: @MainActor () -> Bool) async -> Bool {
        let gate = Gate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.continuation = continuation
            gate.observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { gate.finish(true, center: center) }
            }
            if isActive() {
                gate.finish(true, center: center)
                return
            }
            gate.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.finish(false, center: center)
            }
        }
    }

    /// Resumes the continuation once, and removes the observer and the timer.
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Bool, Never>?
        var observer: NSObjectProtocol?
        var timer: Task<Void, Never>?

        func finish(_ value: Bool, center: NotificationCenter) {
            guard let c = continuation else { return }
            continuation = nil
            if let observer { center.removeObserver(observer) }
            observer = nil
            timer?.cancel()
            timer = nil
            c.resume(returning: value)
        }
    }
}
