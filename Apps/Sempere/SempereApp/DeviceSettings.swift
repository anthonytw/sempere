import Foundation
import Sempere

// The per-device settings of docs/attachments.md §15. Every one lives in
// `UserDefaults` on this device and never in the vault. Each type reads and
// writes a `UserDefaults` it is given (tests pass a scratch suite), clamps
// whatever is stored to a valid value, and holds the decided default.
// Pure Foundation: no UIKit, so the logic is typechecked on Linux.

// MARK: - Recording

/// The format new recordings are made in: *Recording* in the Settings panel.
/// The recorder reads `RecordingSettings.load()` when a recording starts;
/// `sempere attach recording` takes the same values as flags and never reads
/// these.
struct RecordingSettings: Hashable, Sendable {
    enum Codec: String, CaseIterable, Sendable, Identifiable {
        case aacLC = "aac"
        case heAAC = "he-aac"
        case appleLossless = "alac"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .aacLC: return "AAC-LC"
            case .heAAC: return "HE-AAC"
            case .appleLossless: return "Apple Lossless"
            }
        }
        /// Lossless audio has no bit rate to choose.
        var hasBitRate: Bool { self != .appleLossless }
    }

    enum Channels: Int, CaseIterable, Sendable, Identifiable {
        case mono = 1
        case stereo = 2

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .mono: return String(localized: "Mono", comment: "Recording channels: one channel (Settings picker)")
            case .stereo: return String(localized: "Stereo", comment: "Recording channels: two channels (Settings picker)")
            }
        }
    }

    static let defaultCodec = Codec.aacLC
    /// Bits per second (docs/attachments.md §16 decision 8).
    static let defaultBitRate = 64_000
    static let defaultSampleRate = 48_000
    static let defaultChannels = Channels.mono

    /// Bit rates offered, per second per channel pair as the encoder is told.
    static let bitRates = [24_000, 32_000, 48_000, 64_000, 96_000, 128_000]
    /// HE-AAC is a low-rate codec: it does not offer the top rates.
    static let heAACBitRates = [24_000, 32_000, 48_000, 64_000]
    static let sampleRates = [16_000, 22_050, 32_000, 44_100, 48_000]

    static let codecKey = "Sempere.recording.codec"
    static let bitRateKey = "Sempere.recording.bitRate"
    static let sampleRateKey = "Sempere.recording.sampleRate"
    static let channelsKey = "Sempere.recording.channels"

    var codec = defaultCodec
    var bitRate = defaultBitRate
    var sampleRate = defaultSampleRate
    var channels = defaultChannels

    /// The bit rates the settings offer for `codec`.
    static func bitRates(for codec: Codec) -> [Int] {
        switch codec {
        case .aacLC: return bitRates
        case .heAAC: return heAACBitRates
        case .appleLossless: return []
        }
    }

    /// The sample rates the settings offer for `codec`. HE-AAC needs at least
    /// 32 kHz (`RecordingFormat.normalized` records lower rates at 48 kHz).
    static func sampleRates(for codec: Codec) -> [Int] {
        codec == .heAAC ? sampleRates.filter { $0 >= 32_000 } : sampleRates
    }

    /// The stored settings, each field replaced by its default or nearest
    /// offered value when missing or not one of the choices.
    static func load(from defaults: UserDefaults = .standard) -> RecordingSettings {
        var s = RecordingSettings()
        if let raw = defaults.string(forKey: codecKey), let c = Codec(rawValue: raw) { s.codec = c }
        if let r = defaults.object(forKey: sampleRateKey) as? Int, sampleRates.contains(r) { s.sampleRate = r }
        if let c = defaults.object(forKey: channelsKey) as? Int, let ch = Channels(rawValue: c) { s.channels = ch }
        if let b = defaults.object(forKey: bitRateKey) as? Int { s.bitRate = b }
        return s.normalized()
    }

    func save(to defaults: UserDefaults = .standard) {
        let n = normalized()
        defaults.set(n.codec.rawValue, forKey: Self.codecKey)
        defaults.set(n.bitRate, forKey: Self.bitRateKey)
        defaults.set(n.sampleRate, forKey: Self.sampleRateKey)
        defaults.set(n.channels.rawValue, forKey: Self.channelsKey)
    }

    /// Fields forced onto the choices: a bit rate the codec does not offer
    /// becomes the nearest one it does (the default when the codec has none),
    /// a sample rate the codec does not offer becomes the default (48 kHz, as
    /// `RecordingFormat.normalized` records HE-AAC below 32 kHz).
    func normalized() -> RecordingSettings {
        var s = self
        if !Self.sampleRates(for: s.codec).contains(s.sampleRate) { s.sampleRate = Self.defaultSampleRate }
        let offered = Self.bitRates(for: s.codec)
        // Clamped first: the difference below must not overflow for a stored Int.min or Int.max.
        let wanted = min(max(s.bitRate, 0), 1 << 30)
        if let nearest = offered.min(by: { abs($0 - wanted) < abs($1 - wanted) }) {
            s.bitRate = nearest
        } else {
            s.bitRate = Self.defaultBitRate
        }
        return s
    }

    /// The channel count a recording uses: stereo only when chosen *and* the
    /// input has two channels (docs/attachments.md §15).
    func effectiveChannels(inputChannels: Int) -> Int {
        channels == .stereo && inputChannels >= 2 ? 2 : 1
    }

    /// Estimated bytes of one hour of audio.
    ///
    /// AAC and HE-AAC are constant-rate in effect: `bitRate / 8 × 3600`
    /// (the rate is for the whole stream, not per channel). Apple Lossless
    /// has no rate: speech compresses to about half of 16-bit PCM, so
    /// `sampleRate × 2 bytes × channels × 3600 / 2`, an estimate only. The
    /// arithmetic is in `Int64` and every operand is bounded by the choice
    /// lists, so nothing overflows.
    func bytesPerHour(inputChannels: Int = 1) -> Int64 {
        let n = normalized()
        if n.codec.hasBitRate { return Int64(n.bitRate) / 8 * 3600 }
        return Int64(n.sampleRate) * 2 * Int64(n.effectiveChannels(inputChannels: inputChannels)) * 3600 / 2
    }

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

/// *Transcription*: on-device, opt-in (docs/attachments.md §16 decision 9).
enum TranscriptionSettings {
    static let enabledKey = "Sempere.transcription.enabled"
    static let localeKey = "Sempere.transcription.locale"
    /// Opt-in: nothing is transcribed until the user turns it on.
    static let defaultEnabled = false

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// The stored locale identifier, or nil for "same as the device". An
    /// identifier that is not a well-formed BCP 47 / ICU tag reads as nil.
    static func localeIdentifier(_ defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: localeKey), isWellFormed(id) else { return nil }
        return id
    }

    static func setLocaleIdentifier(_ id: String?, in defaults: UserDefaults = .standard) {
        if let id, isWellFormed(id) { defaults.set(id, forKey: localeKey) } else { defaults.removeObject(forKey: localeKey) }
    }

    /// Letters, digits and `-`/`_` only, at most 35 characters, starting with a letter.
    static func isWellFormed(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (1...35).contains(scalars.count), scalars[0].isASCII, scalars[0].properties.isAlphabetic else { return false }
        return scalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-" || $0 == "_") }
    }

    /// Languages the picker offers: the device's preferred ones, in order, without repeats.
    static func offeredLocales(preferred: [String] = Locale.preferredLanguages) -> [String] {
        var seen = Set<String>()
        return preferred.filter { isWellFormed($0) && seen.insert($0).inserted }
    }

    /// Whether the recognition model for a locale is on the device.
    enum ModelStatus: Equatable, Sendable {
        /// The transcription engine is not part of this build or OS.
        case unavailable
        case notDownloaded
        case downloading(fraction: Double?)
        case installed

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

    /// Starts downloading the model; nil when no engine is installed
    /// (`TranscriptionPreference.installSettingsHooks` sets it at launch).
    @MainActor static var downloader: (@Sendable (String?) async throws -> Void)?

    /// Whether Settings offers the download button: the model is missing and an engine can fetch it.
    static func offersDownload(_ status: ModelStatus, hasDownloader: Bool) -> Bool {
        status == .notDownloaded && hasDownloader
    }
}

// MARK: - Device keys

/// *Device keys*: how recipient changes rewrap attachments (format.md §8.1.5).
enum RewrapSettings {
    static let onAddKey = "Sempere.rewrap.onAdd"
    static let onRemoveKey = "Sempere.rewrap.onRemoveOrUpgrade"

    static func onAdd(_ defaults: UserDefaults = .standard) -> RewrapMethod {
        defaults.string(forKey: onAddKey).flatMap(RewrapMethod.init(rawValue:)) ?? RewrapPolicy().onAdd
    }

    static func onRemoveOrUpgrade(_ defaults: UserDefaults = .standard) -> RewrapMethod {
        defaults.string(forKey: onRemoveKey).flatMap(RewrapMethod.init(rawValue:)) ?? RewrapPolicy().onRemoveOrTypeChange
    }

    static func setOnAdd(_ m: RewrapMethod, in defaults: UserDefaults = .standard) { defaults.set(m.rawValue, forKey: onAddKey) }
    static func setOnRemoveOrUpgrade(_ m: RewrapMethod, in defaults: UserDefaults = .standard) {
        defaults.set(m.rawValue, forKey: onRemoveKey)
    }

    /// What `Vault.addRecipient` / `removeRecipient` / `replaceRecipient` get.
    static func policy(_ defaults: UserDefaults = .standard) -> RewrapPolicy {
        RewrapPolicy(onAdd: onAdd(defaults), onRemoveOrTypeChange: onRemoveOrUpgrade(defaults))
    }

    /// Header-only after a removal leaves the removed key able to open old
    /// copies of every attachment: choosing it needs a warning and a confirmation.
    static func needsConfirmation(forRemoval method: RewrapMethod) -> Bool { method == .headerOnly }

    /// What choosing `chosen` in the "When Removing a Device or Upgrading" picker does
    /// while `current` is set: header-only (when not already set) waits for the
    /// confirmation dialog, anything else is applied and stored at once.
    enum RemovalStep: Equatable { case confirm, apply }

    static func removalStep(choosing chosen: RewrapMethod, current: RewrapMethod) -> RemovalStep {
        needsConfirmation(forRemoval: chosen) && chosen != current ? .confirm : .apply
    }

    static func title(_ m: RewrapMethod) -> String {
        m == .headerOnly
            ? String(localized: "Rewrite headers only", comment: "Settings ▸ Device Keys: how attachments are rewrapped (picker choice)")
            : String(localized: "Re-encrypt everything", comment: "Settings ▸ Device Keys: how attachments are rewrapped (picker choice)")
    }
}

// MARK: - New notes

/// *New notes*: the title a note gets when the user gives none and (with
/// `PaperPreference`) the paper. The notebook of quick voice notes is a
/// Quick Voice Notes setting (the capture profile); `LegacyVoiceNotebook`
/// carries over what older builds stored here.
enum NewNoteSettings {
    /// The title presets, and `custom` (the user's own pattern, `titlePattern`).
    enum TitleFormat: String, CaseIterable, Sendable, Identifiable {
        case dateAndTime
        case dateOnly
        /// `2026-10-07 14:30`: sorts by date.
        case isoDateTime
        /// `Wednesday 7 October`.
        case weekday
        case custom
        case blank

        var id: String { rawValue }
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

        /// The pattern of a fixed preset (`DefaultTitle`); nil for the locale's styles, custom and blank.
        var pattern: String? {
            switch self {
            case .isoDateTime: return "yyyy-MM-dd HH:mm"
            case .weekday: return "EEEE d MMMM"
            default: return nil
            }
        }
    }

    static let titleFormatKey = "Sempere.newNote.titleFormat"
    /// The custom pattern (`TitleFormat.custom`): a Unicode date pattern or a
    /// strftime format, checked by `DefaultTitle.check` (as `notes new
    /// --title-format` is) before it is stored.
    static let titlePatternKey = "Sempere.newNote.titlePattern"
    static let defaultTitlePattern = "yyyy-MM-dd HH:mm"
    static let defaultTitleFormat = TitleFormat.dateAndTime

    static func titleFormat(_ defaults: UserDefaults = .standard) -> TitleFormat {
        defaults.string(forKey: titleFormatKey).flatMap(TitleFormat.init(rawValue:)) ?? defaultTitleFormat
    }

    static func setTitleFormat(_ f: TitleFormat, in defaults: UserDefaults = .standard) {
        defaults.set(f.rawValue, forKey: titleFormatKey)
    }

    /// The stored custom pattern; the default one when none (or one that
    /// does not check, written by an older build) is stored.
    static func titlePattern(_ defaults: UserDefaults = .standard) -> String {
        guard let p = defaults.string(forKey: titlePatternKey), !p.isEmpty, DefaultTitle.check(p) == nil else {
            return defaultTitlePattern
        }
        return p
    }

    /// Stores `pattern` as the custom pattern when it can be used; returns why
    /// not otherwise (nothing is stored: the last good one stays).
    @discardableResult
    static func setTitlePattern(_ pattern: String, in defaults: UserDefaults = .standard) -> DefaultTitle.Problem? {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        if let problem = DefaultTitle.check(pattern) { return problem }
        defaults.set(pattern, forKey: titlePatternKey)
        return nil
    }

    /// The title for a note made at `now` in `format`: "Oct 7, 2026 at 2:30 PM",
    /// "Oct 7, 2026", "2026-10-07 14:30", "Wednesday 7 October", the custom
    /// `pattern`'s, or "" (shown as "Untitled").
    static func title(_ format: TitleFormat, pattern: String? = nil, now: Date = Date(), locale: Locale = .current,
                      timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        switch format {
        case .blank: return ""
        case .dateOnly:
            f.dateStyle = .medium
            f.timeStyle = .none
        case .dateAndTime:
            f.dateStyle = .medium
            f.timeStyle = .short
        case .isoDateTime, .weekday, .custom:
            let p = format == .custom ? (pattern ?? defaultTitlePattern) : format.pattern
            return DefaultTitle.title(at: now, format: p, locale: locale, timeZone: timeZone)
        }
        return f.string(from: now)
    }

    /// The title the stored setting gives a note made at `now`.
    static func defaultTitle(_ defaults: UserDefaults = .standard, now: Date = Date()) -> String {
        title(titleFormat(defaults), pattern: titlePattern(defaults), now: now)
    }

    /// `typed` when the user typed a title, else the stored format's.
    static func resolvedTitle(typed: String, defaults: UserDefaults = .standard, now: Date = Date()) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultTitle(defaults, now: now) : t
    }
}

/// The notebook of quick voice notes used to be a second field, in Settings ▸
/// New Notes, that nothing read: capture uses the notebook of its profile
/// (Settings ▸ Quick Voice Notes). The profile is the one setting now; a value
/// an older build stored under this key is applied to the profile once
/// (`AppModel.migrateLegacyVoiceNotebook`, `enableQuickCapture`) and removed.
enum LegacyVoiceNotebook {
    static let key = "Sempere.newNote.voiceNotebook"

    /// The stored notebook, canonical; nil when none was stored (or it is blank).
    static func value(_ defaults: UserDefaults = .standard) -> String? {
        NotebookPath.canonical(defaults.string(forKey: key))
    }

    static func remove(from defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
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

/// The unused attachments of Settings → Storage, by note: notes by title,
/// each note's items biggest first.
enum UnusedAttachmentGroups {
    struct Group: Identifiable, Equatable {
        var note: UUID
        var title: String
        var items: [AttachmentStorageReport.Unused]
        var id: UUID { note }
    }

    static func group(_ items: [AttachmentStorageReport.Unused], title: (UUID) -> String) -> [Group] {
        Dictionary(grouping: items, by: \.note)
            .map { Group(note: $0.key, title: title($0.key), items: $0.value.sorted { ($1.bytes, $0.id) < ($0.bytes, $1.id) }) }
            .sorted { ($0.title.lowercased(), $0.note.uuidString) < ($1.title.lowercased(), $1.note.uuidString) }
    }
}
