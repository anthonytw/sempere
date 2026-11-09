import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// GA-23: File > Start / Stop Voice Note on a Mac, over the recorder Siri and the widgets use. Moved from the app's
/// `VoiceNoteMenuTests` (wave 6 follow-up F1), with `VoiceNoteMenu` and `VoiceNoteBannerRule`; the model tests run
/// on `CaptureRig`'s fakes instead of the app's recorder.
struct VoiceNoteMenuActionTests {
    @Test func theItemFollowsTheRecorder() {
        #expect(VoiceNoteMenu.action(setUp: true, state: .idle) == .start)
        #expect(VoiceNoteMenu.action(setUp: true, state: .recording) == .stop)
        #expect(VoiceNoteMenu.action(setUp: true, state: .starting) == .none)
        #expect(VoiceNoteMenu.action(setUp: true, state: .saving) == .none)
    }

    @Test func withoutASetupItOpensTheSettingsInsteadOfFailing() {
        #expect(VoiceNoteMenu.action(setUp: false, state: .idle) == .openSetup)
        // A recording in progress can always be stopped, profile or not.
        #expect(VoiceNoteMenu.action(setUp: false, state: .recording) == .stop)
    }

    /// Review fix: from a note window the model's `pendingLink` showed nothing (only the library
    /// window answers it), so the Mac menu opens the Settings window when nothing is set up.
    @Test func onlyAMissingSetupOpensTheSettingsWindow() {
        #expect(VoiceNoteMenu.opensSettingsWindow(setUp: false, state: .idle))
        #expect(!VoiceNoteMenu.opensSettingsWindow(setUp: true, state: .idle))
        #expect(!VoiceNoteMenu.opensSettingsWindow(setUp: false, state: .recording), "Stop still stops")
        #expect(!VoiceNoteMenu.opensSettingsWindow(setUp: false, state: .saving))
    }

    /// Review fix: the banner was hidden on a Mac, so a voice note started from the File menu
    /// recorded with no sign in the window. The rule no longer depends on the platform.
    @Test func theBannerShowsWhileRecordingSavingOrNoticing() {
        #expect(VoiceNoteBannerRule.shows(state: .recording, hasNotice: false))
        #expect(VoiceNoteBannerRule.shows(state: .saving, hasNotice: false))
        #expect(VoiceNoteBannerRule.shows(state: .idle, hasNotice: true))
        #expect(!VoiceNoteBannerRule.shows(state: .idle, hasNotice: false))
        #expect(!VoiceNoteBannerRule.shows(state: .starting, hasNotice: false))
    }

    @Test func theMenuContextMirrorsTheRecorder() {
        #expect(VoiceNoteMenu.phase(.idle) == .idle)
        #expect(VoiceNoteMenu.phase(.recording) == .recording)
        #expect(VoiceNoteMenu.phase(.starting) == .busy)
        #expect(VoiceNoteMenu.phase(.saving) == .busy)
    }
}

@Suite(.serialized)
@MainActor
struct VoiceNoteMenuModelTests {
    @Test func notSetUpOpensQuickVoiceNotesSettings() async throws {
        let rig = try CaptureRig(profile: false)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = rig.capture
        await model.toggleVoiceNote()
        #expect(rig.capture.pendingLink == .settings)
        #expect(rig.capture.state == .idle)
        #expect(model.alert == nil)
    }

    /// Start and stop through the menu's entry point seal a voice note into the vault's inbox
    /// without unlocking anything: the existing capture path.
    @Test func startThenStopSealsIntoTheInbox() async throws {
        let rig = try CaptureRig()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = rig.capture
        #expect(rig.inbox.isEmpty)
        await model.toggleVoiceNote()
        #expect(rig.capture.state == .recording)
        #expect(VoiceNoteMenu.phase(rig.capture.state) == .recording)
        await model.toggleVoiceNote()
        #expect(rig.capture.state == .idle)
        #expect(model.alert == nil)
        #expect(!rig.inbox.isEmpty)
    }

    @Test func aMicrophoneRefusalIsShownAsAnError() async throws {
        let rig = try CaptureRig()
        rig.audio.allowed = { false }
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.quickCapture = rig.capture
        await model.toggleVoiceNote()
        #expect(rig.capture.state == .idle)
        #expect(model.alert != nil)
    }
}
