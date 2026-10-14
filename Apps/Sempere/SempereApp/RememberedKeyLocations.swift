import CryptoKit
import Sempere
import Foundation

/// Where each remembered vault key may be offered (security review 2026-10
/// stage 4, S16; the app's counterpart of the web viewer's P3 fix).
///
/// A remembered key is found by the vault id in `vault.json`, which nothing
/// has authenticated when the unlock sheet offers the key: a lookalike folder
/// opened from AirDrop, Files or another app could claim the id of a vault
/// whose key this device holds. So the key is offered only at a location where
/// it, or a pasted key checked against this device's trust record, unlocked
/// that vault before. Elsewhere the user pastes the key (or the passphrase).
///
/// A location is the SHA-256 of the vault folder's resolved path, so the file
/// names no folder. A vault "On This Device" (in the app container's
/// Documents, `VaultLibrary.onDeviceFolder`) is located by its path inside
/// that folder instead: the container's own path changes when iOS moves it
/// (an app update, a restore), and the vault with it, though nothing about
/// the vault changed and no other app can put a folder there. A vault folder
/// the user moves or renames elsewhere is a new location, as is any folder
/// handed over from outside. Keys arriving through iCloud Keychain from another
/// device have no location here yet: they are offered for vaults the user
/// opened in the app (recents, the picker), never for one handed to the app
/// from outside, and bound to the first location they unlock.
@MainActor
final class RememberedKeyLocations {
    /// The file (nil: memory only, for tests).
    let url: URL?
    /// Where "On This Device" vaults are (`VaultLibrary.onDeviceFolder`).
    let onDeviceFolder: URL
    private var byVault: [UUID: Set<String>]?

    init(url: URL? = nil, onDeviceFolder: URL? = nil) {
        self.url = url
        self.onDeviceFolder = onDeviceFolder ?? VaultLibrary.onDeviceFolder
    }

    /// The app's file, in Application Support next to the device state, excluded from backups.
    static func onDisk() -> RememberedKeyLocations {
        RememberedKeyLocations(url: DeviceClock.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("RememberedKeyLocations.json"))
    }

    /// The location of the vault folder `folder`.
    func location(of folder: URL) -> String {
        Self.location(of: folder, onDeviceFolder: onDeviceFolder)
    }

    /// The location of the vault folder `folder`: its resolved path, or its
    /// path inside `onDeviceFolder` when it is there.
    nonisolated static func location(of folder: URL, onDeviceFolder: URL) -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let root = onDeviceFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let name: String
        if path.hasPrefix(root + "/") {
            name = "on-device|" + path.dropFirst(root.count + 1)
        } else {
            name = "path|" + path
        }
        return SHA256.hash(data: Data(("sempere-key-location|" + name).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The locations bound to `vault`'s key (empty: none yet).
    func locations(for vault: UUID) -> Set<String> {
        load()[vault] ?? []
    }

    /// Binds `vault`'s key to the folder `folder` too.
    func bind(_ vault: UUID, to folder: URL) {
        var all = load()
        let here = location(of: folder)
        guard all[vault]?.contains(here) != true else { return }
        all[vault, default: []].insert(here)
        save(all)
    }

    /// Forgets every location of `vault` (its key was forgotten).
    func forget(_ vault: UUID) {
        var all = load()
        guard all.removeValue(forKey: vault) != nil else { return }
        save(all)
    }

    private func load() -> [UUID: Set<String>] {
        if let byVault { return byVault }
        var loaded: [UUID: Set<String>] = [:]
        if let url, let data = try? BoundedRead.contents(of: url, maxBytes: 1 << 20),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for (id, locations) in decoded {
                if let uuid = UUID(uuidString: id) { loaded[uuid] = Set(locations.filter { $0.count == 64 }) }
            }
        }
        byVault = loaded
        return loaded
    }

    private func save(_ all: [UUID: Set<String>]) {
        byVault = all
        guard let url else { return }
        let plain = Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString.lowercased(), $0.value.sorted()) })
        guard let data = try? JSONEncoder().encode(plain) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = url
        try? file.setResourceValues(values)
    }
}
