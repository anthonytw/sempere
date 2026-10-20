import Crypto
import Foundation

// Joining by approval (docs/design/key-hierarchy.md §6.2; format.md §15.12):
// the join request, the joining device's commitment, its six words and QR
// payload, and the approver's reverse code. Pure functions.

/// `joins/<id>.join.json`: `sempere-join/1`.
public struct JoinRequest: Hashable, Sendable {
    public static let formatName = "sempere-join/1"
    /// Readers bound the file at 16 KiB (design §6.2).
    public static let maxBytes = 16 * 1024

    public var vaultId: UUID
    public var key: String
    public var sign: DeviceSigningPublicKeys
    public var name: String
    public var kind: String
    public var created: String

    public init(vaultId: UUID, key: String, sign: DeviceSigningPublicKeys, name: String, kind: String, created: String) {
        self.vaultId = vaultId; self.key = key; self.sign = sign; self.name = name; self.kind = kind; self.created = created
    }

    /// The device fingerprint and its id (the file's `<id>`).
    public var fingerprint: Data { KeyFingerprint.device(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex) }
    public var fileName: String { "\(Hex.encode(fingerprint).prefix(8)).join.json" }

    /// The commitment `c = SHA-256("sempere/1 join" ‖ lp(vaultId) ‖ lp(key) ‖ lp(sign.p256)
    /// ‖ lp(sign.mldsa65) ‖ lp(kind))`. The name is not covered: E shows it, the user judges it.
    public var commitment: Data {
        var m = LPMessage("sempere/1 join")
        m.field(vaultId.uuidString.lowercased()); m.field(key); m.field(sign.p256Hex); m.field(sign.mldsa65Hex)
        m.field(kind)
        return Data(SHA256.hash(data: m.bytes))
    }

    /// Parses an untrusted request (bounded). The name is returned as written; callers clean it
    /// as `label` (format.md §2) before showing it.
    public static func parse(_ data: Data) throws -> JoinRequest {
        guard data.count <= maxBytes else { throw EpochFileError.tooLarge }
        do { return try JSONDecoder().decode(JoinRequest.self, from: data) } catch let e as EpochFileError { throw e } catch {
            throw EpochFileError.malformed("\(error)")
        }
    }
}

extension JoinRequest: Codable {
    enum CodingKeys: String, CodingKey { case format, vaultId, key, sign, name, kind, created }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == Self.formatName else {
            throw EpochFileError.malformed("not \(Self.formatName)")
        }
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        key = try c.decode(String.self, forKey: .key)
        guard key.hasPrefix("age1pq1") else { throw EpochFileError.malformed("not a post-quantum key") }
        sign = try c.decode(DeviceSigningPublicKeys.self, forKey: .sign)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        // A lowercase word (design §3: ipad, iphone, mac, cli, …), at most 32 letters (review L5).
        guard (1...32).contains(kind.utf8.count), kind.utf8.allSatisfy({ (0x61...0x7a).contains($0) }) else {
            throw EpochFileError.malformed("kind is not a lowercase word")
        }
        created = try c.decode(String.self, forKey: .created)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(key, forKey: .key)
        try c.encode(sign, forKey: .sign)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(created, forKey: .created)
    }
}

/// The codes typed or scanned in both directions (design §6.2).
public enum JoinCodes {
    /// Six words: the first 66 bits of `digest`, as six 11-bit indices (most significant bit
    /// first) into the BIP-39 English word list.
    public static func words(_ digest: Data) -> [String] {
        let bytes = [UInt8](digest)
        precondition(bytes.count >= 9, "a digest of at least 66 bits")
        var out: [String] = []
        for w in 0..<6 {
            var v = 0
            for b in 0..<11 {
                let bit = w * 11 + b
                v = v << 1 | Int(bytes[bit / 8] >> (7 - bit % 8) & 1)
            }
            out.append(BIP39English.words[v])
        }
        return out
    }

    /// The indices of six typed words (case-insensitive, surrounding spaces ignored); nil when a
    /// word is not in the list.
    public static func indices(_ typed: [String]) -> [Int]? {
        guard typed.count == 6 else { return nil }
        var out: [Int] = []
        for w in typed {
            guard let i = BIP39English.index[w.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
            out.append(i)
        }
        return out
    }

    /// True when `typed` are the six words of `digest`.
    public static func matches(_ typed: [String], _ digest: Data) -> Bool {
        indices(typed) == indices(words(digest))
    }

    /// The QR payload of the joining device: the vault id's 16 bytes, then `c` (48 bytes).
    public static func commitmentQR(vaultId: UUID, commitment: Data) -> Data {
        var u = vaultId.uuid
        var out = withUnsafeBytes(of: &u) { Data($0) }
        out.append(commitment)
        return out
    }

    /// Parses `commitmentQR`; nil unless exactly 48 bytes.
    public static func parseCommitmentQR(_ data: Data) -> (vaultId: UUID, commitment: Data)? {
        guard data.count == 48 else { return nil }
        let b = [UInt8](data)
        let id = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
                             b[14], b[15]))
        return (id, Data(b[16...]))
    }

    /// The reverse code's digest: `SHA-256("sempere/1 join reply" ‖ lp(vaultId) ‖ lp(c) ‖ lp(root))`,
    /// `c` raw (32 bytes) and `root` as its 64 hex digits. Its QR is `KitRecovery.rootQR`.
    public static func reply(vaultId: UUID, commitment: Data, root: Data) -> Data {
        var m = LPMessage("sempere/1 join reply")
        m.field(vaultId.uuidString.lowercased()); m.field(commitment); m.field(Hex.encode(root))
        return Data(SHA256.hash(data: m.bytes))
    }
}
