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
        if let a = record.fields.assetSize {
            guard a == f.size else { throw CloudRecordError.corrupt(path: shown(path), reason: "asset size") }
            return .asset
        }
        if f.size == 0 { return .empty }
        throw CloudRecordError.corrupt(path: shown(path), reason: "no content")
    }

    // MARK: Reads

    /// Streams a live file's bytes, checked against the record's SHA-256, and returns its change tag. A record that
    /// changed while its bytes were read is read again (once): its hash then says whose bytes arrived.
    private func readContent(_ path: [String], maxBytes: Int, begin: () throws -> Void, sink: (Data) throws -> Void) throws -> String {
        var lastError: Error?
        for _ in 0..<2 {
            try checkInterrupt()
            guard let (f, record) = try fetchFile(path, payload: true), !f.tomb else { throw CloudRecordError.notFound(shown(path)) }
            if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
            if f.size > Int64(maxBytes) { throw CloudRecordError.tooLarge(path: shown(path), limit: maxBytes) }
            let content = try body(of: f, record, path)
            try begin()
            var whole = SHA256()
            var total: Int64 = 0
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
                try readParts(f, count: n, path, take)
            }
            guard total == f.size, Data(whole.finalize()) == f.sha256 else {
                lastError = CloudRecordError.corrupt(path: shown(path), reason: "SHA-256 does not match")
                // Another device may have replaced it meanwhile: ask again once.
                if let again = try fetchFile(path, payload: false), again.file.tag != f.tag { continue }
                throw lastError!
            }
            return f.tag
        }
        throw lastError ?? CloudRecordError.corrupt(path: shown(path), reason: "changed while being read")
    }

    private func readParts(_ f: CloudMirror.File, count n: Int, _ path: [String], _ take: (Data) throws -> Void) throws {
        var offered: Int64 = 0
        for i in 0..<n {
            try checkInterrupt()
            let name = CloudRecordNaming.partName(fileName: f.name, index: i)
            guard let part = try perform({ try store.fetch(zone: zone, name: name, payload: false) }), part.kind == .part,
                  let size = part.fields.size, size > 0, size <= Int64(layout.partSize) * 4, part.fields.assetSize == size,
                  let sha = part.fields.sha256, sha.count == 32, (part.fields.schema ?? 0) <= CloudSchema.current else {
                throw CloudRecordError.corrupt(path: shown(path), reason: "part \(i) is missing or invalid")
            }
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
        let tag = try readContent(path, maxBytes: maxBytes, begin: { data = Data() }, sink: { data.append($0) })
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
        // No ranged reads: a download always starts over.
        var written = 0
        do {
            let tag = try readContent(path, maxBytes: maxBytes, begin: {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                written = 0
            }, sink: { chunk in
                try handle.write(contentsOf: chunk)
                written += chunk.count
                try progress?(chunk.count)
            })
            if written == 0 { try progress?(0) }
            return DownloadResult(resumed: false, etag: Self.quote(tag))
        } catch let e as CloudRecordError {
            // Bytes that failed their checks are not left to be taken for the file.
            if case .corrupt = e { try? handle.truncate(atOffset: 0) }
            throw e
        }
    }

    // MARK: Writes

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
            case .data(let d): return .data(d.subdata(in: Int(offset) ..< Int(offset + length)))
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
            let name = CloudRecordNaming.partName(fileName: fileName, index: i)
            let offset = Int64(i) * partSize
            let length = min(partSize, p.size - offset)
            if let have = try perform({ try store.fetch(zone: zone, name: name, payload: false) }), have.kind == .part,
               have.fields.sha256 == p.partHashes[i], have.fields.assetSize == length, (have.fields.schema ?? 0) == CloudSchema.current {
                noteSaved(part: have, name: name)
                continue
            }
            let save = CloudSave(name: name, kind: .part, fields: CloudFields(schema: CloudSchema.current, sha256: p.partHashes[i], size: length),
                                 asset: p.range(offset, length), precondition: .none)
            let result = try perform { try store.modify(zone: zone, saves: [save], deletes: []) }
            switch result.saves.first {
            case .saved(let r)?: noteSaved(part: r, name: name)
            case .failed(let e)?: throw map(e)
            default: throw CloudRecordError.store(CloudStoreError(.serverRecordChanged, "part \(i)"))
            }
        }
    }

    private func noteSaved(part r: CloudRecord, name: String) {
        guard let parsed = CloudRecordNaming.parsePartName(name), CloudRecordNaming.isValidTag(r.changeTag) else { return }
        core.with { $0.upsert(.init(name: name, fileHash: parsed.fileHash, index: parsed.index, tag: r.changeTag,
                                    modified: r.modified.map(CloudMirror.millis) ?? 0)) }
    }

    /// Saves the file's record under `precondition`; the mirror learns the new tag when it was saved.
    private func commit(_ path: [String], _ p: Prepared, _ precondition: CloudPrecondition) throws -> CloudSaveOutcome {
        let name = CloudRecordNaming.fileName(path)
        var save = CloudSave(name: name, kind: .file, fields: fields(path, p), precondition: precondition)
        if p.inline == nil, p.partCount == 0 { save.asset = p.range(0, p.size) }
        let result = try perform { try store.modify(zone: zone, saves: [save], deletes: []) }
        guard let outcome = result.saves.first else { throw CloudRecordError.corrupt(path: shown(path), reason: "no answer to a save") }
        if case .saved(let r) = outcome, CloudRecordNaming.isValidTag(r.changeTag) {
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
        guard core.with({ $0.collectionExists(Array(path.dropLast())) }) else {
            throw CloudRecordError.missingParent(shown(Array(path.dropLast())))
        }
        let prepared = try prepare(body, path)
        let name = CloudRecordNaming.fileName(path)
        var partsDone = false
        func parts() throws {
            if !partsDone { try uploadParts(name, prepared); partsDone = true }
        }
        let same = { (f: CloudMirror.File) in f.size == prepared.size && f.sha256 == prepared.sha }

        for _ in 0..<4 {
            let current = try fetchFile(path, payload: false)?.file
            if let f = current, f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
            let precondition: CloudPrecondition
            switch condition {
            case .create:
                if let f = current {
                    if f.tomb {
                        if Self.mutations.contains(.createOverTombstoneRefused) { return false }
                        precondition = .ifTag(f.tag)
                    } else if Self.mutations.contains(.createReplacesExisting) {
                        precondition = .ifTag(f.tag)
                    } else {
                        // There already: the same bytes is a create that lost its answer, or two devices writing one file.
                        return same(f)
                    }
                } else {
                    precondition = .mustNotExist
                }
            case .replace(let etag):
                guard let f = current, !f.tomb else { return false }
                if Self.quote(f.tag) != etag, !Self.mutations.contains(.replaceIgnoresTag) { return same(f) }
                precondition = .ifTag(f.tag)
            case .unconditional:
                precondition = current.map { .ifTag($0.tag) } ?? .mustNotExist
            }
            try parts()
            switch try commit(path, prepared, precondition) {
            case .saved: return true
            case .conflict: continue
            case .failed(let e): throw map(e)
            }
        }
        throw CloudRecordError.store(CloudStoreError(.serverRecordChanged, "\(shown(path)) kept changing"))
    }

    // MARK: Deletes (design §2.4)

    private func tombstone(_ path: [String], _ f: CloudMirror.File) throws -> CloudSaveOutcome {
        let save = CloudSave(name: f.name, kind: .file, fields: CloudFields(schema: CloudSchema.current, path: path.joined(separator: "/"), tomb: 1),
                             precondition: .ifTag(f.tag))
        let result = try perform { try store.modify(zone: zone, saves: [save], deletes: []) }
        guard let outcome = result.saves.first else { throw CloudRecordError.corrupt(path: shown(path), reason: "no answer to a save") }
        if case .saved(let r) = outcome, CloudRecordNaming.isValidTag(r.changeTag) {
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
        (0..<max(f.parts, 0)).map { CloudRecordNaming.partName(fileName: f.name, index: $0) }
    }

    @discardableResult
    public func delete(_ path: [String], ifETag: String?) throws -> Bool {
        try check(path)
        try checkInterrupt()
        try refreshIfNeeded()
        try requireWritable(path: path)
        // A collection: every file below it (a folder's version token is the digest of what is below).
        let isCollection = core.with { $0.liveFile(path) == nil && $0.collectionExists(path) }
        if isCollection { return try deleteCollection(path, ifETag: ifETag) }

        let strong = ifETag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }
        guard let (f, record) = try fetchFile(path, payload: false) else { return true }
        if f.isNewer { throw CloudRecordError.newerSchema(path: path.joined(separator: "/")) }
        if f.tomb {
            // Already deleted; finish the second step, best effort.
            try? hardDelete(f)
            return true
        }
        guard let strong else {
            try hardDelete(f, parts: record.fields.parts.map { Int($0) } ?? f.parts)
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
        do { try hardDelete(done ?? f, parts: f.parts) } catch is CloudRecordError {} catch is CloudStoreError {}
        return true
    }

    /// Deletes the record and its parts; the mirror forgets them.
    private func hardDelete(_ f: CloudMirror.File, parts: Int? = nil) throws {
        let names = [f.name] + partNames(of: parts.map { var g = f; g.parts = $0; return g } ?? f)
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
        let (data, etag) = try read(path, maxBytes: 256 << 20)
        guard try write(destination, .data(data), condition: .create) else { return false }
        try delete(path, ifETag: etag)
        return true
    }

    // MARK: The sweep (design §2.4, §2.5)

    /// Deletes the tombstones it finds after fetching each again and finding the same tag, and the parts no file
    /// names after `orphanPartAge`. Best effort: a failure is for a later run (the tombstone stays, listed as absent).
    func sweep() throws {
        let cutoff = CloudMirror.millis(now().addingTimeInterval(-layout.orphanPartAge))
        let (tombs, orphans) = core.with { m -> ([CloudMirror.File], [CloudMirror.Part]) in
            let tombs = m.tombstones.filter { !$0.isNewer }.sorted { $0.name < $1.name }.prefix(layout.sweepLimit)
            let orphans = m.parts.values.filter { p in
                guard p.modified > 0, p.modified < cutoff else { return false }
                guard let f = m.file(named: "f-" + p.fileHash) else { return true }
                return f.tomb || p.index >= f.parts
            }.sorted { $0.name < $1.name }.prefix(layout.sweepLimit)
            return (Array(tombs), Array(orphans))
        }
        guard !tombs.isEmpty || !orphans.isEmpty else { return }
        do {
            var deletable: [CloudMirror.File] = []
            for t in tombs {
                try checkInterrupt()
                guard let cur = try call({ try store.fetch(zone: zone, name: t.name, payload: false) }) else {
                    core.with { $0.removeRecord(named: t.name) }
                    continue
                }
                if case .file(let f) = CloudMirror.ingest(cur) {
                    if f.tomb, f.tag == t.tag { deletable.append(t) } else { core.with { $0.upsert(f) } }
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
