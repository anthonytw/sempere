import Age
import Foundation

/// A revision file taken apart without decoding the JSON.
public struct RecoveredRevision: Hashable, Sendable {
    /// The revision JSON, exactly as `gunzip` prints it.
    public var json: Data
    /// True when the inner HMAC tag was checked against the vault secret and
    /// matched; false when no vault secret was available.
    public var verified: Bool
    /// True when a vault secret was available and the tag did NOT match, and
    /// the caller asked to proceed anyway (`TagPolicy.allowMismatch`).
    public var tagMismatch = false
}

/// What `Recovery.decrypt` does when the tag does not match.
public enum TagPolicy: Sendable {
    /// Throw `BodyFramingError.tagMismatch`.
    case fail
    /// Return the body with `tagMismatch == true` (for damaged vaults).
    case allowMismatch
}

/// The "get my data out" path (format.md §4): one `.age` file and an
/// identity, with the vault's help when it can be found.
public enum Recovery {
    /// Decrypts one revision file and returns its JSON.
    ///
    /// - Parameters:
    ///   - file: the bytes of the `.age` file.
    ///   - noteId, filename: the note directory name and file name the tag
    ///     binds to (only used when `vault` is given).
    ///   - identities: age identities to try.
    ///   - vault: when given and unlocked, the tag is verified (also under
    ///     the previous secret during an unfinished rewrap).
    ///   - onMismatch: what to do when the tag does not match.
    /// - Throws: `AgeError` if age decryption fails, `BodyFramingError` for
    ///   a bad frame or a tag mismatch, `VaultError`/`RevisionReadError` for
    ///   a corrupt gzip body.
    public static func decrypt(_ file: Data, noteId: String, filename: String,
                               identities: [any AgeIdentity], vault: Vault?,
                               onMismatch: TagPolicy = .fail) throws -> RecoveredRevision {
        let plain = try AgeFile.decrypt(file, with: identities)
        var unframed: BodyFraming.Unframed
        var mismatch = false
        if let vault, let secret = vault.secret {
            do {
                unframed = try Vault.unframe(plain, note: noteId, filename: filename, secret: secret,
                                             previous: vault.previousSecret)
            } catch BodyFramingError.tagMismatch where onMismatch == .allowMismatch {
                unframed = try BodyFraming.unframe(plain, noteId: noteId, filename: filename, secret: nil)
                mismatch = true
            }
        } else {
            unframed = try BodyFraming.unframe(plain, noteId: noteId, filename: filename, secret: nil)
        }
        let json: Data
        do { json = try Gzip.decompress(unframed.gzip) } catch {
            throw RevisionReadError.corruptBody("\(error)")
        }
        return RecoveredRevision(json: json, verified: unframed.verified, tagMismatch: mismatch)
    }
}

/// What `Recovery.decryptBlob` found.
public struct RecoveredBlob: Hashable, Sendable {
    /// The blob's header: content hash and length.
    public var header: BlobHeader
    /// True when the file name was checked against the vault secret and
    /// verified (format.md §8.1.2); false when no vault secret was available.
    /// The content hash is always checked.
    public var nameVerified: Bool
}

extension Recovery {
    /// Decrypts one attachment blob file (`notes/<id>/att/<name>.<kind>.age`)
    /// and streams its content to `sink`, exactly the bytes the stock-tool
    /// recovery of format.md §8.1.7 prints. Framing, zero padding and the
    /// content hash are always checked; the name too when `vault` is given
    /// and unlocked. Content reaches `sink` before the hash is known: if this
    /// throws, discard it.
    ///
    /// - Throws: `BlobError` (`nameMismatch` for a name that does not
    ///   verify under the vault's secret).
    public static func decryptBlob(at url: URL, identities: [any AgeIdentity], vault: Vault?,
                                   _ sink: (Data) throws -> Void) throws -> RecoveredBlob {
        let secrets = vault?.blobSecrets ?? []
        let (header, matched) = try Vault.readBlobFile(url, identities: identities, secrets: secrets, expected: nil,
                                                       maxContent: BlobRef.maxSize, sink: sink)
        return RecoveredBlob(header: header, nameVerified: matched != nil)
    }
}
