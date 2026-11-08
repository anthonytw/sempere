import Foundation
import Sempere
import SempereAppCore

// The words of the backups' values (`AppModel+Backup.swift` in SempereAppCore).

extension AppModelBackupError: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .noVault: return String(localized: "No vault is open.")
        case .noFolder: return String(localized: "Choose a backup folder first.")
        case .folderGone(let name):
            return String(localized: "The backup folder “\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose it again.",
                          comment: "Backups: %@ is the folder's name")
        case .folderUnavailable(let name):
            return String(localized: "The backup folder “\(name)” can't be reached now: its drive is not connected or its share is not mounted. Connect it and try again.",
                          comment: "Backups: %@ is the folder's name")
        case .busy: return String(localized: "A backup, check or restore is already running.")
        case .notDownloadedFromServer(let n, let server):
            return String(localized: "\(server) has not delivered every note yet (missing: \(n)), and a backup must hold every note. Check that this device is online and try again.",
                          comment: "Back Up Now: %@ is a server's host name, %lld notes are not downloaded yet [not-plural]")
        case .notDownloaded(let n):
            return String(localized: "iCloud Drive has not delivered every note yet (missing: \(n)), and a backup must hold every note. Check that this device is online and try again.",
                          comment: "Back Up Now: %lld notes are not downloaded yet [not-plural]")
        }
    }
}
