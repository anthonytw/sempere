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
/// names no folder. Keys remembered by earlier builds (or arriving through
/// iCloud Keychain) have no location yet: they are offered for vaults the user
/// opened in the app (recents, the picker), never for one handed to the app
/// from outside, and bound to the first location they unlock.
@MainActor
final class RememberedKeyLocations {
    /// The file (nil: memory only, for tests).
    let url: URL?
    private var byVault: [UUID: Set<String>]?

    init(url: URL? = nil) {
        self.url = url
    }

    /// The app's file, in Application Support next to the device state, excluded from backups.
    static func onDisk() -> RememberedKeyLocations {
        RememberedKeyLocations(url: DeviceClock.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("RememberedKeyLocations.json"))
    }

    /// The location of the vault folder `folder`.
    nonisolated static func location(of folder: URL) -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(("sempere-key-location|" + path).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The locations bound to `vault`'s key (empty: none yet).
    func locations(for vault: UUID) -> Set<String> {
        load()[vault] ?? []
    }

    /// Binds `vault`'s key to the folder `folder` too.
    func bind(_ vault: UUID, to folder: URL) {
        var all = load()
        let location = Self.location(of: folder)
        guard all[vault]?.contains(location) != true else { return }
        all[vault, default: []].insert(location)
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
