import Foundation
import Observation
import SwiftUI
import UIKit

/// The Mac menu-bar item's setting: Settings → General → Show in Menu Bar (Mac only, on by default).
enum StatusItemPreference {
    static let key = "Sempere.showMenuBarItem"
    static let defaultValue = true

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// The app side of the Mac menu-bar item (docs/mac.md "Menu-bar item"). Mac Catalyst has no
/// `NSStatusItem`, so an AppKit bundle (`SempereStatusItem`, embedded in `PlugIns`) draws the item;
/// this loads it, tells it what to show (`StatusItemProtocol`) and does what its entries ask:
/// Quick Voice Note goes through `AppModel.toggleVoiceNote` (the same `QuickCapture` as Siri and
/// the widgets: sealed into the vault's inbox without unlocking), New Note asks the model for a
/// note once the vault is unlocked (`AppModel.requestNewNoteFromMenuBar`). Everything here is
/// inert where the bundle does not exist (iPad, iPhone, tests), so the app builds and runs
/// without it.
@MainActor
final class StatusItemHost {
    static let shared = StatusItemHost()

    /// Loads the AppKit bundle and returns its principal object; nil where there is none.
    var loader: @MainActor () -> NSObject? = StatusItemHost.loadBundle
    var center: NotificationCenter = .default
    var defaults: UserDefaults = .standard
    var capture: QuickCapture = .shared
    /// What an entry of the item does.
    var perform: @MainActor (StatusItemProtocol.Action) -> Void = { _ in }

    private(set) var plugin: NSObject?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// States posted since `start` (tests).
    private(set) var published: [StatusItemProtocol.State] = []

    /// The titles are the app's, localized here: the bundle has no strings of its own.
    static func state(visible: Bool, recorder: QuickCapture.State) -> StatusItemProtocol.State {
        StatusItemProtocol.State(
            visible: visible, recording: recorder == .recording, busy: recorder == .starting || recorder == .saving,
            voiceTitle: recorder == .recording ? String(localized: "Stop Voice Note")
                : String(localized: "Quick Voice Note", comment: "Menu-bar item: record a voice note into the inbox"),
            newNoteTitle: String(localized: "New Note", comment: "Menu-bar item: create a note"),
            openTitle: String(localized: "Open Sempere", comment: "Menu-bar item: bring the app forward"),
            toolTip: String(localized: "Sempere", comment: "Menu-bar item tooltip"))
    }

    /// Wires the entries to `model` and starts showing the item, if the setting is on.
    func start(model: AppModel) {
        perform = { [weak model] action in
            guard let model else { return }
            StatusItemHost.run(action, model: model)
        }
        start()
    }

    /// Starts listening and publishing (idempotent).
    func start() {
        guard !started else { return }
        started = true
        observers.append(center.addObserver(forName: StatusItemProtocol.actionName, object: nil, queue: .main) { [weak self] note in
            let action = StatusItemProtocol.action(from: note.userInfo)
            MainActor.assumeIsolated {
                if let action { self?.perform(action) }
            }
        })
        observers.append(center.addObserver(forName: StatusItemProtocol.readyName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceMayHaveChanged() }
        })
        preferenceMayHaveChanged()
        observeRecorder()
    }

    private var shown: Bool?

    /// Loads the bundle when the item is first wanted, and posts the state when the setting changed.
    private func preferenceMayHaveChanged() {
        let on = StatusItemPreference.isOn(in: defaults)
        if on, plugin == nil { plugin = loader() }
        guard on != shown else { return }
        shown = on
        publish()
    }

    /// Posts the item's state: shown or hidden, recording or not.
    func publish() {
        let state = Self.state(visible: StatusItemPreference.isOn(in: defaults) && plugin != nil, recorder: capture.state)
        published.append(state)
        center.post(name: StatusItemProtocol.updateName, object: nil, userInfo: state.userInfo)
    }

    /// Re-posts the state whenever the recorder changes (Observation: one change per arm).
    private func observeRecorder() {
        withObservationTracking {
            _ = capture.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.observeRecorder()
            }
        }
    }

    /// Asks the bundle to bring the app to the front.
    func activateApp() {
        center.post(name: StatusItemProtocol.activateName, object: nil)
    }

    // MARK: Entries

    /// What an entry of the item does in the app.
    static func run(_ action: StatusItemProtocol.Action, model: AppModel) {
        switch action {
        case .voiceNote:
            let wasSetUp = model.quickCapture.isSetUp
            Task {
                await model.toggleVoiceNote()
                // Not set up: the setup is a sheet of a library window, so show one.
                if !wasSetUp { StatusItemHost.shared.showLibrary() }
            }
        case .newNote:
            model.requestNewNoteFromMenuBar()
            StatusItemHost.shared.showLibrary()
        case .openApp:
            StatusItemHost.shared.showLibrary()
        }
    }

    /// Brings the app forward on a library window (opening one when every window was closed).
    func showLibrary() {
        activateApp()
        if let scene = MenuRouting.shared.libraryScene() {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
        } else {
            MenuRouting.shared.openScene?(SceneRestoration.librarySceneID)
        }
    }

    // MARK: Bundle

    /// The bundle in the app's `PlugIns` folder, or nil.
    static func pluginURL(in bundle: Bundle = .main) -> URL? {
        bundle.builtInPlugInsURL?.appendingPathComponent(StatusItemProtocol.bundleName)
    }

    /// Loads the AppKit bundle and makes its principal object. Nil where the bundle is not there.
    static func loadBundle() -> NSObject? {
        guard Platform.isMac, let url = pluginURL(), FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), bundle.load(), let type = bundle.principalClass as? NSObject.Type else { return nil }
        return type.init()
    }
}

// MARK: - Library window

/// Carries out a pending New Note request of the menu-bar item (`AppModel+MenuBar`) in a library
/// window: when the request arrives, and when the vault becomes unlocked.
private struct MenuBarRequests: ViewModifier {
    @AppModelEnvironment private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.menuBarNewNoteRequest) { _, request in
                if request != nil { Task { await model.performMenuBarNewNote() } }
            }
            .onChange(of: model.phase == .unlocked && !model.isBusy) { _, ready in
                if ready { Task { await model.performMenuBarNewNote() } }
            }
    }
}

extension View {
    /// The library window's part of the Mac menu-bar item.
    func menuBarRequests() -> some View { modifier(MenuBarRequests()) }
}
