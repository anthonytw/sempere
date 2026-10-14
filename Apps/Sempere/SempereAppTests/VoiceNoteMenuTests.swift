import Foundation
import Testing
@testable import SempereApp
import Sempere

/// GA-23: File > Start / Stop Voice Note on a Mac, over the recorder Siri and the widgets use.
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
    @Test func notSetUpOpensQuickVoiceNotesSettings() async {
        let model = AppModel()
        let capture = QuickCapture()
        capture.store = MemoryCaptureProfileStore()
        capture.showsActivity = false
        model.quickCapture = capture
        await model.toggleVoiceNote()
        #expect(capture.pendingLink == .settings)
        #expect(capture.state == .idle)
        #expect(model.errorMessage == nil)
    }

    /// Start and stop through the menu's entry point seal a voice note into the vault's inbox
    /// without unlocking anything: the existing capture path.
    @Test func startThenStopSealsIntoTheInbox() async throws {
        let (url, _, _, capture, _) = try QuickCaptureTests.setUp(transcribe: false, transcriber: nil)
        let model = AppModel()
        model.quickCapture = capture
        #expect(QuickCaptureTests.inbox(url).isEmpty)
        await model.toggleVoiceNote()
        #expect(capture.state == .recording)
        #expect(VoiceNoteMenu.phase(capture.state) == .recording)
        await model.toggleVoiceNote()
        #expect(capture.state == .idle)
        #expect(model.errorMessage == nil)
        #expect(!QuickCaptureTests.inbox(url).isEmpty)
    }

    @Test func aMicrophoneRefusalIsShownAsAnError() async throws {
        let (_, _, _, capture, _) = try QuickCaptureTests.setUp(transcribe: false, transcriber: nil)
        capture.microphoneAllowed = { false }
        let model = AppModel()
        model.quickCapture = capture
        await model.toggleVoiceNote()
        #expect(capture.state == .idle)
        #expect(model.errorMessage != nil)
    }
}
