import Foundation

/// The bounds a front end asks one run for, over the defaults (`SyncLimits`, `SyncOptions.maxBlobBytes`): the CLI's
/// `--max-blob-mib`, `--max-notes`, `--max-entries`, `--max-download-mib`, `--max-minutes`, and the app's background
/// task, which gives a run its share of the task's time. Nil leaves a default. One place fills them in (`apply`), and
/// one place checks the values a person typed (`checked`).
public struct SyncBounds: Sendable, Hashable {
    /// The largest attachment blob sent or taken, in bytes.
    public var maxBlobBytes: Int?
    public var maxNotes: Int?
    public var maxEntries: Int?
    public var maxDownloadBytes: Int64?
    /// Wall-clock seconds.
    public var maxDuration: TimeInterval?

    public init(maxBlobBytes: Int? = nil, maxNotes: Int? = nil, maxEntries: Int? = nil, maxDownloadBytes: Int64? = nil,
                maxDuration: TimeInterval? = nil) {
        self.maxBlobBytes = maxBlobBytes
        self.maxNotes = maxNotes
        self.maxEntries = maxEntries
        self.maxDownloadBytes = maxDownloadBytes
        self.maxDuration = maxDuration
    }

    /// One bound as a person gives it, in whole units, and the values it takes.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case maxBlobMiB, maxNotes, maxEntries, maxDownloadMiB, maxMinutes

        /// The values accepted: from 1 up to a bound no real vault reaches.
        public var range: ClosedRange<Int> {
            switch self {
            case .maxBlobMiB: return 1...(1 << 20)
            case .maxNotes: return 1...100_000_000
            case .maxEntries: return 1...1_000_000_000
            case .maxDownloadMiB: return 1...(1 << 30)
            case .maxMinutes: return 1...525_600
            }
        }
    }

    /// A value outside its field's `range`; the front end words it.
    public struct OutOfRange: Error, Sendable, Hashable {
        public var field: Field
        public var value: Int

        public init(field: Field, value: Int) {
            self.field = field
            self.value = value
        }
    }

    /// The bounds for values in whole units (MiB, minutes), each checked against its `Field.range`, in the order
    /// of `Field.allCases`.
    public static func checked(maxBlobMiB: Int? = nil, maxNotes: Int? = nil, maxEntries: Int? = nil,
                               maxDownloadMiB: Int? = nil, maxMinutes: Int? = nil) throws(OutOfRange) -> SyncBounds {
        func check(_ value: Int?, _ field: Field) throws(OutOfRange) -> Int? {
            guard let value else { return nil }
            guard field.range.contains(value) else { throw OutOfRange(field: field, value: value) }
            return value
        }
        var out = SyncBounds()
        out.maxBlobBytes = try check(maxBlobMiB, .maxBlobMiB).map { $0 << 20 }
        out.maxNotes = try check(maxNotes, .maxNotes)
        out.maxEntries = try check(maxEntries, .maxEntries)
        out.maxDownloadBytes = try check(maxDownloadMiB, .maxDownloadMiB).map { Int64($0) << 20 }
        out.maxDuration = try check(maxMinutes, .maxMinutes).map { TimeInterval($0) * 60 }
        return out
    }

    /// Sets the bounds given on `options`; the others keep what they had.
    public func apply(to options: inout SyncOptions) {
        if let maxBlobBytes { options.maxBlobBytes = maxBlobBytes }
        if let maxNotes { options.limits.maxNotes = maxNotes }
        if let maxEntries { options.limits.maxEntries = maxEntries }
        if let maxDownloadBytes { options.limits.maxDownloadBytes = maxDownloadBytes }
        if let maxDuration { options.limits.maxDuration = maxDuration }
    }
}
