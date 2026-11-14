import Foundation
import Sempere

// MARK: - The shared vectors and map (docs/design/1.2-note-insights.md §3.8, D12, D13, D15, D20)
//
// One work device (`insights.workDevice`, D13) embeds every note at the pinned revision (`insights.embeddingRevision`,
// by default the lowest every recently seen device supports, moved only by hand, D12) and builds the map. Devices
// check its canaries: compatible ones use its vectors and place their own new notes locally; incompatible ones build a
// local set and map of their own, never mixed; a device without the pinned revision is a vector reader.

/// The vault's insights settings (`settings.age`, format.md §13; docs/settings-sync.md §5).
public struct InsightsSettings: Hashable, Sendable {
    /// `insights.enabled` as resolved (default false).
    public var enabled: Bool
    /// True when the file holds an explicit `false` for `insights.enabled` (turned off): only then do devices delete
    /// `insights/` (format.md §16.6). Unset is not off: nothing is synced, nothing deleted.
    public var explicitlyOff: Bool
    /// `insights.compute` for this device's type: `auto` lets a device that is not the work device compute too.
    public var computeAuto: Bool
    public var workDevice: DeviceID?
    /// Per language, the pinned revision.
    public var pins: [String: Int]
    public var voiceNoteTitle: String

    public init(enabled: Bool = false, explicitlyOff: Bool = false, computeAuto: Bool = false, workDevice: DeviceID? = nil,
                pins: [String: Int] = [:], voiceNoteTitle: String = VoiceNoteTitleFormat.defaultFormat) {
        self.enabled = enabled; self.explicitlyOff = explicitlyOff; self.computeAuto = computeAuto; self.workDevice = workDevice
        self.pins = pins; self.voiceNoteTitle = voiceNoteTitle
    }

    public static let keys = (enabled: "insights.enabled", compute: "insights.compute", workDevice: "insights.workDevice",
                              pin: "insights.embeddingRevision", voiceNoteTitle: "insights.voiceNoteTitle")

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
        if case .string(let c)? = value(Self.keys.compute) { computeAuto = c == "auto" } else { computeAuto = false }
        if case .string(let d)? = value(Self.keys.workDevice) { workDevice = DeviceID(d) } else { workDevice = nil }
        var pins: [String: Int] = [:]
        if case .object(let o)? = value(Self.keys.pin) {
            for (k, v) in o { if case .number(let d) = v, d >= 1, d <= 1_000_000, d.rounded() == d { pins[k] = Int(d) } }
        }
        self.pins = pins
        if case .string(let f)? = value(Self.keys.voiceNoteTitle), VoiceNoteTitleFormat.check(f) == nil {
            voiceNoteTitle = f
        } else { voiceNoteTitle = VoiceNoteTitleFormat.defaultFormat }
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
    /// Uses the work device's vectors and map, places its own new notes.
    case compatible
    /// Supports the pin but fails the canaries: builds a local set and map.
    case incompatible
    /// Does not support the pin (or has no embedder): reads the shared vectors and map as they are.
    case vectorReader
    /// This device is the work device.
    case workDevice
    /// There is no map yet.
    case noMap
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

/// The work device's standing (D13): who it is, whether it was seen lately, and who may hold the role.
public struct WorkDeviceStatus: Hashable, Sendable {
    /// The work device is "not seen" when it wrote nothing in `insights/` for 14 days.
    public static let notSeenAfter: TimeInterval = 14 * 24 * 3600

    public var workDevice: DeviceID?
    /// Its latest `written` among its files, nil when it has none.
    public var lastSeen: Date?
    /// It wrote nothing for 14 days (status offers "Use this device"; never taken over by itself).
    public var notSeen: Bool
    /// Devices whose records say they can hold the role (they support the pin, or any revision when unset), sorted.
    public var capable: [DeviceID]

    public init(settings: InsightsSettings, snapshot: InsightsSnapshot, listed: Set<DeviceID>, language: String, now: Date) {
        workDevice = settings.workDevice
        var latest: Int64?
        if let w = settings.workDevice {
            let mine = snapshot.notes.values.compactMap { $0[w]?.written } + [snapshot.maps[w]?.written, snapshot.devices[w]?.written,
                                                                              snapshot.topics[w]?.written].compactMap { $0 }
            latest = mine.max()
        }
        lastSeen = latest.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if settings.workDevice != nil {
            notSeen = lastSeen.map { now.timeIntervalSince($0) > Self.notSeenAfter } ?? true
        } else {
            notSeen = false
        }
        let pin = settings.pins[language]
        capable = snapshot.devices.filter { d, r in
            listed.contains(d) && !(r.supported[language] ?? []).isEmpty && (pin.map { (r.supported[language] ?? []).contains($0) } ?? true)
        }.map(\.key).sorted()
    }
}
