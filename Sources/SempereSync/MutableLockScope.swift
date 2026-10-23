import Foundation
import Sempere

// MARK: - The write lock and the network (F7)
//
// The vault's write lock (`SyncOptions.localWriteLock`) is shared by every writer of the vault on the device:
// the app's edits and settings, other targets' runs, the CLI. A run must never hold it across a request, or a
// slow or hung server would stall them all. So the mutable files (`vault.json`, `settings.age`) go in rounds of
// three steps:
//
// 1. Without the lock: whether each is available (a provider may be downloading it), and the server's copy
//    read (`prefetchMutables`). `checkSameVault` read `vault.json` already.
// 2. Under the lock: the local copies are read and judged against those, and taken, merged or kept exactly as
//    before, every local check (the stale-vault guard, `incomingManifestProblem`) included. An upload that
//    judging decides is recorded (`deferredUploads`), not made.
// 3. Without the lock: the uploads (`flushDeferredUploads`), in order, each under the precondition judging
//    chose (`If-Match` on the version read in step 1, or create-only).
//
// An upload the server refuses because its copy moved on since step 1 starts another round for that file:
// read again, judged again under the lock (the same bytes under a new version token are retried; other bytes
// are a change on both sides: merged, taken or kept as a conflict). After `SyncEngine.stampRetries` rounds it
// is left to the next run, with nothing recorded for it.
//
// One exception, by design: a provider's conflict versions (`settleConflictVersions`) are read and resolved
// under the lock. They exist only on a folder target (iCloud Drive, a local folder: local files, no network
// request); a WebDAV target has none. They merge into the local `settings.age`, so they need the lock.
//
// `WriteLockScopeTests.testNoRequestIsMadeUnderTheLock` fails if any other request is made under the lock.

/// An upload of a mutable file decided under the write lock and made after it (F7).
struct DeferredUpload {
    var name: String
    var data: Data
    var condition: PutCondition
    /// The hash to record as in step once it is uploaded (`recordMutable`); nil: none.
    var recordHash: String?
}

extension SyncEngine {
    /// `vault.json` and `settings.age`, in rounds that never hold the write lock across a request.
    func syncMutableFiles(_ remoteRoot: [String: RemoteEntry]) {
        var entries = remoteRoot.filter { [Vault.manifestName, SharedSettings.fileName].contains($0.key) }
        var names = [Vault.manifestName, SharedSettings.fileName]
        for round in 0..<Self.stampRetries {
            let ready = prefetchMutables(names, entries: entries)
            do {
                try withLocalWriteLock {
                    deferringUploads = true
                    defer { deferringUploads = false }
                    // A provider's conflict versions of the root files, merged or kept, then resolved
                    // (`ConflictVersions.swift`); local files only.
                    if round == 0 { settleConflictVersions(remoteRoot) }
                    for name in names where ready.contains(name) {
                        let remote = entries[name].flatMap { $0.isCollection ? nil : $0 }
                        do {
                            if name == SharedSettings.fileName {
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
                mutablePrefetch = [:]
                for name in names {
                    report.skipped.append(.init(path: name, message: "not synced this run: \(Self.describe(error))"))
                }
                return
            }
            mutablePrefetch = [:]
            let refused = flushDeferredUploads()
            guard !refused.isEmpty else { return }
            // The server's copy moved on: judged again with what it holds now.
            names = names.filter(refused.contains)
            for name in names { entries[name] = (try? transport.stat([name])) ?? nil }
        }
        for name in names {
            report.skipped.append(.init(path: name, message: "the server copy kept changing while uploading; synced on a later run"))
        }
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
                if remote != nil, !(name == Vault.manifestName && fetchedManifest != nil) {
                    mutablePrefetch[name] = try transport.read([name], maxBytes: limit)
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
        for upload in uploads where !refused.contains(upload.name) {
            do {
                try ensureCollection([])
                guard try transport.write([upload.name], .data(upload.data), condition: upload.condition) else {
                    refused.insert(upload.name)
                    continue
                }
                report.uploaded.append(upload.name)
                if let hash = upload.recordHash { try recordMutable(upload.name, hash: hash) }
            } catch {
                report.errors.append(.init(path: upload.name, message: Self.describe(error)))
            }
        }
        return refused
    }
}
