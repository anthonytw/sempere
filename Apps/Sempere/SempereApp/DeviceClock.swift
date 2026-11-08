import Foundation
import Sempere
import SempereAppCore

// The revision writer (`DeviceClock`, `NoteWriter`, `Vault.writeDelta`) is the package's
// (Sources/Sempere/RevisionWriter.swift). The app adds only where its state file lives, the `app`
// name its revisions carry and its signposts.

extension DeviceClock {
    /// The app's clock on the state file at `url` (created with a fresh device id): its revisions carry
    /// `NoteWriter.appName`, its writers' reads are signposted (`Perf`). One per state file: the model's.
    init(url: URL = DeviceClock.defaultURL, onWrite: (@Sendable (UUID) -> Void)? = nil) throws {
        try self.init(url: url, app: NoteWriter.appName, perf: AppPerfSink(), onWrite: onWrite)
    }
}

extension NoteWriter {
    /// `sempere-ios/<version>` (format.md §5.1 `app`).
    static var appName: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "sempere-ios/\(v)"
    }
}
