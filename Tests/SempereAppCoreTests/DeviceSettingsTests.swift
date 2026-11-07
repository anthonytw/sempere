import Foundation
import Sempere
import SempereAppCore
import Testing

/// The device settings (docs/attachments.md §15): defaults, valid choices and persistence in the device's
/// key-value store. Their wording and the behavior they drive in the app: `SettingsTests` (SempereAppTests).
struct DeviceSettingsTests {
    /// An empty store.
    func scratch() -> MemoryKeyValueStore { MemoryKeyValueStore() }

    // MARK: Recording

    @Test func recordingDefaultsAreTheDecidedPolicy() {
        let s = RecordingSettings.load(from: scratch())
        #expect(s.codec == .aacLC)
        #expect(s.bitRate == 64_000)
        #expect(s.sampleRate == 48_000)
        #expect(s.channels == .mono)
    }

    @Test func recordingValuesOutsideTheChoicesAreCorrected() {
        let d = scratch()
        d.set("mp3", forKey: RecordingSettings.codecKey)
        d.set(12_345, forKey: RecordingSettings.sampleRateKey)
        d.set(7, forKey: RecordingSettings.channelsKey)
        d.set(10_000_000, forKey: RecordingSettings.bitRateKey)
        let s = RecordingSettings.load(from: d)
        #expect(s.codec == .aacLC && s.sampleRate == 48_000 && s.channels == .mono)
        #expect(s.bitRate == 128_000, "the nearest offered rate")
        // Extremes do not overflow the distance computation.
        #expect(RecordingSettings(bitRate: Int.min).normalized().bitRate == 24_000)
        #expect(RecordingSettings(bitRate: Int.max).normalized().bitRate == 128_000)
        // HE-AAC does not offer the top rates.
        #expect(RecordingSettings(codec: .heAAC, bitRate: 128_000).normalized().bitRate == 64_000)
        // HE-AAC does not offer sample rates below 32 kHz: 48 kHz, as it is recorded.
        #expect(RecordingSettings.sampleRates(for: .heAAC) == [32_000, 44_100, 48_000])
        #expect(RecordingSettings(codec: .heAAC, sampleRate: 16_000).normalized().sampleRate == 48_000)
        #expect(RecordingSettings(codec: .heAAC, sampleRate: 22_050).normalized().sampleRate == 48_000)
        #expect(RecordingSettings(codec: .aacLC, sampleRate: 16_000).normalized().sampleRate == 16_000)
        // Lossless has no rate: the default is kept for when the codec changes back.
        #expect(RecordingSettings(codec: .appleLossless, bitRate: 24_000).normalized().bitRate == 64_000)
    }

    @Test func stereoNeedsAStereoInput() {
        let stereo = RecordingSettings(channels: .stereo)
        #expect(stereo.effectiveChannels(inputChannels: 1) == 1)
        #expect(stereo.effectiveChannels(inputChannels: 2) == 2)
        #expect(RecordingSettings(channels: .mono).effectiveChannels(inputChannels: 2) == 1)
    }

    @Test func sizePerHourFollowsTheBitRate() {
        // 64 kbit/s = 8000 B/s = 28.8 MB per hour.
        #expect(RecordingSettings().bytesPerHour() == 28_800_000)
        #expect(RecordingSettings(bitRate: 128_000).bytesPerHour() == 57_600_000)
        #expect(RecordingSettings(codec: .heAAC, bitRate: 24_000).bytesPerHour() == 10_800_000)
        // Lossless: half of 16-bit PCM, per channel.
        let alac = RecordingSettings(codec: .appleLossless, sampleRate: 48_000, channels: .stereo)
        #expect(alac.bytesPerHour(inputChannels: 2) == 48_000 * 2 * 2 * 3600 / 2)
        #expect(alac.bytesPerHour(inputChannels: 1) == 48_000 * 2 * 3600 / 2)
    }

    // MARK: Transcription

    @Test func transcriptionIsOffUntilTheUserOptsIn() {
        let d = scratch()
        #expect(!TranscriptionSettings.isEnabled(d))
        TranscriptionSettings.setEnabled(true, in: d)
        #expect(TranscriptionSettings.isEnabled(d))
    }

    @Test func transcriptionLocaleIsValidated() {
        let d = scratch()
        #expect(TranscriptionSettings.localeIdentifier(d) == nil)
        TranscriptionSettings.setLocaleIdentifier("es-MX", in: d)
        #expect(TranscriptionSettings.localeIdentifier(d) == "es-MX")
        TranscriptionSettings.setLocaleIdentifier("../../etc", in: d)
        #expect(TranscriptionSettings.localeIdentifier(d) == nil)
        d.set(String(repeating: "a", count: 200), forKey: TranscriptionSettings.localeKey)
        #expect(TranscriptionSettings.localeIdentifier(d) == nil)
        TranscriptionSettings.setLocaleIdentifier("en_US", in: d)
        TranscriptionSettings.setLocaleIdentifier(nil, in: d)
        #expect(TranscriptionSettings.localeIdentifier(d) == nil)
        #expect(TranscriptionSettings.offeredLocales(preferred: ["en-US", "en-US", "x y", "fr"]) == ["en-US", "fr"])
    }

    @Test func theDownloadButtonNeedsAMissingModelAndAnEngine() {
        typealias S = TranscriptionSettings.ModelStatus
        #expect(TranscriptionSettings.offersDownload(.notDownloaded, hasDownloader: true))
        #expect(!TranscriptionSettings.offersDownload(.notDownloaded, hasDownloader: false))
        for status in [S.installed, .unavailable, .downloading(fraction: nil)] {
            #expect(!TranscriptionSettings.offersDownload(status, hasDownloader: true))
        }
    }

    // MARK: New notes

    @Test func titleFormatDefaultsToDateAndTime() {
        let d = scratch()
        #expect(NewNoteSettings.titleFormat(d) == .dateAndTime)
        NewNoteSettings.setTitleFormat(.dateOnly, in: d)
        #expect(NewNoteSettings.titleFormat(d) == .dateOnly)
        d.set("nonsense", forKey: NewNoteSettings.titleFormatKey)
        #expect(NewNoteSettings.titleFormat(d) == .dateAndTime)
    }

    @Test func titlesFollowTheFormat() {
        let now = Date(timeIntervalSince1970: 1_791_383_400)   // 2026-10-07 14:30 UTC
        let utc = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        #expect(NewNoteSettings.title(.dateAndTime, now: now, locale: us, timeZone: utc).contains("2026"))
        #expect(NewNoteSettings.title(.dateAndTime, now: now, locale: us, timeZone: utc).contains(":"))
        let dateOnly = NewNoteSettings.title(.dateOnly, now: now, locale: us, timeZone: utc)
        #expect(dateOnly.contains("2026") && !dateOnly.contains(":"))
        #expect(NewNoteSettings.title(.blank, now: now, locale: us, timeZone: utc) == "")
    }

    /// TestFlight build 7: presets and a custom pattern, checked as it is
    /// typed (the rules `notes new --title-format` applies), only a good one stored.
    @Test func customPatternsAreChecked() {
        let d = scratch()
        let now = Date(timeIntervalSince1970: 1_791_383_400)   // 2026-10-07 14:30 UTC
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(NewNoteSettings.titlePattern(d) == NewNoteSettings.defaultTitlePattern)
        #expect(NewNoteSettings.setTitlePattern("'Lecture' d MMM", in: d) == nil)
        #expect(NewNoteSettings.titlePattern(d) == "'Lecture' d MMM")
        #expect(NewNoteSettings.setTitlePattern("'Lecture d MMM", in: d) == .unclosedQuote)
        #expect(NewNoteSettings.setTitlePattern("Lecture", in: d) == .unknownLetter("t"))
        #expect(NewNoteSettings.setTitlePattern("  ", in: d) == .blank)
        #expect(NewNoteSettings.titlePattern(d) == "'Lecture' d MMM", "the last good pattern stays")
        d.set("'broken", forKey: NewNoteSettings.titlePatternKey)
        #expect(NewNoteSettings.titlePattern(d) == NewNoteSettings.defaultTitlePattern)

        NewNoteSettings.setTitleFormat(.custom, in: d)
        NewNoteSettings.setTitlePattern("%Y-%m-%d", in: d)
        #expect(NewNoteSettings.resolvedTitle(typed: "", defaults: d).count == 10)
        #expect(NewNoteSettings.title(.custom, pattern: "'Note' yyyy", now: now, locale: posix, timeZone: utc) == "Note 2026")
        #expect(NewNoteSettings.title(.isoDateTime, now: now, locale: posix, timeZone: utc) == "2026-10-07 14:30")
        #expect(NewNoteSettings.title(.weekday, now: now, locale: posix, timeZone: utc) == "Wednesday 7 October")
    }

    @Test func aTypedTitleWinsOverTheFormat() {
        let d = scratch()
        NewNoteSettings.setTitleFormat(.blank, in: d)
        #expect(NewNoteSettings.resolvedTitle(typed: "  Physics  ", defaults: d) == "Physics")
        #expect(NewNoteSettings.resolvedTitle(typed: "   ", defaults: d) == "")
        NewNoteSettings.setTitleFormat(.dateOnly, in: d)
        #expect(!NewNoteSettings.resolvedTitle(typed: "", defaults: d).isEmpty)
    }
}
