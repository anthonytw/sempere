import Foundation

// The app's interface strings (docs/localization.md, docs/design/thin-app.md "Rules"). This target holds
// `Localizable.xcstrings` and, as the thin-app moves bring them, the extensions that word library values
// (`SyncProblem.folderUnreachable(path:)` and the like) in the user's language. The library itself holds no
// user-facing text, and the CLI words its values in English.
//
// The one catalog file is compiled twice:
//
// - Into this target's resource bundle (`Bundle.sempereLocalization`): what code in this package looks up,
//   with `String(localized: "…", bundle: .sempereLocalization)` or `SempereStrings.localized`. Package code
//   never looks in the main bundle.
// - Into the app's and the widget's main bundles: both targets list this same file as a resource
//   (`project.pbxproj`), so SwiftUI literals (`Text("Cancel")`, which look in `Bundle.main`) and the app's
//   `String(localized:)` find their strings with no `bundle:` argument, and the pseudo-language harness, which
//   swaps `Bundle`'s lookups, sees the same tables as before.
//
// Apple-only (`Package.swift`): Linux has no rule for the resource and no `String(localized:bundle:)`.

extension Bundle {
    /// The bundle with this package's compiled `Localizable` table (every interface string of the app).
    public static var sempereLocalization: Bundle { .module }
}

/// Lookups in the shared catalog for code that is not in the app's bundle.
public enum SempereStrings {
    /// The localized text of `key` in the user's language (`Localizable`, `Bundle.sempereLocalization`).
    public static func localized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
        String(localized: key, table: nil, bundle: .module, comment: comment)
    }

    /// The text of `key` in `language` (`"es"`), or nil when the bundle has no such language or key. For tests
    /// and checks that must read one language whatever the device's is.
    public static func text(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let missing = "\u{1}missing\u{1}"
        let value = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }
}
