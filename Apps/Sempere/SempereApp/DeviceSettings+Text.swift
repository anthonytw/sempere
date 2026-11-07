import Foundation
import Sempere
import SempereAppCore

// The device settings' wording (docs/attachments.md §15) and the transcription hooks the app installs at launch.
// The settings themselves, their keys, defaults and clamping, are `DeviceSettings.swift` in SempereAppCore.

// MARK: - Recording

extension RecordingSettings.Codec {
    var title: String {
        switch self {
        case .aacLC: return "AAC-LC"
        case .heAAC: return "HE-AAC"
        case .appleLossless: return "Apple Lossless"
        }
    }
}

extension RecordingSettings.Channels {
    var title: String {
        switch self {
        case .mono: return String(localized: "Mono", comment: "Recording channels: one channel (Settings picker)")
        case .stereo: return String(localized: "Stereo", comment: "Recording channels: two channels (Settings picker)")
        }
    }
}

extension RecordingSettings {
    /// "Quality" row label: "64 kbit/s".
    static func label(bitRate: Int) -> String { "\(bitRate / 1000) kbit/s" }
    /// "48 kHz", "22.05 kHz" ("22,05 kHz" in Spanish): the number in `locale`'s format.
    static func label(sampleRate: Int, locale: Locale = .current) -> String {
        let khz = (Double(sampleRate) / 1000).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return "\(khz) kHz" // l10n:ignore: a number and a unit symbol
    }

    /// "About 29 MB per hour".
    func sizePerHourText(inputChannels: Int = 1) -> String {
        let size = StorageText.bytes(bytesPerHour(inputChannels: inputChannels))
        return String(localized: "About \(size) per hour", comment: "Settings ▸ Recording ▸ Size: estimated file size of one hour of audio, e.g. 28.8 MB")
    }
}

// MARK: - Transcription

extension TranscriptionSettings.ModelStatus {
    var text: String {
        switch self {
        case .unavailable: return String(localized: "Not available on this device", comment: "Transcription language model status")
        case .notDownloaded: return String(localized: "Not downloaded", comment: "Transcription language model status")
        case .downloading(let f):
            guard let f, f.isFinite else { return String(localized: "Downloading…", comment: "Transcription language model status") }
            let percent = Int((min(max(f, 0), 1)) * 100)
            return String(localized: "Downloading… \(percent) %", comment: "Transcription language model status with percent done")
        case .installed: return String(localized: "Downloaded", comment: "Transcription language model status: installed on the device")
        }
    }
}

extension TranscriptionSettings {
    /// Asks the engine for the model status of a locale (nil: the device's).
    /// The transcription feature installs the real lookup at launch; until
    /// then the Settings panel shows `unavailable`.
    @MainActor static var statusProvider: @Sendable (String?) async -> ModelStatus = { _ in .unavailable }
    /// One speech engine as the panel lists it: its name, what it says for the chosen language, and
    /// whether transcription would use it (the first available one, as `SpeechTranscription.transcribe` tries them).
    struct EngineLine: Equatable, Sendable {
        var title: String
        var state: String
        var available: Bool
        var isUsed: Bool
    }

    /// Asks the engines for their status for a locale (nil: the device's), for the panel's engine list.
    @MainActor static var enginesProvider: @Sendable (String?) async -> [EngineLine] = { _ in [] }
    /// The one line under the Preferred Language picker: which engine the app chose for a locale.
    @MainActor static var engineNoteProvider: @Sendable (String?) async -> String = { _ in "" }

    /// Starts downloading the model; nil when no engine is installed
    /// (`TranscriptionPreference.installSettingsHooks` sets it at launch).
    @MainActor static var downloader: (@Sendable (String?) async throws -> Void)?
}

// MARK: - New notes

extension NewNoteSettings.TitleFormat {
    var title: String {
        switch self {
        case .dateAndTime: return String(localized: "Date and Time", comment: "Settings ▸ New Notes ▸ Title: default title is the date and time")
        case .dateOnly: return String(localized: "Date", comment: "Settings ▸ New Notes ▸ Title: default title is the date")
        case .isoDateTime: return String(localized: "Year-Month-Day Time", comment: "Settings ▸ New Notes ▸ Title: 2026-10-07 14:30")
        case .weekday: return String(localized: "Weekday and Date", comment: "Settings ▸ New Notes ▸ Title: Wednesday 7 October")
        case .custom: return String(localized: "Custom", comment: "Settings ▸ New Notes ▸ Title: the user's own date pattern")
        case .blank: return String(localized: "Untitled", comment: "Settings ▸ New Notes ▸ Title: new notes get no title (shown as Untitled)")
        }
    }
}

// MARK: - Storage

/// Sizes shown under *Storage*.
enum StorageText {
    /// "12.3 MB", "Zero KB".
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: max(n, 0))
    }

    /// "3 items, 12.3 MB".
    static func items(_ count: Int, bytes n: Int64) -> String {
        let size = bytes(n)
        return String(localized: "\(count) items, \(size)", comment: "Settings ▸ Storage: number of unused attachments and their total size")
    }

    /// "in 3 versions": how many versions of its note still show a held attachment.
    static func versions(_ count: Int) -> String {
        String(localized: "in \(count) versions", comment: "Settings ▸ Storage ▸ Held by History: how many versions of the note show it")
    }

    /// "12 Oct 2026" (the day, in this device's calendar and language).
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Where an unused attachment stands in the 30-day window at `now`:
    /// "Unused since 7 Oct 2026" plus "can be deleted from 6 Nov 2026" until then.
    static func window(_ item: AttachmentStorageReport.Unused, now: Date) -> String {
        let since = day(item.firstSeen)
        return item.isEligible(at: now) ? String(localized: "Unused since \(since)")
            : String(localized: "Unused since \(since); can be deleted from \(day(item.deletableFrom))")
    }

    /// "Recording, 0:24" / "Image" / "PDF": what an attachment is, with an
    /// audio item's duration and title from the last revision that had it.
    static func describe(kind: BlobKind, lastUse: AttachmentIndexEntry.LastUse?) -> String {
        let name: String
        switch kind {
        case .image: name = String(localized: "Image", comment: "Attachment kind in the unused attachments list")
        case .pdf: name = String(localized: "PDF", comment: "Attachment kind in the unused attachments list")
        case .audio: name = String(localized: "Recording")
        case .video: name = String(localized: "Video")
        case .transcript: name = String(localized: "Transcript")
        default: name = String(localized: "File", comment: "Attachment kind in the unused attachments list: anything else")
        }
        var parts = [name]
        if kind == .audio || kind == .video, let d = lastUse?.duration, d.isFinite, d >= 0, d < 1e7 {
            parts.append(Transcript.clock(d.rounded()))
        }
        if let title = lastUse?.title, !title.isEmpty { parts.append(String(localized: "“\(title)”", comment: "A recording's title in quotes")) }
        return parts.joined(separator: ", ")
    }
}
