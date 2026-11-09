import Foundation
import Sempere
import SempereSpeech
import Testing
@testable import SempereAppCore

/// The per-device preferences that used to live in the app: appearance, the eraser mode, the recording format,
/// the transcription engine choice and the hidden drag diagnostics. Their words and the PencilKit mapping are the
/// app's (`AppearanceSettingsTests`, `EraserPreferenceTests`, `SettingsPolishTests`).
struct PreferencesTests {
    // MARK: Appearance

    @Test func themeDefaultsToTheSystemAndRoundTrips() {
        let d = MemoryKeyValueStore()
        #expect(AppTheme.load(from: d) == .system)
        AppTheme.save(.dark, to: d)
        #expect(AppTheme.load(from: d) == .dark)
        d.set("sepia", forKey: AppTheme.key)
        #expect(AppTheme.load(from: d) == .system, "an unknown value is the default")
        #expect(AppTheme.system.forcesDark == nil)
        #expect(AppTheme.light.forcesDark == false)
        #expect(AppTheme.dark.forcesDark == true)
    }

    @Test func notePagesAreLightUnlessChosen() {
        let d = MemoryKeyValueStore()
        #expect(NotePagesAppearance.load(from: d) == .light)
        for appIsDark in [false, true] {
            #expect(!NotePagesAppearance.light.isDark(appIsDark: appIsDark))
            #expect(NotePagesAppearance.dark.isDark(appIsDark: appIsDark))
            #expect(NotePagesAppearance.matchApp.isDark(appIsDark: appIsDark) == appIsDark)
        }
        NotePagesAppearance.save(.matchApp, to: d)
        #expect(NotePagesAppearance.load(from: d) == .matchApp)
    }

    // MARK: Eraser

    @Test func theEraserIsTheObjectOneUntilAPixelModeIsStored() {
        let d = MemoryKeyValueStore()
        #expect(EraserModeStorage.load(from: d) == .object)
        EraserModeStorage.save(.pixel, to: d)
        #expect(d.string(forKey: EraserModeStorage.key) == "pixelFixedWidth")
        #expect(EraserModeStorage.load(from: d) == .pixel)
        EraserModeStorage.save(.object, to: d)
        #expect(d.string(forKey: EraserModeStorage.key) == "object")
    }

    /// Older builds stored PencilKit's type names: any pixel one is the pixel mode, anything unknown the object one.
    @Test func everyStoredNameReadsAsOneOfTwoModes() {
        let d = MemoryKeyValueStore()
        for (stored, mode) in [("object", EraserMode.object), ("pixel", .pixel), ("pixelFixedWidth", .pixel), ("garbage", .object)] {
            d.set(stored, forKey: EraserModeStorage.key)
            #expect(EraserModeStorage.load(from: d) == mode, "stored \(stored)")
        }
    }

    @Test func settingsSyncSpeaksObjectAndPixel() {
        let d = MemoryKeyValueStore()
        #expect(EraserModeStorage.syncedName(from: d) == "object")
        EraserModeStorage.store(syncedName: "pixel", in: d)
        #expect(d.string(forKey: EraserModeStorage.key) == "pixelFixedWidth")
        #expect(EraserModeStorage.syncedName(from: d) == "pixel")
        d.set("pixelFixedWidth", forKey: EraserModeStorage.key)
        #expect(EraserModeStorage.syncedName(from: d) == "pixel")
        EraserModeStorage.store(syncedName: "whatever", in: d)
        #expect(EraserModeStorage.syncedName(from: d) == "object")
    }

    // MARK: Recording and transcription

    @Test func recordingSettingsDefaultAndRoundTrip() {
        let d = MemoryKeyValueStore()
        #expect(RecordingPreference.format(d) == .default)
        RecordingPreference.save(RecordingFormat(codec: .heAAC, bitRate: 24_000, sampleRate: 44_100, channels: 2), d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .heAAC, bitRate: 24_000, sampleRate: 44_100, channels: 2))
        d.set(12_345, forKey: RecordingPreference.sampleRateKey)
        d.set("opus", forKey: RecordingPreference.codecKey)
        #expect(RecordingPreference.format(d).sampleRate == 48_000)
        #expect(RecordingPreference.format(d).codec == .aac)
        #expect(TranscriptionPreference.isOn(d) == false, "transcription is opt-in")
    }

    /// The Settings panel (`RecordingSettings`, `TranscriptionSettings`) is the one place these are chosen: every
    /// choice it offers is what is recorded, and its transcription switch and language are what is used.
    @Test func theSettingsPanelsChoicesAreWhatIsUsed() {
        let d = MemoryKeyValueStore()
        RecordingSettings(codec: .heAAC, bitRate: 64_000, sampleRate: 32_000, channels: .stereo).save(to: d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .heAAC, bitRate: 64_000, sampleRate: 32_000, channels: 2))
        RecordingSettings(codec: .aacLC, bitRate: 24_000, sampleRate: 22_050).save(to: d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .aac, bitRate: 24_000, sampleRate: 22_050, channels: 1))
        RecordingSettings(codec: .appleLossless, sampleRate: 16_000).save(to: d)
        #expect(RecordingPreference.format(d) == RecordingFormat(codec: .alac, bitRate: nil, sampleRate: 16_000, channels: 1))
        for codec in RecordingSettings.Codec.allCases {
            for rate in RecordingSettings.bitRates(for: codec) {
                for sampleRate in RecordingSettings.sampleRates(for: codec) {
                    RecordingSettings(codec: codec, bitRate: rate, sampleRate: sampleRate).save(to: d)
                    let f = RecordingPreference.format(d)
                    #expect(f.codec.rawValue == codec.rawValue)
                    #expect(f.bitRate == rate, "\(codec) \(rate)")
                    #expect(f.sampleRate == sampleRate, "\(codec) \(sampleRate)")
                }
            }
        }
        #expect(!TranscriptionPreference.isOn(d))
        TranscriptionSettings.setEnabled(true, in: d)
        TranscriptionSettings.setLocaleIdentifier("es-MX", in: d)
        #expect(TranscriptionPreference.isOn(d))
        #expect(TranscriptionPreference.language(d) == "es-MX")
    }

    typealias E = SpeechTranscription.EngineStatus
    static let stOK = E(engine: "apple-speechtranscriber-27.0", available: true, language: "en-US", detail: "model installed")
    static let stNo = E(engine: "apple-speechtranscriber-27.0", available: false, language: nil, detail: "language not supported")
    static let sfOK = E(engine: "apple-sfspeech-27.0", available: true, language: "tl-PH", detail: "on device; allowed")
    static let sfNo = E(engine: "apple-sfspeech-27.0", available: false, language: nil, detail: "language not supported")

    @Test func speechTranscriberWinsWhereItSupportsTheLanguageAndSFSpeechIsTheFallback() {
        #expect(TranscriptionPreference.chosenEngine([Self.stOK, Self.sfOK]) == .speechTranscriber)
        #expect(TranscriptionPreference.chosenEngine([Self.sfOK, Self.stOK]) == .speechTranscriber, "the order of the list does not matter")
        #expect(TranscriptionPreference.chosenEngine([Self.stNo, Self.sfOK]) == .sfSpeech)
        #expect(TranscriptionPreference.chosenEngine([Self.sfOK]) == .sfSpeech)
        #expect(TranscriptionPreference.chosenEngine([Self.stNo, Self.sfNo]) == nil)
        #expect(TranscriptionPreference.chosenEngine([]) == nil)
    }

    @Test func modelStatusFollowsWhatTheEnginesSay() {
        let none = E(engine: "a", available: false, language: nil, detail: "language not supported")
        let missing = E(engine: "b", available: true, language: "en-US", detail: "model not installed (downloaded on first use)")
        let ready = E(engine: "c", available: true, language: "en-US", detail: "model installed")
        #expect(TranscriptionPreference.modelStatus([none]) == .unavailable)
        #expect(TranscriptionPreference.modelStatus([missing, none]) == .notDownloaded)
        #expect(TranscriptionPreference.modelStatus([missing, ready]) == .installed)
    }

    @Test func theEngineListNamesEachEngineItsStateAndTheOneUsed() {
        let st = E(engine: "apple-speechtranscriber-26.7", available: true, language: "es-ES",
                   detail: "model not installed (downloaded on first use)")
        let sf = E(engine: "apple-sfspeech-26.7", available: true, language: "es-ES", detail: "on device; permission not asked yet")
        let rows = TranscriptionPreference.engineRows([st, sf])
        #expect(rows.map(\.kind) == [.speechTranscriber, .sfSpeech])
        #expect(rows.map(\.isUsed) == [true, false], "the first available engine is used")
        #expect(rows.map(\.state) == [.availableOnceModelDownloaded, .availableAsksForPermission])

        let missing = E(engine: "apple-speechtranscriber-26.7", available: false, language: nil, detail: "language not supported")
        let noModel = E(engine: "apple-sfspeech-26.7", available: false, language: "xx",
                        detail: "no on-device model (server recognition is never used)")
        let none = TranscriptionPreference.engineRows([missing, noModel])
        #expect(none.allSatisfy { !$0.isUsed && !$0.available })
        #expect(none.map(\.state) == [.languageNotSupported, .noOnDeviceModel])

        let fallback = TranscriptionPreference.engineRows([missing, E(engine: "apple-sfspeech-26.7", available: true, language: "en-US",
                                                                        detail: "on device; allowed")])
        #expect(fallback.map(\.isUsed) == [false, true], "when SpeechTranscriber cannot, SFSpeechRecognizer is used")
        #expect(fallback[1].state == .availablePermissionGranted)
        #expect(TranscriptionPreference.state(of: Self.stOK) == .availableModelInstalled)
        #expect(TranscriptionPreference.state(of: E(engine: "x", available: true, language: nil, detail: "on device; permission refused"))
                == .availableButNotAllowed)
        #expect(TranscriptionPreference.state(of: E(engine: "x", available: true, language: nil, detail: "ok")) == .available)
        #expect(TranscriptionPreference.state(of: E(engine: "x", available: false, language: nil, detail: "no Speech framework")) == .notAvailable)
        #expect(TranscriptionPreference.kind(of: E(engine: "other", available: true, language: nil, detail: "")) == .other("other"))
        #expect(TranscriptionPreference.engineRows([]).isEmpty)
    }

    // MARK: Drag diagnostics

    @Test func eachDragTestRunWritesItsSwitchesAndOffRemovesThem() {
        let defaults = MemoryKeyValueStore()
        for run in NoteDragTestRun.allCases {
            run.apply(to: defaults)
            let read = NoteDragDebug.read(from: defaults, environment: [:])
            #expect(read == run.switches, "\(run)")
            #expect(NoteDragTestRun.matching(read) == run)
        }
        NoteDragTestRun.off.apply(to: defaults)
        #expect(defaults.object(forKey: NoteDragDebug.styleKey) == nil)
        #expect(defaults.object(forKey: NoteDragDebug.controlKey) == nil)
        #expect(defaults.object(forKey: NoteDragDebug.fileOnlyKey) == nil)
    }

    @Test func switchesNoRunSetsAreClearedSoOffWorks() {
        let defaults = MemoryKeyValueStore()
        defaults.set("uikit", forKey: NoteDragDebug.styleKey)
        defaults.set(true, forKey: NoteDragDebug.controlKey)   // uikit + control: no run sets this
        #expect(NoteDragTestRun.matching(NoteDragDebug.read(from: defaults, environment: [:])) == nil)
        #expect(NoteDragTestRun.settled(in: defaults) == .off)
        #expect(defaults.object(forKey: NoteDragDebug.styleKey) == nil)
        #expect(defaults.object(forKey: NoteDragDebug.controlKey) == nil)
        NoteDragTestRun.b.apply(to: defaults)
        #expect(NoteDragTestRun.settled(in: defaults) == .b, "a run's own switches stay")
    }

    @Test func notesDragAsShippedUnlessTheHiddenSwitchesSayOtherwise() {
        #expect(NoteDragStyle.shipped == .onDrag)
        let defaults = MemoryKeyValueStore()
        #expect(NoteDragDebug.read(from: defaults, environment: [:]) == NoteDragDebug())
        defaults.set("uikit", forKey: NoteDragDebug.styleKey)
        defaults.set(true, forKey: NoteDragDebug.controlKey)
        defaults.set(true, forKey: NoteDragDebug.fileOnlyKey)
        #expect(NoteDragDebug.read(from: defaults, environment: [:]) == NoteDragDebug(style: .uikit, control: true, fileOnly: true))
        defaults.set("sideways", forKey: NoteDragDebug.styleKey)
        #expect(NoteDragDebug.read(from: defaults, environment: [:]).style == nil, "an unknown style is the shipped one")
        let env = ["SEMPERE_DEBUG_NOTE_DRAG": "onDrag", "SEMPERE_DEBUG_DRAG_FILE_ONLY": "1"]
        #expect(NoteDragDebug.read(from: MemoryKeyValueStore(), environment: env) == NoteDragDebug(style: .onDrag, fileOnly: true),
                "the environment overrides")
    }

    @Test func fiveQuickClicksOrAnOptionClickRevealTheDiagnostics() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var clicks = RevealClicks()
        let option = clicks.click(at: t0, option: true)
        #expect(option)
        let quick = (0..<5).map { clicks.click(at: t0.addingTimeInterval(10 + Double($0) * 0.3), option: false) }
        #expect(quick == [false, false, false, false, true])
        let slow = (0..<5).map { clicks.click(at: t0.addingTimeInterval(100 + Double($0) * 2), option: false) }
        #expect(!slow.contains(true), "clicks far apart start the count again")
    }
}
