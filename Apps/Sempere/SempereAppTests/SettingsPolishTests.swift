import Foundation
import SempereAppCore
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

    @Test func noEngineWhenNeitherSupportsTheLanguage() {
        #expect(TranscriptionPreference.engineNote([Self.stNo, Self.sfNo]) == "No speech engine on this device can transcribe this language.")
    }

    @Test func engineNoteNamesTheChosenEngine() {
        #expect(TranscriptionPreference.engineNote([Self.stOK, Self.sfOK]) == "Engine: SpeechTranscriber (on device)")
        #expect(TranscriptionPreference.engineNote([Self.stNo, Self.sfOK]) == "Engine: SFSpeechRecognizer (on device)")
        let lines = TranscriptionPreference.engineLines([Self.stNo, Self.sfOK])
        #expect(lines.map(\.isUsed) == [false, true], "the engine list agrees with the note")
    }

    // MARK: Sync bar

    // MARK: Voice-note permissions

    @Test func voiceNoteBlockersNameWhatIsOff() {
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: true, microphoneDenied: false).isEmpty)
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: false, microphoneDenied: false) == [.liveActivitiesOff])
        #expect(VoiceNoteBlocker.current(liveActivitiesEnabled: false, microphoneDenied: true) == [.liveActivitiesOff, .microphoneDenied])
        #expect(VoiceNoteBlocker.liveActivitiesOff.explanation.contains("Live Activities"))
    }
}
