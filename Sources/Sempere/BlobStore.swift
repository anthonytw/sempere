import Age
import Crypto
import Foundation

// MARK: - The per-note blob store (docs/format.md §8.1)
//
// Every blob operation is local to one note: blobs live in
// `notes/<noteId>/att/` and a reference resolves only inside the note whose
// revision holds it (§8.1.1). Blobs are streamed: memory is one 64 KiB age
// chunk plus small buffers, never the blob (§8.1.4), except for the in-memory
// `Data` APIs, which callers use for blobs of at most 16 MiB.

/// Read access to the blobs of one note, for renderers and exporters
/// (`docs/attachments.md` §10). `Vault.blobSource(note:)` returns one.
public protocol BlobSource: Sendable {
    /// The verified content of a referenced blob (at most `maxBytes`).
    func data(for ref: BlobRef, maxBytes: Int) throws -> Data
    /// Runs `body` with a private temporary file holding the verified
    /// content (for random access: PDFs, audio playback), deleted afterwards.
    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T
    /// Hands the content to `sink` in pieces, in memory proportional to a
    /// piece whatever the blob's size (a 1 GiB video into an export). Content
    /// may be handed out before the whole is verified: if this throws, what
    /// the sink received must be discarded (format.md §8.1.4).
    func stream(for ref: BlobRef, _ sink: (Data) throws -> Void) throws
    /// A cheap check that the blob is there and is the one referenced (its
    /// header, not its whole content), so an export can leave out a missing
    /// 1 GiB clip instead of failing halfway through writing it.
    func isAvailable(_ ref: BlobRef) -> Bool
}

extension BlobSource {
    /// True: sources without a cheaper check find out when they read.
    public func isAvailable(_ ref: BlobRef) -> Bool { true }

    /// Reads the verified temporary file of `withFile` in 1 MiB pieces.
    public func stream(for ref: BlobRef, _ sink: (Data) throws -> Void) throws {
        try withFile(for: ref) { url in try Vault.readSourceFile(url, sink) }
    }
}

/// The blobs of one note of a vault, as a `BlobSource`.
public struct NoteBlobSource: BlobSource {
    public let vault: Vault
    public let note: UUID

    public func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        try vault.readBlob(note: note, ref, maxBytes: maxBytes)
    }

    public func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        try vault.withBlobFile(note: note, ref, body)
    }

    /// The blob file exists and its first chunk holds the referenced header
    /// under a name that verifies (format.md §8.1.4 step 2).
    public func isAvailable(_ ref: BlobRef) -> Bool {
        guard let url = try? vault.locateBlob(note: note, ref) else { return false }
        return vault.isValidBlob(url, ref: ref)
    }

    /// Decrypts straight into `sink`, without a temporary file.
    public func stream(for ref: BlobRef, _ sink: (Data) throws -> Void) throws {
        try vault.streamBlob(note: note, ref, sink)
    }
}

extension Vault {
    /// A note's attachment folder name (format.md §1).
    package static let attachmentsName = "att"
    /// The largest blob the in-memory APIs hold by default (format.md §8.1.4).
    public static let maxInMemoryBlobBytes = 16 << 20
    /// Plaintext piece size for streaming writes.
    static let blobPieceSize = 1 << 20

    func attURL(_ noteId: UUID) -> URL { noteURL(noteId).appendingPathComponent(Self.attachmentsName) }

    /// The blob of `note` a reference resolves to, as a `BlobSource`.
    public func blobSource(note: UUID) -> NoteBlobSource { NoteBlobSource(vault: self, note: note) }

    /// The keyed name of content with this SHA-256 (32 raw bytes) under the
    /// current vault secret (format.md §8.1.2).
    ///
    /// - Throws: `VaultError.locked` without the secret,
    ///   `BlobError.invalidReference` unless `sha256` is 32 bytes.
    public func blobName(sha256: Data) throws -> String {
        let secret = try requireSecret()
        guard sha256.count == 32 else { throw BlobError.invalidReference }
        return BlobName.name(digest: sha256, secret: secret)
    }

    /// `<blobName>.<kind>.age` for a reference, under the current secret.
    public func blobFileName(for ref: BlobRef) throws -> String {
        guard ref.isValid, let digest = ref.digest else { throw BlobError.invalidReference }
        return BlobName.fileName(name: try blobName(sha256: digest), kind: ref.kind)
    }

    /// The secrets a blob name may verify under: the current one and, while a
    /// secret-rotating recipient change is unfinished, the previous one
    /// (format.md §8.1.5).
    var blobSecrets: [VaultSecret] {
        guard let secret else { return [] }
        if let previousSecret, pendingRewrap { return [secret, previousSecret] }
        return [secret]
    }

    /// The paths a reference may resolve to, in lookup order: the name under
    /// the current secret, then (journal present) under the previous one.
    /// The kind always comes from the reference; no other kind is guessed.
    func blobCandidates(note: UUID, _ ref: BlobRef) throws -> [URL] {
        guard ref.isValid, let digest = ref.digest else { throw BlobError.invalidReference }
        _ = try requireSecret()
        let dir = attURL(note)
        return blobSecrets.map {
            dir.appendingPathComponent(BlobName.fileName(name: BlobName.name(digest: digest, secret: $0), kind: ref.kind))
        }
    }

    /// The existing blob file for a reference.
    ///
    /// - Throws: `BlobError.missing` (with the current path) when none exists.
    func locateBlob(note: UUID, _ ref: BlobRef) throws -> URL {
        let candidates = try blobCandidates(note: note, ref)
        if let found = candidates.first(where: { FileIO.exists($0) }) { return found }
        throw BlobError.missing(candidates[0].path)
    }

    // MARK: - Reading

    /// The verified content of a blob of `note` (format.md §8.1.4): framing,
    /// zero padding, content hash, the reference's hash and size, and the
    /// keyed name are all checked before anything is returned.
    ///
    /// - Parameter maxBytes: the largest content accepted (default 16 MiB;
    ///   larger blobs should be streamed with `streamBlob` or `withBlobFile`).
    /// - Throws: `VaultError.locked` / `.noIdentities` / `.legacyVault`,
    ///   `BlobError` for a missing or bad blob (`contentTooLarge` beyond
    ///   `maxBytes`).
    public func readBlob(note: UUID, _ ref: BlobRef, maxBytes: Int = Vault.maxInMemoryBlobBytes) throws -> Data {
        guard ref.isValid else { throw BlobError.invalidReference }
        guard ref.size <= Int64(maxBytes) else { throw BlobError.contentTooLarge(limit: Int64(maxBytes)) }
        var out = Data()
        out.reserveCapacity(Int(ref.size))
        try streamBlob(note: note, ref, maxBytes: Int64(maxBytes)) { out += $0 }
        return out
    }

    /// Streams the content of a blob of `note` to `sink` in pieces of at most
    /// 64 KiB. Content is handed out as it is decrypted, **before** the
    /// whole-content hash is known: if this throws, everything the sink
    /// received must be discarded (format.md §8.1.4).
    public func streamBlob(note: UUID, _ ref: BlobRef, maxBytes: Int64 = BlobRef.maxSize,
                           _ sink: (Data) throws -> Void) throws {
        try requireMigrated()
        _ = try requireReadable()
        let url = try locateBlob(note: note, ref)
        _ = try Self.readBlobFile(url, identities: identities, secrets: blobSecrets, expected: ref,
                                  maxContent: maxBytes, sink: sink)
    }

    /// Runs `body` with a private temporary file (mode 0600, in the system
    /// temporary directory) holding the verified content of a blob, and
    /// deletes it afterwards. The file exists only once the whole blob has
    /// verified. For random access (PDF parsing, audio playback).
    ///
    /// - Parameter pathExtension: given to the temporary file (players and
    ///   PDF readers may look at it).
    public func withBlobFile<T>(note: UUID, _ ref: BlobRef, pathExtension: String? = nil,
                                _ body: (URL) throws -> T) throws -> T {
        var tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sempere-blob-" + UUID().uuidString.lowercased())
        if let pathExtension, !pathExtension.isEmpty { tmp.appendPathExtension(pathExtension) }
        try FileIO.writeNewFile(tmp) { write in try streamBlob(note: note, ref) { try write($0) } }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try body(tmp)
    }

    // MARK: - Writing

    /// Writes `data` as a blob of `note` (format.md §8.1.4 steps 1–3) and
    /// returns its reference. Write the revision that references it only
    /// after this returns (step 4).
    ///
    /// Reuses an existing valid blob of the same content; replaces one that
    /// exists under the name but fails the header check. Adds the
    /// `attachments` feature to `vault.json` first (format.md §2).
    ///
    /// - Throws: `BlobError.tooLarge` over 1 GiB, `VaultError` (locked, no
    ///   identities, legacy vault, unsupported feature, I/O).
    @discardableResult
    public func writeBlob(note: UUID, _ data: Data, type: String) throws -> BlobRef {
        guard Int64(data.count) <= BlobRef.maxSize else { throw BlobError.tooLarge(Int64(data.count)) }
        let digest = Data(SHA256.hash(data: data))
        let ref = BlobRef(sha256: BlobHeader(digest: digest, length: 0).sha256, size: Int64(data.count), type: type)
        try writeBlobStream(note: note, ref: ref, digest: digest) { emit in
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: min(Self.blobPieceSize, data.endIndex - offset))
                try emit(Data(data[offset..<end]))
                offset = end
            }
        }
        return ref
    }

    /// The reference `writeBlob(note:contentsOf:type:edits:)` would return
    /// for `file` with `edits` applied: one streaming pass, nothing written.
    ///
    /// - Throws: `BlobError.tooLarge` over 1 GiB, `VaultError.io`.
    public static func blobRef(contentsOf file: URL, type: String, edits: [ByteEdit] = []) throws -> BlobRef {
        let (digest, size) = try digestFile(file, edits: edits)
        return BlobRef(sha256: BlobHeader(digest: digest, length: 0).sha256, size: size, type: type)
    }

    static func digestFile(_ file: URL, edits: [ByteEdit]) throws -> (Data, Int64) {
        var hasher = SHA256()
        var size: Int64 = 0
        try readSourceFile(file, edits: edits) { piece in
            size += Int64(piece.count)
            guard size <= BlobRef.maxSize else { throw BlobError.tooLarge(size) }
            hasher.update(data: piece)
        }
        return (Data(hasher.finalize()), size)
    }

    /// Writes the file at `file` as a blob of `note`, streaming (two passes:
    /// one to hash it, one to encrypt it; a file that changes in between is
    /// refused with `BlobError.sourceChanged`), in memory proportional to a
    /// piece whatever the file's size. `edits` change bytes on the way (a
    /// video's metadata removed in place, `VideoMetadata`); the file itself is
    /// never changed. As `writeBlob(note:_:type:)` otherwise.
    @discardableResult
    public func writeBlob(note: UUID, contentsOf file: URL, type: String, edits: [ByteEdit] = []) throws -> BlobRef {
        let (digest, size) = try Self.digestFile(file, edits: edits)
        let ref = BlobRef(sha256: BlobHeader(digest: digest, length: 0).sha256, size: size, type: type)
        try writeBlobStream(note: note, ref: ref, digest: digest) { emit in
            var seen: Int64 = 0
            try Self.readSourceFile(file, edits: edits) { piece in
                seen += Int64(piece.count)
                guard seen <= size else { throw BlobError.sourceChanged }
                try emit(piece)
            }
        }
        return ref
    }

    /// Copies a blob of note `from` into note `to` (format.md §8.1.4: copy
    /// and paste, move to another note, duplicating a note). Call it before
    /// writing the delta in `to` that references it.
    ///
    /// The source is verified as it is read. When it is under its current
    /// name the age file is copied byte for byte (the name does not depend on
    /// the note, so the copy is valid there); during an unfinished rotation a
    /// source still under the previous name is re-encrypted under the current
    /// one instead. An existing valid copy in `to` is kept.
    public func copyBlob(_ ref: BlobRef, from: UUID, to: UUID) throws {
        try requireMigrated()
        _ = try requireReadable()
        try requireWritable()
        let source = try locateBlob(note: from, ref)
        guard let digest = ref.digest else { throw BlobError.invalidReference }
        let target = try blobCandidates(note: to, ref)[0]
        if from == to && source == target { return }
        try ensureFeature(VaultManifest.attachmentsFeature)
        if FileIO.exists(target), isValidBlob(target, ref: ref) { return }
        guard source.lastPathComponent == target.lastPathComponent else {
            // Still under the outgoing secret's name: re-encrypt to the current name.
            try writeBlobStream(note: to, ref: ref, digest: digest) { emit in
                _ = try Self.readBlobFile(source, identities: identities, secrets: blobSecrets, expected: ref,
                                          maxContent: BlobRef.maxSize, sink: emit)
            }
            return
        }
        let dir = target.deletingLastPathComponent()
        try FileIO.createDirectory(dir)
        let tmp = FileIO.tempURL(in: dir)
        // One pass: the raw bytes are copied as the decryptor reads them, and
        // the copy is placed only once the whole source verified.
        try FileIO.writeNewFile(tmp) { write in
            _ = try Self.readBlobFile(source, identities: identities, secrets: blobSecrets, expected: ref,
                                      maxContent: BlobRef.maxSize, raw: write)
        }
        try place(tmp, at: target, ref: ref)
    }

    /// Steps 1–3 of format.md §8.1.4 for content that `produce` emits (and
    /// whose hash and length are already known): reuse a valid existing file,
    /// else encrypt header, content and Padmé zero padding to a temporary file
    /// and put it in place (replacing only a file that fails the check).
    func writeBlobStream(note: UUID, ref: BlobRef, digest: Data,
                         produce: (_ emit: (Data) throws -> Void) throws -> Void) throws {
        try requireMigrated()
        _ = try requireReadable()
        try requireWritable()
        guard ref.isValid else { throw BlobError.invalidReference }
        let target = try blobCandidates(note: note, ref)[0]
        if FileIO.exists(target), isValidBlob(target, ref: ref) { return }
        try ensureFeature(VaultManifest.attachmentsFeature)
        let dir = target.deletingLastPathComponent()
        try FileIO.createDirectory(dir)
        let tmp = FileIO.tempURL(in: dir)
        let encryptor = try AgeEncryptor(to: try ageRecipients(), allowMixedPostQuantum: true)
        try FileIO.writeNewFile(tmp) { write in
            try write(try encryptor.update(BlobFraming.header(digest: digest, length: ref.size)))
            var hasher = SHA256()
            var count: Int64 = 0
            try withoutActuallyEscaping(write) { write in
                try produce { piece in
                    count += Int64(piece.count)
                    guard count <= ref.size else { throw BlobError.sourceChanged }
                    hasher.update(data: piece)
                    try write(try encryptor.update(piece))
                }
            }
            guard count == ref.size, Data(hasher.finalize()) == digest else { throw BlobError.sourceChanged }
            var padding = BlobFraming.paddedPlaintextLength(contentLength: ref.size) - Int64(BlobFraming.headerSize) - ref.size
            let zeros = Data(count: Self.blobPieceSize)
            while padding > 0 {
                let n = Int(min(padding, Int64(zeros.count)))
                try write(try encryptor.update(zeros.prefix(n)))
                padding -= Int64(n)
            }
            try write(try encryptor.finish())
        }
        try place(tmp, at: target, ref: ref)
    }

    /// Puts a finished blob in place: never over a valid file (a concurrent
    /// writer of the same content won), atomically over an invalid one
    /// (format.md §8.1.4 step 2).
    private func place(_ tmp: URL, at target: URL, ref: BlobRef) throws {
        if FileIO.exists(target), !isValidBlob(target, ref: ref) {
            try FileIO.place(tmp, at: target)
            return
        }
        do { try FileIO.placeNew(tmp, at: target) } catch VaultError.alreadyExists {
            if isValidBlob(target, ref: ref) { return }
            throw VaultError.alreadyExists(target.path)
        }
    }

    /// The step-2 check of format.md §8.1.4: the first chunk decrypts to a
    /// header with the reference's hash and length, and the name verifies.
    func isValidBlob(_ url: URL, ref: BlobRef) -> Bool {
        guard let peek = try? Self.peekBlobFile(url, identities: identities) else { return false }
        return peek.header.sha256 == ref.sha256 && peek.header.length == ref.size
            && BlobName.verify(BlobName.parse(url.lastPathComponent)?.name ?? "", digest: peek.header.digest,
                               secrets: blobSecrets) != nil
    }

    /// Feeds a source file to `body` in 1 MiB pieces (regular files only),
    /// with `edits` applied.
    public static func readSourceFile(_ url: URL, edits: [ByteEdit] = [], _ body: (Data) throws -> Void) throws {
        let handle = try BoundedRead.openRegularFile(url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while true {
            var piece: Data
            do { piece = try autoreleasing { try handle.read(upToCount: blobPieceSize) ?? Data() } } catch {
                throw VaultError.io("read \(url.path): \(error)")
            }
            if piece.isEmpty { return }
            ByteEdit.apply(edits, to: &piece, at: offset)
            offset += UInt64(piece.count)
            try body(piece)
        }
    }

    // MARK: - Blob files (no vault needed)

    /// The header of a blob file and the stanza counts of its age header,
    /// from the first STREAM chunk only (format.md §8.1.5 "complete").
    struct BlobPeek {
        var header: BlobHeader
        var stanzas: [String: Int]
    }

    /// Decrypts only the first chunk of a blob file and parses its header.
    static func peekBlobFile(_ url: URL, identities: [any AgeIdentity]) throws -> BlobPeek {
        let (decryptor, handle) = try openBlobFile(url, identities: identities)
        defer { try? handle.close() }
        var stanzas: [String: Int] = [:]
        for s in decryptor.header.stanzas { stanzas[s.type, default: 0] += 1 }
        let first: Data?
        do { first = try decryptor.next() } catch let e as BlobError { throw e } catch {
            throw BlobError.undecryptable("\(error)")
        }
        return BlobPeek(header: try BlobFraming.parseHeader(first ?? Data()), stanzas: stanzas)
    }

    /// Reads a whole blob file and checks it (format.md §8.1.4): age
    /// authentication of every chunk, framing, zero padding, content hash,
    /// `expected`'s hash and size, and, when `secrets` is not empty, that the
    /// file name is the keyed name of the header's hash under one of them
    /// (checked before any content is handed out).
    ///
    /// - Parameters:
    ///   - sink: receives the content, unverified until this returns.
    ///   - raw: receives the file's bytes exactly as read (for byte copies).
    /// - Returns: the header and the index in `secrets` the name verified
    ///   under (nil when not checked).
    /// `name` is the blob file name the keyed name is checked against;
    /// nil for `url`'s own (a download in a partial file passes its target's).
    static func readBlobFile(_ url: URL, identities: [any AgeIdentity], secrets: [VaultSecret], expected: BlobRef?,
                             maxContent: Int64, name: String? = nil, sink: (Data) throws -> Void = { _ in },
                             raw: (Data) throws -> Void = { _ in }) throws -> (header: BlobHeader, secret: Int?) {
        // The decryptor is released before this returns, so `raw` does not
        // actually escape.
        try withoutActuallyEscaping(raw) { raw in
            let (decryptor, handle) = try openBlobFile(url, identities: identities, raw: raw)
            defer { try? handle.close() }
            return try readBlob(decryptor, fileName: name ?? url.lastPathComponent, secrets: secrets, expected: expected,
                                maxContent: maxContent, sink: sink)
        }
    }

    private static func readBlob(_ decryptor: AgeDecryptor, fileName: String, secrets: [VaultSecret], expected: BlobRef?,
                                 maxContent: Int64, sink: (Data) throws -> Void) throws -> (header: BlobHeader, secret: Int?) {
        var checker = BlobPlaintextChecker(expected: expected, maxContent: maxContent)
        var matched: Int?
        var nameChecked = secrets.isEmpty
        while true {
            let chunk: Data?
            do { chunk = try decryptor.next() } catch let e as BlobError { throw e } catch let e as VaultError {
                throw e
            } catch {
                throw BlobError.undecryptable("\(error)")
            }
            guard let chunk else { break }
            guard !nameChecked else {
                try checker.consume(chunk, sink: sink)
                continue
            }
            // The header comes whole in the first chunk of any valid blob
            // (only the last chunk may be short); the name is checked before
            // any content reaches the sink.
            try checker.consume(chunk.prefix(BlobFraming.headerSize))
            guard let header = checker.header else { continue }
            guard let name = BlobName.parse(fileName)?.name,
                  let i = BlobName.verify(name, digest: header.digest, secrets: secrets)
            else { throw BlobError.nameMismatch }
            matched = i
            nameChecked = true
            try checker.consume(chunk.dropFirst(BlobFraming.headerSize), sink: sink)
        }
        guard nameChecked else { throw BlobError.truncated }
        return (try checker.finish(), matched)
    }

    /// Opens a blob file for streaming decryption: a regular file, read
    /// through a counter that stops at `BoundedRead.maxBlobFileBytes`.
    static func openBlobFile(_ url: URL, identities: [any AgeIdentity],
                             raw: (@escaping (Data) throws -> Void) = { _ in }) throws -> (AgeDecryptor, FileHandle) {
        let handle: FileHandle
        do { handle = try BoundedRead.openRegularFile(url) } catch { throw BlobError.unreadable("\(error)") }
        var total = 0
        let limit = BoundedRead.maxBlobFileBytes
        do {
            let decryptor = try AgeDecryptor(identities: identities) { n in
                let piece: Data
                do { piece = try autoreleasing { try handle.read(upToCount: n) ?? Data() } } catch {
                    throw BlobError.unreadable("read \(url.path): \(error)")
                }
                total += piece.count
                guard total <= limit else { throw BlobError.unreadable("\(url.path) is larger than \(limit) bytes") }
                try raw(piece)
                return piece
            }
            return (decryptor, handle)
        } catch let e as BlobError {
            try? handle.close()
            throw e
        } catch let e as VaultError {
            try? handle.close()
            throw e
        } catch {
            try? handle.close()
            throw BlobError.undecryptable("\(error)")
        }
    }
}
