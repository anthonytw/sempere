import Foundation
import Security
import Sempere
import SempereAppCore
import SempereSync

// The words of the model's typed values (docs/design/thin-app.md "Rules": the library holds no user-facing text).
// Moved with wave 5b part 2 from the files that moved into SempereAppCore; the strings are unchanged.

extension AppModelAlert {
    /// The model's alert (`AppModel.alert`), worded: a thrown error through `AppModel.describe`
    /// (`Insert+Text.swift`).
    var text: String {
        switch self {
        case .error(let error): return AppModel.describe(error)
        case .notice(let notice): return notice.text
        case .insert(let notice): return notice.text
        case .worded(let sentence): return sentence
        }
    }
}

extension EditorFailure {
    /// The detail pane's sentence for a note that could not be shown (`AppModel.editorFailure`).
    var text: String {
        switch self {
        case .unreadable(let reason): return reason?.text ?? String(localized: "This note could not be read.")
        case .failed(let error): return AppModel.describe(error)
        }
    }
}

extension NoteSort {
    /// The picker's label (`rawValue` is not localized).
    var title: String {
        switch self {
        case .modified: return String(localized: "Date Modified", comment: "Note list sort order")
        case .created: return String(localized: "Date Created", comment: "Note list sort order: by creation date, newest first")
        case .title: return String(localized: "Title", comment: "Note list sort order: by title")
        }
    }
}

extension AppModelError {
    var text: String {
        switch self {
        case .noVaultOpen: return String(localized: "No vault is open.")
        case .notAnIdentity: return String(localized: "That text holds no device key file and no AGE-SECRET-KEY-PQ-1… identity.")
        case .noStoredKeys: return String(localized: "This vault has no passphrase copy of its recovery key.")
        case .passphraseMatchesNoKey: return String(localized: "The passphrase does not open this vault's recovery key copy.")
        case .notJoined:
            return String(localized: "This device has not joined the vault: the key is neither one of its devices' keys nor its recovery key.")
        case .noteNotFound: return String(localized: "That note is no longer in the vault.")
        case .noteNotDownloaded:
            return String(localized: "iCloud Drive has not delivered all of this note's files yet. Try again in a moment.")
        case .noteNotDownloadedFromServer(let server):
            return String(localized: "\(server) has not delivered all of this note's files yet. Try again in a moment.",
                          comment: "%@ is a server's host name")
        case .notesStillDownloadingFromServer(let server):
            return String(localized: "Some notes are still loading or downloading from \(server). Try again once the list has finished loading.",
                          comment: "%@ is a server's host name")
        case .notesStillDownloading:
            return String(localized: "Some notes are still loading or downloading from iCloud Drive. Try again once the list has finished loading.")
        case .invalidNotebookMove: return String(localized: "A notebook cannot be moved into itself or into a notebook inside it.")
        case .notebookNotEmpty: return String(localized: "Only an empty notebook can be deleted. Move or delete its notes first.")
        case .notebookNameTooLong: return String(localized: "That notebook name is too long.")
        case .unsavedChanges(let detail):
            // The editor's save failure (`saveFailure`), worded as the editor words it (`saveError`).
            let reason = String(localized: "Could not save: \(detail)")
            return String(localized: "The note's latest changes could not be saved first, so nothing was restored. \(reason)")
        }
    }
}

extension AppModelNotice {
    /// The alert's sentence (`AppModelAlert.notice`).
    var text: String {
        switch self {
        case .keyNoLongerListed:
            return String(localized: "This device's key is no longer one of the vault's keys, so the vault was closed. Ask a device that still has the vault to add this device again.")
        case .deviceListUnreadable(let error):
            return String(localized: "The vault's device list changed on another device and could not be read here: \(error)",
                          comment: "The value is the error (English)")
        case .recordingUnplayable(let detail):
            return String(localized: "Could not play the recording: \(detail)")
        case .recordingUnreadable(let detail):
            return String(localized: "Could not read the recording: \(detail)")
        case .recordingNotTranscribed(let detail):
            return String(localized: "Could not transcribe the recording: \(detail)")
        case .transcriptionModelMissing:
            return RecordingTranscriptionError.modelNotDownloaded.message
        case .inboxUnreadable(let detail):
            return String(localized: "Voice notes could not be read from the inbox: \(detail)")
        case .voiceNoteNotAdded(let reason):
            return String(localized: "A voice note could not be added: \(reason)")
        case .voiceNoteUnreadable(let detail):
            return String(localized: "Could not read the voice note to transcribe it: \(detail)")
        }
    }
}

extension SettingsSyncProblem {
    /// Settings ▸ Sync Settings' line.
    var text: String {
        switch self {
        case .readOnly:
            return String(localized: "Settings sync is paused: this vault is read-only on this device.")
        case .untrustedRecipients:
            return String(localized: "Settings sync is paused until the vault's device list is checked.")
        case .needsNewerApp:
            return String(localized: "Settings sync is paused: this vault's settings need a newer Sempere. Update the app to resume.")
        case .failed(let detail):
            return String(localized: "Settings could not be synced: \(detail)",
                          comment: "Settings ▸ Sync Settings; the error text follows (English)")
        }
    }
}

extension NoteLoading {
    /// "Opening vault: 120 of 640 notes", or "Updating 640 changed notes: 120 done"
    /// over a list already shown.
    var headline: String {
        if refreshing {
            let changed = String(localized: "\(total) changed notes", comment: "A number of notes that changed")
            return String(localized: "Updating \(changed): \(done) done",
                          comment: "Progress; %@ is a number of changed notes, the number is how many are done")
        }
        let notes = String(localized: "\(total) notes", comment: "A number of notes")
        return String(localized: "Opening vault: \(done) of \(notes)",
                      comment: "Progress; %@ is a number of notes, e.g. “120 of 640 notes”")
    }
}

extension SearchScope {
    /// The scope bar's label: the list's is the sidebar row it searches
    /// ("In “Math”", "In #todo"), so the bar says what the results cover.
    func title(for selection: SidebarItem?) -> String {
        guard self == .list else { return String(localized: "All Notes", comment: "Search scope: every note") }
        switch selection ?? .allNotes {
        case .allNotes: return String(localized: "This List", comment: "Search scope: the notes the sidebar selection shows")
        case .notebook(let n):
            let name = NotebookPath.components(n).last ?? n
            return String(localized: "In “\(name)”", comment: "Search scope: the notes of one notebook (its name)")
        case .tag(let t): return String(localized: "In #\(t)", comment: "Search scope: the notes with one tag")
        case .deleted: return String(localized: "In Recently Deleted", comment: "Search scope")
        case .favorites: return String(localized: "In Favorites", comment: "Search scope")
        case .recentlyRecognized: return String(localized: "In Recently Recognized", comment: "Search scope")
        }
    }
}

extension RecognitionResults {
    /// "Recognized 12 notes".
    var headline: String { String(localized: "Recognized \(notes.count) notes", comment: "Result of a Recognize All Notes run") }
}

extension JoinProgress {
    /// The bar's line: "Downloading from <server>: n of m notes…".
    var headline: String {
        String(localized: "Downloading from \(server): \(readyNotes) of \(notes) notes…",
               comment: "Progress: %@ is a server's host name, then notes downloaded so far of all notes")
    }
}

extension SyncTargetProblem {
    var text: String {
        switch self {
        case .notAStoreVault:
            return String(localized: "Only a vault kept on this device can have sync targets. Open the vault from the list first.")
        case .duplicate:
            return String(localized: "This vault already syncs with that folder.")
        case .overlapsStore:
            return String(localized: "Choose a folder outside Sempere's own storage.")
        case .isBackup:
            return String(localized: "That folder is a backup. A sync would write into it and pass deletions on, so it is never a sync target. Restore it, or open it as a one-time copy.")
        case .otherVault(let name):
            return String(localized: "This folder holds another vault (\(name)). Choose an empty folder or the vault's own sync folder.",
                          comment: "Sync targets: the picked folder is another vault's; %@ is that vault's name")
        case .insideVault(let name):
            return String(localized: "That folder is inside “\(name)”, a vault or a backup. A sync would write into it, so choose a folder outside it: for example the folder that holds “\(name)”.",
                          comment: "Sync targets: the picked folder is inside a vault or backup folder; %@ is that folder's name")
        case .notAVault(let name):
            return String(localized: "“\(name)” is named like a vault's sync folder but holds no vault, and it is not empty. Choose the folder that holds it, or an empty folder.",
                          comment: "Sync targets: a picked ….sempere folder with other files; %@ is its name")
        case .notDownloaded(let name):
            return String(localized: "“\(name)” is in iCloud Drive but not on this device yet. Sempere asked iCloud Drive to download it: wait a moment, then choose it again.",
                          comment: "Sync targets: the picked sync folder is not downloaded yet; %@ is its name")
        case .notWritable(let name):
            return String(localized: "Sempere cannot write to “\(name)”: this account has no permission to change it (it belongs to another user, or is read-only). Choose a folder you can write to.",
                          comment: "Sync targets: the picked folder is not writable; %@ is its name")
        case .serverFolderTaken:
            return Self.other(String(localized: "The server folder holds another vault or other files. Choose an empty or new folder.")).text
        case .other(let message):
            return String(localized: "The folder could not be added: \(message)", comment: "The value is the reason (English)")
        }
    }
}

extension WebDAVVaultError {
    var text: String {
        switch self {
        case .noSuchLocation:
            return String(localized: "That WebDAV vault is no longer set up on this device. Connect to it again.")
        case .downloadIncomplete(let detail):
            return String(localized: "The vault was not completely downloaded: \(detail)\n\nOpen it again to continue the download.",
                          comment: "The value is the first problems (English)")
        case .replacedWithChanges(let n):
            return String(localized: "Another vault is now at this address, and this device has \(n) changes of the vault that was there which were never uploaded. Nothing was changed. To start over, remove that WebDAV vault on the welcome screen first.",
                          comment: "Connect to WebDAV: the folder holds another vault; the count is files not uploaded")
        }
    }
}

extension WebDAVPasswordError {
    var text: String {
        switch self {
        case .notFound: return String(localized: "No password is saved for this server. Enter it again.")
        case .missingEntitlement: return String(localized: "This build of Sempere cannot use the Keychain (missing entitlement).")
        case .locked: return String(localized: "The server's password can be read once this device is unlocked.")
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return String(localized: "Keychain error \(status): \(text)", comment: "The values are the status code and the system's message")
        }
    }
}

extension WebDAVLeftover {
    /// The alert's text: where the previous copy is, and how to merge it.
    var message: String {
        String(localized: "An earlier “Download Again” of “\(name)” was interrupted. The previous copy holds notes or attachments that are not in the vault, so it was kept, at \(folder.path). Merge it in with the sempere command-line tool (vault merge-copy) before removing it.",
               comment: "First %@ is the vault's name, the second a folder path")
    }
}

extension WebDAVDownloadStatus {
    /// One line under the bar: "Downloading from server: 12 of 800 files · 34 MB of 1 GB".
    var description: String {
        if cancelling {
            return String(localized: "Stopping… What arrived is kept for the next time.",
                          comment: "WebDAV download: after Cancel, while the transfers in flight finish")
        }
        let p = progress
        switch p.stage {
        case .listing:
            guard p.notesTotal > 0 else {
                return String(localized: "Connecting to the server…", comment: "WebDAV download: before the server is listed")
            }
            let notes = String(localized: "\(p.notesTotal) notes", comment: "A number of notes")
            return String(localized: "Listing the server: \(p.notesListed) of \(notes)",
                          comment: "WebDAV download; the second value is a number of notes, e.g. “120 notes”")
        case .downloading, .done:
            let files = String(localized: "\(p.filesTotal) files", comment: "A number of files")
            return String(localized: "Downloading from server: \(p.filesDone) of \(files) · \(Self.bytes(p.bytesDone)) of \(Self.bytes(p.bytesTotal))",
                          comment: "WebDAV download; values: files done, “800 files”, MB done, MB in all (e.g. “34 MB”)")
        case .syncingNotes:
            let notes = String(localized: "\(p.notesTotal) notes", comment: "A number of notes")
            return String(localized: "Checking the downloaded notes: \(p.notesSynced) of \(notes)",
                          comment: "WebDAV download, last step; the second value is a number of notes, e.g. “120 notes”")
        }
    }

    /// Bytes as the system writes file sizes ("34.2 MB").
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(count, 0), countStyle: .file)
    }
}

extension AppModel {
    /// The banner over the note list of a read-only vault; nil when writable.
    var readOnlyBanner: String? {
        if isRecoveryOpen { return Self.recoveryReadOnlyText }
        if let problem = listProblem { return Self.listReadOnlyText(problem) }
        let reasons = readOnlyReasons
        guard !reasons.isEmpty else { return nil }
        return Self.readOnlyText(reasons)
    }

    /// Why a vault opened with the recovery key is read-only, and the ways to write to it (demovault-mac, build 11:
    /// "it's not obvious how you can do that").
    nonisolated static var recoveryReadOnlyText: String {
        String(localized: "Read-only: unlocked with the recovery key, which reads but never writes. To change this vault on this device, close it and open it again, then choose Join This Device… (the device that manages devices approves it) or Take Over with Recovery Kit….")
    }

    /// Why a vault whose device list does not check here is read-only, and what to do.
    nonisolated static func listReadOnlyText(_ problem: ListProblem) -> String {
        if problem.reason == .rootUnconfirmed { return unconfirmedReadOnlyText }
        return String(localized: "Read-only: this vault's device list does not check on this device, so nothing is written to it. Sync with the device that manages devices, or take over with the recovery kit in Settings ▸ Sync & Devices ▸ Devices.")
    }

    /// Why a vault opened with a device key this device has not confirmed is read-only.
    nonisolated static var unconfirmedReadOnlyText: String {
        String(localized: "Read-only: this device has not confirmed this vault yet. Choose Confirm Vault… and type the root fingerprint from its recovery kit to change it here.")
    }

    /// "Read-only: <reasons>. Update Sempere to change this vault."
    nonisolated static func readOnlyText(_ reasons: ReadOnlyReasons) -> String {
        let details = readOnlyDetails(reasons).joined(separator: "; ")
        return String(localized: "Read-only: \(details). Update Sempere to change this vault.")
    }

    /// The reasons, localized. `ReadOnlyReasons.descriptions` is the CLI's English, which in the
    /// banner left an English clause inside the Spanish sentence; the format and feature names
    /// themselves are identifiers and stay as they are.
    nonisolated static func readOnlyDetails(_ reasons: ReadOnlyReasons) -> [String] {
        var out: [String] = []
        if let format = reasons.vaultFormat {
            let current = SempereFormat.identifier
            out.append(String(localized: "the vault uses format \(format), newer than this version's \(current)"))
        }
        if !reasons.unknownFeatures.isEmpty {
            let features = reasons.unknownFeatures.joined(separator: ", ")
            out.append(String(localized: "the vault uses format extensions this version does not know: \(features)"))
        }
        if !reasons.newerNotes.isEmpty {
            out.append(String(localized: "\(reasons.newerNotes.count) notes hold revisions written by a newer version"))
        }
        return out
    }
}
