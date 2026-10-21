import Crypto
import Foundation
import Sempere

// MARK: - Published summaries on the server (format.md §12)
//
// The server's `sempere-summaries.sealed` describes what the SERVER holds
// after the sync: one entry per note whose revisions there are exactly the
// local ones (computed from the local vault, which needs the key). It is never
// copied from one side to the other, and only rewritten when its entries
// change; the listing it was last written for is kept in the sync state when
// every note there got an entry, so an unchanged server then costs no request.

extension SyncEngine {
    /// How many times the summaries file is read and written again after another device replaced it.
    static let summariesWriteAttempts = 3

    func refreshRemoteSummaries(exists: Bool) {
        let name = PublishedSummaries.fileName
        guard exists || options.publishForWebViewer || options.publishSummaries else { return }
        guard let vault else {
            report.skipped.append(.init(path: name, message: "vault not unlocked (--identity): the server's summaries are not updated"))
            return
        }
        let listing: String
        do {
            // The sealed vault secret too: a rotation (recipient removed) re-seals the file under a new key
            // though no revision name changes (format.md §12.1).
            var hashed = try encodedWebIndex()
            hashed.append(0)
            hashed.append(Data(vault.manifest.vaultSecret.utf8))
            listing = FileDigest.sha256(hashed)
        } catch {
            report.errors.append(.init(path: name, message: Self.describe(error)))
            return
        }
        if exists, state.publishedSummaries == listing { return }
        // A run that took another vault.json (a key change, a rotation) opened `vault` from the one before:
        // what it would seal could be under the old secret or miss the new list. The next run publishes.
        if manifestHash() != checkerBaseManifest {
            report.skipped.append(.init(path: name, message: "vault.json changed during the run; not updated"))
            state.publishedSummaries = nil
            return
        }
        do {
            let cache = options.summaryCacheDirectory.flatMap { try? SummaryCache(directory: $0, vault: vault) }
            var exists = exists
            var entries: [UUID: PublishedSummaries.Entry] = [:]
            var written = false, kept = false
            // Conditional on the version this run read (its ETag, or the folder's stamp), so a device that
            // listed the server earlier never replaces a newer, larger copy another device just wrote. After a
            // conflict the other copy's entries this run has none of are kept: they describe notes it listed
            // later (the next uncontested run drops any that are gone).
            for attempt in 0..<Self.summariesWriteAttempts {
                var current: [UUID: PublishedSummaries.Entry]?
                var condition = PutCondition.create
                if exists {
                    condition = .unconditional
                    if let got = try? transport.read([name], maxBytes: PublishedSummaries.maxFileBytes) {
                        current = try? vault.openPublishedSummaries(got.data)
                        condition = Self.replaceCondition(etag: got.etag)
                    }
                }
                (entries, _) = try vault.publishedSummaryEntries(for: remoteRevisions, reuse: current ?? [:], cache: cache)
                if attempt > 0, let current {
                    for (id, e) in current where entries[id] == nil { entries[id] = e; kept = true }
                }
                if current == entries { written = true; break }
                try ensureCollection([])
                if try transport.write([name], .data(try vault.sealPublishedSummaries(entries)), condition: condition) {
                    report.uploaded.append(name)
                    written = true
                    break
                }
                exists = true
            }
            guard written else {
                report.skipped.append(.init(path: name, message: "changed on the server by another device while being written; not updated"))
                state.publishedSummaries = nil
                return
            }
            // A note without an entry (unreadable here, or different here) is tried again next run.
            let complete = remoteRevisions.keys.allSatisfy { id in UUID(uuidString: id).map { entries[$0] != nil } ?? true }
            state.publishedSummaries = complete && !kept ? listing : nil
        } catch {
            report.errors.append(.init(path: name, message: Self.describe(error)))
        }
    }
}
