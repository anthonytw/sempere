import Foundation

/// The name of a folder sync target's copy that the app or the CLI makes in a folder the user picked
/// (`FolderTargetPlacement.location`): `<vault name> Sempere Vault`, then `<vault name> Sempere Vault 2`, … A plain
/// name with NO extension (docs/io.md "A vault folder held as a package"): iCloud Drive kept `….sempere` sync folders
/// as packages on an account where early builds declared the extension `com.apple.package`, new folders included
/// (the owner's `ToneDawgNotes.sempere`, then a new `notes/<vault>.sempere` made by build 111), so the extension itself
/// is the liability. A name without one cannot be mapped to a package by any device's or server's type database.
///
/// The suffix always follows a space, so whatever dots the vault's name holds ("v1.2") end in text with a space in it,
/// which no system takes for an extension (`hasTypeExtension`). The name stays English (text written into a vault and
/// the folders the app makes for it are English). What a folder is stays decided by its content (`vault.json`); the
/// name only says, where nothing can be read (above a pick on iOS), that a folder is probably a vault's copy.
public enum SyncFolderName {
    /// The fixed part after the vault's name.
    public static let suffix = "Sempere Vault"

    /// `<vaultName> Sempere Vault` (`n` 1) or `<vaultName> Sempere Vault <n>`. `vaultName` may be a store folder name
    /// (`Notes.sempere`) or a display name; characters a folder name cannot hold are replaced, leading dots dropped,
    /// and a long name shortened (`BackupDestination.baseName`), "Notes" when nothing is left.
    public static func name(forVault vaultName: String, _ n: Int = 1) -> String {
        let base = BackupDestination.baseName(vaultName)
        return n <= 1 ? "\(base) \(suffix)" : "\(base) \(suffix) \(n)"
    }

    /// Whether `name` has the shape `name(forVault:_:)` makes: `<something> Sempere Vault` or `<something> Sempere
    /// Vault <n>` (n from 2, no leading zero). Says nothing about what the folder holds.
    public static func isPlainName(_ name: String) -> Bool { vaultName(fromPlainName: name) != nil }

    /// The vault's name in a plain sync folder's name (`Notes Sempere Vault 2` → `Notes`), nil when `name` does not
    /// have that shape.
    public static func vaultName(fromPlainName name: String) -> String? {
        let marker = " " + suffix
        guard let r = name.range(of: marker, options: .backwards) else { return nil }
        let head = String(name[..<r.lowerBound]), tail = name[r.upperBound...]
        guard !head.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if tail.isEmpty { return head }
        guard tail.first == " " else { return nil }
        let digits = tail.dropFirst()
        guard let first = digits.first, first != "0", digits.count <= 3,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 2 else { return nil }
        return head
    }

    /// Whether the last path component `name` ends in something a system could take for a type's filename extension:
    /// a dot followed by text with no space (and no dot) in it, as `Foo.sempere` or `Foo.app`. False for every
    /// `name(forVault:_:)` result. Decided here rather than by `URL.pathExtension`, whose rules differ between platforms.
    public static func hasTypeExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...]
        return !ext.isEmpty && !ext.contains(" ") && dot != name.startIndex
    }
}
