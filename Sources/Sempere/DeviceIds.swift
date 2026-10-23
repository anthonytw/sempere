import Foundation

// Device ids stay unique (format.md §15.4, §12.5): an id is the first 8 hex digits of a device's fingerprint,
// so two keys can share one (by chance, or by grinding about 2^32 keys). It names the device's summaries
// file and picks the keys that file is verified under, so no list ever holds two devices with one id, and no
// device takes the id of a device the vault ever listed: a removed device that a takeover re-admits must not
// meet a device that took its id meanwhile. Kept apart from approval and takeover, which only call these.

/// The id rules for device lists.
public enum DeviceIds {
    /// The id of a device fingerprint (its first 8 hex digits).
    public static func id(of fingerprint: Data) -> String { String(Hex.encode(fingerprint).prefix(8)) }

    /// The fingerprints of every device `manifest` lists and, above epoch 1, every device of `chain`'s lists
    /// and additions (the devices the vault ever listed on the chain this device verified). Recovery keys
    /// have no id and are left out.
    public static func everListed(manifest: EpochManifest, chain: EpochChain.Verified?) -> Set<Data> {
        var out = Set(manifest.devices.map(\.fingerprint))
        for e in chain?.entries ?? [] {
            out.formUnion(e.list)
            out.formUnion(e.parentList)
            out.formUnion(e.additions.map(\.fingerprint))
        }
        out.subtract(chain?.recoveryKeys ?? [])
        if let r = manifest.recoveryEntry?.fingerprint { out.remove(r) }
        return out
    }

    /// The fingerprint in `known` with the same id as `fingerprint` but another key, nil when none: a device
    /// whose id another device of the vault had or has.
    public static func collision(_ fingerprint: Data, in known: Set<Data>) -> Data? {
        let id = id(of: fingerprint)
        return known.first { $0 != fingerprint && Self.id(of: $0) == id }
    }

    /// An id two of `devices` share, nil when they are all distinct.
    public static func duplicate(in devices: [EpochKeyEntry]) -> String? {
        var seen = Set<String>()
        for d in devices where d.role == .device {
            let id = d.id ?? id(of: d.fingerprint)
            if !seen.insert(id).inserted { return id }
        }
        return nil
    }
}
