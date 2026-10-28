import Foundation

/// The fonts the CLI ships for text in exports (docs/attachments.md §6):
/// Noto Sans, Noto Serif (regular, bold, italic, bold italic) and Noto Sans
/// Mono (regular, bold), covering Latin, Greek and Cyrillic, under the SIL
/// Open Font License 1.1 (`OFL.txt` beside them). They are data files, not
/// part of the program: other scripts come from font packs.
///
/// The app does not link this target; it draws text with the system fonts.
public enum SempereFonts {
    /// Font file names, by generic family and face.
    public static let files: [String] = [
        "NotoSans-Regular.ttf", "NotoSans-Bold.ttf", "NotoSans-Italic.ttf", "NotoSans-BoldItalic.ttf",
        "NotoSerif-Regular.ttf", "NotoSerif-Bold.ttf", "NotoSerif-Italic.ttf", "NotoSerif-BoldItalic.ttf",
        "NotoSansMono-Regular.ttf", "NotoSansMono-Bold.ttf",
    ]

    /// The directory holding the bundled fonts, or nil when they are not
    /// installed. Looked up, in order:
    /// - `$SEMPERE_BUNDLED_FONTS`;
    /// - `fonts/` next to the executable (the release tarball) and
    ///   `../share/sempere/fonts` (Homebrew-style prefixes);
    /// - SwiftPM's resource bundle next to the executable or any loaded
    ///   bundle (`swift build`, `swift test`).
    ///
    /// Never traps (SwiftPM's generated `Bundle.module` does when the bundle is missing).
    public static var directory: URL? {
        let fm = FileManager.default
        func valid(_ url: URL) -> URL? {
            fm.fileExists(atPath: url.appendingPathComponent(files[0]).path) ? url : nil
        }
        if let env = ProcessInfo.processInfo.environment["SEMPERE_BUNDLED_FONTS"], !env.isEmpty {
            return valid(URL(fileURLWithPath: env))
        }
        var dirs: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            dirs.append(exe)
            if let d = valid(exe.appendingPathComponent("fonts")) { return d }
            if let d = valid(exe.deletingLastPathComponent().appendingPathComponent("share/sempere/fonts")) { return d }
        }
        dirs += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        for dir in dirs {
            let bundle = dir.appendingPathComponent("sempere-core_SempereFonts.bundle")
            for candidate in [bundle.appendingPathComponent("Fonts"), bundle.appendingPathComponent("Contents/Resources/Fonts")] {
                if let d = valid(candidate) { return d }
            }
        }
        return nil
    }
}
