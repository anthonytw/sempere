import Foundation
import SempereSync

/// Where a vault folder lives, judged from its path (docs/io.md, "Other
/// Files providers"): iCloud Drive, another app's File Provider storage, this
/// app's container, or anything else. Moved to the package as
/// `FolderLocation` (`Sources/SempereSync/FolderProvider.swift`), which the
/// folder transport uses to decide which folders are coordinated; the app's
/// name stays for its callers.
typealias StorageLocation = FolderLocation
