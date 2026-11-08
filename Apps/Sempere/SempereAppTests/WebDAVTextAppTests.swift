import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// The words of WebDAV vaults (the download's status, the bar, the sync problems) and the connect sheet's checks. The
/// model's half is `SempereAppCoreTests` (`WebDAVTests`, `WebDAVPartialTests`, `JoinTests`, `TwoDeviceSyncTests`).
struct WebDAVAppTests {
    @Test func downloadStatusDescribesEachStage() {
        var status = WebDAVDownloadStatus(name: "Notes")
        #expect(status.fractionCompleted == nil, "nothing known yet: an indeterminate bar")
        #expect(!status.description.isEmpty)
        status.progress.notesTotal = 10
        status.progress.notesListed = 5
        #expect(status.fractionCompleted == 0.5)
        #expect(status.description.contains("5"))
        status.progress.stage = .downloading
        status.progress.filesTotal = 800
        status.progress.filesDone = 12
        status.progress.bytesTotal = 1_000_000_000
        status.progress.bytesDone = 250_000_000
        #expect(status.fractionCompleted == 0.25, "bytes when they are known")
        #expect(status.description.contains("12"))
        #expect(status.description.contains("800"))
        #expect(status.description.contains(WebDAVDownloadStatus.bytes(250_000_000)))
        #expect(status.description.contains(WebDAVDownloadStatus.bytes(1_000_000_000)))
        status.progress.bytesTotal = 0
        #expect(status.fractionCompleted == 12.0 / 800.0, "files when no sizes are listed")
        status.progress.stage = .syncingNotes
        status.progress.notesSynced = 10
        #expect(status.fractionCompleted == 1)
        status.cancelling = true
        #expect(status.description != WebDAVDownloadStatus(name: "Notes").description)
    }

    @Test func statusTextsSayWhatToDo() {
        #expect(SyncStatus.text(for: .unauthorized).contains("password"))
        #expect(SyncStatus.text(for: .serverChangedManifest).contains("Both copies were kept"))
        #expect(SyncStatus.text(for: .redirect("https://x/")).contains("https://x/"))
        #expect("\(SyncTargetProblem.serverFolderTaken)"
                == "The folder could not be added: The server folder holds another vault or other files. Choose an empty or new folder.")
    }

    /// The bar's words for what the model reports (`SyncStatus.headline`, `JoinProgress.headline`): offline says
    /// so, with the count of changes kept; a partial copy's fill names its server.
    @Test func theBarSaysOfflineAndNamesTheServerOfAFill() {
        let offline = SyncStatus(syncing: false, problems: [.offline], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: nil)
        #expect(offline.kind == .offline)
        #expect(offline.headline.hasPrefix("Offline."))
        var kept = offline
        kept.unconfirmed = 3
        #expect(kept.headline.hasPrefix("Offline.") && kept.headline.contains("3"))
        let fill = JoinProgress(notes: 4, pending: 3, server: "dav.example.org")
        #expect(fill.headline.contains("dav.example.org") && fill.headline.contains("1") && fill.headline.contains("4"))
    }

    @Test func connectSheetAcceptsOnlyUsableURLs() {
        #expect(WebDAVConnectSheet.collectionURL("dav.example.org/notes")?.absoluteString == "https://dav.example.org/notes/")
        #expect(WebDAVConnectSheet.collectionURL("http://dav.example.org/") == nil)
        #expect(WebDAVConnectSheet.collectionURL("http://localhost:8080/v")?.absoluteString == "http://localhost:8080/v/")
        #expect(WebDAVConnectSheet.collectionURL("https://me:pw@dav.example.org/") == nil)
        #expect(WebDAVConnectSheet.collectionURL("  ") == nil)
        #expect(WebDAVConnectSheet.fingerprint("ab01") == "AB:01")
    }
}

/// Where a vault lives decides whether its files are coordinated (docs/io.md, "Other Files providers").
struct StorageLocationTests {
    let home = "/private/var/mobile/Containers/Data/Application/1111-AAAA"

    func classify(_ path: String) -> StorageLocation {
        StorageLocation.classify(URL(fileURLWithPath: path), container: home)
    }

    @Test func iCloudDriveAndProvidersAreCoordinated() {
        #expect(classify("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Notes.sempere") == .iCloudDrive)
        #expect(classify("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Notes.sempere") == .iCloudDrive)
        #expect(classify("/Users/me/Library/CloudStorage/ProtonDrive-me@proton.me-folder/Notes.sempere")
                == .fileProvider(name: "ProtonDrive"))
        #expect(classify("/Users/me/Library/CloudStorage/Dropbox/Notes.sempere") == .fileProvider(name: "Dropbox"))
        #expect(classify("/private/var/mobile/Containers/Shared/AppGroup/2222-BBBB/File Provider Storage/Notes.sempere")
                == .fileProvider(name: nil))
        #expect(classify("/private/var/mobile/Containers/Shared/AppGroup/2222-BBBB/Notes.sempere") == .fileProvider(name: nil))
        for path in ["/private/var/mobile/Library/Mobile Documents/x/V.sempere",
                     "/Users/me/Library/CloudStorage/ProtonDrive-x/V.sempere"] {
            #expect(classify(path).needsCoordination, "\(path)")
        }
    }

    @Test func localFoldersAreNot() {
        #expect(classify(home + "/Documents/Notes.sempere") == .appContainer)
        #expect(classify(home + "/Library/Application Support/Sempere/WebDAV/x/V.sempere") == .appContainer)
        #expect(classify("/private/var/mobile/Containers/Data/Application/3333-CCCC/Documents/V.sempere") == .other)
        #expect(classify("/Volumes/USB/V.sempere") == .other)
        #expect(classify(home + "x/V.sempere") == .other, "a sibling with the same prefix is not the container")
        #expect(!classify(home + "/Documents/V.sempere").needsCoordination)
        #expect(!classify("/Volumes/USB/V.sempere").needsCoordination)
    }
}
