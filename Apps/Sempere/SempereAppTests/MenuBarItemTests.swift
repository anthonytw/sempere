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
        let defaults = UserDefaults(suiteName: name)!
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
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            self.capture = capture
            host.center = center
            host.defaults = defaults
            host.capture = capture
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

    @Test func theItemIsShownWhenTheBundleLoadsAndTheSettingIsOn() {
        let rig = Rig()
        rig.host.start()
        #expect(rig.loads == 1)
        let last = rig.updates.last
        #expect(last?.visible == true)
        #expect(last?.recording == false && last?.busy == false)
        #expect(last?.voiceTitle == StatusItemHost.state(visible: true, recorder: .idle).voiceTitle)
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
        await model.performMenuBarNewNote(now: now)
        #expect(model.menuBarNewNoteRequest != nil, "nothing is created while locked, and the request stays")
        #expect(model.notes.isEmpty)
    }

    @Test func noVaultDropsTheRequest() {
        let model = AppModel()
        model.requestNewNoteFromMenuBar()
        #expect(model.menuBarNewNoteStep() == .none)
        #expect(model.menuBarNewNoteRequest == nil)
    }

    @Test func anOldRequestIsDroppedAndNeverCreatesANote() async throws {
        let (model, key) = try await Self.model()
        try await model.unlock(identityText: key)
        let then = Date()
        model.requestNewNoteFromMenuBar(now: then)
        let later = then.addingTimeInterval(AppModel.menuBarRequestLifetime + 1)
        let before = model.notes.count
        await model.performMenuBarNewNote(now: later)
        #expect(model.menuBarNewNoteRequest == nil)
        #expect(model.notes.count == before)
    }

    @Test func anUnlockedVaultCreatesTheNoteOnceAndSelectsIt() async throws {
        let (model, key) = try await Self.model()
        try await model.unlock(identityText: key)
        let before = Set(model.notes.map(\.id))
        model.requestNewNoteFromMenuBar()
        #expect(model.menuBarNewNoteStep() == .create)
        // Two library windows react to one request: only one note comes of it.
        async let a: Void = model.performMenuBarNewNote()
        async let b: Void = model.performMenuBarNewNote()
        _ = await (a, b)
        #expect(model.menuBarNewNoteRequest == nil)
        let created = Set(model.notes.map(\.id)).subtracting(before)
        #expect(created.count == 1)
        #expect(model.selectedNoteID == created.first)
        #expect(model.errorMessage == nil)
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
