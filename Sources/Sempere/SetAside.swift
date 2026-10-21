import Age
import Crypto
import Foundation

// The set-aside store (docs/design/key-hierarchy.md §5.8; format.md §15.14; phase KH3, carried over from
// the late-file quarantine of P4a, PR #57): device-local, outside the vault, never deleted without the
// user. Files under an earlier key that the acceptance rule does not take are copied here, under a
// content-addressed name, at most 16 copies per path, durably BEFORE anything replaces or removes the
// original; a copy that cannot be kept stops that replacement (J6).

/// One file set aside (design §5.8).
public struct SetAsideItem: Hashable, Sendable {
    /// Its vault path (`notes/<id>/<name>`, `notes/<id>/att/<name>`, `notebooks/<name>`, `inbox/<name>`,
    /// `settings.age`).
    public var path: String
    /// Lowercase hex SHA-256 of its bytes (its name in the store).
    public var sha256: String
    public var reason: SetAsideReason
    /// The epoch whose key it is under, when this device knows it.
    public var epoch: Int?
    /// That epoch's id, lowercase hex.
    public var epochId: String?
    /// When it was set aside (RFC 3339).
    public var setAside: String
    /// The kept copy.
    public var file: URL
}

/// Set-aside copies on this device, per vault: `<directory>/<vaultId>/<vault path>/<sha256>.age` and its
/// `<sha256>.json` (mode 0600 in 0700 folders). The CLI's directory is `$XDG_STATE_HOME/sempere/setaside`.
public struct SetAsideStore: Sendable {
    public let directory: URL
    /// At most this many copies per path (P2/#52's rule): a further one is refused, and with it whatever
    /// replacement needed it.
    public static let maxCopiesPerPath = 16

    public init(directory: URL) { self.directory = directory }

    /// `$XDG_STATE_HOME/sempere/setaside`, else `~/.local/state/sempere/setaside`.
    public static func cliDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("setaside", isDirectory: true)
    }

    /// The vault path's folder in the store; nil for a path that is not a vault file's.
    func folder(vaultId: UUID, path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0 != ".." }),
              ["notes", "notebooks", "inbox", "settings.age"].contains(parts[0]) else { return nil }
        var url = directory.appendingPathComponent(vaultId.uuidString.lowercased(), isDirectory: true)
        for p in parts { url.appendPathComponent(p, isDirectory: true) }
        return url
    }

    private struct Meta: Codable {
        var path: String
        var reason: SetAsideReason
        var epoch: Int?
        var epochId: String?
        var setAside: String
    }

    /// Keeps `data` (the file at `path`) set aside; the copy is durable when this returns. A copy with the
    /// same bytes already kept is kept as it is.
    ///
    /// - Throws: `VaultError.setAsideFailed` when it cannot be kept (16 copies of the path already, a full
    ///   disk, a path that is no vault file's): the caller must not replace or remove the original.
    @discardableResult
    public func keep(_ data: Data, path: String, vaultId: UUID, reason: SetAsideReason, epoch: Int? = nil,
                     epochId: Data? = nil, now: Date = Date()) throws -> SetAsideItem {
        try keep(sha256: FileDigest.sha256(data), path: path, vaultId: vaultId, reason: reason, epoch: epoch,
                 epochId: epochId, now: now) { try FileIO.writePrivate(data, to: $0) }
    }

    /// `keep` for a file on disk (a blob), copied in pieces.
    @discardableResult
    public func keep(file: URL, path: String, vaultId: UUID, reason: SetAsideReason, epoch: Int? = nil,
                     epochId: Data? = nil, now: Date = Date()) throws -> SetAsideItem {
        let sha: String
        do { sha = try FileDigest.sha256(of: file).hex } catch { throw VaultError.setAsideFailed("\(path): \(error)") }
        return try keep(sha256: sha, path: path, vaultId: vaultId, reason: reason, epoch: epoch, epochId: epochId,
                        now: now) { target in
            let dir = target.deletingLastPathComponent()
            let tmp = FileIO.tempURL(in: dir)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FileIO.writeNewFile(tmp) { write in try Vault.readSourceFile(file) { try write($0) } }
            try FileIO.place(tmp, at: target)
        }
    }

    private func keep(sha256: String, path: String, vaultId: UUID, reason: SetAsideReason, epoch: Int?, epochId: Data?,
                      now: Date, write: (URL) throws -> Void) throws -> SetAsideItem {
        guard let dir = folder(vaultId: vaultId, path: path) else { throw VaultError.setAsideFailed("\(path) is no vault file") }
        let file = dir.appendingPathComponent(sha256 + ".age")
        let metaURL = dir.appendingPathComponent(sha256 + ".json")
        let meta = Meta(path: path, reason: reason, epoch: epoch, epochId: epochId.map { Hex.encode($0) },
                        setAside: RFC3339.string(now))
        do {
            try FileIO.createPrivateDirectory(directory)
            var made = directory
            for p in path.split(separator: "/").map(String.init) {
                if made == directory { made.appendPathComponent(vaultId.uuidString.lowercased(), isDirectory: true)
                    try FileIO.createPrivateDirectory(made) }
                made.appendPathComponent(p, isDirectory: true)
                try FileIO.createPrivateDirectory(made)
            }
            if FileIO.exists(file), (try? FileDigest.sha256(of: file).hex) == sha256 {
                return try item(at: file) ?? SetAsideItem(path: path, sha256: sha256, reason: reason, epoch: epoch,
                                                           epochId: meta.epochId, setAside: meta.setAside, file: file)
            }
            let copies = (try? FileIO.entries(dir).filter { $0.hasSuffix(".age") }.count) ?? 0
            guard copies < Self.maxCopiesPerPath else {
                throw VaultError.setAsideFailed("\(path): \(Self.maxCopiesPerPath) copies are set aside already")
            }
            try write(file)
            guard (try? FileDigest.sha256(of: file).hex) == sha256 else {
                try? FileManager.default.removeItem(at: file)
                throw VaultError.setAsideFailed("\(path): the copy does not read back")
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try FileIO.writePrivate(try enc.encode(meta), to: metaURL)
            try FileIO.syncDirectory(dir)
        } catch let e as VaultError {
            if case .setAsideFailed = e { throw e }
            throw VaultError.setAsideFailed("\(path): \(e)")
        } catch {
            throw VaultError.setAsideFailed("\(path): \(error)")
        }
        return SetAsideItem(path: path, sha256: sha256, reason: reason, epoch: epoch, epochId: meta.epochId,
                            setAside: meta.setAside, file: file)
    }

    private func item(at file: URL) throws -> SetAsideItem? {
        let metaURL = file.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? BoundedRead.contents(of: metaURL, maxBytes: 64 * 1024),
              let m = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return SetAsideItem(path: m.path, sha256: file.deletingPathExtension().lastPathComponent, reason: m.reason,
                            epoch: m.epoch, epochId: m.epochId, setAside: m.setAside, file: file)
    }

    /// Every item kept for `vaultId`, by path, then by when it was set aside.
    public func items(vaultId: UUID) -> [SetAsideItem] {
        let base = directory.appendingPathComponent(vaultId.uuidString.lowercased(), isDirectory: true)
        guard let e = FileManager.default.enumerator(atPath: base.path) else { return [] }
        let files = e.compactMap { $0 as? String }.filter { $0.hasSuffix(".age") }.sorted()
        return files.compactMap { try? item(at: base.appendingPathComponent($0)) }
            .sorted { ($0.path, $0.setAside) < ($1.path, $1.setAside) }
    }

    /// Deletes an item: only on the user's word (Repair's Clear, `sempere set-aside clear`).
    public func remove(_ item: SetAsideItem) throws {
        try FileIO.remove(item.file)
        try? FileIO.remove(item.file.deletingPathExtension().appendingPathExtension("json"))
    }
}

/// What `Vault.setAsideReport` says about one item (design §5.8).
public struct SetAsideStatus: Hashable, Sendable {
    public var item: SetAsideItem
    /// An accepted file with the same path and body exists (or, for a blob, the same content under its
    /// current name): the item can be cleared.
    public var superseded: Bool
}

extension Vault {
    /// The set-aside items of this vault on this device, each with whether it is superseded.
    public func setAsideReport() -> [SetAsideStatus] {
        guard let setAsideStore else { return [] }
        return setAsideStore.items(vaultId: vaultId).map { SetAsideStatus(item: $0, superseded: isSuperseded($0)) }
    }

    /// True when an accepted copy of `item`'s body is in the vault.
    func isSuperseded(_ item: SetAsideItem) -> Bool {
        guard canRead, let data = try? BoundedRead.contents(of: item.file, maxBytes: BoundedRead.maxRevisionBytes),
              let body = plainBody(of: data, path: item.path) else {
            return blobSuperseded(item)
        }
        guard let current = try? readFile(url.appendingPathComponent(item.path), maxBytes: BoundedRead.maxRevisionBytes),
              FileDigest.sha256(current) != item.sha256, let mine = acceptedBody(of: current, path: item.path) else {
            return false
        }
        return mine == body
    }

    /// A blob item is superseded when the content it holds is in its note under the current name.
    private func blobSuperseded(_ item: SetAsideItem) -> Bool {
        let parts = item.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == Self.attachmentsName, let note = UUID(uuidString: parts[1]),
              let secret, let peek = try? Self.peekBlobFile(item.file, identities: blobIdentities) else { return false }
        let name = BlobName.fileName(name: BlobName.name(digest: peek.header.digest, secret: secret),
                                     kind: BlobName.parse(parts[3])?.kind ?? .image)
        let current = attURL(note).appendingPathComponent(name)
        guard FileIO.exists(current), let p = try? Self.peekBlobFile(current, identities: identities) else { return false }
        return p.header == peek.header
    }

    /// The tagged body (gzip) of a framed vault file under any key this vault holds; nil otherwise.
    func plainBody(of data: Data, path: String) -> Data? {
        guard case .opened(let plain, let key, _) = openUnderEpochs(data), let (scope, name) = Self.framing(path) else { return nil }
        return try? BodyFraming.unframe(plain, noteId: scope, filename: name, secret: key).gzip
    }

    /// The tagged body of a framed vault file that the acceptance rule takes; nil otherwise.
    func acceptedBody(of data: Data, path: String) -> Data? {
        guard case .opened(let plain, let key, let older) = openUnderEpochs(data), let (scope, name) = Self.framing(path),
              let gzip = try? BodyFraming.unframe(plain, noteId: scope, filename: name, secret: key).gzip,
              setAsideReason(older, path: path, sha256: FileDigest.sha256(data)) == nil else { return nil }
        return gzip
    }

    /// The body framing's scope and file name of a framed vault file (revision, notebook record,
    /// `settings.age`); nil for blobs, inbox files and anything else.
    static func framing(_ path: String) -> (scope: String, name: String)? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == notesName, UUID(uuidString: parts[1]) != nil, RevisionName(parts[2]) != nil {
            return (parts[1], parts[2])
        }
        if parts.count == 2, parts[0] == NotebookRecords.folderName { return (NotebookRecords.tagScope, parts[1]) }
        if path == SharedSettings.fileName { return (SharedSettings.tagScope, SharedSettings.fileName) }
        return nil
    }

    /// Exports `item` as it is (an age file its epoch's key opens) to `directory`, under its vault path,
    /// never over an existing file. The item stays set aside.
    @discardableResult
    public func exportSetAside(_ item: SetAsideItem, to directory: URL) throws -> URL {
        let target = directory.appendingPathComponent(item.path)
        try FileIO.createDirectory(target.deletingLastPathComponent())
        let tmp = FileIO.tempURL(in: target.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileIO.writeNewFile(tmp) { write in try Self.readSourceFile(item.file) { try write($0) } }
        try FileIO.placeNew(tmp, at: target)
        return target
    }

    /// Keeps a set-aside item in the vault on the user's word (design §5.8 "Keep"; it may come from a
    /// removed device): its body re-encrypted under the current key, at its path (a revision, a notebook
    /// record, `settings.age`) or under the current name (a blob). The item stays set aside until cleared.
    ///
    /// - Throws: `VaultError.setAsideFailed` when it does not verify under any key this vault holds, and
    ///   what writes throw.
    public func keepSetAside(_ item: SetAsideItem) throws {
        try requireWritable()
        let parts = item.path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[2] == Self.attachmentsName, let note = UUID(uuidString: parts[1]) {
            try reencryptBlob(at: item.file, note: note, fileName: parts[3])
            return
        }
        let data = try BoundedRead.contents(of: item.file, maxBytes: BoundedRead.maxRevisionBytes)
        guard let gzip = plainBody(of: data, path: item.path), let (scope, name) = Self.framing(item.path) else {
            throw VaultError.setAsideFailed("\(item.path) does not verify under any key this device holds")
        }
        let target = url.appendingPathComponent(item.path)
        if let current = try? readFile(target, maxBytes: BoundedRead.maxRevisionBytes), acceptedBody(of: current, path: item.path) == gzip {
            return   // already in the vault, accepted
        }
        let fresh = try encrypt(BodyFraming.frame(gzip: gzip, noteId: scope, filename: name, secret: try requireSecret()))
        // What is at the path now is unaccepted (else it would be the same body): it is set aside first.
        if FileIO.exists(target), let setAsideStore {
            try setAsideStore.keep(try readFile(target, maxBytes: BoundedRead.maxRevisionBytes), path: item.path,
                                   vaultId: vaultId, reason: .notSealed)
        }
        try recordWrite(path: item.path, bytes: fresh)
        try FileIO.createDirectory(target.deletingLastPathComponent())
        try FileIO.writeAtomically(fresh, to: target, replacing: true)
    }

    /// A media type whose kind is `kind` (format.md §8.1.2): only the file name's kind depends on it.
    static func mediaType(of kind: BlobKind) -> String? {
        let types = ["application/pdf", BlobRef.transcriptType, "image/unknown", "audio/unknown", "video/unknown",
                     "application/octet-stream"]
        return types.first { BlobKind(mediaType: $0) == kind }
    }

    /// Writes the content of the blob file `source` (under any key this vault holds) as a blob of `note`
    /// under the current key and name; nothing when it is there already.
    func reencryptBlob(at source: URL, note: UUID, fileName: String) throws {
        let secrets = [try requireSecret()] + blobOlderEpochs.map(\.key)
        let peek: BlobPeek
        do { peek = try Self.peekBlobFile(source, identities: blobIdentities) } catch {
            throw VaultError.setAsideFailed("\(fileName) does not open under any key this device holds")
        }
        guard let kind = BlobName.parse(fileName)?.kind, let type = Self.mediaType(of: kind) else {
            throw VaultError.setAsideFailed("\(fileName) is no blob name this version writes")
        }
        let ref = BlobRef(sha256: peek.header.sha256, size: peek.header.length, type: type)
        try writeBlobStream(note: note, ref: ref, digest: peek.header.digest) { emit in
            _ = try Self.readBlobFile(source, identities: blobIdentities, secrets: secrets, expected: nil,
                                      maxContent: BlobRef.maxSize, name: fileName, sink: emit)
        }
    }
}
