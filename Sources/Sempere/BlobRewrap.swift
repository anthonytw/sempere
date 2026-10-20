import Age
import Foundation

// MARK: - Recipient changes and blobs (docs/format.md §3.3.1, §8.1.5)

/// How a recipient change rewraps an attachment blob (format.md §8.1.5).
public enum RewrapMethod: String, Hashable, Sendable, Codable, CaseIterable {
    /// A new age header wrapping the same file key; nonce and payload copied
    /// unchanged. Cheap (one header write and one file copy), but every old
    /// copy of the header still opens the new file.
    case headerOnly = "header"
    /// The content decrypted and encrypted again under a fresh file key and
    /// nonce: the current file shares nothing with old copies.
    case reencrypt
}

/// Which `RewrapMethod` a recipient change uses for blobs, by kind of change
/// (format.md §8.1.5). The defaults are the decided policy
/// (`docs/attachments.md` §3, §16 decision 3); the app's Settings expose the
/// two choices (§15).
public struct RewrapPolicy: Hashable, Sendable {
    /// A recipient (device key) is added and none removed.
    public var onAdd: RewrapMethod
    /// A recipient is removed (or replaced).
    public var onRemove: RewrapMethod

    public init(onAdd: RewrapMethod = .headerOnly, onRemove: RewrapMethod = .reencrypt) {
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    /// The method for a recipient change: one that rotates the secret
    /// (removes or replaces a recipient) follows the removal row, an
    /// addition the other (format.md §8.1.5 table).
    public func method(rotating: Bool) -> RewrapMethod {
        rotating ? onRemove : onAdd
    }
}

extension RevisionReadError {
    /// A blob failure as a rewrap report entry: the stage that failed.
    init(blob error: any Error) {
        switch error {
        case BlobError.unreadable(let m): self = .unreadable(m)
        case BlobError.undecryptable(let m): self = .undecryptable(m)
        case BlobError.nameMismatch: self = .tagMismatch
        case let e as VaultError: self = .unreadable("\(e)")
        case let e as AgeError: self = .undecryptable("\(e)")
        default: self = .corruptBody("\(error)")
        }
    }
}

extension Vault {
    /// Step 3 of format.md §3.3.1 for the blobs of one note (§8.1.5).
    ///
    /// A blob is complete when its header has exactly the stanzas the current
    /// recipients need and its name verifies under the current secret (from
    /// the first chunk). Otherwise:
    ///
    /// - named under the current secret (an addition): rewrapped by `method`
    ///   and replaced atomically under the same name;
    /// - named under `previousVaultSecret` (a removal): rewrapped by `method`
    ///   into the current name, never over a valid file there, then the old
    ///   name is deleted; if a complete file with the same content already
    ///   holds the new name (an interrupted run), only the old one is deleted;
    /// - named under neither: left untouched and reported, so a rewrap can
    ///   never launder a planted file.
    ///
    /// Every rewrapped blob is verified in full as it streams (framing, zero
    /// padding, content hash); one that fails is left as it is and reported.
    /// Entries that are not blob file names are unknown files and ignored.
    func rewrapBlobs(note: String, recipients: [NativeRecipient], method: RewrapMethod,
                     report: inout RewrapReport, stopAfter: Int?) throws {
        let current = try requireSecret()
        let dir = notesURL.appendingPathComponent(note).appendingPathComponent(Self.attachmentsName)
        guard FileIO.isDirectory(dir) else { return }
        let expected = Self.expectedStanzas(recipients)
        // The journal's outgoing secret, then (a late file's rewrap, design §6.3) the keyring's.
        let secrets = [current] + (previousSecret.map { [$0] } ?? []) + olderSecrets
        for entry in try FileIO.entries(dir) {
            guard let parsed = BlobName.parse(entry) else { continue }
            let url = dir.appendingPathComponent(entry)
            guard !FileIO.isDirectory(url) else { continue }
            let path = "\(note)/\(Self.attachmentsName)/\(entry)"
            let peek: BlobPeek
            do { peek = try Self.peekBlobFile(url, identities: identities) } catch {
                report.failures[path] = RevisionReadError(blob: error); continue
            }
            let target: URL
            switch BlobName.verify(parsed.name, digest: peek.header.digest, secrets: secrets) {
            case 0?:
                if peek.stanzas == expected { report.alreadyCurrent.append(path); continue }
                target = url
            case let older? where older >= 1:
                // A keyring secret (R3): every blob already in this copy is made current. A blob is inert: only a
                // current revision makes it part of a note, and whoever can write one can upload the blob too;
                // left under the old wrap, it would stay readable to keys removed since (the property run,
                // seed 29: blobs of revisions kept aside as late files).
                target = dir.appendingPathComponent(
                    BlobName.fileName(name: BlobName.name(digest: peek.header.digest, secret: current), kind: parsed.kind))
                if FileIO.exists(target), isCompleteBlob(target, header: peek.header, stanzas: expected, secret: current) {
                    // Finished before an interruption: only the old name is left.
                    try FileIO.remove(url)
                    report.rewrapped.append(path)
                    continue
                }
            default:
                report.failures[path] = .tagMismatch; continue
            }
            if let stopAfter, report.rewrapped.count >= stopAfter { throw VaultError.interrupted }
            let tmp = FileIO.tempURL(in: dir)
            do {
                var checker = BlobPlaintextChecker()
                let inspect: (Data) throws -> Void = { try checker.consume($0) }
                switch method {
                case .headerOnly:
                    try AgeFile.rewrapHeader(contentsOf: url, to: tmp, identities: identities, recipients: recipients,
                                             inspect: inspect)
                case .reencrypt:
                    try AgeFile.reencrypt(contentsOf: url, to: tmp, identities: identities, recipients: recipients,
                                          inspect: inspect)
                }
                guard try checker.finish() == peek.header else { throw BlobError.contentHashMismatch }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                report.failures[path] = RevisionReadError(blob: error); continue
            }
            if target == url || FileIO.exists(target) {
                // Same name (an addition), or a file under the new name that
                // is not a complete copy of this content (checked above): a
                // stale or damaged file, which may be replaced.
                try FileIO.place(tmp, at: target)
            } else {
                try FileIO.placeNew(tmp, at: target)
            }
            if target != url {
                if crashAfterBlobPlace { throw VaultError.interrupted }
                try FileIO.remove(url)
            }
            report.rewrapped.append(path)
        }
    }

    /// True when `url` is a finished copy of the blob with `header`: its
    /// stanzas are `stanzas` and it verifies **in full** (every chunk,
    /// framing, padding, content hash, its name under `secret`). Callers
    /// delete the other copy on the strength of this, so the first chunk
    /// alone is not enough: a file damaged past it would replace the only
    /// good copy (format.md §8.1.4 "valid", §8.1.5).
    func isCompleteBlob(_ url: URL, header: BlobHeader, stanzas: [String: Int], secret: VaultSecret) -> Bool {
        guard Self.stanzaCounts(blob: url) == stanzas,
              let (found, _) = try? Self.readBlobFile(url, identities: identities, secrets: [secret], expected: nil,
                                                      maxContent: BlobRef.maxSize)
        else { return false }
        return found == header
    }
}
