import Foundation
import Sempere

// MARK: - The write lock and the network (lock scope)
//
// The vault's write lock (`SyncOptions.localWriteLock`) is shared by every writer of the vault on the device:
// the app's edits and settings, other targets' runs, the CLI. A run must never hold it across a request, or a
// slow or hung server would stall them all. So the mutable files (`vault.json`, `settings.age`) go in rounds of
// three steps:
//
// 1. Without the lock: whether each is available (a provider may be downloading it), and the server's copy
//    read (`prefetchMutables`), with what it held (`mutableSeen`). `checkSameVault` read `vault.json` already.
// 2. Under the lock: the local copies are read and judged against those, and taken, merged or kept exactly as
//    before, every local check (the stale-vault guard, `incomingManifestProblem`) included. An upload that
//    judging decides is recorded (`deferredUploads`), not made.
// 3. Without the lock: the uploads (`flushDeferredUploads`), in order, each under a precondition on the copy
//    step 1 read: create-only, `If-Match` on its strong version token, or, where the server gives none (a weak
//    or missing ETag), the server's file read again just before and found to hold the same bytes. An
//    upload without its own precondition is never made over a copy this run did not see.
//
// An upload the server refuses because its copy moved on since step 1 starts another round for that file:
// read again, judged again under the lock (the same bytes under a new version token are retried; other bytes
// are a change on both sides: merged, taken or kept as a conflict). After `SyncEngine.stampRetries` rounds it
// is left to the next run, with nothing recorded for it. `settings.age` is not uploaded in a round whose
// `vault.json` upload did not land: its seal may depend on the `vault.json` the server lacks.
//
// One exception, by design: a provider's conflict versions (`settleConflictVersions`) are settled under the
// lock. They exist only on a folder target (iCloud Drive, a local folder), where reading one is reading a
// file of the provider's own, and a WebDAV target has none. They merge into the local `settings.age`, so they
// need the lock. What they compare against (the current `vault.json`, which may first have to arrive from the
// provider) is fetched before it (`prefetchConflictCurrent`).
//
// `WriteLockScopeTests.testNoRequestIsMadeUnderTheLock` fails if any other request is made under the lock.

/// An upload of a mutable file decided under the write lock and made after it.
struct DeferredUpload {
    var name: String
    var data: Data
    var condition: PutCondition
    /// With no precondition, the hash of the server's copy that judging was made against: the file is read
    /// again before the upload and the upload is refused if it no longer has these bytes.
    var verifyHash: String?
    /// The hash to record as in step once it is uploaded (`recordMutable`); nil: none.
    var recordHash: String?
    /// Report entries made once the upload has succeeded.
    var afterUpload: (() -> Void)?
}

extension SyncEngine {
    /// `vault.json` and `settings.age`, in rounds that never hold the write lock across a request.
    /// `settleVersions`: false for a metadata pull of a partial copy, which leaves provider versions alone.
    func syncMutableFiles(_ remoteRoot: [String: RemoteEntry], settleVersions: Bool = true) {
        var entries = remoteRoot.filter { [Vault.manifestName, SharedSettings.fileName].contains($0.key) }
        var names = [Vault.manifestName, SharedSettings.fileName]
        if settleVersions { prefetchConflictCurrent(remoteRoot) }
        defer { conflictCurrent = nil }
        for round in 0..<Self.stampRetries {
            mutableSeen = [:]
            let ready = prefetchMutables(names, entries: entries)
            do {
                try withLocalWriteLock {
                    deferringUploads = true
                    defer { deferringUploads = false }
                    // A provider's conflict versions of the root files, merged or kept, then resolved
                    // (`ConflictVersions.swift`); local files only.
                    if round == 0, settleVersions { settleConflictVersions(remoteRoot) }
                    for name in names where ready.contains(name) {
                        let remote = entries[name].flatMap { $0.isCollection ? nil : $0 }
                        do {
                            if name == SharedSettings.fileName {
                                // A held run leaves settings alone (J5b, §5.5): its key may be the old one.
                                guard epochHold == nil else { continue }
                                // Shared settings (format.md §13): merged per key when both sides changed.
                                try syncSharedSettings(remote: remote)
                            } else {
                                options.pushOnly ? try pushMutable(name, remote: remote) : try syncMutable(name, remote: remote)
                            }
                        } catch {
                            report.errors.append(.init(path: name, message: Self.describe(error)))
                        }
                    }
                }
            } catch {
                // Another writer held the lock for the whole wait: the mutable files wait for the next run.
                deferredUploads = []
                dropUnusedPrefetch()
                for name in names {
                    report.skipped.append(.init(path: name, message: "not synced this run: \(Self.describe(error))"))
                }
                return
            }
            dropUnusedPrefetch()
            let refused = flushDeferredUploads()
            mutableSeen = [:]
            guard !refused.isEmpty else { return }
            // The server's copy moved on: judged again with what it holds now.
            names = names.filter(refused.contains)
            for name in names {
                do { entries[name] = try transport.stat([name]) } catch {
                    // Not read: judging a file taken for absent would only upload a create that is refused.
                    report.errors.append(.init(path: name, message: Self.describe(error)))
                    names.removeAll { $0 == name }
                }
            }
            if names.isEmpty { return }
        }
        for name in names {
            report.skipped.append(.init(path: name, message: "the server copy kept changing while uploading; synced on a later run"))
        }
    }

    /// Copies read in step 1 and not used by judging were downloaded all the same: counted, then dropped.
    private func dropUnusedPrefetch() {
        for (_, got) in mutablePrefetch { _ = try? budget.downloaded(got.data.count) }
        mutablePrefetch = [:]
    }

    /// Step 1: the names among `names` to judge this round, with the server's copies of them read. A file still
    /// arriving, or whose copy could not be read, is left to the next run (reported).
    func prefetchMutables(_ names: [String], entries: [String: RemoteEntry]) -> Set<String> {
        var ready: Set<String> = []
        for name in names {
            let limit = name == SharedSettings.fileName ? SharedSettings.maxFileBytes : Self.maxMutableReadBytes
            let remote = entries[name].flatMap { $0.isCollection ? nil : $0 }
            do {
                // Listed but not downloaded yet: neither taken nor replaced this run.
                if try !available([name], entry: remote) { continue }
                if remote != nil {
                    let got: (data: Data, etag: String?)
                    if name == Vault.manifestName, let fetched = fetchedManifest {
                        got = fetched
                    } else {
                        do { got = try transport.read([name], maxBytes: limit) } catch where options.pushOnly {
                            // A server file that cannot be read (too large, malformed; also a transient read error)
                            // is just different: the mirror replaces it, over a copy this run did not see.
                            ready.insert(name)
                            continue
                        }
                        mutablePrefetch[name] = got
                    }
                    mutableSeen[name] = (FileDigest.sha256(got.data), got.etag ?? remote?.etag)
                }
                ready.insert(name)
            } catch {
                report.errors.append(.init(path: name, message: Self.describe(error)))
            }
        }
        return ready
    }

    /// Step 3: the uploads decided under the lock, made now that it is released. Returns the names whose upload
    /// the server refused because its copy changed since it was read (nothing recorded for them).
    func flushDeferredUploads() -> Set<String> {
        let uploads = deferredUploads
        deferredUploads = []
        var refused: Set<String> = []
        var manifestMissed = false, manifestRefused = false
        for upload in uploads where !refused.contains(upload.name) {
            if upload.name == SharedSettings.fileName, manifestMissed {
                // Refused (its copy moved on): judged again with it in the next round. Failed: a later run.
                if manifestRefused { refused.insert(upload.name) } else {
                    report.skipped.append(.init(path: upload.name, message: "held back: vault.json did not reach the server; synced on a later run"))
                }
                continue
            }
            do {
                try ensureCollection([])
                if let hash = upload.verifyHash {
                    // No strong version token to put a precondition on: the bytes judged are the server's now.
                    let limit = upload.name == SharedSettings.fileName ? SharedSettings.maxFileBytes : Self.maxMutableReadBytes
                    guard let now = try? transport.read([upload.name], maxBytes: limit), FileDigest.sha256(now.data) == hash else {
                        refused.insert(upload.name)
                        if upload.name == Vault.manifestName { manifestMissed = true; manifestRefused = true }
                        continue
                    }
                }
                guard try transport.write([upload.name], .data(upload.data), condition: upload.condition) else {
                    refused.insert(upload.name)
                    if upload.name == Vault.manifestName { manifestMissed = true; manifestRefused = true }
                    continue
                }
                report.uploaded.append(upload.name)
                upload.afterUpload?()
                if let hash = upload.recordHash { try recordMutable(upload.name, hash: hash) }
            } catch {
                if upload.name == Vault.manifestName { manifestMissed = true }
                report.errors.append(.init(path: upload.name, message: Self.describe(error)))
            }
        }
        return refused
    }
}
