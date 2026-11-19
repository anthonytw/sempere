import Foundation
import Sempere

// MARK: - The shared vectors and map (docs/design/1.2-note-insights.md §3.8, D12, D13, D15, D20)
//
// Every capable device does the work (D21 replaced D13's work device): a device with the model makes summaries and
// keywords for notes no device has a current result for; a device that supports the pinned revision
// (`insights.embeddingRevision`, by default the lowest every recently seen device supports, moved only by hand, D12)
// embeds notes no device has a current vector for and rebuilds the map when it is due. Embeddings are bit-identical
// across devices and the map build is deterministic, so concurrent rebuilds converge. Devices check the map's canaries:
// compatible ones use its vectors and place their own new notes locally; incompatible ones build a local set and map of
// their own, never mixed; a device without the pinned revision is a vector reader.

/// The vault's insights settings (`settings.age`, format.md §13; docs/settings-sync.md §5).
public struct InsightsSettings: Hashable, Sendable {
    /// `insights.enabled` as resolved (default false).
    public var enabled: Bool
    /// True when the file holds an explicit `false` for `insights.enabled` (turned off): only then do devices delete
    /// `insights/` (format.md §16.6). Unset is not off: nothing is synced, nothing deleted.
    public var explicitlyOff: Bool
    /// Per language, the pinned revision.
    public var pins: [String: Int]
    public var voiceNoteTitle: String
    /// `insights.language`: the language generated summaries and voice-note titles are written in; nil: the note's own
    /// ("Same as note", the default).
    public var language: String?

    public init(enabled: Bool = false, explicitlyOff: Bool = false,
                pins: [String: Int] = [:], voiceNoteTitle: String = VoiceNoteTitleFormat.defaultFormat, language: String? = nil) {
        self.enabled = enabled; self.explicitlyOff = explicitlyOff
        self.pins = pins; self.voiceNoteTitle = voiceNoteTitle; self.language = language
    }

    /// (1.2.0 files may still hold `insights.workDevice`; it is not a setting any more and is kept and ignored.)
    public static let keys = (enabled: "insights.enabled",
                              pin: "insights.embeddingRevision", voiceNoteTitle: "insights.voiceNoteTitle",
                              language: "insights.language")

    /// The settings of `file` (nil: none) for a device of `type` (nil: the CLI, top level only).
    public init(_ file: SharedSettings?, type: SettingsDeviceType?) {
        let s = file ?? SharedSettings()
        func value(_ key: String) -> JSONValue? {
            guard let spec = SharedSettingsCatalog.spec(named: key) else { return nil }
            return s.resolve(spec, for: type).value
        }
        // Vault-wide: the top level only (a type block does not turn the feature on for one kind of device).
        if case .bool(let b)? = s.value(SettingSlotKey(Self.keys.enabled)) { enabled = b } else { enabled = false }
        if case .bool(false)? = s.value(SettingSlotKey(Self.keys.enabled)) { explicitlyOff = true } else { explicitlyOff = false }
        var pins: [String: Int] = [:]
        if case .object(let o)? = value(Self.keys.pin) {
            for (k, v) in o { if case .number(let d) = v, d >= 1, d <= 1_000_000, d.rounded() == d { pins[k] = Int(d) } }
        }
        self.pins = pins
        if case .string(let f)? = value(Self.keys.voiceNoteTitle), VoiceNoteTitleFormat.check(f) == nil {
            voiceNoteTitle = f
        } else { voiceNoteTitle = VoiceNoteTitleFormat.defaultFormat }
        // Vault-wide like `enabled`: the top level only, so a block for one kind of device never makes it write another language
        // than the others (they all write the same files).
        if case .string(let l)? = s.value(SettingSlotKey(Self.keys.language)),
           SharedSettingsCatalog.spec(named: Self.keys.language)?.validated(.string(l)) != nil { language = l } else { language = nil }
    }

    /// The vault's settings as this device reads them (nil file: defaults; an unreadable file: defaults).
    public static func read(_ vault: Vault, type: SettingsDeviceType? = nil) -> InsightsSettings {
        InsightsSettings((try? vault.readSharedSettings()) ?? nil, type: type)
    }
}

/// The 8 canary sentences (set 1, format.md §16.5) and the compatibility check (design §3.8).
public enum Canaries {
    public static let set = 1
    public static let threshold = 0.999
    public static let sentences: [String] = [
        "The damping ratio decides whether a spring and mass system oscillates or settles slowly.",
        "Photosynthesis turns light, water and carbon dioxide into sugar and oxygen.",
        "The treaty ended the war and redrew the borders of several kingdoms.",
        "A recursive function calls itself until it reaches a base case.",
        "Knead the dough for ten minutes, then let it rise in a warm place.",
        "Interest rates rose as the central bank tried to slow inflation.",
        "The patient reported chest pain after climbing two flights of stairs.",
        "Vectors in a basis span the space and are linearly independent.",
    ]

    /// The canary vectors at `revision`, nil when one does not embed.
    public static func vectors(_ provider: any EmbeddingProvider, language: String, revision: Int) throws -> [[Float]]? {
        var out: [[Float]] = []
        for s in sentences {
            guard let v = try provider.embed(EmbeddingInput.clean(s), language: language, revision: revision) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Compatible: the same key (model, language, revision, input) and every canary at cosine ≥ 0.999.
    public static func compatible(mine: [[Float]], myKey: EmbeddingKey, theirs: [[Float]], theirKey: EmbeddingKey) -> Bool {
        guard myKey == theirKey, mine.count == sentences.count, theirs.count == sentences.count else { return false }
        return zip(mine, theirs).allSatisfy { $0.count == $1.count && VectorMath.cosine($0, $1) >= threshold }
    }
}

/// How this device stands to the shared map (design §3.8; `insights status`).
public enum MapCompatibility: String, Hashable, Sendable, Codable {
    /// Uses the shared vectors and map, places its own new notes (the device that built the map is compatible with it).
    case compatible
    /// Supports the pin but fails the canaries: builds a local set and map.
    case incompatible
    /// Does not support the pin (or has no embedder): reads the shared vectors and map as they are.
    case vectorReader
    /// There is no map yet.
    case noMap

    /// Whether a device in this standing writes to the shared set (D21): vectors and the map are written only by devices
    /// the canaries accept (the map's builder is one) or, with no map yet, by devices not contradicted by the others' canaries.
    public var mayWriteShared: Bool { self == .compatible || self == .noMap }
}

public enum EmbeddingPin {
    /// A device record counts as "recently seen" when written within 30 days by a device the current list has.
    public static let recentlySeen: TimeInterval = 30 * 24 * 3600

    /// The records of devices the current list has, written within 30 days of `now`.
    public static func recent(_ records: [DeviceID: InsightsDeviceRecord], listed: Set<DeviceID>, now: Date) -> [DeviceID: InsightsDeviceRecord] {
        records.filter { d, r in
            listed.contains(d) && Double(r.written) / 1000 >= now.timeIntervalSince1970 - recentlySeen
        }
    }

    /// The lowest revision of `language` every recently seen device supports (D12); nil when they share none.
    /// Devices that support no revision of the language at all (no embedder) do not hold the pin back.
    public static func lowestCommon(_ records: [DeviceID: InsightsDeviceRecord], language: String) -> Int? {
        let sets = records.values.compactMap { r -> Set<Int>? in
            let s = Set(r.supported[language] ?? []); return s.isEmpty ? nil : s
        }
        guard var common = sets.first else { return nil }
        for s in sets.dropFirst() { common.formIntersection(s) }
        return common.min()
    }

    /// The devices among `records` that do not support `revision` of `language` (they become vector readers).
    public static func leftOut(_ records: [DeviceID: InsightsDeviceRecord], language: String, revision: Int) -> [DeviceID] {
        records.filter { !($0.value.supported[language] ?? []).contains(revision) }.map(\.key).sorted()
    }

    /// The newest revision a recently seen device supports above `pin` (the upgrade offer, "Use the newer embedding
    /// model"), nil when none.
    public static func upgradeOffer(_ records: [DeviceID: InsightsDeviceRecord], language: String, pin: Int) -> Int? {
        records.values.flatMap { $0.supported[language] ?? [] }.filter { $0 > pin }.max()
    }
}

/// Devices whose records say they can embed (D21: any of them may build the map).
public enum CapableDevices {
    /// Devices of the current list whose records say they support the pin (any revision when unset), sorted.
    public static func list(snapshot: InsightsSnapshot, listed: Set<DeviceID>, language: String, pin: Int?) -> [DeviceID] {
        snapshot.devices.filter { d, r in
            listed.contains(d) && !(r.supported[language] ?? []).isEmpty && (pin.map { (r.supported[language] ?? []).contains($0) } ?? true)
        }.map(\.key).sorted()
    }
}
