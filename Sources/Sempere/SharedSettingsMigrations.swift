import Foundation

/// Up-conversion of `settings.age` between `$schemaVersion`s (format.md §13.4,
/// docs/settings-sync.md §6): an ordered list of migrations `vN → vN+1`, run on
/// read, on the in-memory copy. Migrations are additive (rule 2): they copy an
/// old key into its new one and keep the old key for older readers; a step
/// that removes a key belongs only to a migration that raises
/// `$minReaderVersion`. Each copy carries the slot's `$meta` unchanged, so every
/// device that migrates the same file gets the same result. A file of a later
/// version than this one is left as it is.
public enum SharedSettingsMigrations {
    /// The `$schemaVersion` this version writes, and this reader's version for `$minReaderVersion`.
    public static let current = 1
    /// The `$minReaderVersion` this version writes. Raising it is a reviewed act:
    /// docs/settings-sync.md §6.3 must have a row for it (a test checks).
    public static let minReaderVersion = 1

    /// One step of a migration.
    public enum Step: Sendable {
        /// The key `to` is written from `from` (value mapped; nil: not written),
        /// at the top level and in every block, unless `to` was written later.
        /// `from` stays (dual-write window).
        case copy(from: String, to: String, map: @Sendable (JSONValue) -> JSONValue? = { $0 })
        /// Several keys are written from `key`, each value derived from the old
        /// one; `key` stays.
        case split(key: String, into: [(key: String, map: @Sendable (JSONValue) -> JSONValue?)])
        /// `key` goes, at the top level and in every block (its `$meta` too).
        /// Only in a migration that raises `minReaderVersion` past every reader of `key`.
        case remove(key: String)
    }

    /// The migration from `version` to `version + 1`.
    public struct Migration: Sendable {
        public var version: Int
        public var steps: [Step]
        /// The `$minReaderVersion` the migrated file needs (nil: unchanged).
        public var raisesMinReaderTo: Int?

        public init(from version: Int, _ steps: [Step], raisesMinReaderTo: Int? = nil) {
            self.version = version; self.steps = steps; self.raisesMinReaderTo = raisesMinReaderTo
        }

        /// False for a migration that removes a key without raising `$minReaderVersion` (rule 2).
        public var isAdditiveOrBreakingOnPurpose: Bool {
            let removes = steps.contains { if case .remove = $0 { return true } else { return false } }
            return !removes || (raisesMinReaderTo ?? 0) > version
        }
    }

    /// Every migration, in order. Version 1 has none yet: the first change of a
    /// key's name or meaning adds `Migration(from: 1, …)`, bumps `current`, adds
    /// a fixture `Tests/SempereTests/Fixtures/settings/v2.json`, a registry
    /// snapshot, and a row in docs/settings-sync.md §6.3.
    public static let all: [Migration] = []

    /// `settings` migrated to `target` with `migrations`. A file at or beyond
    /// the target version is returned unchanged.
    public static func migrated(_ settings: SharedSettings, using migrations: [Migration] = all,
                                to target: Int = current) -> SharedSettings {
        guard settings.schemaVersion < target else { return settings }
        var s = settings
        for m in migrations.sorted(by: { $0.version < $1.version })
        where m.version >= s.schemaVersion && m.version < target {
            for step in m.steps { apply(step, to: &s) }
            if let min = m.raisesMinReaderTo { s.minReaderVersion = max(s.minReaderVersion, min) }
            s.schemaVersion = m.version + 1
        }
        s.schemaVersion = target
        return s
    }

    static func apply(_ step: Step, to s: inout SharedSettings) {
        switch step {
        case .copy(let from, let to, let map):
            copy(from, [(to, map)], in: &s)
        case .split(let key, let into):
            copy(key, into, in: &s)
        case .remove(let key):
            for k in s.slots.keys where k.key == key { s.slots.removeValue(forKey: k) }
        }
    }

    private static func copy(_ from: String, _ targets: [(key: String, map: @Sendable (JSONValue) -> JSONValue?)],
                             in s: inout SharedSettings) {
        for (k, slot) in s.slots where k.key == from {
            for target in targets {
                let value: JSONValue?
                if let v = slot.value {
                    guard let mapped = target.map(v) else { continue }
                    value = mapped
                } else {
                    value = nil   // a reset stays a reset
                }
                let dest = SettingSlotKey(target.key, block: k.block)
                let copied = SettingSlot(value: value, meta: slot.meta)
                if let there = s.slots[dest], !SettingSlot.precedes(there, copied) { continue }
                s.slots[dest] = copied
            }
        }
    }
}
