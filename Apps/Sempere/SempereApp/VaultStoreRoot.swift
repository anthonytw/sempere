import Foundation
import Sempere
import SempereSync

/// Where the in-app vault store lives (docs/design/device-first-sync.md §2).
enum VaultStoreRoot {
    /// The app's App Group (entitled on iPhone and iPad builds only).
    static let appGroup = "group.io.github.anthonytw.sempere"

    /// The store's folder: `<App Group>/Library/Application Support/Sempere/Vaults` when the App Group
    /// container is there, else `fallback` (the Mac's). The folder
    /// is `completeUntilFirstUserAuthentication` (quick capture writes from the Lock Screen; every file
    /// is age-encrypted anyway).
    static func prepare(appGroup container: URL?, fallback: URL) -> URL {
        guard let container else { return fallback }
        let root = container.appendingPathComponent("Library/Application Support/Sempere/Vaults", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        return root
    }
}

