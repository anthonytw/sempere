import Foundation

// MARK: - Reading one note's revisions on several cores (perf audit P50, P53)
//
// Reading a note is dominated by decrypting each revision file (a
// post-quantum age header per file, about 1 ms each on an M-series core),
// which `loadNote` does one file after another. The app's interactive reads
// of a whole note (opening Version History, a metadata edit from the browser,
// a restore) wait on that, so they read the files on several threads.

extension Vault {
    /// `loadNote(_:detail:)` with the revisions read on up to
    /// `maxConcurrency` threads (0: `Parallel.defaultWidth`, the active cores,
    /// at most 8). The result is the same: every listed revision read once
    /// (same checks, same `LoadedNote`, revisions in listing order), only
    /// the wall time differs. Peak memory is the same too, since the result
    /// holds every revision anyway.
    ///
    /// - Throws: as `loadNote`: `VaultError.locked` / `.noIdentities` when the
    ///   vault cannot read, `VaultError.io` when the note cannot be listed;
    ///   unreadable revisions are collected in `failures`.
    public func loadNoteConcurrently(_ noteId: UUID, detail: RevisionDetail = .full,
                                     maxConcurrency: Int = 0) throws -> LoadedNote {
        _ = try requireReadable()
        let names = try revisionNames(of: noteId)
        let width = maxConcurrency > 0 ? maxConcurrency : Parallel.defaultWidth
        let results = Parallel.map(names, width: width) { n in
            Result { try readRevision(noteId: noteId, name: n, detail: detail) }
        }
        var revs: [Revision] = []
        var failures: [RevisionName: RevisionReadError] = [:]
        for (n, result) in zip(names, results) {
            switch result {
            case .success(let r): revs.append(r)
            case .failure(let e as RevisionReadError): failures[n] = e
            case .failure(let e): throw e
            }
        }
        return LoadedNote(revisions: revs, failures: failures)
    }
}

// MARK: - What a writer observes before writing to a note (perf audit P50)

/// The clock readings a writer observes before it writes to a note, and its
/// next `seq` there (format.md §5 "What a writer observes").
public struct WriteReadings: Hashable, Sendable {
    public var readings: [HLC]
    public var nextSeq: Int
}

extension Vault {
    /// Reads every revision of `noteId` without stroke geometry, on several
    /// cores, and returns what a writer of `device` must observe before
    /// writing to it (`readings(of:wall:)`) and its next `seq`. Every
    /// revision is decrypted and its header checked, so a revision a newer
    /// version wrote sets the vault read-only (format.md §7.3) before the
    /// write, exactly as a full read did.
    ///
    /// - Throws: as `loadNoteConcurrently`, and as `nextSeq(noteId:device:)`
    ///   when a revision failed to read.
    public func writeReadings(of noteId: UUID, device: DeviceID, wall: Date = Date()) throws -> WriteReadings {
        let loaded = try loadNoteConcurrently(noteId, detail: .withoutStrokePoints)
        return WriteReadings(readings: Self.readings(of: loaded, wall: wall),
                             nextSeq: try nextSeq(of: noteId, loaded: loaded, device: device))
    }

    /// The readings a writer observes from `loaded` (format.md §5): every
    /// readable revision's `hlc` (its file name's, which readers check); for
    /// a file that could not be READ (I/O: not downloaded, vanished), its
    /// name's `hlc`, capped at `wall`, so it orders our next reading after it
    /// without moving the clock past the wall clock; nothing from a file that
    /// was read but does not decrypt, authenticate or decode, which anyone
    /// can plant (§9).
    public static func readings(of loaded: LoadedNote, wall: Date) -> [HLC] {
        let w = HybridClock.wallMillis(wall)
        var out = loaded.revisions.map(\.hlc)
        for (name, error) in loaded.failures {
            guard case .unreadable = error else { continue }
            out.append(name.hlc.millis <= w ? name.hlc : HLC(millis: w, counter: 0) ?? name.hlc)
        }
        return out
    }

    /// The next `seq` of `device` in a note already loaded in full or without
    /// stroke points: from the revisions when all read, else from the names
    /// and snapshots on disk (`nextSeq(noteId:device:)`); never at or below
    /// a `seq` of `device` in any listed name.
    public func nextSeq(of noteId: UUID, loaded: LoadedNote, device: DeviceID) throws -> Int {
        let fromRevisions = loaded.failures.isEmpty
            ? Self.nextSeq(from: loaded.revisions, device: device)
            : try nextSeq(noteId: noteId, device: device)
        let listed = loaded.failures.keys.filter { $0.device == device }.map(\.seq).max() ?? 0
        return max(fromRevisions, listed + 1)
    }
}
