import Age
import Crypto
import Foundation

// The files of the key hierarchy that the printed kit's script reads, frozen
// in KH1 (docs/design/key-hierarchy.md §5.2.1, §7.4, §8.1, §8.2; format.md
// §15.6, §15.10, §15.11, §15.13): epoch records under `epochs/`, the
// re-encryption journal, and the recovery key's passphrase copy. Pure
// functions over bytes: nothing here touches a vault folder.

/// Errors of the epoch record, journal and passphrase-copy readers.
public enum EpochFileError: Error, Hashable, Sendable {
    /// Larger than the bound (64 MiB on disk or after gunzip; 16 KiB for a passphrase copy).
    case tooLarge
    /// Not an age file this key opens, or its framing or tag does not verify.
    case unreadable
    /// The JSON is not the format, or a field is malformed.
    case malformed(String)
    /// The record names another vault, epoch or id than the reader expects.
    case mismatch(String)
}

/// The parent part of an epoch record: the parent's key and identity (absent for a re-encryption)
/// and the sealed set.
public struct EpochRecordParent: Hashable, Sendable {
    public var epoch: Int
    public var epochId: Data
    public var key: VaultEpochKey?
    /// Paths and SHA-256 digests (lowercase hex) of the files the change kept.
    public var sealed: [String: String]
    /// SHA-256 of the parent epoch's own record file (`epochs/<parent>-<idprefix>.epoch.age`), so every record
    /// is bound from the current `epochRecordHash` downward (format.md §15.6): a holder of an earlier key
    /// cannot rewrite an earlier record's sealed set. Absent only in a parent without a record.
    public var recordHash: Data?

    public init(epoch: Int, epochId: Data, key: VaultEpochKey?, sealed: [String: String], recordHash: Data? = nil) {
        self.epoch = epoch; self.epochId = epochId; self.key = key; self.sealed = sealed; self.recordHash = recordHash
    }
}

/// `epochs/<e>-<idprefix>.epoch.age` (design §5.2.1): `sempere-epoch/1`.
public struct EpochRecord: Hashable, Sendable {
    public static let formatName = "sempere-epoch/1"
    /// The bound on the file and on its gunzipped JSON.
    public static let maxBytes = 64 << 20
    /// The framing label (in place of a note id).
    public static let label = "epochs"

    public var vaultId: UUID
    public var root: Data
    public var epoch: Int
    public var epochId: Data
    /// Nil at epoch 1.
    public var parent: EpochRecordParent?
    /// Epoch 1 up to and including this epoch.
    public var chain: [ChainEntry]
    public var created: String
    /// The author's id.
    public var by: String
    public var reason: String
    /// Informational: removals are computed (design §4.1).
    public var removed: [Data]

    public init(vaultId: UUID, root: Data, epoch: Int, epochId: Data, parent: EpochRecordParent?, chain: [ChainEntry],
                created: String, by: String, reason: String, removed: [Data] = []) {
        self.vaultId = vaultId; self.root = root; self.epoch = epoch; self.epochId = epochId; self.parent = parent
        self.chain = chain; self.created = created; self.by = by; self.reason = reason; self.removed = removed
    }

    /// `<e>-<first 16 hex digits of epochId>.epoch.age` (in `epochs/`).
    public static func fileName(epoch: Int, epochId: Data) -> String {
        "\(epoch)-\(Hex.encode(epochId).prefix(16)).epoch.age"
    }

    public var fileName: String { Self.fileName(epoch: epoch, epochId: epochId) }

    /// The record's JSON (keys sorted, no whitespace; readers accept any order).
    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// The file: an age file to the epoch's vault identity whose plaintext is the body framing
    /// of format.md §4 (label `epochs`, the file name) tagged under the epoch's `tagKey`.
    ///
    /// - Throws: `EpochFileError.mismatch` when `key` is not this epoch's.
    public func seal(key: VaultEpochKey) throws -> Data {
        guard key.epochId == epochId else { throw EpochFileError.mismatch("the key is not this epoch's") }
        let body = try BodyFraming.frame(json: try json(), noteId: Self.label, filename: fileName,
                                         secret: key)
        return try AgeFile.encrypt(body, to: [try key.vaultIdentity().recipient])
    }

    /// Opens and checks the record of epoch `epoch` with id `epochId`, keyed `key`.
    public static func open(_ file: Data, key: VaultEpochKey, vaultId: UUID, epoch: Int) throws -> EpochRecord {
        guard file.count <= maxBytes else { throw EpochFileError.tooLarge }
        let name = fileName(epoch: epoch, epochId: key.epochId)
        let body: Data
        do { body = try AgeFile.decrypt(file, with: [try key.vaultIdentity()]) } catch {
            throw EpochFileError.unreadable
        }
        let gzip: Data
        do { gzip = try BodyFraming.unframe(body, noteId: label, filename: name, secret: key).gzip }
        catch { throw EpochFileError.unreadable }
        let json: Data
        do { json = try Gzip.decompress(gzip, maxOutput: maxBytes) } catch { throw EpochFileError.tooLarge }
        let r = try parse(json)
        guard r.vaultId == vaultId else { throw EpochFileError.mismatch("another vault") }
        guard r.epoch == epoch, r.epochId == key.epochId else { throw EpochFileError.mismatch("another epoch") }
        return r
    }

    /// Parses and checks the JSON alone (untrusted input): the format, the epoch numbers, the chain
    /// ending at this epoch, the parent matching the chain, the parent key's id.
    public static func parse(_ json: Data) throws -> EpochRecord {
        guard json.count <= maxBytes else { throw EpochFileError.tooLarge }
        let r: EpochRecord
        do { r = try JSONDecoder().decode(EpochRecord.self, from: json) } catch let e as EpochFileError { throw e } catch {
            throw EpochFileError.malformed("\(error)")
        }
        guard r.epoch >= 1, r.chain.count == r.epoch, let last = r.chain.last,
              last.epoch == r.epoch, last.epochId == r.epochId else {
            throw EpochFileError.malformed("the chain does not end at this epoch")
        }
        if let p = r.parent {
            guard r.epoch >= 2, p.epoch == r.epoch - 1, p.epochId == r.chain[r.epoch - 2].epochId,
                  last.parent == p.epochId else { throw EpochFileError.malformed("the parent is not the chain's") }
            if let k = p.key, k.epochId != p.epochId { throw EpochFileError.malformed("the parent key is not the parent's") }
        } else {
            guard r.epoch == 1 else { throw EpochFileError.malformed("no parent") }
        }
        if r.reason == EpochReason.reencrypt.rawValue, r.parent?.key != nil {
            throw EpochFileError.malformed("a re-encryption carries no parent key")
        }
        // The record's own fields agree with its chain entry, which is what readers use (review M6).
        guard r.reason == last.reason, r.by == String(Hex.encode(last.author.fingerprint).prefix(8)) else {
            throw EpochFileError.malformed("reason or by differ from the chain's last entry")
        }
        return r
    }
}

extension EpochRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case format, vaultId, root, epoch, epochId, parent, chain, created, by, reason, removed
    }
    enum ParentKeys: String, CodingKey { case epoch, epochId, key, identity, sealed, recordHash }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == Self.formatName else {
            throw EpochFileError.malformed("not \(Self.formatName)")
        }
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        root = try ChainEntry.hex32(c, .root)
        epoch = try c.decode(Int.self, forKey: .epoch)
        epochId = try ChainEntry.hex32(c, .epochId)
        if c.contains(.parent) {
            let p = try c.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent)
            var key: VaultEpochKey?
            if p.contains(.key) {
                guard let raw = Hex.decode(try p.decode(String.self, forKey: .key)) else {
                    throw EpochFileError.malformed("parent.key")
                }
                let k = try VaultEpochKey(bytes: raw)
                // The identity next to it must be the one derived from it (design §2.1).
                let identity = try p.decode(String.self, forKey: .identity)
                guard let derived = try? k.vaultIdentity(), derived.string == identity else {
                    throw EpochFileError.malformed("parent.identity is not derived from parent.key")
                }
                key = k
            } else if p.contains(.identity) {
                throw EpochFileError.malformed("parent.identity without parent.key")
            }
            let sealed = try p.decode([String: String].self, forKey: .sealed)
            for (path, digest) in sealed where path.isEmpty || Hex.decode(digest) == nil {
                throw EpochFileError.malformed("sealed: \(path)")
            }
            let recordHash = p.contains(.recordHash) ? try ChainEntry.hex32(p, .recordHash) : nil
            parent = EpochRecordParent(epoch: try p.decode(Int.self, forKey: .epoch),
                                       epochId: try ChainEntry.hex32(p, .epochId), key: key, sealed: sealed,
                                       recordHash: recordHash)
        } else {
            parent = nil
        }
        chain = try c.decode([ChainEntry].self, forKey: .chain)
        guard chain.count <= EpochChain.maxEpochs else { throw EpochFileError.tooLarge }
        created = try c.decode(String.self, forKey: .created)
        by = try c.decode(String.self, forKey: .by)
        reason = try c.decode(String.self, forKey: .reason)
        removed = try c.contains(.removed) ? ChainEntry.fingerprints(c, .removed) : []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(Hex.encode(root), forKey: .root)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(Hex.encode(epochId), forKey: .epochId)
        if let parent {
            var p = c.nestedContainer(keyedBy: ParentKeys.self, forKey: .parent)
            try p.encode(parent.epoch, forKey: .epoch)
            try p.encode(Hex.encode(parent.epochId), forKey: .epochId)
            if let k = parent.key {
                try p.encode(Hex.encode(k.bytes), forKey: .key)
                try p.encode(try k.vaultIdentity().string, forKey: .identity)
            }
            try p.encode(parent.sealed, forKey: .sealed)
            if let h = parent.recordHash { try p.encode(Hex.encode(h), forKey: .recordHash) }
        }
        try c.encode(chain, forKey: .chain)
        try c.encode(created, forKey: .created)
        try c.encode(by, forKey: .by)
        try c.encode(reason, forKey: .reason)
        try c.encode(removed.map { Hex.encode($0) }, forKey: .removed)
    }
}

// MARK: - The re-encryption journal (design §7.4)

/// `reencrypt-journal.age`: `sempere-reencrypt/1`, every earlier epoch key on the kept chain.
public struct ReencryptJournal: Hashable, Sendable {
    public static let formatName = "sempere-reencrypt/1"
    public static let fileName = "reencrypt-journal.age"
    public static let label = "reencrypt"

    public struct Key: Hashable, Sendable {
        public var epoch: Int
        public var key: VaultEpochKey
        public init(epoch: Int, key: VaultEpochKey) { self.epoch = epoch; self.key = key }
    }

    public var vaultId: UUID
    /// The re-encryption epoch.
    public var epoch: Int
    public var epochId: Data
    public var keys: [Key]
    public var created: String
    public var by: String

    public init(vaultId: UUID, epoch: Int, epochId: Data, keys: [Key], created: String, by: String) {
        self.vaultId = vaultId; self.epoch = epoch; self.epochId = epochId; self.keys = keys
        self.created = created; self.by = by
    }

    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// The file: age to `v_m`, body framing with label `reencrypt` and the file name, tagged
    /// under `tagKey` of `K_m`.
    public func seal(key: VaultEpochKey) throws -> Data {
        guard key.epochId == epochId else { throw EpochFileError.mismatch("the key is not this epoch's") }
        let body = try BodyFraming.frame(json: try json(), noteId: Self.label, filename: Self.fileName,
                                         secret: key)
        return try AgeFile.encrypt(body, to: [try key.vaultIdentity().recipient])
    }

    public static func open(_ file: Data, key: VaultEpochKey, vaultId: UUID) throws -> ReencryptJournal {
        guard file.count <= EpochRecord.maxBytes else { throw EpochFileError.tooLarge }
        let body: Data
        do { body = try AgeFile.decrypt(file, with: [try key.vaultIdentity()]) } catch { throw EpochFileError.unreadable }
        let gzip: Data
        do { gzip = try BodyFraming.unframe(body, noteId: label, filename: fileName, secret: key).gzip }
        catch { throw EpochFileError.unreadable }
        let json: Data
        do { json = try Gzip.decompress(gzip, maxOutput: EpochRecord.maxBytes) } catch { throw EpochFileError.tooLarge }
        let j = try parse(json)
        guard j.vaultId == vaultId, j.epochId == key.epochId else { throw EpochFileError.mismatch("another vault or epoch") }
        return j
    }

    public static func parse(_ json: Data) throws -> ReencryptJournal {
        guard json.count <= EpochRecord.maxBytes else { throw EpochFileError.tooLarge }
        let j: ReencryptJournal
        do { j = try JSONDecoder().decode(ReencryptJournal.self, from: json) } catch let e as EpochFileError { throw e } catch {
            throw EpochFileError.malformed("\(error)")
        }
        guard j.epoch >= 2, j.keys.allSatisfy({ $0.epoch >= 1 && $0.epoch < j.epoch }) else {
            throw EpochFileError.malformed("epochs")
        }
        return j
    }

    /// `reencryptPending` = HMAC-SHA256(`pendingKey`, `"sempere/1 reencrypt pending"` ‖ lp(vaultId)
    /// ‖ lp(SHA-256(journal bytes))), under the current epoch's key, lowercase hex.
    public static func binding(journalFile: Data, vaultId: UUID, currentKey: VaultEpochKey) -> String {
        var m = LPMessage("sempere/1 reencrypt pending")
        m.field(vaultId.uuidString.lowercased())
        m.field(Data(SHA256.hash(data: journalFile)))
        return Hex.encode(Data(HMAC<SHA256>.authenticationCode(for: m.bytes, using: SymmetricKey(data: currentKey.pendingKey))))
    }
}

extension ReencryptJournal: Codable {
    enum CodingKeys: String, CodingKey { case format, vaultId, epoch, epochId, keys, created, by }
    enum KeyKeys: String, CodingKey { case epoch, epochId, key, identity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == Self.formatName else {
            throw EpochFileError.malformed("not \(Self.formatName)")
        }
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        epoch = try c.decode(Int.self, forKey: .epoch)
        epochId = try ChainEntry.hex32(c, .epochId)
        var list = try c.nestedUnkeyedContainer(forKey: .keys)
        var keys: [Key] = []
        while !list.isAtEnd {
            guard keys.count < EpochChain.maxEpochs else { throw EpochFileError.tooLarge }
            let k = try list.nestedContainer(keyedBy: KeyKeys.self)
            guard let raw = Hex.decode(try k.decode(String.self, forKey: .key)) else { throw EpochFileError.malformed("key") }
            let key = try VaultEpochKey(bytes: raw)
            guard try ChainEntry.hex32(k, .epochId) == key.epochId,
                  (try? key.vaultIdentity())?.string == (try k.decode(String.self, forKey: .identity)) else {
                throw EpochFileError.malformed("a key whose id or identity is not derived from it")
            }
            keys.append(Key(epoch: try k.decode(Int.self, forKey: .epoch), key: key))
        }
        self.keys = keys
        created = try c.decode(String.self, forKey: .created)
        by = try c.decode(String.self, forKey: .by)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(Hex.encode(epochId), forKey: .epochId)
        var list = c.nestedUnkeyedContainer(forKey: .keys)
        for k in keys {
            var e = list.nestedContainer(keyedBy: KeyKeys.self)
            try e.encode(k.epoch, forKey: .epoch)
            try e.encode(Hex.encode(k.key.epochId), forKey: .epochId)
            try e.encode(Hex.encode(k.key.bytes), forKey: .key)
            try e.encode(try k.key.vaultIdentity().string, forKey: .identity)
        }
        try c.encode(created, forKey: .created)
        try c.encode(by, forKey: .by)
    }
}

// MARK: - The passphrase copy (design §8.2)

/// `keys/recovery-<fingerprint>.key.age`: the recovery identity with the vault id and root,
/// age-encrypted with one scrypt stanza.
public struct RecoveryPassphraseCopy: Hashable, Sendable {
    /// The largest plaintext or file read.
    public static let maxBytes = 16 * 1024
    /// Writers use this work factor (design §8.2).
    public static let workFactor = 20

    public var created: String
    public var vaultId: UUID
    public var root: Data
    public var identity: MLKEM768X25519Identity

    public init(created: String, vaultId: UUID, root: Data, identity: MLKEM768X25519Identity) {
        self.created = created; self.vaultId = vaultId; self.root = root; self.identity = identity
    }

    /// `keys/recovery-<recovery fingerprint hex>.key.age` (the fingerprint binds the derived signing keys).
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public func path() throws -> String { "keys/recovery-\(Hex.encode(try KeyFingerprint.recovery(identity: identity))).key.age" }

    /// The plaintext: `# created:`, `# sempere-vault:`, `# sempere-root:`, `# public key:` and the
    /// identity, one per line; `age -i` reads it as it is.
    public var plaintext: String {
        "# created: \(created)\n# sempere-vault: \(vaultId.uuidString.lowercased())\n"
            + "# sempere-root: \(Hex.encode(root))\n# public key: \(identity.recipient.string)\n\(identity.string)\n"
    }

    /// Parses the plaintext strictly: exactly these five lines, the public key the identity's.
    public static func parse(_ plaintext: Data) throws -> RecoveryPassphraseCopy {
        guard plaintext.count <= maxBytes, let text = String(data: plaintext, encoding: .utf8), text.hasSuffix("\n") else {
            throw EpochFileError.malformed("not a passphrase copy")
        }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func value(_ i: Int, _ prefix: String) throws -> String {
            guard lines.count == 5, lines[i].hasPrefix(prefix) else { throw EpochFileError.malformed("line \(i + 1)") }
            return String(lines[i].dropFirst(prefix.count))
        }
        let created = try value(0, "# created: ")
        guard let vaultId = UUID(uuidString: try value(1, "# sempere-vault: ")),
              try value(1, "# sempere-vault: ") == vaultId.uuidString.lowercased() else {
            throw EpochFileError.malformed("sempere-vault")
        }
        guard let root = Hex.decode(try value(2, "# sempere-root: ")) else { throw EpochFileError.malformed("sempere-root") }
        let publicKey = try value(3, "# public key: ")
        guard let identity = try? MLKEM768X25519Identity(string: lines[4]) else { throw EpochFileError.malformed("identity") }
        guard identity.recipient.string == publicKey else { throw EpochFileError.malformed("the public key is not the identity's") }
        return RecoveryPassphraseCopy(created: created, vaultId: vaultId, root: root, identity: identity)
    }

    /// The file, with one scrypt stanza.
    public func seal(passphrase: String, workFactor: Int = RecoveryPassphraseCopy.workFactor) throws -> Data {
        try AgeFile.encrypt(Data(plaintext.utf8), to: [ScryptRecipient(passphrase: passphrase, workFactor: workFactor)])
    }

    public static func open(_ file: Data, passphrase: String) throws -> RecoveryPassphraseCopy {
        guard file.count <= maxBytes else { throw EpochFileError.tooLarge }
        let plain: Data
        do { plain = try AgeFile.decrypt(file, with: [ScryptIdentity(passphrase: passphrase)]) } catch {
            throw EpochFileError.unreadable
        }
        return try parse(plain)
    }
}

// MARK: - The printed kit (design §4.2, §8.1)

/// What the recovery kit prints besides the key, frozen in KH1.
public enum KitRecovery {
    /// The root as 16 groups of 4 hex digits, each with its line checksum: the first 4 hex digits
    /// of SHA-256 of the group as typed (as for the key's lines, `sempere keys paper`).
    public static func rootGroups(_ root: Data) -> [(group: String, checksum: String)] {
        let hex = Array(Hex.encode(root))
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let g = String(hex[i..<min(i + 4, hex.count)])
            return (g, String(FileDigest.sha256(Data(g.utf8)).prefix(4)))
        }
    }

    /// The kit's second QR code: `sempere-root:<vaultId>:<hex>`; also the reverse QR of an approval join.
    public static func rootQR(vaultId: UUID, root: Data) -> String {
        "sempere-root:\(vaultId.uuidString.lowercased()):\(Hex.encode(root))"
    }

    /// Parses `rootQR`; nil for anything else.
    public static func parseRootQR(_ text: String) -> (vaultId: UUID, root: Data)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "sempere-root", let id = UUID(uuidString: parts[1]),
              parts[1] == id.uuidString.lowercased(), let root = Hex.decode(parts[2]) else { return nil }
        return (id, root)
    }

    /// The recovery script the kit prints (design §8.1), byte for byte.
    public static let script = """
        # 0. Only if you use the passphrase copy instead of the printed key:
        #    age -d keys/recovery-<fingerprint>.key.age > recovery.txt
        # 1. The current vault key, from the recovery entry.
        jq -r '.keys[] | select(.role == "recovery") | .wrap' vault.json \\
          | age -d -i recovery.txt > vault-keys.txt
        # 2. Earlier vault keys, newest record first. Run twice: the second pass picks up
        #    records that open only with a key the journal (2b) added.
        for pass in 1 2; do
          for f in $(ls epochs | sort -t- -k1,1nr); do
            age -d -i vault-keys.txt "epochs/$f" | tail -c +38 | gunzip \\
              | jq -r '.parent.identity // empty' > prev.txt
            cat prev.txt >> vault-keys.txt
          done
          # 2b. Only while a re-encryption is unfinished (the file exists only then):
          if [ -f reencrypt-journal.age ]; then
            age -d -i vault-keys.txt reencrypt-journal.age | tail -c +38 | gunzip \\
              | jq -r '.keys[].identity' > prev.txt
            cat prev.txt >> vault-keys.txt
          fi
        done
        # 3. Any note, as before.
        age -d -i vault-keys.txt notes/ID/NAME.delta.age | tail -c +38 | gunzip | jq .

        """
}
