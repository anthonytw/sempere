import SwiftUI
import UIKit

/// The app's `WindowGroup`s, and what a window of one shows when the system
/// brings it back (state restoration) in a build or a state it does not fit.
///
/// The Mac Catalyst build and the iPad build ("Designed for iPad" on an Apple
/// silicon Mac) share one container, so either may be handed the scenes the
/// other saved: the iPad build has a single scene and never opens a settings,
/// key or note window itself, and a restored note window may come back
/// without its value. Such a window shows the library instead (or closes and
/// brings the library up), never a view whose environment or value is
/// missing (docs/mac.md "Windows restored from another build").
enum SceneRestoration {
    /// The `WindowGroup`s of `SempereApp`.
    enum Kind: Equatable, Sendable {
        case library, note, settings, keys

        /// The `WindowGroup` id. The library has the same id in every build,
        /// so a library window saved by one build is the library in the other.
        var sceneID: String {
            switch self {
            case .library: return librarySceneID
            case .note: return NoteWindowValue.sceneID
            case .settings: return settingsSceneID
            case .keys: return keysSceneID
            }
        }
    }

    static let librarySceneID = "library"
    static let settingsSceneID = "settings"
    static let keysSceneID = "keys"

    /// What a window of a scene shows.
    enum Shows: Equatable, Sendable {
        /// Its own content.
        case own
        /// The library (`RootView`): the only window of a single-scene build.
        case library
        /// Nothing: it closes and brings the library window up if none is open.
        case closeOpeningLibrary
    }

    /// What a window of `kind` shows. `hasValue` is whether a window that is
    /// opened with a value (a note window) got one; `multipleScenes` is
    /// `UIApplication.supportsMultipleScenes` (the Catalyst build only).
    static func shows(_ kind: Kind, hasValue: Bool = true, multipleScenes: Bool) -> Shows {
        if kind == .library { return .library }
        // A single-scene build has one window: whatever was restored into it
        // must be the library, or there would be no way back to the notes.
        guard multipleScenes else { return .library }
        if kind == .note, !hasValue { return .closeOpeningLibrary }
        return .own
    }
}

/// The app state every window reads from its environment. Every `WindowGroup`
/// gets all of it through `appEnvironment`, whatever its own views need today:
/// a view that reads one that is missing traps (`EnvironmentValues`), and a
/// restored window may show views of another scene (`SceneRestoration`).
struct AppEnvironment: ViewModifier {
    let model: AppModel
    let library: VaultLibrary
    let keys: RememberedKeys

    func body(content: Content) -> some View {
        content
            .environment(model)
            .environment(library)
            .environment(keys)
    }
}

extension View {
    /// Puts the app's model, vault library and remembered keys into the
    /// environment (`AppEnvironment`). Every `WindowGroup` uses it.
    func appEnvironment(model: AppModel, library: VaultLibrary, keys: RememberedKeys) -> some View {
        modifier(AppEnvironment(model: model, library: library, keys: keys))
    }
}

/// The root of a window of `kind`: its own content, or the library, or a
/// window that closes itself (`SceneRestoration.shows`).
struct RestoredScene<Content: View>: View {
    let kind: SceneRestoration.Kind
    var hasValue = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch SceneRestoration.shows(kind, hasValue: hasValue, multipleScenes: UIApplication.shared.supportsMultipleScenes) {
        case .own: content()
        case .library: RootView()
        case .closeOpeningLibrary: ClosingWindow()
        }
    }
}

/// A window restored without what it shows: it brings the library window up
/// (unless one is open) and closes.
private struct ClosingWindow: View {
    @AppModelEnvironment private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .task {
                if model.shouldOpenLibraryWindow() { openWindow(id: SceneRestoration.librarySceneID) }
                dismissWindow()
            }
    }
}
