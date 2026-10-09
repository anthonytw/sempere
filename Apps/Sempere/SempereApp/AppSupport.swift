import Foundation

/// The app's folder in Application Support (`Application Support/Sempere`),
/// where its local state lives. Nothing is created here: whoever writes
/// creates the folders it needs.
enum AppSupport {
    /// `Application Support/Sempere`.
    static var sempere: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Sempere", isDirectory: true)
    }

    /// The folder `name` in `sempere`.
    static func folder(_ name: String) -> URL {
        sempere.appendingPathComponent(name, isDirectory: true)
    }
}
