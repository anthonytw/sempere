import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The Mac menu-bar item (GA-23 follow-up, docs/mac.md "Menu-bar item"): the notification protocol
/// with the AppKit bundle, the host that drives it, the setting and the New Note request. The bundle
/// itself exists only in the Catalyst build; everything else runs on every destination.
struct StatusItemProtocolTests {
    @Test func everyActionSurvivesTheNotification() {
        for action in StatusItemProtocol.Action.allCases {
            #expect(StatusItemProtocol.action(from: StatusItemProtocol.userInfo(for: action)) == action)
        }
    }

    @Test func anythingElseIsNoAction() {
        #expect(StatusItemProtocol.action(from: nil) == nil)
        #expect(StatusItemProtocol.action(from: [:]) == nil)
        #expect(StatusItemProtocol.action(from: ["action": 3]) == nil)
        #expect(StatusItemProtocol.action(from: ["action": "format"]) == nil)
    }

    @Test func theStateRoundTripsThroughUserInfo() {
        let state = StatusItemProtocol.State(visible: true, recording: true, busy: false, voiceTitle: "Stop", newNoteTitle: "New",
                                             openTitle: "Open", toolTip: "Sempere")
        #expect(StatusItemProtocol.State(userInfo: state.userInfo) == state)
    }

    @Test func aMistypedOrMissingValueIsTheDefaultAndALongTitleIsCut() {
        let hostile: [AnyHashable: Any] = ["visible": "yes", "recording": 1, "voiceTitle": 7,
                                           "toolTip": String(repeating: "x", count: 10_000)]
        let state = StatusItemProtocol.State(userInfo: hostile)
        #expect(!state.visible && !state.recording && !state.busy)
        #expect(state.voiceTitle.isEmpty)
        #expect(state.toolTip.count == StatusItemProtocol.maxTitleLength)
        #expect(StatusItemProtocol.State(userInfo: nil) == StatusItemProtocol.State())
    }
}

struct StatusItemPreferenceTests {
    @Test func theItemIsOnUntilTheUserTurnsItOff() {
        let name = "StatusItemPreferenceTests-\(UUID().uuidString)"
        let defaults = TestDefaults.suite(name)!
        defaults.removePersistentDomain(forName: name)
        #expect(StatusItemPreference.isOn(in: defaults))
        defaults.set(false, forKey: StatusItemPreference.key)
        #expect(!StatusItemPreference.isOn(in: defaults))
        defaults.set(true, forKey: StatusItemPreference.key)
        #expect(StatusItemPreference.isOn(in: defaults))
    }
}

/// A stand-in for the AppKit bundle: an object the host "loads".
private final class FakePlugin: NSObject {}

@Suite(.serialized)
@MainActor
struct StatusItemHostTests {
    /// A host on its own center and defaults, with a fake bundle, and what the "bundle" saw.
    @MainActor
    final class Rig {
        let center = NotificationCenter()
        let defaults: UserDefaults
        let capture: QuickCapture
        let host = StatusItemHost()
        var actions: [StatusItemProtocol.Action] = []
        var loads = 0
        var updates: [StatusItemProtocol.State] = []
        private var token: NSObjectProtocol?

        init(bundleExists: Bool = true, capture: QuickCapture = QuickCapture()) {
            let name = "StatusItemHostTests-\(UUID().uuidString)"
            defaults = TestDefaults.suite(name)!
            defaults.removePersistentDomain(forName: name)
            self.capture = capture
            host.center = center
            host.defaults = defaults
            host.capture = capture
            // The launch's end comes only when a test calls `launchSettled` (or sets its own grace).
            host.launchGrace = .seconds(3600)
            host.loader = { [unowned self] in
                self.loads += 1
                return bundleExists ? FakePlugin() : nil
            }
            host.perform = { [unowned self] action in self.actions.append(action) }
            token = center.addObserver(forName: StatusItemProtocol.updateName, object: nil, queue: nil) { [unowned self] note in
                let state = StatusItemProtocol.State(userInfo: note.userInfo)
                MainActor.assumeIsolated { self.updates.append(state) }
            }
        }
    }

    /// TestFlight build 8: with every window closed the app stays in ⌘-Tab, where it does nothing. With the
    /// item shown it leaves the Dock and ⌘-Tab (accessory) and comes back when a window opens.
    @Test func everyWindowClosedTheAppLeavesTheDockWhileTheItemIsShown() {
        #expect(StatusItemHost.staysInDock(windows: 1, itemShown: true))
        #expect(!StatusItemHost.staysInDock(windows: 0, itemShown: true))
        #expect(StatusItemHost.staysInDock(windows: 0, itemShown: false), "without the item nothing could bring a window back")

        let rig = Rig()
        var policies: [Bool] = []
        let token = rig.center.addObserver(forName: StatusItemProtocol.policyName, object: nil, queue: nil) { note in
            let regular = StatusItemProtocol.isRegular(note.userInfo)
            MainActor.assumeIsolated { policies.append(regular) }
        }
        defer { rig.center.removeObserver(token) }
        var windows = 1
        rig.host.windowCount = { _ in windows }
        rig.host.start()
        #expect(policies.isEmpty, "regular from the start: nothing to ask")
        windows = 0
        rig.host.windowsChanged()
        #expect(policies == [false])
        rig.host.windowsChanged()
        #expect(policies == [false], "asked once")
        rig.host.activateApp()   // New Note or Open Sempere: a window is coming
        #expect(policies == [false, true])
        rig.host.windowsChanged()
        #expect(policies == [false, true, false])
        rig.defaults.set(false, forKey: StatusItemPreference.key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(policies == [false, true, false, true], "the item hidden: back in the Dock")
    }

    /// `start` runs in the app's `init`, before any scene connects: no window yet is the launch, not "every window
    /// closed". Going accessory there and regular when the first window came left that window behind other apps'
    /// (from #107 on, the Mac UI tests' screenshots showed another app's window). The app stays regular until a
    /// window has been open.
    @Test func noWindowYetAtLaunchKeepsTheAppInTheDock() {
        let rig = Rig()
        var policies: [Bool] = []
        let token = rig.center.addObserver(forName: StatusItemProtocol.policyName, object: nil, queue: nil) { note in
            let regular = StatusItemProtocol.isRegular(note.userInfo)
            MainActor.assumeIsolated { policies.append(regular) }
        }
        defer { rig.center.removeObserver(token) }
        var windows = 0
        rig.host.windowCount = { _ in windows }
        rig.host.start()
        rig.host.windowsChanged()
        #expect(policies.isEmpty, "no window yet: the launch, nothing to ask")
        windows = 1
        rig.host.windowsChanged()
        #expect(policies.isEmpty, "the first window: still regular")
        windows = 0
        rig.host.windowsChanged()
        #expect(policies == [false], "every window closed after one was open: accessory")
    }

    /// Review of #120: a launch for a background intent (StartVoiceNoteIntent, VoiceNoteControlIntent) opens no
    /// window. Once the launch is over (`launchGrace`), "no window" counts, and with the item shown the app leaves the
    /// Dock; a window that opened in time keeps it there, and nothing is asked twice.
    @Test func aLaunchThatOpensNoWindowLeavesTheDockOnceItIsOver() async {
        let rig = Rig()
        var policies: [Bool] = []
        let token = rig.center.addObserver(forName: StatusItemProtocol.policyName, object: nil, queue: nil) { note in
            let regular = StatusItemProtocol.isRegular(note.userInfo)
            MainActor.assumeIsolated { policies.append(regular) }
        }
        defer { rig.center.removeObserver(token) }
        rig.host.windowCount = { _ in 0 }
        rig.host.launchGrace = .milliseconds(50)
        rig.host.start()
        #expect(policies.isEmpty, "during the launch: regular")
        for _ in 0..<100 where policies.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(policies == [false], "the launch over with no window: accessory")
        rig.host.launchSettled()
        #expect(policies == [false], "asked once")

        // A window opened during the launch: settling changes nothing.
        let windowed = Rig()
        var windowedPolicies: [Bool] = []
        let token2 = windowed.center.addObserver(forName: StatusItemProtocol.policyName, object: nil, queue: nil) { note in
            let regular = StatusItemProtocol.isRegular(note.userInfo)
            MainActor.assumeIsolated { windowedPolicies.append(regular) }
        }
        defer { windowed.center.removeObserver(token2) }
        windowed.host.windowCount = { _ in 1 }
        windowed.host.start()
        windowed.host.launchSettled()
        #expect(windowedPolicies.isEmpty, "a window is open: regular")
    }

    @Test func theItemIsShownWhenTheBundleLoadsAndTheSettingIsOn() {
        let rig = Rig()
        rig.host.start()
        #expect(rig.loads == 1)
        let last = rig.updates.last
        #expect(last?.visible == true)
        #expect(last?.recording == false && last?.busy == false)
        #expect(last?.voiceTitle == StatusItemHost.state(visible: true, recorder: .idle).voiceTitle)
        // Review of #107: with every window closed the app is accessory, so the item offers Quit.
        #expect(last?.quitTitle.isEmpty == false)
        #expect(last?.quitTitle == StatusItemHost.state(visible: true, recorder: .idle).quitTitle)
    }

    @Test func withoutTheBundleNothingIsShown() {
        let rig = Rig(bundleExists: false)
        rig.host.start()
        #expect(rig.updates.last?.visible == false)
    }

    @Test func turningTheSettingOffHidesTheItemAndBackOnShowsIt() {
        let rig = Rig()
        rig.host.start()
        rig.defaults.set(false, forKey: StatusItemPreference.key)
        rig.host.publish()
        #expect(rig.updates.last?.visible == false)
        rig.defaults.set(true, forKey: StatusItemPreference.key)
        rig.host.publish()
        #expect(rig.updates.last?.visible == true)
    }

    @Test func aSettingThatStartsOffNeverLoadsTheBundle() {
        let rig = Rig()
        rig.defaults.set(false, forKey: StatusItemPreference.key)
        rig.host.start()
        #expect(rig.loads == 0)
        #expect(rig.updates.last?.visible == false)
    }

    @Test func theBundleAsksForTheStateWhenItIsReady() {
        let rig = Rig()
        rig.host.start()
        let before = rig.updates.count
        rig.center.post(name: StatusItemProtocol.readyName, object: nil)
        #expect(rig.updates.count == before + 1)
    }

    @Test func anEntryChosenInTheItemRunsItsAction() {
        let rig = Rig()
        rig.host.start()
        for action in StatusItemProtocol.Action.allCases {
            rig.center.post(name: StatusItemProtocol.actionName, object: nil, userInfo: StatusItemProtocol.userInfo(for: action))
        }
        rig.center.post(name: StatusItemProtocol.actionName, object: nil, userInfo: ["action": "unlock"])
        rig.center.post(name: StatusItemProtocol.actionName, object: nil)
        #expect(rig.actions == StatusItemProtocol.Action.allCases)
    }

    @Test func recordingTintsTheItemAndTheEntryStops() async throws {
        let (_, _, _, capture, _) = try QuickCaptureTests.setUp(transcribe: false, transcriber: nil)
        let rig = Rig(capture: capture)
        rig.host.start()
        #expect(rig.updates.last?.recording == false)
        try await capture.start()
        #expect(await TS.waitUntil { rig.updates.last?.recording == true })
        #expect(rig.updates.last?.voiceTitle == StatusItemHost.state(visible: true, recorder: .recording).voiceTitle)
        _ = try await capture.stop()
        #expect(await TS.waitUntil { rig.updates.last?.recording == false && rig.updates.last?.busy == false })
    }

    @Test func theTitlesFollowTheRecorder() {
        let idle = StatusItemHost.state(visible: true, recorder: .idle)
        let recording = StatusItemHost.state(visible: true, recorder: .recording)
        #expect(idle.voiceTitle != recording.voiceTitle)
        #expect(!idle.newNoteTitle.isEmpty && !idle.openTitle.isEmpty && !idle.toolTip.isEmpty)
        #expect(StatusItemHost.state(visible: true, recorder: .starting).busy)
        #expect(StatusItemHost.state(visible: true, recorder: .saving).busy)
        #expect(!idle.busy && !recording.busy && recording.recording && !idle.recording)
    }

    @Test func thePluginIsLookedForInThePlugInsFolder() {
        let url = StatusItemHost.pluginURL(in: .main)
        #expect(url?.lastPathComponent == StatusItemProtocol.bundleName)
        #expect(url?.deletingLastPathComponent().lastPathComponent == "PlugIns")
    }
}

@MainActor
struct MenuBarNewNoteTests {
    /// A model with the fixture vault open and locked, and its key.
    static func model() async throws -> (AppModel, String) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        return (model, try String(contentsOf: key, encoding: .utf8))
    }

    @Test func noRequestMeansNothingToDo() {
        let model = AppModel()
        #expect(model.menuBarNewNoteStep() == .none)
    }

    @Test func aLockedVaultMakesTheRequestWait() async throws {
        let (model, _) = try await Self.model()
        #expect(model.phase == .locked)
        let now = Date()
        model.requestNewNoteFromMenuBar(now: now)
        #expect(model.menuBarNewNoteStep(now: now) == .waitForUnlock)
        #expect(!model.takeMenuBarNewNote(now: now))
        #expect(model.menuBarNewNoteRequest != nil, "nothing is taken while locked, and the request stays")
        #expect(model.notes.isEmpty)
    }

    @Test func noVaultDropsTheRequest() {
        let model = AppModel()
        model.requestNewNoteFromMenuBar()
        #expect(model.menuBarNewNoteStep() == .none)
        #expect(model.menuBarNewNoteRequest == nil)
    }

    @Test func anOldRequestIsDroppedAndNeverOpensTheSheet() async throws {
        let (model, key) = try await Self.model()
        try await model.unlock(identityText: key)
        let then = Date()
        model.requestNewNoteFromMenuBar(now: then)
        let later = then.addingTimeInterval(AppModel.menuBarRequestLifetime + 1)
        let before = model.notes.count
        #expect(!model.takeMenuBarNewNote(now: later))
        #expect(model.menuBarNewNoteRequest == nil)
        #expect(model.notes.count == before)
    }

    @Test func anUnlockedVaultHandsTheRequestToOneWindowAndCreatesNoNote() async throws {
        let (model, key) = try await Self.model()
        try await model.unlock(identityText: key)
        let before = model.notes.count
        model.requestNewNoteFromMenuBar()
        #expect(model.menuBarNewNoteStep() == .create)
        // Two library windows react to one request: only one opens the New Note sheet.
        let taken = [model.takeMenuBarNewNote(), model.takeMenuBarNewNote()]
        #expect(taken == [true, false])
        #expect(model.menuBarNewNoteRequest == nil)
        #expect(model.notes.count == before, "the sheet creates the note, with the owner's name and style")
    }
}

/// On the Mac the AppKit bundle is really embedded and loads (`scripts/app.sh test-mac`).
@MainActor
struct MacStatusItemBundleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.isMacCatalystApp))
    func theBundleIsEmbeddedLoadsAndTakesStateWithoutCrashing() throws {
        let url = try #require(StatusItemHost.pluginURL())
        #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path)")
        let plugin = try #require(StatusItemHost.loadBundle())
        // The bundle answers the host's state notifications; hidden, it draws nothing.
        NotificationCenter.default.post(name: StatusItemProtocol.updateName, object: nil,
                                        userInfo: StatusItemProtocol.State(visible: false).userInfo)
        #expect(plugin.responds(to: NSSelectorFromString("description")))
    }

    @Test func theBundleIsAbsentOffTheMac() {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        #expect(StatusItemHost.loadBundle() == nil)
    }
}
