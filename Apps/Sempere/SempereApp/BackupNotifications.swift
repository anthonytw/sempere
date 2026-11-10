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
    func authorize() async -> Bool { await Self.authorize() }

    func isAuthorized() async -> Bool { await Self.allowed() }

    func schedule(id: String, at date: Date, notice: LocalNotice) async {
        let text = notice.text
        await Self.schedule(id: id, after: max(date.timeIntervalSinceNow, 60), title: text.title, body: text.body)
    }

    func cancel(id: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
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
