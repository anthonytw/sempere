import Foundation
import Sempere

/// What deleting this device's keys for a vault costs (re-check of #88, R2 and SHOULD): the one check behind
/// Delete from This Device (a store vault), Remove from This Device (a WebDAV vault) and Forget Key (the unlock
/// sheet). Read without the key: the copy's list and the fingerprint kept with this device's signing item.
struct KeyRemoval: Equatable, Sendable {
    enum Home: Equatable, Sendable {
        /// This device does not manage the vault's devices (or that cannot be told).
        case no
        /// It manages them and other devices are listed: another device should be made home first.
        case withOthers
        /// It is the vault's only device: afterwards only the recovery kit restores write access.
        case alone
    }

    var home: Home = .no
    /// Other local copies of the vault this device opens with the same keys (folder vaults in the recents, by
    /// name): the keys are kept for them.
    var otherCopies: [String] = []
    /// Folder vaults in the recents that could not be checked (the bookmark does not resolve, the folder does not
    /// read, or it did not answer within `copyCheckBound`): each may be a copy, so the keys are kept for them too
    /// (second re-check of #88).
    var uncheckedCopies: [String] = []

    /// The keys go with the copy: false while another local copy opens, or may open, with them.
    var deletesKeys: Bool { otherCopies.isEmpty && uncheckedCopies.isEmpty }

    /// How long a folder copy's `vault.json` is waited for (a file provider may be slow): one that has not answered
    /// by then counts as unchecked.
    static let copyCheckBound: Duration = .seconds(2)

    /// What reading one recent folder vault found.
    enum CopyAnswer: Equatable, Sendable {
        /// Resolved to `path`; its vault id, nil when its `vault.json` did not read.
        case folder(path: String, vaultId: UUID?)
        /// The bookmark does not resolve.
        case unresolved
    }

    typealias CopyReader = @Sendable (Data) -> CopyAnswer

    /// Resolves a recent's bookmark and reads its vault id without the key (blocking; it may wait on a provider).
    static let readCopy: CopyReader = { bookmark in
        guard let resolved = try? VaultBookmark.resolve(bookmark) else { return .unresolved }
        let url = resolved.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return .folder(path: url.standardizedFileURL.path, vaultId: try? Vault.open(at: url).vaultId)
    }

    /// The check for the copy of `vaultID` at `url` (nil: home is not looked up). `recents` are looked through for
    /// other folder copies, `except` the copy being removed.
    @MainActor
    static func check(vaultID: UUID, at url: URL?, store: any DeviceKeyStore, library: VaultLibrary?,
                      except: URL? = nil) async -> KeyRemoval {
        var out = KeyRemoval()
        if let url, let mine = await store.fingerprint(for: vaultID) {
            out.home = await Task.detached(priority: .userInitiated) { () -> Home in
                guard let m = try? Vault.open(at: url).manifest, m.home == mine else { return .no }
                return m.devices.count > 1 ? .withOthers : .alone
            }.value
        }
        guard let library else { return out }
        let folders = library.recents.filter { $0.storeID == nil && $0.webdav == nil }.map { (name: $0.name, bookmark: $0.bookmark) }
        let found = await folderCopies(of: vaultID, in: folders, except: except?.standardizedFileURL.path)
        out.otherCopies = found.copies
        out.uncheckedCopies = found.unchecked
        return out
    }

    /// The `entries` (name, bookmark) that are copies of `vaultID`, and those that could not be checked, all read
    /// at once, each given `bound`: a reader that hangs (a provider that never answers; `Vault.open` does not
    /// heed cancellation) is left running and its entry counted as unchecked.
    static func folderCopies(of vaultID: UUID, in entries: [(name: String, bookmark: Data)], except: String?,
                             bound: Duration = copyCheckBound,
                             reader: @escaping CopyReader = readCopy) async -> (copies: [String], unchecked: [String]) {
        let answers = await withTaskGroup(of: (Int, CopyAnswer?).self) { group -> [Int: CopyAnswer?] in
            for (i, entry) in entries.enumerated() {
                let bookmark = entry.bookmark
                group.addTask { (i, await answer(within: bound) { reader(bookmark) }) }
            }
            var out: [Int: CopyAnswer?] = [:]
            for await (i, a) in group { out[i] = a }
            return out
        }
        var copies: [String] = [], unchecked: [String] = []
        for (i, entry) in entries.enumerated() {
            switch answers[i] ?? nil {
            case .folder(let path, _) where path == except: continue
            case .folder(_, let id?): if id == vaultID { copies.append(entry.name) }
            case .folder(_, nil), .unresolved, nil: unchecked.append(entry.name)
            }
        }
        return (copies, unchecked)
    }

    /// `work`'s answer, or nil when it has not answered within `bound`. It runs in an unstructured task raced
    /// against the timer, so a call that blocks and ignores cancellation does not hold the caller.
    static func answer(within bound: Duration, _ work: @escaping @Sendable () -> CopyAnswer) async -> CopyAnswer? {
        await withCheckedContinuation { (c: CheckedContinuation<CopyAnswer?, Never>) in
            let first = FirstAnswer(c)
            Task.detached(priority: .userInitiated) { first.resume(work()) }
            Task.detached {
                try? await Task.sleep(for: bound)
                first.resume(nil)
            }
        }
    }

    /// Delete from This Device / Remove from This Device: what happens to this device's key, nil when it simply
    /// goes (the dialog's own text says so).
    func removalWarning() -> String? {
        if !deletesKeys {
            // The keys stay, and with them anything this device does for the vault (home's role too).
            let found = otherCopies.map { "“\($0)”" }.formatted(.list(type: .and))
            let unknown = uncheckedCopies.map { "“\($0)”" }.formatted(.list(type: .and))
            if uncheckedCopies.isEmpty {
                return String(localized: "This device's key for the vault stays: it also opens \(found) on this device.",
                              comment: "The value is a list of vault folder names")
            }
            if otherCopies.isEmpty {
                return String(localized: "This device's key for the vault stays: \(unknown) on this device could not be checked and may be a copy of it.",
                              comment: "The value is a list of vault folder names")
            }
            return String(localized: "This device's key for the vault stays: it also opens \(found) on this device, and \(unknown) could not be checked.",
                          comment: "The values are lists of vault folder names")
        }
        switch home {
        case .no: return nil
        case .withOthers:
            return String(localized: "This device manages the vault's devices, and its key goes with this copy: then only the recovery kit can manage them. Open the vault and make another device home first (Settings ▸ Sync & Devices ▸ Devices ▸ Make Home).")
        case .alone:
            return String(localized: "This device is the vault's only device, and its key goes with this copy: afterwards only the recovery kit restores write access to the vault (Take Over).")
        }
    }

    /// Whether the dialog offers to open the vault and make another device home first.
    var offersMakeHome: Bool { deletesKeys && home == .withOthers }

    /// Forget Key on the unlock sheet: the warning when this device is home, nil otherwise.
    var forgetWarning: String? {
        switch home {
        case .no: return nil
        case .withOthers:
            return String(localized: "This device manages the vault's devices: once its key is forgotten, only the recovery kit can manage them (Take Over).")
        case .alone:
            return String(localized: "This device is the vault's only device: once its key is forgotten, only the recovery kit restores write access to the vault (Take Over).")
        }
    }
}

/// Resumes a continuation once: with the first of a reader's answer and its timer.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<KeyRemoval.CopyAnswer?, Never>?

    init(_ c: CheckedContinuation<KeyRemoval.CopyAnswer?, Never>) { continuation = c }

    func resume(_ answer: KeyRemoval.CopyAnswer?) {
        let c = lock.withLock { () -> CheckedContinuation<KeyRemoval.CopyAnswer?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: answer)
    }
}
