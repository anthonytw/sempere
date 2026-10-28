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
/// the widgets: sealed into the vault's inbox without unlocking), New Note asks the model to open the New Note
/// sheet once the vault is unlocked (`AppModel.requestNewNoteFromMenuBar`). Everything here is
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
    /// How many windows are open, leaving out a scene being disconnected.
    var windowCount: @MainActor (_ leaving: UIScene?) -> Int = { leaving in
        UIApplication.shared.connectedScenes.filter { $0 is UIWindowScene && $0 !== leaving }.count
    }
    /// The activation policy last asked of the bundle (nil: never asked; the app starts regular).
    private(set) var regular: Bool?
    /// Whether a window has been open since launch, or the launch is over (`launchGrace`). Until then "no window" is the
    /// launch itself (`start` runs in the app's `init`, before any scene connects), never "every window closed": going
    /// accessory there and regular again when the first scene connected left the new window behind other apps'
    /// windows (from #107 on, the Mac UI tests' screenshots showed another app's window in front of it).
    private var hadWindow = false
    /// How long after `start` a launch that opened no window counts as over: then "no window" is the app's state
    /// (a launch for a background intent, `StartVoiceNoteIntent`, `VoiceNoteControlIntent`), and with the item shown
    /// the app leaves the Dock.
    var launchGrace: Duration = .seconds(2)

    /// The titles are the app's, localized here: the bundle has no strings of its own.
    static func state(visible: Bool, recorder: QuickCapture.State) -> StatusItemProtocol.State {
        StatusItemProtocol.State(
            visible: visible, recording: recorder == .recording, busy: recorder == .starting || recorder == .saving,
            voiceTitle: recorder == .recording ? String(localized: "Stop Voice Note")
                : String(localized: "Quick Voice Note", comment: "Menu-bar item: record a voice note into the inbox"),
            newNoteTitle: String(localized: "New Note", comment: "Menu-bar item: create a note"),
            openTitle: String(localized: "Open Sempere", comment: "Menu-bar item: bring the app forward"),
            quitTitle: String(localized: "Quit Sempere", comment: "Menu-bar item: quit the app (its last entry)"),
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
        // Every window closed, the app leaves the Dock and ⌘-Tab while the item stays (TestFlight build 8:
        // "it's not useful there, e.g. ⌘N does nothing until you open the app"); a window brings it back.
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hadWindow = true
                self?.setRegular(true)   // a window is opening
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            let scene = note.object as? UIScene
            MainActor.assumeIsolated { self?.windowsChanged(leaving: scene) }
        })
        preferenceMayHaveChanged()
        observeRecorder()
        let grace = launchGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.launchSettled()
        }
    }

    /// The launch is over (`launchGrace` after `start`): with no window opened, "no window" now counts, so a launch
    /// for a background intent does not sit in the Dock.
    func launchSettled() {
        guard !hadWindow else { return }
        hadWindow = true
        windowsChanged()
    }

    /// Whether the app belongs in the Dock and ⌘-Tab: while a window is open, or the item is not
    /// there to bring one back (pure, tested).
    static func staysInDock(windows: Int, itemShown: Bool) -> Bool { windows > 0 || !itemShown }

    /// A window opened or closed (or the item was shown or hidden): asks the bundle for the policy
    /// that follows (`staysInDock`). `leaving` is a scene being disconnected, not counted.
    func windowsChanged(leaving: UIScene? = nil) {
        let shown = StatusItemPreference.isOn(in: defaults) && plugin != nil
        let windows = windowCount(leaving)
        if windows > 0 { hadWindow = true }
        // Before the first window, the launch is not over: the app stays as it starts (regular).
        guard hadWindow else { return }
        setRegular(Self.staysInDock(windows: windows, itemShown: shown))
    }

    private func setRegular(_ regular: Bool) {
        guard regular != (self.regular ?? true) else { return }
        self.regular = regular
        center.post(name: StatusItemProtocol.policyName, object: nil, userInfo: StatusItemProtocol.policyUserInfo(regular: regular))
    }

    private var shown: Bool?

    /// Loads the bundle when the item is first wanted, and posts the state when the setting changed.
    private func preferenceMayHaveChanged() {
        let on = StatusItemPreference.isOn(in: defaults)
        if on, plugin == nil { plugin = loader() }
        guard on != shown else { return }
        shown = on
        publish()
        windowsChanged()
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

    /// Asks the bundle to bring the app to the front (back in the Dock first: a window is coming).
    func activateApp() {
        setRegular(true)
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
    /// The window's own state (passed in: the window sets its environment further in).
    let ui: WindowUI
    @AppEnvironmentObject private var keys: RememberedKeys

    /// Opens this window's New Note sheet when a request is pending and can be carried out.
    private func present() {
        // Not while the unlock sheet is still up: a second sheet would be dropped and the request lost.
        guard !keys.holdsUnlockSheet(model) else { return }
        if model.takeMenuBarNewNote() { ui.creatingNote = true }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: model.menuBarNewNoteRequest) { _, request in
                if request != nil { present() }
            }
            .onChange(of: model.phase == .unlocked && !model.isBusy) { _, ready in
                if ready { present() }
            }
            .onChange(of: keys.holdsUnlockSheet(model)) { _, holds in
                if !holds, model.phase == .unlocked { present() }
            }
            // A window the item opened (every window was closed) starts with the request already there and the
            // vault already unlocked: neither change above ever comes (TestFlight build 8: "Add Note just opens
            // Sempere, it doesn't create a new note").
            .onAppear {
                if model.menuBarNewNoteRequest != nil { present() }
            }
    }
}

extension View {
    /// The library window's part of the Mac menu-bar item.
    func menuBarRequests(_ ui: WindowUI) -> some View { modifier(MenuBarRequests(ui: ui)) }
}
