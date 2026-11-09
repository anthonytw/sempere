import Foundation

/// Where notes dragged out of the app (a Mac drop on the Finder) are written as plaintext files: one folder per
/// model under `$TMPDIR/SempereExport/` (`AppModelCore.exportFolder`), emptied when the vault closes. Rendering
/// and writing them is `AppModel+DragExport.swift` (`NotePDFExport.render`, `write`, on `services.exportRendering`).
public enum NotePDFExport {
    /// Folder under the temporary directory holding exported files, one
    /// sub-folder per export so equal titles never collide.
    public static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereExport", isDirectory: true)
    }

    /// Removes exports older than `age` seconds (all of them with 0).
    public static func purge(in folder: URL = NotePDFExport.folder, olderThan age: TimeInterval = 600, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if age <= 0 || modified.map({ now.timeIntervalSince($0) > age }) ?? true {
                try? fm.removeItem(at: entry)
            }
        }
    }
}

/// A vault generation readable from any thread: `AppModel.close` bumps it, and
/// an export prepared before then writes nothing (`PreparedExport.write`).
final class ExportEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    init() {}

    var value: Int { lock.withLock { current } }

    func bump() { lock.withLock { current += 1 } }
}
