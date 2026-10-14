import Age
import Foundation

// MARK: - Files received from elsewhere (security review 2026-10, W2)
//
// A sync run (WebDAV) used to link a downloaded revision or blob in as
// write-once after checking only its age magic. A server could then plant
// junk under a revision name of a note (every later edit failed, since its
// coverage could not be read) or under a blob name it had seen. These checks
// run before a received file is placed under `notes/`; a file that fails one
// is quarantined by the caller, never placed and never silently dropped.

/// Why a received file was not placed (format.md §9.1).
public struct IncomingFileProblem: Error, Hashable, Sendable, CustomStringConvertible {
    /// What failed, in one line.
    public var reason: String

    public init(_ reason: String) { self.reason = reason }

    public var description: String { reason }
}

extension Vault {
    /// The vault opened again from disk with the same identities and trust
    /// store: after `vault.json` was replaced (a sync took a newer one), so
    /// files are checked under the secret it carries now.
    public func reopened() throws -> Vault {
        try Vault.open(at: url, identities: identities, trust: trustStore)
    }

    /// Checks a revision file received from elsewhere before it is placed as
    /// `notes/<noteId>/<name>` (format.md §9.1).
    ///
    /// - Unlocked: it must decrypt with this vault's identities, verify its
    ///   tag (under the current secret, or the previous one during an
    ///   unfinished rotation) and decode as a revision of this note and
    ///   name: exactly what `readRevision` checks. A revision a newer version
    ///   wrote (format.md §7) passes, as reading it would.
    /// - Locked: only its structure: an age header that parses, whose
    ///   stanzas are all of a type this vault's recipients use and no more
    ///   than it has recipients, and a payload long enough for one chunk.
    ///
    /// - Throws: `IncomingFileProblem`.
    public func checkIncomingRevision(_ data: Data, noteId: UUID, name: RevisionName) throws {
        guard data.count <= BoundedRead.maxRevisionBytes else {
            throw IncomingFileProblem("larger than \(BoundedRead.maxRevisionBytes) bytes")
        }
        guard let secret else { return try checkAgeStructure(data) }
        do {
            _ = try decodeRevisionFile(data, note: noteId.uuidString.lowercased(), name: name, secret: secret)
        } catch RevisionReadError.newer {
            return
        } catch let e as RevisionReadError {
            throw IncomingFileProblem(Self.describe(e))
        } catch {
            throw IncomingFileProblem("\(error)")
        }
    }

    /// Checks a blob file received from elsewhere (at `file`, a temporary
    /// name) before it is placed as `notes/<id>/att/<fileName>` (format.md
    /// §9.1). Unlocked: the whole file is decrypted as a stream and checked
    /// as a read is (framing, zero padding, content hash) and `fileName` must
    /// be the keyed name of its hash (§8.1.2). Locked: only the age structure
    /// of its first bytes, as for revisions.
    ///
    /// - Throws: `IncomingFileProblem`.
    public func checkIncomingBlob(at file: URL, fileName: String) throws {
        guard BlobName.parse(fileName) != nil else { throw IncomingFileProblem("not a blob file name") }
        guard canRead else {
            let head: Data
            do {
                let handle = try BoundedRead.openRegularFile(file)
                defer { try? handle.close() }
                head = try handle.read(upToCount: 4 << 20) ?? Data()
            } catch {
                throw IncomingFileProblem("unreadable: \(error)")
            }
            return try checkAgeStructure(head, complete: false)
        }
        do {
            _ = try Self.readBlobFile(file, identities: identities, secrets: blobSecrets, expected: nil,
                                      maxContent: BlobRef.maxSize, name: fileName)
        } catch let e as BlobError {
            throw IncomingFileProblem(Self.describe(e))
        } catch {
            throw IncomingFileProblem("\(error)")
        }
    }

    /// The structural check of a locked vault. `complete` is false when
    /// `data` is only the start of the file (blobs).
    func checkAgeStructure(_ data: Data, complete: Bool = true) throws {
        let parsed: (header: Header, payloadStart: Int)
        do { parsed = try AgeFile.parseHeader(data) } catch {
            throw IncomingFileProblem("not an age file (\(error))")
        }
        let types = Set(((try? ageRecipients()) ?? []).map(\.stanzaType))
        let stanzas = parsed.header.stanzas
        guard !stanzas.isEmpty, stanzas.count <= max(recipients.count, 1) else {
            throw IncomingFileProblem("encrypted to \(stanzas.count) recipients; the vault has \(recipients.count)")
        }
        if !types.isEmpty, let other = stanzas.first(where: { !types.contains($0.type) }) {
            throw IncomingFileProblem("encrypted to a \(String(other.type.prefix(32))) recipient this vault does not have")
        }
        // A 16-byte nonce and at least one chunk with its 16-byte tag.
        if complete, data.count - parsed.payloadStart < 32 {
            throw IncomingFileProblem("the age payload is truncated")
        }
    }

    static func describe(_ e: RevisionReadError) -> String {
        switch e {
        case .unreadable(let s): return "unreadable: \(s)"
        case .undecryptable(let s): return "does not decrypt with this vault's key: \(s)"
        case .tagMismatch: return "its tag does not verify under the vault's secret (not written with the vault's key)"
        case .tagMismatchJournalUnreadable(let s): return "its tag does not verify, and the rewrap journal is unreadable: \(s)"
        case .corruptBody(let s): return "corrupt body: \(s)"
        case .undecodable(let s): return "not a revision of this note and name: \(s)"
        case .newer(let s): return "written by a newer version: \(s)"
        }
    }

    static func describe(_ e: BlobError) -> String {
        switch e {
        case .nameMismatch: return "its name is not the keyed name of its content (not written with the vault's key)"
        case .undecryptable(let s): return "does not decrypt with this vault's key: \(s)"
        default: return "not a valid blob: \(e)"
        }
    }
}
