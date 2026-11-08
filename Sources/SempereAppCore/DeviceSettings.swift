import Foundation
import Sempere

// The per-device settings of docs/attachments.md §15. Every one lives in
// `UserDefaults` on this device and never in the vault. Each type reads and
// writes the `KeyValueStore` it is given (the app's `UserDefaults.standard`, tests
// a `MemoryKeyValueStore`), clamps whatever is stored to a valid value, and holds
// the decided default. No text: the app words the choices (`DeviceSettings+Text.swift`).

// MARK: - Recording

/// The format new recordings are made in: *Recording* in the Settings panel.
/// The recorder reads `RecordingSettings.load(from:)` when a recording starts;
/// `sempere attach recording` takes the same values as flags and never reads
/// these.
public struct RecordingSettings: Hashable, Sendable {
    public enum Codec: String, CaseIterable, Sendable, Identifiable {
        case aacLC = "aac"
        case heAAC = "he-aac"
        case appleLossless = "alac"

        public var id: String { rawValue }
        /// Lossless audio has no bit rate to choose.
        public var hasBitRate: Bool { self != .appleLossless }
    }

    public enum Channels: Int, CaseIterable, Sendable, Identifiable {
        case mono = 1
        case stereo = 2

        public var id: Int { rawValue }
    }

    public static let defaultCodec = Codec.aacLC
    /// Bits per second (docs/attachments.md §16 decision 8).
    public static let defaultBitRate = 64_000
    public static let defaultSampleRate = 48_000
    public static let defaultChannels = Channels.mono

    /// Bit rates offered, per second per channel pair as the encoder is told.
    public static let bitRates = [24_000, 32_000, 48_000, 64_000, 96_000, 128_000]
    /// HE-AAC is a low-rate codec: it does not offer the top rates.
    public static let heAACBitRates = [24_000, 32_000, 48_000, 64_000]
    public static let sampleRates = [16_000, 22_050, 32_000, 44_100, 48_000]

    public static let codecKey = "Sempere.recording.codec"
    public static let bitRateKey = "Sempere.recording.bitRate"
    public static let sampleRateKey = "Sempere.recording.sampleRate"
    public static let channelsKey = "Sempere.recording.channels"

    public var codec = defaultCodec
    public var bitRate = defaultBitRate
    public var sampleRate = defaultSampleRate
    public var channels = defaultChannels

    public init(codec: Codec = defaultCodec, bitRate: Int = defaultBitRate, sampleRate: Int = defaultSampleRate,
                channels: Channels = defaultChannels) {
        self.codec = codec
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// The bit rates the settings offer for `codec`.
    public static func bitRates(for codec: Codec) -> [Int] {
        switch codec {
        case .aacLC: return bitRates
        case .heAAC: return heAACBitRates
        case .appleLossless: return []
        }
    }

    /// The sample rates the settings offer for `codec`. HE-AAC needs at least
    /// 32 kHz (`RecordingFormat.normalized` records lower rates at 48 kHz).
    public static func sampleRates(for codec: Codec) -> [Int] {
        codec == .heAAC ? sampleRates.filter { $0 >= 32_000 } : sampleRates
    }

    /// The stored settings, each field replaced by its default or nearest
    /// offered value when missing or not one of the choices.
    public static func load(from defaults: any KeyValueStore) -> RecordingSettings {
        var s = RecordingSettings()
        if let raw = defaults.string(forKey: codecKey), let c = Codec(rawValue: raw) { s.codec = c }
        if let r = defaults.object(forKey: sampleRateKey) as? Int, sampleRates.contains(r) { s.sampleRate = r }
        if let c = defaults.object(forKey: channelsKey) as? Int, let ch = Channels(rawValue: c) { s.channels = ch }
        if let b = defaults.object(forKey: bitRateKey) as? Int { s.bitRate = b }
        return s.normalized()
    }

    public func save(to defaults: any KeyValueStore) {
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
    public func normalized() -> RecordingSettings {
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
    public func effectiveChannels(inputChannels: Int) -> Int {
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
    public func bytesPerHour(inputChannels: Int = 1) -> Int64 {
        let n = normalized()
        if n.codec.hasBitRate { return Int64(n.bitRate) / 8 * 3600 }
        return Int64(n.sampleRate) * 2 * Int64(n.effectiveChannels(inputChannels: inputChannels)) * 3600 / 2
    }
}

// MARK: - Transcription

/// *Transcription*: on-device, opt-in (docs/attachments.md §16 decision 9).
public enum TranscriptionSettings {
    public static let enabledKey = "Sempere.transcription.enabled"
    public static let localeKey = "Sempere.transcription.locale"
    /// Opt-in: nothing is transcribed until the user turns it on.
    public static let defaultEnabled = false

    public static func isEnabled(_ defaults: any KeyValueStore) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static func setEnabled(_ on: Bool, in defaults: any KeyValueStore) {
        defaults.set(on, forKey: enabledKey)
    }

    /// The stored locale identifier, or nil for "same as the device". An
    /// identifier that is not a well-formed BCP 47 / ICU tag reads as nil.
    public static func localeIdentifier(_ defaults: any KeyValueStore) -> String? {
        guard let id = defaults.string(forKey: localeKey), isWellFormed(id) else { return nil }
        return id
    }

    public static func setLocaleIdentifier(_ id: String?, in defaults: any KeyValueStore) {
        if let id, isWellFormed(id) { defaults.set(id, forKey: localeKey) } else { defaults.removeObject(forKey: localeKey) }
    }

    /// Letters, digits and `-`/`_` only, at most 35 characters, starting with a letter.
    public static func isWellFormed(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (1...35).contains(scalars.count), scalars[0].isASCII, scalars[0].properties.isAlphabetic else { return false }
        return scalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-" || $0 == "_") }
    }

    /// Languages the picker offers: the device's preferred ones, in order, without repeats.
    public static func offeredLocales(preferred: [String] = Locale.preferredLanguages) -> [String] {
        var seen = Set<String>()
        return preferred.filter { isWellFormed($0) && seen.insert($0).inserted }
    }

    /// Whether the recognition model for a locale is on the device.
    public enum ModelStatus: Equatable, Sendable {
        /// The transcription engine is not part of this build or OS.
        case unavailable
        case notDownloaded
        case downloading(fraction: Double?)
        case installed
    }

    /// Whether Settings offers the download button: the model is missing and an engine can fetch it.
    public static func offersDownload(_ status: ModelStatus, hasDownloader: Bool) -> Bool {
        status == .notDownloaded && hasDownloader
    }
}

// MARK: - New notes

/// *New notes*: the title a note gets when the user gives none and (with
/// `PaperPreference`) the paper. The notebook of quick voice notes is a
/// Quick Voice Notes setting (the capture profile).
public enum NewNoteSettings {
    /// The title presets, and `custom` (the user's own pattern, `titlePattern`).
    public enum TitleFormat: String, CaseIterable, Sendable, Identifiable {
        case dateAndTime
        case dateOnly
        /// `2026-10-07 14:30`: sorts by date.
        case isoDateTime
        /// `Wednesday 7 October`.
        case weekday
        case custom
        case blank

        public var id: String { rawValue }

        /// The pattern of a fixed preset (`DefaultTitle`); nil for the locale's styles, custom and blank.
        public var pattern: String? {
            switch self {
            case .isoDateTime: return "yyyy-MM-dd HH:mm"
            case .weekday: return "EEEE d MMMM"
            default: return nil
            }
        }
    }

    public static let titleFormatKey = "Sempere.newNote.titleFormat"
    /// The custom pattern (`TitleFormat.custom`): a Unicode date pattern or a
    /// strftime format, checked by `DefaultTitle.check` (as `notes new
    /// --title-format` is) before it is stored.
    public static let titlePatternKey = "Sempere.newNote.titlePattern"
    public static let defaultTitlePattern = "yyyy-MM-dd HH:mm"
    public static let defaultTitleFormat = TitleFormat.dateAndTime

    public static func titleFormat(_ defaults: any KeyValueStore) -> TitleFormat {
        defaults.string(forKey: titleFormatKey).flatMap(TitleFormat.init(rawValue:)) ?? defaultTitleFormat
    }

    public static func setTitleFormat(_ f: TitleFormat, in defaults: any KeyValueStore) {
        defaults.set(f.rawValue, forKey: titleFormatKey)
    }

    /// The stored custom pattern; the default one when none (or one that
    /// does not check) is stored.
    public static func titlePattern(_ defaults: any KeyValueStore) -> String {
        guard let p = defaults.string(forKey: titlePatternKey), !p.isEmpty, DefaultTitle.check(p) == nil else {
            return defaultTitlePattern
        }
        return p
    }

    /// Stores `pattern` as the custom pattern when it can be used; returns why
    /// not otherwise (nothing is stored: the last good one stays).
    @discardableResult
    public static func setTitlePattern(_ pattern: String, in defaults: any KeyValueStore) -> DefaultTitle.Problem? {
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        if let problem = DefaultTitle.check(pattern) { return problem }
        defaults.set(pattern, forKey: titlePatternKey)
        return nil
    }

    /// The title for a note made at `now` in `format`: "Oct 7, 2026 at 2:30 PM",
    /// "Oct 7, 2026", "2026-10-07 14:30", "Wednesday 7 October", the custom
    /// `pattern`'s, or "" (shown as "Untitled").
    public static func title(_ format: TitleFormat, pattern: String? = nil, now: Date = Date(), locale: Locale = .current,
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
    public static func defaultTitle(_ defaults: any KeyValueStore, now: Date = Date()) -> String {
        title(titleFormat(defaults), pattern: titlePattern(defaults), now: now)
    }

    /// `typed` when the user typed a title, else the stored format's.
    public static func resolvedTitle(typed: String, defaults: any KeyValueStore, now: Date = Date()) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultTitle(defaults, now: now) : t
    }
}

// MARK: - Storage

/// The unused attachments of Settings → Storage, by note: notes by title,
/// each note's items biggest first.
public enum UnusedAttachmentGroups {
    public struct Group: Identifiable, Equatable, Sendable {
        public var note: UUID
        public var title: String
        public var items: [AttachmentStorageReport.Unused]
        public var id: UUID { note }
    }

    public static func group(_ items: [AttachmentStorageReport.Unused], title: (UUID) -> String) -> [Group] {
        Dictionary(grouping: items, by: \.note)
            .map { Group(note: $0.key, title: title($0.key), items: $0.value.sorted { ($1.bytes, $0.id) < ($0.bytes, $1.id) }) }
            .sorted { ($0.title.lowercased(), $0.note.uuidString) < ($1.title.lowercased(), $1.note.uuidString) }
    }
}

/// Whether the app recognizes handwriting on its own (default on). It is
/// on-device only: Vision runs in the app and nothing leaves the device.
public enum RecognitionPreference {
    public static let key = "Sempere.recognizeHandwriting"
    /// On until the user turns it off (docs/attachments.md §15).
    public static let defaultValue = true

    /// The stored choice, `defaultValue` when never set.
    public static func isEnabled(_ defaults: any KeyValueStore) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}
