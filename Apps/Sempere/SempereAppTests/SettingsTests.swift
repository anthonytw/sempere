import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The Settings panel's settings (docs/attachments.md §15): defaults, valid
/// choices, persistence in `UserDefaults`, and the behaviour each one drives.
@MainActor
@Suite(.serialized)
struct SettingsTests {
    /// An empty defaults suite (one fixed name, emptied per use; the suite runs serially).
    func scratch() -> UserDefaults {
        let name = "sempere-settings-tests"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Recording

    @Test func recordingDefaultsAreTheDecidedPolicy() {
        let s = RecordingSettings.load(from: scratch())
        #expect(s.codec == .aacLC)
        #expect(s.bitRate == 64_000)
        #expect(s.sampleRate == 48_000)
        #expect(s.channels == .mono)
    }

    /// Sample rates are numbers in the device's format (docs/localization.md rule 8).
    @Test func sampleRateLabelsFollowTheLocale() {
        #expect(RecordingSettings.label(sampleRate: 48_000, locale: Locale(identifier: "en_US")) == "48 kHz")
        #expect(RecordingSettings.label(sampleRate: 22_050, locale: Locale(identifier: "en_US")) == "22.05 kHz")
        #expect(RecordingSettings.label(sampleRate: 22_050, locale: Locale(identifier: "es_ES")) == "22,05 kHz")
        #expect(RecordingSettings.label(sampleRate: 44_100, locale: Locale(identifier: "es_ES")) == "44,1 kHz")
    }

    @Test func recordingSettingsRoundTrip() {
        let d = scratch()
        RecordingSettings(codec: .heAAC, bitRate: 32_000, sampleRate: 44_100, channels: .stereo).save(to: d)
        let s = RecordingSettings.load(from: d)
        #expect(s == RecordingSettings(codec: .heAAC, bitRate: 32_000, sampleRate: 44_100, channels: .stereo))
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
        #expect(RecordingSettings().sizePerHourText().hasPrefix("About "))
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

    @Test func modelStatusText() {
        typealias S = TranscriptionSettings.ModelStatus
        #expect(S.installed.text == "Downloaded")
        #expect(S.notDownloaded.text == "Not downloaded")
        #expect(S.downloading(fraction: 0.5).text == "Downloading… 50 %")
        #expect(S.downloading(fraction: .nan).text == "Downloading…")
        #expect(S.downloading(fraction: 7).text == "Downloading… 100 %")
        #expect(S.unavailable.text == "Not available on this device")
    }

    /// GA-05: the launch hook installs the download, and the button shows only when the model is missing.
    @MainActor @Test func theDownloadButtonNeedsAMissingModelAndAnEngine() {
        typealias S = TranscriptionSettings.ModelStatus
        let saved = TranscriptionSettings.downloader
        defer { TranscriptionSettings.downloader = saved }
        TranscriptionSettings.downloader = nil
        TranscriptionPreference.installSettingsHooks()
        #expect(TranscriptionSettings.downloader != nil, "the launch hook wires the download")
        #expect(TranscriptionSettings.offersDownload(.notDownloaded, hasDownloader: true))
        #expect(!TranscriptionSettings.offersDownload(.notDownloaded, hasDownloader: false))
        for status in [S.installed, .unavailable, .downloading(fraction: nil)] {
            #expect(!TranscriptionSettings.offersDownload(status, hasDownloader: true))
        }
    }

    // MARK: Photos

    @Test func photoPrivacyIsOnByDefault() {
        let d = scratch()
        #expect(PhotoPrivacy.isOn(d))
        d.set(false, forKey: PhotoPrivacy.key)
        #expect(!PhotoPrivacy.isOn(d))
    }

    // MARK: Device keys

    @Test func rewrapDefaultsAreTheDecidedPolicy() {
        let d = scratch()
        #expect(RewrapSettings.onAdd(d) == .headerOnly)
        #expect(RewrapSettings.onRemoveOrUpgrade(d) == .reencrypt)
        #expect(RewrapSettings.policy(d) == RewrapPolicy())
    }

    @Test func rewrapChoicesFeedThePolicy() {
        let d = scratch()
        RewrapSettings.setOnAdd(.reencrypt, in: d)
        RewrapSettings.setOnRemoveOrUpgrade(.headerOnly, in: d)
        let policy = RewrapSettings.policy(d)
        #expect(policy.onAdd == .reencrypt)
        #expect(policy.onRemoveOrTypeChange == .headerOnly)
        d.set("garbage", forKey: RewrapSettings.onAddKey)
        #expect(RewrapSettings.onAdd(d) == .headerOnly)
    }

    @Test func onlyHeaderOnlyRemovalNeedsConfirmation() {
        #expect(RewrapSettings.needsConfirmation(forRemoval: .headerOnly))
        #expect(!RewrapSettings.needsConfirmation(forRemoval: .reencrypt))
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
    @Test func customPatternsAreCheckedAndPreviewed() {
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

        #expect(TitlePatternField.status(of: "'Day' d, EEE", now: now, locale: posix, timeZone: utc) == .preview("Day 7, Wed"))
        guard case .problem(let message) = TitlePatternField.status(of: "Lesson d", now: now, locale: posix, timeZone: utc) else {
            Issue.record("no problem reported")
            return
        }
        #expect(message.contains("single quotes"))
        #expect(TitlePatternField.status(of: "", now: now) != .preview(""))
        for field in TitlePatternField.fields { #expect(DefaultTitle.check(field.pattern) == nil, "\(field.name)") }
    }

    @Test func aTypedTitleWinsOverTheFormat() {
        let d = scratch()
        NewNoteSettings.setTitleFormat(.blank, in: d)
        #expect(NewNoteSettings.resolvedTitle(typed: "  Physics  ", defaults: d) == "Physics")
        #expect(NewNoteSettings.resolvedTitle(typed: "   ", defaults: d) == "")
        NewNoteSettings.setTitleFormat(.dateOnly, in: d)
        #expect(!NewNoteSettings.resolvedTitle(typed: "", defaults: d).isEmpty)
    }

    @Test func defaultPaperIsRemembered() {
        let d = scratch()
        #expect(PaperPreference.load(from: d) == PaperPreference.fallback)
        var grid = PaperPreference.fallback
        grid.kind = .grid
        PaperPreference.save(grid, to: d)
        #expect(PaperPreference.load(from: d).kind == .grid)
    }

    // MARK: General and history

    @Test func generalSettingsKeepTheirKeysAndDefaults() {
        #expect(KeepScreenOn.key == "Sempere.keepScreenOn")
        #expect(RecognitionPreference.key == "Sempere.recognizeHandwriting")
        // What the app reads when nothing is stored, then a stored choice.
        let d = scratch()
        #expect(!KeepScreenOn.defaultValue && !KeepScreenOn.isOn(d), "off unless set")
        #expect(RecognitionPreference.defaultValue && RecognitionPreference.isEnabled(d), "on unless set")
        d.set(true, forKey: KeepScreenOn.key)
        d.set(false, forKey: RecognitionPreference.key)
        #expect(KeepScreenOn.isOn(d))
        #expect(!RecognitionPreference.isEnabled(d))
    }

    @Test func recognitionSwitchReachesTheModel() {
        let saved = RecognitionPreference.enabled
        defer { RecognitionPreference.enabled = saved }
        let model = AppModel()
        model.setHandwritingRecognition(true)
        #expect(model.recognizer != nil && RecognitionPreference.enabled)
        model.setHandwritingRecognition(false)
        #expect(model.recognizer == nil && !RecognitionPreference.enabled)
    }

    @Test func thinningDefaultsToThirtyDaysAndNeverIsOffered() {
        #expect(ThinningPreference.defaultDays == 30)
        #expect(ThinningPreference.choices.contains(30) && ThinningPreference.choices.contains(0))
        #expect(ThinningPreference.label(0) == "Never")
    }

    // MARK: Menu

    @Test func settingsAreInTheMenuWithCommandComma() {
        #expect(MenuCommand.showSettings.shortcut == MenuCommand.Shortcut(",", [.command]))
        #expect(MenuLayout.all.contains(.showSettings))
        // Device settings need no vault.
        for vault in [MenuCommand.Context.Vault.none, .locked, .unlocked] {
            var c = MenuCommand.Context()
            c.vault = vault
            #expect(MenuCommand.showSettings.isEnabled(in: c))
        }
    }

    // MARK: Storage

    @Test func storageTextFormats() {
        #expect(StorageText.items(1, bytes: 0).hasPrefix("1 item, "))
        #expect(StorageText.items(3, bytes: 5_000_000).hasPrefix("3 items, "))
        #expect(StorageText.bytes(-5) == StorageText.bytes(0))
    }

    @Test func storageNeedsAnUnlockedVault() async throws {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        await #expect(throws: AppModel.ModelError.noVaultOpen) { _ = try await model.deleteUnusedAttachments([]) }
        #expect(model.attachmentStorage().unused.isEmpty)
        // Unused attachments themselves: `AttachmentIndexAppTests`.
    }

    @Test func clearCachesEmptiesBothCachesAndKeepsTheVault() async throws {
        let root = DrawingCacheTests.tempDir()
        let (model, url, _) = try await DrawingCacheTests.model(root: root)
        #expect(await model.cacheSizes() == CacheSizes())
        let cache = try #require(await model.openDrawingCache())
        let key = try DrawingCacheTests.key(url, DrawingCacheTests.lecture)
        cache.store(drawing: Data(repeating: 7, count: 4096), for: key, page: UUID())
        #expect(await model.cacheSizes().drawings > 0)
        let before = model.notes.count
        await model.clearCaches()
        #expect(await model.cacheSizes() == CacheSizes())
        #expect(model.blobCache == nil)
        #expect(!cache.isClosed, "the cache stays usable")
        cache.store(drawing: Data(repeating: 7, count: 4096), for: key, page: UUID())
        #expect(await model.cacheSizes().drawings > 0)
        #expect(model.notes.count == before)
    }
}
