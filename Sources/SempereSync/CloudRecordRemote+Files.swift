import Crypto
import Foundation
import Sempere

// MARK: - Reading, writing and deleting files (design §2.2 to §2.5)

/// Ways the transport can be made wrong, to prove the tests notice (tests only: the same idea as
/// `SyncEpochMutation`). Each must break the invariant it names (`EpochInterleavingTests`, `CloudRecordRemoteTests`).
enum CloudRemoteMutation: Hashable, Sendable, CaseIterable {
    /// A create over a live record replaces it instead of failing (write-once files are overwritten).
    case createReplacesExisting
    /// A conditional replace ignores the tag it was given (the mutable files' compare-and-swap).
    case replaceIgnoresTag
    /// A conditional delete deletes whatever version is there.
    case deleteIgnoresTag
    /// A create over a tombstone is refused (a file written again after a delete never arrives).
    case createOverTombstoneRefused
    /// A conditional delete says it deleted and does nothing.
    case deleteSkipsTombstone
    /// A tombstone is listed as a live file.
    case tombstonesListAsPresent
    /// The save of a replace or a tombstone does not ask the server to check the tag (the transport's own earlier check
    /// is all that is left, which another device can beat between the fetch and the save).
    case serverConditionsDropped
    /// The sweep takes every old part for an orphan, whatever file names it.
    case orphanRuleIgnoresFiles
    /// A device's own saves and deletes are not recorded in its mirror (a run does not read its own writes).
    case ownWritesNotMirrored
}

extension CloudRecordRemote {
    /// The active mutations (tests only).
    nonisolated(unsafe) static var mutations: Set<CloudRemoteMutation> = []

    // MARK: Fetching and judging one record

    /// One file's record from the server, judged. nil: there is none (the mirror forgets it).
    func fetchFile(_ path: [String], payload: Bool) throws -> (file: CloudMirror.File, record: CloudRecord)? {
        let name = CloudRecordNaming.fileName(path)
        guard let r = try perform({ try store.fetch(zone: zone, name: name, payload: payload) }) else {
            core.with { $0.removeFile(path) }
            return nil
        }
        guard r.name == name, r.kind == .file else { throw CloudRecordError.corrupt(path: shown(path), reason: "wrong record") }
        switch CloudMirror.ingest(r) {
        case .file(let f):
            guard f.path == path else { throw CloudRecordError.corrupt(path: shown(path), reason: "path") }
            core.with { $0.upsert(f) }
            return (f, r)
        case .skipped(let why):
            throw CloudRecordError.corrupt(path: shown(path), reason: why.rawValue)
        default:
            throw CloudRecordError.corrupt(path: shown(path), reason: "wrong record")
        }
    }

    private enum Body { case empty, inline(Data), asset, parts(Int) }

    private func body(of f: CloudMirror.File, _ record: CloudRecord, _ path: [String]) throws -> Body {
        if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
        if f.parts > 0 { return .parts(f.parts) }
        if let b = record.fields.bytes {
            guard Int64(b.count) == f.size else { throw CloudRecordError.corrupt(path: shown(path), reason: "inline size") }
            return b.isEmpty ? .empty : .inline(b)
        }
        // Not inline: an asset (its size is the record's `size`; a store may not say what an asset weighs without
        // downloading it, so it is read bounded by `size` and checked against the SHA-256).
        return f.size == 0 ? .empty : .asset
    }

    // MARK: Requests that group (design §13: a save takes 0.4 s and a zone takes about 2.5 a second, so saves that are
    // waiting at the same time go in one request of at most 400 items and 4 MiB of fields)

    /// One save, grouped with the others that wait with it; its own result.
    func submitSave(_ save: CloudSave) throws -> CloudSaveOutcome {
        do {
            // A save with an asset goes by itself: its upload is the slow part, and a request that carries one holds the
            // others' answers (and fails them together when it is cut). Only plain records are grouped.
            if save.asset != nil {
                let r = try call { try store.modify(zone: zone, saves: [save], deletes: [], atomic: false) }
                guard r.saves.count == 1, r.deletes.isEmpty else { throw CloudStoreError(.internalError, "the answer does not match the request") }
                return r.saves[0]
            }
            let o = try batcher.submit(save: save) { saves, deletes in
                try self.call { try self.store.modify(zone: self.zone, saves: saves, deletes: deletes, atomic: false) }
            }
            switch o {
            case .saved(let r): return .saved(r)
            case .conflict(let r): return .conflict(r)
            case .deleted: return .failed(CloudStoreError(.internalError, "a delete answered a save"))
            }
        } catch let e as CloudStoreError {
            throw map(e)
        }
    }

    // MARK: Reads

    /// Streams a live file's bytes, checked against the record's SHA-256, and returns its change tag. A record that
    /// changed while its bytes were read is read again (once): its hash then says whose bytes arrived.
    /// A download that continues: the bytes already in the file (`local` reads a range of them) are kept up to the last part
    /// boundary whose part they match, and only the parts after it are fetched (a push wakes an iOS app for about 30 s, so a
    /// large file arrives over several of them). Only a split file resumes (design §2.5); any other starts over.
    struct Resume {
        var from: Int64
        var tag: String?
        var local: (Int64, Int) throws -> Data?
    }

    private func readContent(_ path: [String], maxBytes: Int, resume: Resume? = nil, begin: (Int64) throws -> Void,
                             sink: (Data) throws -> Void) throws -> (tag: String, resumedAt: Int64) {
        var lastError: Error?
        var resume = resume
        for _ in 0..<2 {
            try checkInterrupt()
            guard let (f, record) = try fetchFile(path, payload: true), !f.tomb else { throw CloudRecordError.notFound(shown(path)) }
            if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
            if f.size > Int64(maxBytes) { throw CloudRecordError.tooLarge(path: shown(path), limit: maxBytes) }
            let content = try body(of: f, record, path)
            // What was already received counts only for the version it came from.
            if let r = resume, r.tag.map({ Self.quote(f.tag) != $0 }) ?? false { resume = nil }
            var whole = SHA256()
            var total: Int64 = 0
            var kept: (bytes: Int64, parts: Int) = (0, 0)
            func skip(_ d: Data) { total += Int64(d.count); whole.update(data: d) }
            if case .parts(let n) = content, let r = resume, r.from > 0 {
                kept = try keptParts(f, count: n, path, resume: r, skip: skip)
            }
            try begin(kept.bytes)
            func take(_ d: Data) throws {
                total += Int64(d.count)
                guard total <= f.size else { throw CloudRecordError.corrupt(path: shown(path), reason: "more bytes than its size") }
                whole.update(data: d)
                try sink(d)
            }
            switch content {
            case .empty: break
            case .inline(let d): try take(d)
            case .asset:
                try perform { try store.readAsset(zone: zone, name: f.name, maxBytes: f.size) { try take($0) } }
            case .parts(let n):
                try readParts(f, count: n, path, kept: kept, take)
            }
            guard total == f.size, Data(whole.finalize()) == f.sha256 else {
                lastError = CloudRecordError.corrupt(path: shown(path), reason: "SHA-256 does not match")
                // Another device may have replaced it meanwhile: ask again once. So is a resumed read that did not add up.
                if kept.bytes > 0 { resume = nil; continue }
                if let again = try fetchFile(path, payload: false), again.file.tag != f.tag { continue }
                throw lastError!
            }
            return (f.tag, kept.bytes)
        }
        throw lastError ?? CloudRecordError.corrupt(path: shown(path), reason: "changed while being read")
    }

    /// The part records of a split file, checked, in order (`from`: the first one wanted; the sizes before it still count).
    private func partRecord(_ f: CloudMirror.File, _ i: Int, _ path: [String]) throws -> (name: String, size: Int64, sha: Data) {
        let name = CloudRecordNaming.partName(fileName: f.name, fileSha: f.sha256 ?? Data(), index: i)
        guard let part = try perform({ try store.fetch(zone: zone, name: name, payload: false) }), part.kind == .part,
              let size = part.fields.size, size > 0, size <= Int64(layout.partSize) * 4,
              let sha = part.fields.sha256, sha.count == 32, (part.fields.schema ?? 0) <= CloudSchema.current else {
            throw CloudRecordError.corrupt(path: shown(path), reason: "part \(i) is missing or invalid")
        }
        return (name, size, sha)
    }

    /// How much of the bytes already received (`resume.from`) can be kept: whole parts from the start whose own SHA-256
    /// the local bytes match. Feeds them to `skip` (the whole file's hash and count) and returns where reading goes on.
    private func keptParts(_ f: CloudMirror.File, count n: Int, _ path: [String], resume r: Resume, skip: (Data) -> Void) throws -> (bytes: Int64, parts: Int) {
        var offset: Int64 = 0
        var count = 0
        for i in 0..<n {
            try checkInterrupt()
            let part = try partRecord(f, i, path)
            guard offset + part.size <= r.from, offset + part.size <= f.size, part.size <= Int64(Int32.max),
                  let have = try r.local(offset, Int(part.size)), Int64(have.count) == part.size,
                  Data(SHA256.hash(data: have)) == part.sha else { break }
            skip(have)
            offset += part.size
            count += 1
        }
        return (offset, count)
    }

    private func readParts(_ f: CloudMirror.File, count n: Int, _ path: [String], kept: (bytes: Int64, parts: Int) = (0, 0),
                           _ take: (Data) throws -> Void) throws {
        var offered: Int64 = kept.bytes
        for i in kept.parts..<n {   // the first ones were kept from the earlier attempt (`keptParts`)
            try checkInterrupt()
            let (name, size, sha) = try partRecord(f, i, path)
            offered += size
            guard offered <= f.size else { throw CloudRecordError.corrupt(path: shown(path), reason: "parts add up to more than the size") }
            var h = SHA256()
            var got: Int64 = 0
            try perform {
                try store.readAsset(zone: zone, name: name, maxBytes: size) { d in
                    got += Int64(d.count)
                    guard got <= size else { throw CloudRecordError.corrupt(path: shown(path), reason: "part \(i) is longer than its size") }
                    h.update(data: d)
                    try take(d)
                }
            }
            guard got == size, Data(h.finalize()) == sha else {
                throw CloudRecordError.corrupt(path: shown(path), reason: "part \(i) does not match its SHA-256")
            }
        }
    }

    public func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        try check(path)
        var data = Data()
        let tag = try readContent(path, maxBytes: maxBytes, begin: { _ in data = Data() }, sink: { data.append($0) }).tag
        return (data, Self.quote(tag))
    }

    @discardableResult
    public func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int,
                         segmentBytes: Int, progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        try check(path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SyncError.io("cannot create \(file.path)")
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // No ranged reads: a split file continues at the last part boundary its bytes match, any other starts over.
        var written = 0
        do {
            let reader = resumeFrom > 0 ? try? FileHandle(forReadingFrom: file) : nil
            defer { try? reader?.close() }
            let resume = Resume(from: Int64(resumeFrom), tag: ifETag) { offset, length in
                guard let reader else { return nil }
                try reader.seek(toOffset: UInt64(offset))
                return try reader.read(upToCount: length)
            }
            let result = try readContent(path, maxBytes: maxBytes, resume: resumeFrom > 0 ? resume : nil, begin: { keep in
                try handle.truncate(atOffset: UInt64(keep))
                try handle.seek(toOffset: UInt64(keep))
                written = 0
            }, sink: { chunk in
                try handle.write(contentsOf: chunk)
                written += chunk.count
                try progress?(chunk.count)
            })
            if written == 0, result.resumedAt == 0 { try progress?(0) }
            return DownloadResult(resumed: result.resumedAt > 0, etag: Self.quote(result.tag))
        } catch let e as CloudRecordError {
            // Bytes that failed their checks are not left to be taken for the file.
            if case .corrupt = e { try? handle.truncate(atOffset: 0) }
            throw e
        }
    }

    // MARK: Writes

    private func dropped(_ c: CloudPrecondition) -> CloudPrecondition {
        if Self.mutations.contains(.serverConditionsDropped), case .ifTag = c { return .none }
        return c
    }

    /// A file's content prepared for a save: its size and hash, and where the bytes come from.
    private struct Prepared {
        enum Source { case data(Data), file(URL) }
        var size: Int64
        var sha: Data
        var source: Source
        var partHashes: [Data]
        var inline: Data?
        var partCount: Int { partHashes.count }

        func range(_ offset: Int64, _ length: Int64) -> CloudAssetBody {
            switch source {
            case .data(let d): return .data(Data(d[(d.startIndex + Int(offset)) ..< (d.startIndex + Int(offset + length))]))
            case .file(let url): return .file(url, offset: offset, length: length)
            }
        }
    }

    private func prepare(_ body: RemoteBody, _ path: [String]) throws -> Prepared {
        let partSize = Int64(layout.partSize)
        switch body {
        case .data(let d):
            let size = Int64(d.count)
            var parts: [Data] = []
            if size > Int64(layout.partThreshold) {
                var o = 0
                while o < d.count {
                    let end = min(o + layout.partSize, d.count)
                    parts.append(Data(SHA256.hash(data: d[(d.startIndex + o) ..< (d.startIndex + end)])))
                    o = end
                }
            }
            return Prepared(size: size, sha: Data(SHA256.hash(data: d)), source: .data(d), partHashes: parts,
                            inline: size <= Int64(layout.inlineLimit) ? d : nil)
        case .file(let url):
            let h: FileHandle
            do { h = try BoundedRead.openRegularFile(url) } catch { throw SyncError.io("read \(url.path): \(error.localizedDescription)") }
            defer { try? h.close() }
            let size = Int64(try h.seekToEnd())
            try h.seek(toOffset: 0)
            if size <= Int64(layout.inlineLimit) {
                let d = try h.readToEnd() ?? Data()
                return Prepared(size: Int64(d.count), sha: Data(SHA256.hash(data: d)), source: .data(d), partHashes: [], inline: d)
            }
            let splitting = size > Int64(layout.partThreshold)
            var whole = SHA256(), part = SHA256()
            var inPart: Int64 = 0, hashed: Int64 = 0
            var parts: [Data] = []
            while hashed < size {
                try checkInterrupt()
                guard let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                whole.update(data: chunk)
                hashed += Int64(chunk.count)
                if splitting {
                    var rest = chunk[...]
                    while !rest.isEmpty {
                        let take = Int(min(partSize - inPart, Int64(rest.count)))
                        part.update(data: rest.prefix(take))
                        rest = rest.dropFirst(take)
                        inPart += Int64(take)
                        if inPart == partSize { parts.append(Data(part.finalize())); part = SHA256(); inPart = 0 }
                    }
                }
            }
            guard hashed == size else { throw SyncError.io("read \(url.path): the file changed while it was read") }
            if splitting, inPart > 0 { parts.append(Data(part.finalize())) }
            return Prepared(size: size, sha: Data(whole.finalize()), source: .file(url), partHashes: parts, inline: nil)
        }
    }

    private func fields(_ path: [String], _ p: Prepared) -> CloudFields {
        CloudFields(schema: CloudSchema.current, path: path.joined(separator: "/"), sha256: p.sha, size: p.size, bytes: p.inline,
                    parts: p.partCount > 0 ? Int64(p.partCount) : nil)
    }

    /// Uploads the parts of a split file that are not already there with the right hash (a cut upload resumes).
    private func uploadParts(_ fileName: String, _ p: Prepared) throws {
        let partSize = Int64(layout.partSize)
        for i in 0..<p.partCount {
            try checkInterrupt()
            let name = CloudRecordNaming.partName(fileName: fileName, fileSha: p.sha, index: i)
            let offset = Int64(i) * partSize
            let length = min(partSize, p.size - offset)
            if let have = try perform({ try store.fetch(zone: zone, name: name, payload: false) }), have.kind == .part,
               have.fields.sha256 == p.partHashes[i], have.fields.size == length, (have.fields.schema ?? 0) == CloudSchema.current,
               // Not one a sweep may be about to take as an orphan (it is deleted after `orphanPartAge`): older ones are saved again.
               have.modified.map({ (serverNow() ?? $0).timeIntervalSince($0) < layout.orphanPartAge / 2 }) ?? false {
                noteSaved(part: have, name: name)
                continue
            }
            let save = CloudSave(name: name, kind: .part, fields: CloudFields(schema: CloudSchema.current, sha256: p.partHashes[i], size: length),
                                 asset: p.range(offset, length), precondition: .none)
            switch try submitSave(save) {
            case .saved(let r): noteSaved(part: r, name: name)
            case .failed(let e): throw map(e)
            case .conflict: throw CloudRecordError.store(CloudStoreError(.serverRecordChanged, "part \(i)"))
            }
        }
    }

    private func noteSaved(part r: CloudRecord, name: String) {
        noteServerTime(r.modified)
        guard let parsed = CloudRecordNaming.parsePartName(name), CloudRecordNaming.isValidTag(r.changeTag) else { return }
        core.with { $0.upsert(.init(name: name, fileHash: parsed.fileHash, gen: parsed.gen, index: parsed.index, tag: r.changeTag,
                                    modified: r.modified.map(CloudMirror.millis) ?? 0)) }
    }

    /// Saves the file's record under `precondition`; the mirror learns the new tag when it was saved.
    private func commit(_ path: [String], _ p: Prepared, _ precondition: CloudPrecondition) throws -> CloudSaveOutcome {
        let name = CloudRecordNaming.fileName(path)
        var save = CloudSave(name: name, kind: .file, fields: fields(path, p), precondition: dropped(precondition))
        if p.inline == nil, p.partCount == 0 { save.asset = p.range(0, p.size) }
        let outcome = try submitSave(save)
        if case .saved(let r) = outcome { noteServerTime(r.modified) }
        if case .saved(let r) = outcome, CloudRecordNaming.isValidTag(r.changeTag), !Self.mutations.contains(.ownWritesNotMirrored) {
            core.with { m in
                m.upsert(.init(name: name, path: path, tag: r.changeTag, modified: r.modified.map(CloudMirror.millis) ?? 0, size: p.size,
                               sha256: p.sha, tomb: false, parts: p.partCount, schema: CloudSchema.current))
            }
        }
        return outcome
    }

    @discardableResult
    public func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        try check(path)
        try checkInterrupt()
        try refreshIfNeeded()
        try requireWritable(path: path)
        try requireRoom()
        try sweepIfDue()
        guard core.with({ $0.collectionExists(Array(path.dropLast())) }) else {
            throw CloudRecordError.missingParent(shown(Array(path.dropLast())))
        }
        let prepared = try prepare(body, path)
        let name = CloudRecordNaming.fileName(path)
        var partsDone = false
        func parts() throws {
            if !partsDone { try uploadParts(name, prepared); partsDone = true }
        }
        // A small create asks the server straight away (`.mustNotExist`): a record that is there comes back with its tag and
        // fields in the conflict, so nothing is fetched first. A replace over the tag it names needs no fetch either. Only a
        // create that must upload an asset or parts looks first, so a lost race does not cost the upload (design §13).
        let fastCreate = condition == .create && prepared.inline != nil && !Self.mutations.contains(.createOverTombstoneRefused)
        let fastReplace = !Self.mutations.contains(.replaceIgnoresTag)
        var known: CloudMirror.File??   // nil: fetch; .some(x): the server's record is x (nil: there is none)
        if fastCreate { known = .some(nil) }
        for _ in 0..<4 {
            let precondition: CloudPrecondition
            var current: CloudMirror.File?
            func server() throws -> CloudMirror.File? {
                if let k = known { known = nil; return k }
                return try fetchFile(path, payload: false)?.file
            }
            switch condition {
            case .replace(let etag) where fastReplace:
                guard etag.count > 2, etag.hasPrefix("\""), etag.hasSuffix("\"") else { return false }
                // An upload is not started for a replace that cannot win: the server is asked first (the mirror may be behind).
                if prepared.inline == nil {
                    guard let f = try fetchFile(path, payload: false)?.file, !f.tomb, Self.quote(f.tag) == etag else { return false }
                }
                precondition = .ifTag(String(etag.dropFirst().dropLast()))
                current = nil
            case .create:
                current = try server()
                if let f = current {
                    if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
                    if f.tomb {
                        if Self.mutations.contains(.createOverTombstoneRefused) { return false }
                        precondition = .ifTag(f.tag)
                    } else if Self.mutations.contains(.createReplacesExisting) {
                        precondition = .ifTag(f.tag)
                    } else {
                        return false   // there already (the engine reads it and finds its own bytes if it was its own)
                    }
                } else {
                    precondition = .mustNotExist
                }
            case .replace(let etag):
                current = try server()
                guard let f = current, !f.tomb else { return false }
                if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
                if Self.quote(f.tag) != etag, !Self.mutations.contains(.replaceIgnoresTag) { return false }
                precondition = .ifTag(f.tag)
            case .unconditional:
                current = try server()
                if let f = current, f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
                precondition = current.map { .ifTag($0.tag) } ?? .mustNotExist
            }
            try parts()
            switch try commit(path, prepared, precondition) {
            case .saved:
                // The replaced version's parts are named by nothing now; they stay for the sweep (a reader of the old
                // version may be between its record and its parts).
                return true
            case .conflict(let found):
                if case .replace = condition, fastReplace { return false }
                if fastCreate, let r = found, case .file(let f) = CloudMirror.ingest(r) {
                    core.with { $0.upsert(f) }
                    known = .some(f)
                }
                continue
            case .failed(let e): throw map(e)
            }
        }
        throw CloudRecordError.store(CloudStoreError(.serverRecordChanged, "\(shown(path)) kept changing"))
    }

    // MARK: Deletes (design §2.4)

    private func tombstone(_ path: [String], _ f: CloudMirror.File) throws -> CloudSaveOutcome {
        let save = CloudSave(name: f.name, kind: .file, fields: CloudFields(schema: CloudSchema.current, path: path.joined(separator: "/"), tomb: 1),
                             precondition: dropped(.ifTag(f.tag)))
        let outcome = try submitSave(save)
        if case .saved(let r) = outcome { noteServerTime(r.modified) }
        if case .saved(let r) = outcome, CloudRecordNaming.isValidTag(r.changeTag), !Self.mutations.contains(.ownWritesNotMirrored) {
            core.with { m in
                m.upsert(.init(name: f.name, path: path, tag: r.changeTag, modified: r.modified.map(CloudMirror.millis) ?? 0, size: 0,
                               sha256: nil, tomb: true, parts: 0, schema: CloudSchema.current))
            }
        }
        return outcome
    }

    /// Deletes records by name, in requests of at most `batchRecords`, halving one the store calls too big.
    func deleteRecords(_ names: [String]) throws {
        var i = 0
        while i < names.count {
            let chunk = Array(names[i ..< min(i + max(layout.batchRecords, 1), names.count)])
            try deleteChunk(chunk)
            i += chunk.count
        }
    }

    private func deleteChunk(_ names: [String]) throws {
        do {
            let result = try call { try store.modify(zone: zone, saves: [], deletes: names) }
            for o in result.deletes { if case .failed(let e) = o { throw e } }
        } catch let e as CloudStoreError where e.code == .limitExceeded && names.count > 1 {
            let mid = names.count / 2
            try deleteChunk(Array(names[..<mid]))
            try deleteChunk(Array(names[mid...]))
        } catch let e as CloudStoreError {
            throw map(e)
        }
    }

    private func partNames(of f: CloudMirror.File) -> [String] {
        guard let sha = f.sha256 else { return [] }
        return (0..<max(f.parts, 0)).map { CloudRecordNaming.partName(fileName: f.name, fileSha: sha, index: $0) }
    }

    @discardableResult
    public func delete(_ path: [String], ifETag: String?) throws -> Bool {
        try check(path)
        try checkInterrupt()
        try refreshIfNeeded()
        try requireWritable(path: path)
        try sweepIfDue()
        // A collection: every file below it (a folder's version token is the digest of what is below).
        let isCollection = core.with { $0.liveFile(path) == nil && $0.collectionExists(path) }
        if isCollection { return try deleteCollection(path, ifETag: ifETag) }

        let strong = ifETag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }
        guard let (f, _) = try fetchFile(path, payload: false) else { return true }
        if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
        if f.tomb {
            // Already deleted; finish the second step, best effort.
            try? hardDelete(f)
            return true
        }
        guard let strong else {
            try hardDelete(f)
            return true
        }
        if Self.quote(f.tag) != strong, !Self.mutations.contains(.deleteIgnoresTag) { return false }
        if Self.mutations.contains(.deleteSkipsTombstone) { return true }
        // Step 1: the tombstone, under the tag. From here the file lists as absent on every device.
        switch try tombstone(path, f) {
        case .saved: break
        case .conflict: return false
        case .failed(let e): throw map(e)
        }
        // Step 2: the delete, best effort. A failure leaves the tombstone for a later run's sweep.
        let done = core.with { $0.file(path) }
        do { try hardDelete(f) } catch is CloudRecordError {} catch is CloudStoreError {}
        return true
    }

    /// Deletes the record and its parts; the mirror forgets them.
    private func hardDelete(_ f: CloudMirror.File) throws {
        let names = [f.name] + partNames(of: f)
        try deleteRecords(names)
        core.with { m in
            m.removeFile(f.path)
            for n in names.dropFirst() { m.removePart(n) }
        }
    }

    private func deleteCollection(_ path: [String], ifETag: String?) throws -> Bool {
        if let tag = ifETag, SyncEngine.isStrong(tag), core.with({ $0.folderTag(path) }) != tag { return false }
        let files = core.with { $0.liveFiles(below: path) }
        for f in files where f.isNewer { throw CloudRecordError.newerSchema(path: f.path.joined(separator: "/")) }
        try deleteRecords(files.flatMap { [$0.name] + partNames(of: $0) })
        core.with { m in
            for f in files { m.removeFile(f.path) }
            let prefix = CloudMirror.pathKey(path)
            m.declared = m.declared.filter { $0 != prefix && !$0.hasPrefix(prefix + "/") }
        }
        return true
    }

    // MARK: Moves

    @discardableResult
    public func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool {
        try check(destination)
        // The engine creates at the final name (`atomicCreate`); a move is only for small files, read whole.
        guard let size = try stat(path)?.size else { throw CloudRecordError.notFound(shown(path)) }
        guard size <= layout.inlineLimit else { throw CloudRecordError.unsupported("a move of a file over \(layout.inlineLimit) bytes") }
        let (data, etag) = try read(path, maxBytes: layout.inlineLimit)
        guard try write(destination, .data(data), condition: .create) else { return false }
        try delete(path, ifETag: etag)
        return true
    }

    // MARK: The sweep (design §2.4, §2.5)

    /// Runs the sweep once per run, at the first write or delete (which a pull-only, held or dry run never makes).
    func sweepIfDue() throws {
        guard core.locked({ let d = core.sweepDue; core.sweepDue = false; return d }) else { return }
        try sweep()
    }

    /// Deletes the tombstones it finds after fetching each again and finding the same tag, and the parts no file
    /// names after `orphanPartAge` (by the server's clock). Best effort: a failure is for a later run (the tombstone
    /// stays, listed as absent). Never in a zone of a newer layout, and never a record of a newer layout.
    func sweep() throws {
        if (core.with { $0.zoneSchema ?? 0 }) > CloudSchema.current { return }
        let cutoff = serverNow().map { CloudMirror.millis($0.addingTimeInterval(-layout.orphanPartAge)) }
        let ignoreFiles = Self.mutations.contains(.orphanRuleIgnoresFiles)
        let (tombs, orphans) = core.with { m -> ([CloudMirror.File], [CloudMirror.Part]) in
            let tombs = m.tombstones.filter { !$0.isNewer }.sorted { $0.name < $1.name }.prefix(layout.sweepLimit)
            let orphans = m.parts.values.filter { p in
                guard let cutoff, !p.isNewer, p.modified > 0, p.modified < cutoff else { return false }
                if ignoreFiles { return true }
                guard let f = m.file(named: "f-" + p.fileHash) else { return true }
                if f.isNewer { return false }
                return f.tomb || p.index >= f.parts || f.sha256.map({ Hex.encode($0.prefix(8)) }) != p.gen
            }.sorted { $0.name < $1.name }.prefix(layout.sweepLimit)
            return (Array(tombs), Array(orphans))
        }
        guard !tombs.isEmpty || !orphans.isEmpty else { return }
        do {
            var deletable: [CloudMirror.File] = []
            // One request for up to `batchRecords` tombstones, not one each (a fetch is 0.1 s, design §13.4).
            var i = 0
            while i < tombs.count {
                try checkInterrupt()
                let chunk = Array(tombs[i ..< min(i + max(layout.batchRecords, 1), tombs.count)])
                i += chunk.count
                let current = try call { try store.fetchMany(zone: zone, names: chunk.map(\.name), payload: false) }
                for t in chunk {
                    guard let cur = current[t.name] else {
                        core.with { $0.removeRecord(named: t.name) }
                        continue
                    }
                    if case .file(let f) = CloudMirror.ingest(cur) {
                        if f.tomb, f.tag == t.tag { deletable.append(t) } else { core.with { $0.upsert(f) } }
                    }
                }
            }
            try deleteRecords(deletable.map(\.name))
            core.with { m in for t in deletable { m.removeFile(t.path) } }
            core.locked { core.diagnostics.tombstonesSwept += deletable.count }
            try deleteRecords(orphans.map(\.name))
            core.with { m in for p in orphans { m.removePart(p.name) } }
            core.locked { core.diagnostics.partsSwept += orphans.count }
        } catch is CloudRecordError {
        } catch is CloudStoreError {
        }
    }
}
