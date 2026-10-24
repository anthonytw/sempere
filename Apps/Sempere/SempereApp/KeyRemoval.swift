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

    /// The keys go with the copy: false while another local copy still opens with them.
    var deletesKeys: Bool { otherCopies.isEmpty }

    /// How long a folder copy's `vault.json` is waited for (a file provider may be slow): one not read by then
    /// does not count.
    static let copyCheckBound: Duration = .seconds(2)

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
        let folders = library.recents.filter { $0.storeID == nil && $0.webdav == nil }
        let skip = except?.standardizedFileURL.path
        for entry in folders {
            let bookmark = entry.bookmark
            let matches = await withTaskGroup(of: Bool?.self) { group -> Bool in
                group.addTask {
                    guard let resolved = try? VaultBookmark.resolve(bookmark) else { return false }
                    let url = resolved.url
                    if url.standardizedFileURL.path == skip { return false }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return (try? Vault.open(at: url).vaultId) == vaultID
                }
                group.addTask {
                    try? await Task.sleep(for: copyCheckBound)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? false
            }
            if matches { out.otherCopies.append(entry.name) }
        }
        return out
    }

    /// Delete from This Device / Remove from This Device: what happens to this device's key, nil when it simply
    /// goes (the dialog's own text says so).
    func removalWarning() -> String? {
        if !otherCopies.isEmpty {
            // The keys stay, and with them anything this device does for the vault (home's role too).
            let names = otherCopies.map { "“\($0)”" }.formatted(.list(type: .and))
            return String(localized: "This device's key for the vault stays: it also opens \(names) on this device.",
                          comment: "The value is a list of vault folder names")
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
