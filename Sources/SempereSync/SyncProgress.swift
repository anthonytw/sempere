import Foundation

/// How far a sync run is (`WebDAVSyncOptions.progress`, `SyncReport.progress`).
///
/// Totals are known once the server is listed: `notesTotal` after the
/// `notes/` listing, `filesTotal` and `bytesTotal` once every note folder
/// was listed and compared with the local vault. Until then they are 0.
/// Downloads only: uploads are counted in `uploaded`, without a total.
public struct WebDAVSyncProgress: Codable, Hashable, Sendable {
    /// What the run is doing.
    public enum Stage: String, Codable, Sendable {
        /// Listing the server (the root, `notes/`, each note folder and its `att/`).
        case listing
        /// Downloading the files the vault lacks, `concurrency` at a time.
        case downloading
        /// Going through the notes one by one: uploads, deletions, recording what both sides hold.
        case syncingNotes
        /// The run returned.
        case done
    }

    public var stage: Stage = .listing
    /// Note folders on the server listed so far, and how many there are.
    public var notesListed = 0
    public var notesTotal = 0
    /// Notes gone through in `syncingNotes`.
    public var notesSynced = 0
    /// Downloads placed in the vault, and how many the run found to make. A
    /// file that failed, was quarantined or was cut short is not counted, so
    /// a run with problems ends below its total (they are in the report).
    public var filesDone = 0
    public var filesTotal = 0
    /// Bytes of those downloads received (with what an interrupted earlier
    /// run already had), at most each file's listed size, and their size in
    /// the listing. A file the listing gave no size for adds what arrives to
    /// both. Both only grow, and `bytesDone` never passes `bytesTotal`.
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    /// Files uploaded so far.
    public var uploaded = 0

    public init() {}

    /// `filesDone / filesTotal` (bytes when both are known), 0...1; 0 while nothing is known.
    public var fractionCompleted: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1, Double(filesDone) / Double(filesTotal)) }
        return stage == .done ? 1 : 0
    }

    /// One line for a terminal (English, like the rest of the CLI).
    public var line: String {
        switch stage {
        case .listing:
            return notesTotal > 0 ? "listing notes \(notesListed) of \(notesTotal)" : "listing the server"
        case .downloading, .done:
            return "downloading \(filesDone) of \(filesTotal) files · "
                + "\(Self.megabytes(bytesDone)) of \(Self.megabytes(bytesTotal)) MB"
        case .syncingNotes:
            return "syncing notes \(notesSynced) of \(notesTotal)"
                + (filesTotal > 0 ? " · downloaded \(filesDone) of \(filesTotal) files" : "")
                + (uploaded > 0 ? " · uploaded \(uploaded)" : "")
        }
    }

    /// Bytes as MB (10⁶) with one decimal.
    public static func megabytes(_ bytes: Int64) -> String {
        let tenths = (max(bytes, 0) + 50_000) / 100_000
        return "\(tenths / 10).\(tenths % 10)"
    }
}
