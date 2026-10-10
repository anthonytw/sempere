import Age
import Foundation
import Sempere
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// A `.sempere` folder, shown by Files as one document (a package). Declared
    /// as an exported type in `SempereInfo.plist`.
    static let sempere = UTType(exportedAs: "io.github.anthonytw.sempere.vault", conformingTo: .package)

    /// What the "open vault" pickers accept: vault packages, and plain folders
    /// (older vaults, or ones not named `.sempere`).
    static var vaultPickerTypes: [UTType] { [.sempere, .folder] }
}

/// Turns whatever the user picked into the vault folder.
enum VaultLocator {
    enum LocatorError: Error, Equatable, CustomStringConvertible {
        case severalVaults([String])
        /// The pick is inside the vault named here. Access granted to a picked
        /// folder covers that folder and what is in it, never its parents, so
        /// the vault itself cannot be opened from it.
        case insideVault(String)

        var description: String {
            switch self {
            case .severalVaults(let names):
                let list = names.joined(separator: ", ")
                return String(localized: "That folder holds several vaults (\(list)). Choose one of them.",
                              comment: "%@ is a list of vault folder names")
            case .insideVault(let name):
                return String(localized: "That is a folder inside the vault “\(name)”. Choose “\(name)” itself.")
            }
        }
    }

    /// The vault folder for `picked`:
    /// - a folder with a `vault.json`: itself;
    /// - a folder holding exactly one `.sempere` folder: that folder (the
    ///   picked folder's access covers it);
    /// - anything else: `picked` unchanged (opening it reports the problem).
    ///
    /// - Throws: `LocatorError.severalVaults` for a folder holding more than
    ///   one vault; `LocatorError.insideVault` for a file or folder inside a
    ///   vault (`notes/`, `notes/<id>/…`, `keys/…`, `vault.json`), whose
    ///   security scope would not reach the vault.
    static func resolve(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: picked.path, isDirectory: &isDir) else { return picked }
        func isVault(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(CloudPlaceholder.placeholderName(for: "vault.json")).path)
        }
        if isDir.boolValue, isVault(picked) { return picked }
        // Inside a vault: vault.json is at most `notes/<id>/<file>` above.
        var candidate = picked.deletingLastPathComponent()
        for _ in 0..<3 {
            if isVault(candidate) { throw LocatorError.insideVault(candidate.lastPathComponent) }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        guard isDir.boolValue else { return picked }
        let inside = VaultLibrary.vaults(in: picked)
        if inside.count == 1 { return inside[0] }
        if inside.count > 1 { throw LocatorError.severalVaults(inside.map(\.lastPathComponent)) }
        return picked
    }
}

/// A vault the app has opened before, reachable through a bookmark, or a
/// WebDAV location's local copy.
struct RecentVault: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Folder name without `.sempere`, for display.
    var name: String
    /// Bookmark of the vault folder. On iOS a bookmark made from a
    /// document-picker URL carries its security scope. Empty for a WebDAV vault.
    var bookmark: Data
    var lastOpened: Date
    /// The WebDAV location (`WebDAVLocationStore`) whose local copy this is;
    /// nil for a folder. Opened with `AppModel.openWebDAV`, never through the bookmark.
    var webdav: UUID?
}

/// Whether the app may use a folder it was given access to (a picked folder,
/// or a bookmark resolved at launch). In a sandboxed Mac build a bookmark that
/// does not carry the sandbox extension resolves to a URL that looks fine and
/// is refused on first use; `check` finds that out before the vault is opened,
/// so the error names the folder and the way out (choose it again) instead of
/// a file error from the middle of `Vault.open`.
enum FolderAccess {
    enum Problem: Error, Equatable, CustomStringConvertible {
        /// The system refuses to list the folder. `scoped` is what
        /// `startAccessingSecurityScopedResource()` returned for it.
        case noAccess(name: String, scoped: Bool)

        var description: String {
            switch self {
            case .noAccess(let name, let scoped):
                return scoped
                    ? String(localized: "Sempere has no access to “\(name)” any more. The system only keeps access to folders you choose yourself.")
                    : String(localized: "Sempere has no access to “\(name)” any more (the saved permission did not come back). The system only keeps access to folders you choose yourself.")
            }
        }
    }

    /// Whether `error` is the system refusing access (permissions, the
    /// sandbox), as opposed to a missing or damaged folder.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, (underlying as NSError) != ns {
            return isPermissionDenied(underlying)
        }
        return false
    }

    /// Throws `Problem.noAccess` when the folder at `url` cannot be listed for
    /// lack of permission. Other failures (not there, not a folder) are left
    /// to opening the vault, which reports them.
    static func check(_ url: URL, scoped: Bool, fileManager fm: FileManager = .default) throws {
        do {
            _ = try fm.contentsOfDirectory(atPath: url.path)
        } catch {
            if isPermissionDenied(error) {
                throw Problem.noAccess(name: VaultLibrary.displayName(of: url), scoped: scoped)
            }
        }
    }
}

/// Security-scoped bookmarks of vault folders.
///
/// Mac Catalyst has no `.withSecurityScope` (AppKit only), so bookmarks are
/// made with plain options, as on iOS. `docs/io.md` "Saved folder access"
/// says what is and is not verified about that in a sandboxed Mac build.
enum VaultBookmark {
    struct Resolved {
        var url: URL
        /// A fresh bookmark when the stored one was stale.
        var refreshed: Data?
    }

    /// Bookmarks `url`. Access to it (or a parent) must be active.
    static func make(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark; when it is stale, tries to re-save it.
    static func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard stale else { return Resolved(url: url, refreshed: nil) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Resolved(url: url, refreshed: try? make(for: url))
    }
}

/// What the "new vault" form produces.
struct NewVaultRequest: Sendable {
    enum KeySource: Sendable {
        /// Generate a post-quantum MLKEM768-X25519 key on this device
        /// (docs/post-quantum.md).
        case generate
        /// Encrypt to an existing post-quantum `age1pq1…` recipient; this device gets no key.
        case recipient(String)
    }

    var name: String
    var keySource: KeySource
    /// Wrap the generated key with this passphrase into `keys/` (generate only).
    var passphrase: String?
}

/// The outcome of creating a vault.
struct CreatedVault: Sendable {
    var url: URL
    /// The new secret key (`AGE-SECRET-KEY-PQ-1…`) when one was generated; the
    /// user must save it, nothing else holds it unless a passphrase wrapped it.
    var secretKey: String?
    /// The recents entry saved for it, whose bookmark carries the access the
    /// app needs to reopen it; nil when saving it failed.
    var recentID: UUID?
}

/// Recent vaults, vault creation, and the places vaults live.
@MainActor
@Observable
final class VaultLibrary {
    enum LibraryError: Error, Equatable, CustomStringConvertible {
        case invalidName
        case invalidRecipient
        /// A classic X25519 `age1…` key: vaults take only post-quantum keys.
        case classicRecipient
        case passphraseNeedsGeneratedKey
        case cannotResolve(name: String)

        var description: String {
            switch self {
            case .invalidName: return String(localized: "Give the vault a name without slashes, leading dots or control characters.")
            case .invalidRecipient: return String(localized: "That text is not an age1pq1… recipient.")
            case .classicRecipient:
                return String(localized: "That is a classic age1… key, which is not quantum-safe. Create a new key instead (here, or with age-keygen -pq) and use its age1pq1… recipient.")
            case .passphraseNeedsGeneratedKey: return String(localized: "A passphrase can only wrap a key generated on this device.")
            case .cannotResolve(let name):
                return String(localized: "“\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose its folder again.")
            }
        }
    }

    static let maxRecents = 10

    private(set) var recents: [RecentVault] = []
    let storeURL: URL

    init(storeURL: URL = VaultLibrary.defaultStoreURL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([RecentVault].self, from: data) {
            recents = list
        }
    }

    // MARK: - Places

    /// `Application Support/Sempere/recents.json`.
    static var defaultStoreURL: URL { supportDirectory.appendingPathComponent("recents.json") }

    private static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sempere", isDirectory: true)
    }

    /// The app container's Documents folder, where "On This Device" vaults live.
    static var onDeviceFolder: URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// The `.sempere` folders directly inside `folder`, sorted by name.
    nonisolated static func vaults(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { $0.pathExtension == "sempere" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Recents

    /// Records that the vault at `url` was opened. Access to it must be active.
    @discardableResult
    func remember(_ url: URL) throws -> RecentVault {
        let data = try VaultBookmark.make(for: url)
        let path = url.standardizedFileURL.path
        recents.removeAll { entry in
            (try? VaultBookmark.resolve(entry.bookmark))?.url.standardizedFileURL.path == path
        }
        let entry = RecentVault(id: UUID(), name: Self.displayName(of: url), bookmark: data, lastOpened: Date())
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        return entry
    }

    /// Records that the local copy of the WebDAV location `location` was opened.
    @discardableResult
    func rememberWebDAV(_ location: UUID, name: String) -> RecentVault {
        recents.removeAll { $0.webdav == location }
        let entry = RecentVault(id: UUID(), name: name, bookmark: Data(), lastOpened: Date(), webdav: location)
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        return entry
    }

    /// Drops the recent entries of the WebDAV location `location` (it was removed).
    func forgetWebDAV(_ location: UUID) {
        guard recents.contains(where: { $0.webdav == location }) else { return }
        recents.removeAll { $0.webdav == location }
        save()
    }

    /// Resolves a recent entry to a URL, re-saving a stale bookmark. A
    /// bookmark that no longer resolves is dropped from the list. A WebDAV
    /// entry has no bookmark: `AppModel.open(recent:)` opens it by its location.
    func resolve(_ entry: RecentVault) throws -> URL {
        if entry.webdav != nil { throw LibraryError.cannotResolve(name: entry.name) }
        do {
            let resolved = try VaultBookmark.resolve(entry.bookmark)
            if let fresh = resolved.refreshed, let i = recents.firstIndex(where: { $0.id == entry.id }) {
                recents[i].bookmark = fresh
                save()
            }
            return resolved.url
        } catch {
            forget(entry)
            throw LibraryError.cannotResolve(name: entry.name)
        }
    }

    func forget(_ entry: RecentVault) {
        recents.removeAll { $0.id == entry.id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: storeURL, options: .atomic)
        } catch {
            // Recents are a convenience; a failed save only loses the list.
        }
    }

    nonisolated static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Creating

    /// The folder name for a vault called `name`: `<name>.sempere`.
    nonisolated static func folderName(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = trimmed.isEmpty || trimmed.hasPrefix(".") || trimmed.hasSuffix(".sempere")
            || trimmed.contains { $0 == "/" || $0 == ":" || $0 == "\0" || $0.isNewline }
        if bad { throw LibraryError.invalidName }
        return trimmed + ".sempere"
    }

    /// Creates a vault named `request.name` inside `parent`. For a folder from
    /// the document picker, the caller keeps the vault's own bookmark
    /// (`remember`) while access to `parent` is active, which this does.
    ///
    /// Runs the blocking work (scrypt, file I/O) off the main actor.
    func create(_ request: NewVaultRequest, in parent: URL) async throws -> CreatedVault {
        let folder = try Self.folderName(for: request.name)
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        var created = try await Task.detached(priority: .userInitiated) {
            // In iCloud Drive, a coordinated write so the new folder is uploaded.
            let target = parent.appendingPathComponent(folder, isDirectory: true)
            return try CloudVault.coordinatedWrite(CloudVault.isUbiquitous(parent) ? target : nil) {
                try Self.createVault(request, folder: folder, in: parent)
            }
        }.value
        created.recentID = try? remember(created.url).id
        return created
    }

    /// Synchronous core of `create` (testable without the main actor).
    nonisolated static func createVault(_ request: NewVaultRequest, folder: String, in parent: URL) throws -> CreatedVault {
        let url = parent.appendingPathComponent(folder, isDirectory: true)
        switch request.keySource {
        case .generate:
            let identity = try NativeIdentity.generate(.postQuantum)
            let vault = try Vault.create(at: url, recipients: [identity.recipient], labels: ["This device"],
                                         identities: [identity])
            if let passphrase = request.passphrase, !passphrase.isEmpty {
                try vault.writeIdentityFile(identity, passphrase: passphrase)
            }
            return CreatedVault(url: url, secretKey: identity.string)
        case .recipient(let text):
            guard request.passphrase?.isEmpty ?? true else { throw LibraryError.passphraseNeedsGeneratedKey }
            let recipient: NativeRecipient
            do { recipient = try NativeRecipient(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) } catch {
                throw LibraryError.invalidRecipient
            }
            guard recipient.isPostQuantum else { throw LibraryError.classicRecipient }
            _ = try Vault.create(at: url, recipients: [recipient])
            return CreatedVault(url: url, secretKey: nil)
        }
    }
}
