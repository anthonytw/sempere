import Foundation
import Sempere

/// The open vault's backup reminder (Settings ▸ Backups ▸ Remind Me, `BackupReminder`): a local notification
/// through `backupNotifier`, worded by the front end (`LocalNotice.backupReminder`). Settings sync sets it too
/// (`backup.reminderDays`), without asking for permission. The backups themselves are the app's (`AppModel+Backup`).
extension AppModelCore {
    /// Sets "remind me after `days` without a backup" (0: off) and, when the user switched it on here (`ask`),
    /// asks for permission to notify. A setting that arrives from another device (`ask` false) never prompts: it
    /// notifies only where the permission is already given. Returns false when notifications are not allowed
    /// (the setting is kept: Settings still shows an overdue backup).
    @discardableResult
    public func setBackupReminder(days: Int, now: Date = Date(), ask: Bool = true) async -> Bool {
        guard let vault else { return false }
        var record = backupStore.record(for: vault.vaultId)
        record.reminderDays = max(days, 0)
        record.reminderSince = days > 0 ? (record.reminderSince ?? now) : nil
        backupStore.save(record, for: vault.vaultId)
        let allowed = days > 0 ? (ask ? await backupNotifier.authorize() : await backupNotifier.isAuthorized()) : true
        await rescheduleBackupReminder(now: now)
        return allowed
    }

    /// Replaces the open vault's pending reminder with one for its current
    /// due date (after a backup, a setting change, unlocking), or removes it.
    func rescheduleBackupReminder(now: Date = Date()) async {
        guard let vault, let name = vaultName else { return }
        let record = backupStore.record(for: vault.vaultId)
        let id = BackupReminder.identifier(vault.vaultId)
        guard let date = BackupReminder.fireDate(record, now: now) else {
            await backupNotifier.cancel(id: id)
            return
        }
        await backupNotifier.schedule(id: id, at: date, notice: .backupReminder(vaultName: name, record: record))
    }
}
