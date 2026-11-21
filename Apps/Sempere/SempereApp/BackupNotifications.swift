import Foundation
import UserNotifications
import SempereAppCore

extension LocalNotice {
    /// The notification's title and body.
    var text: (title: String, body: String) {
        switch self {
        case .backupReminder(let vaultName, let record): return BackupReminder.message(vaultName: vaultName, record: record)
        case .takeover(let alert): return (TakeoverAlert.title, alert.message)
        }
    }
}

/// Backup reminders (and the takeover notice) as local notifications (`BackupReminder`): one pending
/// request per vault, replaced whenever the due date moves. Nothing leaves
/// the device; the text names the vault, never a note.
@MainActor
final class UserNotificationBackupNotifier: BackupNotifying {
    private let queue = NotificationQueue()

    func authorize() async -> Bool { await Self.authorize() }

    func isAuthorized() async -> Bool { await Self.allowed() }

    func schedule(id: String, at date: Date, notice: LocalNotice) async {
        let text = notice.text
        let interval = max(date.timeIntervalSinceNow, 60)
        await queue.enqueue { await Self.schedule(id: id, after: interval, title: text.title, body: text.body) }
    }

    /// Off the main actor: `removePendingNotificationRequests` is a synchronous system call that can block for
    /// a long time right after boot or unlock. It runs on the same queue as `schedule`, so the two stay in order.
    func cancel(id: String) async {
        await queue.enqueue { await Self.remove(id: id) }
    }

    // The center's objects are built and used off the main actor, so nothing
    // that is not Sendable crosses an isolation boundary.

    private nonisolated static func allowed() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private nonisolated static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    private nonisolated static func remove(id: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private nonisolated static func schedule(id: String, after interval: TimeInterval, title: String,
                                             body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Runs the notification center's calls one at a time, in the order they were enqueued, off the main actor.
/// (An actor alone would not do: a `schedule` suspends in `add`, and a later `cancel` could run in the gap.)
private actor NotificationQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task.detached { await previous?.value; await operation() }
        tail = task
        await task.value
    }
}
