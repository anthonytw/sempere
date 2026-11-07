import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// The Settings panel (docs/attachments.md §15): the settings' wording and the behavior each one drives in
/// the app. Their defaults, choices and storage: `DeviceSettingsTests` (SempereAppCoreTests).
@MainActor
@Suite(.serialized)
struct SettingsTests {
    /// An empty defaults suite (one fixed name, emptied per use; the suite runs serially).
    func scratch() -> UserDefaults {
        let name = "sempere-settings-tests"
        let d = TestDefaults.suite(name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Recording (the settings themselves: `DeviceSettingsTests`, SempereAppCoreTests)

    /// Sample rates are numbers in the device's format (docs/localization.md rule 8).
    @Test func sampleRateLabelsFollowTheLocale() {
        #expect(RecordingSettings.label(sampleRate: 48_000, locale: Locale(identifier: "en_US")) == "48 kHz")
        #expect(RecordingSettings.label(sampleRate: 22_050, locale: Locale(identifier: "en_US")) == "22.05 kHz")
        #expect(RecordingSettings.label(sampleRate: 22_050, locale: Locale(identifier: "es_ES")) == "22,05 kHz")
        #expect(RecordingSettings.label(sampleRate: 44_100, locale: Locale(identifier: "es_ES")) == "44,1 kHz")
    }

    @Test func sizePerHourIsWorded() {
        #expect(RecordingSettings().sizePerHourText().hasPrefix("About "))
    }

    // MARK: Transcription

    @Test func modelStatusText() {
        typealias S = TranscriptionSettings.ModelStatus
        #expect(S.installed.text == "Downloaded")
        #expect(S.notDownloaded.text == "Not downloaded")
        #expect(S.downloading(fraction: 0.5).text == "Downloading… 50 %")
        #expect(S.downloading(fraction: .nan).text == "Downloading…")
        #expect(S.downloading(fraction: 7).text == "Downloading… 100 %")
        #expect(S.unavailable.text == "Not available on this device")
    }

    /// GA-05: the launch hook installs the download.
    @MainActor @Test func theLaunchHookInstallsTheDownload() {
        let saved = TranscriptionSettings.downloader
        defer { TranscriptionSettings.downloader = saved }
        TranscriptionSettings.downloader = nil
        TranscriptionPreference.installSettingsHooks()
        #expect(TranscriptionSettings.downloader != nil, "the launch hook wires the download")
        // When the button shows: `DeviceSettingsTests.theDownloadButtonNeedsAMissingModelAndAnEngine`.
    }

    // MARK: New notes (the settings themselves: `DeviceSettingsTests`, SempereAppCoreTests)

    /// TestFlight build 7: the custom pattern is checked as it is typed and previewed.
    @Test func customPatternsArePreviewed() {
        let now = Date(timeIntervalSince1970: 1_791_383_400)   // 2026-10-07 14:30 UTC
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(TitlePatternField.status(of: "'Day' d, EEE", now: now, locale: posix, timeZone: utc) == .preview("Day 7, Wed"))
        guard case .problem(let message) = TitlePatternField.status(of: "Lesson d", now: now, locale: posix, timeZone: utc) else {
            Issue.record("no problem reported")
            return
        }
        #expect(message.contains("single quotes"))
        #expect(TitlePatternField.status(of: "", now: now) != .preview(""))
        for field in TitlePatternField.fields { #expect(DefaultTitle.check(field.pattern) == nil, "\(field.name)") }
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
