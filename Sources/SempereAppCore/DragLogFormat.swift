import Foundation

/// What the drag log says about a drag (`DragLog` in the app writes it to the unified log, docs/mac.md "Debugging a
/// drag out"). These are the parts that decide what is public in a stream, apart from the logger itself.
public enum DragLogFormat {
    /// An error's type, NSError domain and code: no user data.
    public static func classify(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(String(reflecting: type(of: error))) domain=\(ns.domain) code=\(ns.code)"
    }

    /// A note id as its first 8 hex digits.
    public static func id(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// `thread=main|bg qos=…` for the thread a callback runs on.
    public static var thread: String {
        "thread=\(Thread.isMainThread ? "main" : "bg") qos=\(Thread.current.qualityOfService.rawValue)"
    }

    /// What a file the drag hands back looks like: extension, size, whether it exists, its folder's last
    /// two components (`SempereExport/<model>/<export>`).
    public static func describe(file url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let folder = url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")
        return "ext=\(url.pathExtension) bytes=\(values?.fileSize ?? -1) regular=\(values?.isRegularFile ?? false) "
            + "exists=\(FileManager.default.fileExists(atPath: url.path)) folder=\(folder)"
    }
}
