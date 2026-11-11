import Foundation
import Sempere

/// Where the user was in a vault when the app last ran: the sidebar item and the open note, so a launch opens there
/// (the owner's 1.1 ask). Kept on this device only, one `UserDefaults` entry per vault (the device's
/// `KeyValueStore`), never in the vault and never synced. It is a `RestorableSelection`, so a notebook or tag is
/// stored as a digest keyed by the vault secret and a note by its id: the preferences name no notebook or tag.
/// Reading it is a `UserDefaults` read: no vault file is opened or locked, so it is safe at any time.
public enum LastPlace {
    /// The preferences key of `vault`.
    public static func key(_ vault: UUID) -> String { "Sempere.lastPlace.\(vault.uuidString.lowercased())" }

    /// The saved place of `vault`; nil when none was saved, it cannot be read, or it belongs to another vault.
    public static func load(vault: UUID, from store: any KeyValueStore) -> RestorableSelection? {
        guard let text = store.string(forKey: key(vault)), let place = RestorableSelection(stored: text),
              place.vault == vault else { return nil }
        return place
    }

    /// Saves `place` for `vault` (skipped when it is already what is stored).
    public static func save(_ place: RestorableSelection, vault: UUID, in store: any KeyValueStore) {
        let text = place.stored
        guard !text.isEmpty, store.string(forKey: key(vault)) != text else { return }
        store.set(text, forKey: key(vault))
    }

    /// Forgets `vault`'s place (a vault removed from this device).
    public static func forget(vault: UUID, in store: any KeyValueStore) { store.removeObject(forKey: key(vault)) }
}
