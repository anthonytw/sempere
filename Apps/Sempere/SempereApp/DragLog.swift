import Foundation
import OSLog

/// Unified-log record of a note dragged out of the app (Mac: to the Finder; docs/mac.md "Drag a note out
/// as PDF"), subsystem `io.github.anthonytw.sempere`, category `drag`. Every step is at debug level (not
/// kept unless someone streams it), failures at error level:
///
///     /usr/bin/log stream --level debug --predicate 'subsystem == "io.github.anthonytw.sempere" AND category == "drag"'
///
/// The steps: the drag begins (`begin`: style, note count, the provider's types), a type is asked for
/// (`requested`: which, on which thread), the preparation is awaited, the file is written (`wrote`:
/// extension, size, folder) or fails, the completion is handed back, and the drag ends (`end`: the
/// operation, for a `UIDragInteraction` drag; `released` for SwiftUI's `onDrag`, which reports no end, when
/// the system lets go of the provider). Notes appear as 8-hex id prefixes; titles and file names are
/// private (shown as `<private>` in a stream).
enum DragLog {
    static let logger = Logger(subsystem: "io.github.anthonytw.sempere", category: "drag")

    /// A step of a drag (debug level). Also appended to the DEBUG trace file when `SEMPERE_DEBUG_DROPS` is set
    /// (`NoteFileDrag.dragTrace`, read by `MacDragToFinderUITests`).
    nonisolated static func step(_ line: String) {
        logger.debug("\(line, privacy: .public)")
        NoteFileDrag.dragTrace(line)
    }

    /// A failed step with its error: only a classifier is public (`classify`); the error's full text,
    /// which may name a note's title or a vault path, is private. The trace file gets the classifier only.
    nonisolated static func failure(_ line: String, error: (any Error)?) {
        let kind = error.map(classify) ?? "none"
        let detail = error.map { String(describing: $0) } ?? "nil"
        logger.error("\(line, privacy: .public) error=\(kind, privacy: .public) detail=\(detail, privacy: .private)")
        NoteFileDrag.dragTrace("ERROR \(line) error=\(kind)")
    }

    /// An error's type, NSError domain and code: no user data.
    nonisolated static func classify(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(String(reflecting: type(of: error))) domain=\(ns.domain) code=\(ns.code)"
    }

    /// A user-data value (title, file name): private in the log.
    nonisolated static func privateValue(_ label: String, _ value: String) {
        logger.debug("\(label, privacy: .public) \(value, privacy: .private)")
    }

    /// A note id as its first 8 hex digits.
    nonisolated static func id(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// `thread=main|bg qos=…` for the thread a callback runs on.
    nonisolated static var thread: String {
        "thread=\(Thread.isMainThread ? "main" : "bg") qos=\(Thread.current.qualityOfService.rawValue)"
    }

    /// What a file the drag hands back looks like: extension, size, whether it exists, its folder's last
    /// two components (`SempereExport/<model>/<export>`).
    nonisolated static func describe(file url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let folder = url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")
        return "ext=\(url.pathExtension) bytes=\(values?.fileSize ?? -1) regular=\(values?.isRegularFile ?? false) "
            + "exists=\(FileManager.default.fileExists(atPath: url.path)) folder=\(folder)"
    }

    /// Logs `released` when the system lets go of `provider` (the drag ended, whatever became of it): SwiftUI's
    /// `onDrag` reports no end, so this is the only sign of it. Holds nothing but a tag in the provider.
    nonisolated static func watchRelease(of provider: NSItemProvider, tag: String) {
        objc_setAssociatedObject(provider, &releaseKey, ReleaseSentinel(tag: tag), .OBJC_ASSOCIATION_RETAIN)
    }

    nonisolated(unsafe) private static var releaseKey: UInt8 = 0

    private final class ReleaseSentinel: NSObject {
        let tag: String
        let start = Date()
        init(tag: String) { self.tag = tag }
        deinit { DragLog.step("released \(tag) after=\(String(format: "%.2f", Date().timeIntervalSince(start)))s") }
    }
}
