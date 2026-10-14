import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SempereApp

/// Windows the system restores where they do not fit: the iPad build
/// ("Designed for iPad" on a Mac) given the scenes the Catalyst build saved in
/// the container they share, or a note window without its value. They show
/// the library or close, and every window has the whole app environment.
@MainActor
@Suite(.serialized)
struct SceneRestorationTests {
    @Test func aSingleSceneBuildShowsTheLibraryWhateverSceneIsRestored() {
        for kind in [SceneRestoration.Kind.library, .note, .settings, .keys] {
            #expect(SceneRestoration.shows(kind, multipleScenes: false) == .library, "\(kind)")
            #expect(SceneRestoration.shows(kind, hasValue: false, multipleScenes: false) == .library, "\(kind)")
        }
    }

    @Test func theMacShowsEachWindowAndClosesANoteWindowWithoutItsNote() {
        #expect(SceneRestoration.shows(.library, multipleScenes: true) == .library)
        #expect(SceneRestoration.shows(.settings, multipleScenes: true) == .own)
        #expect(SceneRestoration.shows(.keys, multipleScenes: true) == .own)
        #expect(SceneRestoration.shows(.note, hasValue: true, multipleScenes: true) == .own)
        #expect(SceneRestoration.shows(.note, hasValue: false, multipleScenes: true) == .closeOpeningLibrary)
    }

    @Test func sceneIDsAreDistinctAndTheMenusUseThem() {
        let ids = [SceneRestoration.Kind.library, .note, .settings, .keys].map(\.sceneID)
        #expect(Set(ids).count == ids.count)
        #expect(SceneRestoration.Kind.library.sceneID == "library")
        #expect(SceneRestoration.Kind.note.sceneID == NoteWindowValue.sceneID)
        #expect(MenuRouting.settingsSceneID == SceneRestoration.Kind.settings.sceneID)
    }

    /// The model, library and keys a window gets (`appEnvironment`), with fakes.
    static func environment<V: View>(_ view: V, model: AppModel) -> some View {
        view.appEnvironment(model: model,
                            library: VaultLibrary(storeURL: FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString).appendingPathComponent("recents.json")),
                            keys: RememberedKeys(store: FakeKeyStore()))
    }

    static func lay<V: View>(_ view: V) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        window.isHidden = true
    }

    /// Each window's own root, with nothing but `appEnvironment`: a view that
    /// reads an environment object the window lacks traps here (TestFlight:
    /// the Settings window restored in the iPad build on a Mac).
    @Test func everyWindowRootLaysOutWithTheSharedEnvironment() {
        let model = AppModel()
        Self.lay(Self.environment(RootView(), model: model))
        Self.lay(Self.environment(SettingsView(showsDone: false), model: model))
        Self.lay(Self.environment(KeysWindowView(), model: model))
        Self.lay(Self.environment(RestoredScene(kind: .settings) { SettingsView(showsDone: false) }, model: model))
        Self.lay(Self.environment(RestoredScene(kind: .keys) { KeysWindowView() }, model: model))
        #expect(model.phase == .noVault)
    }
}
