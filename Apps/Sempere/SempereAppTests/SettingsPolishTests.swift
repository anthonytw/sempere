import Foundation
import SempereSpeech
import Testing
@testable import SempereApp

/// Preferred Language's engine choice, the sync bar's bulk threshold and the voice-note permission notices.
struct SettingsPolishTests {
    typealias E = SpeechTranscription.EngineStatus
    static let stOK = E(engine: "apple-speechtranscriber-27.0", available: true, language: "en-US", detail: "model installed")
    static let stNo = E(engine: "apple-speechtranscriber-27.0", available: false, language: nil, detail: "language not supported")
    static let sfOK = E(engine: "apple-sfspeech-27.0", available: true, language: "tl-PH", detail: "on device; allowed")
    static let sfNo = E(engine: "apple-sfspeech-27.0", available: false, language: nil, detail: "language not supported")

    @Test func speechTranscriberWinsWhereItSupportsTheLanguage() {
        #expect(TranscriptionPreference.chosenEngine([Self.stOK, Self.sfOK]) == .speechTranscriber)
        #expect(TranscriptionPreference.chosenEngine([Self.sfOK, Self.stOK]) == .speechTranscriber, "the order of the list does not matter")
    }

    @Test func sfSpeechIsTheFallback() {
        #expect(TranscriptionPreference.chosenEngine([Self.stNo, Self.sfOK]) == .sfSpeech)
        #expect(TranscriptionPreference.chosenEngine([Self.sfOK]) == .sfSpeech)
    }

    @Test func noEngineWhenNeitherSupportsTheLanguage() {
        #expect(TranscriptionPreference.chosenEngine([Self.stNo, Self.sfNo]) == nil)
        #expect(TranscriptionPreference.chosenEngine([]) == nil)
        #expect(TranscriptionPreference.engineNote([Self.stNo, Self.sfNo]) == "No speech engine on this device can transcribe this language.")
    }

    @Test func engineNoteNamesTheChosenEngine() {
        #expect(TranscriptionPreference.engineNote([Self.stOK, Self.sfOK]) == "Engine: SpeechTranscriber (on device)")
        #expect(TranscriptionPreference.engineNote([Self.stNo, Self.sfOK]) == "Engine: SFSpeechRecognizer (on device)")
        let lines = TranscriptionPreference.engineLines([Self.stNo, Self.sfOK])
        #expect(lines.map(\.isUsed) == [false, true], "the engine list agrees with the note")
    }

    @Test func automaticLanguageIsTheDefault() {
        let d = UserDefaults(suiteName: "SettingsPolishTests-\(UUID().uuidString)")!
        #expect(TranscriptionSettings.localeIdentifier(d) == nil)
        TranscriptionSettings.setLocaleIdentifier("es-ES", in: d)
        #expect(TranscriptionSettings.localeIdentifier(d) == "es-ES")
        TranscriptionSettings.setLocaleIdentifier(nil, in: d)
        #expect(TranscriptionSettings.localeIdentifier(d) == nil)
    }

    // MARK: Sync bar

    @Test func smallSyncsShowNoBar() {
        #expect(!SyncBarPolicy.shows(pending: 0, wasShown: false))
        for pending in 1..<SyncBarPolicy.minimumNotes { #expect(!SyncBarPolicy.shows(pending: pending, wasShown: false)) }
        #expect(SyncBarPolicy.shows(pending: SyncBarPolicy.minimumNotes, wasShown: false))
        #expect(SyncBarPolicy.shows(pending: 400, wasShown: false))
    }

    @Test func aBulkBarStaysUntilTheLastNoteArrives() {
        #expect(SyncBarPolicy.shows(pending: 2, wasShown: true), "no blinking off at the last few notes")
        #expect(!SyncBarPolicy.shows(pending: 0, wasShown: true))
    }

    @Test func statusLatchesTheBarAcrossPasses() {
        var first = CloudSyncStatus(notes: 100, readyNotes: 10)
        first.carryBarState(from: nil)
        #expect(first.showsBar)
        var late = CloudSyncStatus(notes: 100, readyNotes: 98)
        late.carryBarState(from: first)
        #expect(late.showsBar)
        var done = CloudSyncStatus(notes: 100, readyNotes: 100)
        done.carryBarState(from: late)
        #expect(!done.showsBar)
        // One edited note arriving from another device: no bar.
        var edit = CloudSyncStatus(notes: 100, readyNotes: 99)
        edit.carryBarState(from: done)
        #expect(!edit.showsBar)
    }

    @Test func refreshingFewNotesShowsNoBarButOpeningAVaultDoes() {
        #expect(!NoteLoading(done: 0, total: 1, refreshing: true).showsBar)
        #expect(NoteLoading(done: 0, total: 50, refreshing: true).showsBar)
        #expect(NoteLoading(done: 0, total: 1, refreshing: false).showsBar)
    }

    // MARK: Voice-note permissions

    @Test func voiceNoteBlockersNameWhatIsOff() {
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: true, microphoneDenied: false).isEmpty)
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: false, microphoneDenied: false) == [.liveActivitiesOff])
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: false, microphoneDenied: true) == [.liveActivitiesOff, .microphoneDenied])
        #expect(VoiceNoteBlocker.liveActivitiesOff.explanation.contains("Live Activities"))
    }
}
