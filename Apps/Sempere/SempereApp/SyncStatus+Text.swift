import Foundation
import SempereAppCore
import SempereSync
import SempereWebDAV

// The words of a target's sync status (`SyncStatus`, `SyncSession`, SempereAppCore), of a sync problem
// (`WebDAVSyncProblem`, SempereWebDAV) and of a provider's upload error (`ProviderUploads`, SempereSync): the
// library returns values, the app says them (docs/design/thin-app.md "Rules").

extension SyncStatus {
    /// The status's line (Sync Targets, Vault Details, the welcome list).
    var headline: String { headline(for: kind) }

    /// The note list's bar's line: the problem it is shown for, also while the next run goes (`settledKind`).
    var attentionHeadline: String { headline(for: settledKind) }

    private func headline(for kind: Kind) -> String {
        switch kind {
        case .syncing:
            return folder ? String(localized: "Syncing with the folder…") : String(localized: "Syncing with the server…")
        case .offline:
            if folder {
                return String(localized: "The folder cannot be reached now. Changes are kept on this device and sync when it is back. If it is on a share, Sync Now connects it.")
            }
            return unconfirmed > 0
                ? String(localized: "Offline. \(unconfirmed) changes are kept on this device and sync when the server can be reached.",
                         comment: "Sync status; the number is a count of files")
                : String(localized: "Offline. Changes are kept on this device and sync when the server can be reached.")
        case .pending(let n):
            return String(localized: "\(n) changes not synced yet", comment: "Sync status; the number is a count of files")
        case .continuing:
            return String(localized: "Part of the changes synced. The rest follows at the next sync.",
                          comment: "Sync status: a run stopped early after it moved files")
        case .providerFailed(let state):
            return ProviderUploads.errorText(state, viaICloud: viaICloud) ?? ""
        case .waitingForProvider(let n):
            return viaICloud
                ? String(localized: "\(n) changes waiting for iCloud to upload", comment: "Sync status; the number is a count of files")
                : String(localized: "\(n) changes waiting for the folder's provider to upload", comment: "Sync status; the number is a count of files")
        case .waitingForUnlock:
            if staged > 0 {
                return String(localized: "\(staged) files from other devices are on this device and arrive when the vault is unlocked",
                              comment: "Sync status; the number is a count of files")
            }
            return String(localized: "Changes from other devices arrive when the vault is unlocked")
        case .problem(let p):
            if folder, p == .notFound {
                return String(localized: "The folder is gone or can no longer be opened. Nothing was synced. Choose it again, or remove it from Sync Targets.")
            }
            if folder, p == .offline {
                return String(localized: "The folder cannot be reached now. Changes are kept on this device and sync when it is back. If it is on a share, Sync Now connects it.")
            }
            return Self.text(for: p)
        case .synced:
            return arriving > 0
                ? String(localized: "Synced. \(arriving) files are still on their way.", comment: "Sync status; a count of files")
                : (folder ? String(localized: "Synced with the folder") : String(localized: "Synced with the server"))
        }
    }

    /// What to do about a problem.
    static func text(for problem: WebDAVSyncProblem) -> String {
        switch problem {
        case .offline:
            return String(localized: "Offline. Changes are kept on this device and sync when the server can be reached.")
        case .unauthorized:
            return String(localized: "The server refused the user name or password. Update the password.")
        case .certificateDate:
            // Expired or not yet valid by this device's clock: the clock is the likelier culprit (offline audit P14).
            return CertificateDate.reason
        case .certificate:
            return String(localized: "The server's certificate is not trusted or changed. Check the server, then trust its certificate again.")
        case .otherVault:
            return String(localized: "The server folder now holds another vault. Nothing was synced.")
        case .notFound:
            return String(localized: "The server folder is gone. Nothing was synced.")
        case .redirect(let target):
            return String(localized: "The server redirects to \(target). Connect to that address instead.",
                          comment: "The value is a URL")
        case .serverChangedManifest:
            return String(localized: "The vault's device list was changed both on this device and on the server. Both copies were kept; notes still sync.")
        case .writeGrantLapsed:
            // Not "the folder is gone… Nothing was synced" (re-check of #124): the folder is there, writes were refused.
            return String(localized: "Sempere lost permission to write in this folder. Choose it again in Sync Targets.")
        case .notWritable:
            // Not "errno 13" (build 12): what it means and what to do.
            return String(localized: "Sempere cannot write to this sync folder: this account has no permission to change it (it belongs to another user, or is read-only). The notes on this device are kept. Remove the folder in Sync Targets, or add one you can write to.")
        case .failures(let lines):
            return String(localized: "Some files could not be synced: \(lines.joined(separator: "; "))",
                          comment: "The value lists file paths and errors (English)")
        case .failed(let message):
            return String(localized: "Sync failed: \(message)", comment: "The value is an error message (English)")
        }
    }
}

extension SyncSession {
    /// The status's line.
    var headline: String { status.headline }
    /// The note list's bar's line (shown only when `needsAttention`).
    var attentionHeadline: String { status.attentionHeadline }

    /// What to do about a problem.
    static func text(for problem: WebDAVSyncProblem) -> String { SyncStatus.text(for: problem) }
}

extension ProviderUploads {
    /// An upload error that lasted (`ProviderUploads.Persistence`) as the bar says it. "Full" only when the provider
    /// said so (`isStorageFull`); any other error says only that uploads have not gone through for a while, with the
    /// provider's own words.
    static func errorText(_ state: State?, viaICloud: Bool) -> String? {
        guard let state, case .failed(_, _, let message) = state else { return nil }
        if state.isStorageFull {
            return viaICloud
                ? String(localized: "iCloud storage is full, so iCloud is not uploading this folder's files. Changes are kept on this device. Free up iCloud storage in Settings.",
                         comment: "Sync status: a folder target in iCloud Drive whose uploads fail for a full iCloud storage")
                : String(localized: "The folder's provider is out of storage and is not uploading its files. Changes are kept on this device.",
                         comment: "Sync status: a folder target whose provider reports a full storage")
        }
        return viaICloud
            ? String(localized: "iCloud has not uploaded this folder's files for a while. Changes are kept on this device. iCloud reports: \(message)",
                     comment: "Sync status; the value is iCloud's error message")
            : String(localized: "The folder's provider could not upload some files: \(message)",
                     comment: "Sync status; the value is the provider's error message")
    }
}

extension CertificateDate {
    /// What a certificate refused for its dates means and what to do (`WebDAVSyncProblem.certificateDate`).
    static var reason: String {
        String(localized: "The server's certificate is not valid at this device's date and time. Check this device's date and time.",
               comment: "WebDAV: a certificate expired or not yet valid by this device's clock")
    }

    /// The reason `PinnedServerTrust` refuses with: the marker, then `reason`.
    static var refusal: String { marker + reason }
}
