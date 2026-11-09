import Foundation
import Sempere

// What crosses WatchConnectivity with a sealed capture and back (docs/design/1.1-watch.md §3.6): the file's plaintext
// description, and the phone's acknowledgements. Nothing here is secret, and the phone trusts none of it: the file crossed
// a daemon, so `WatchIntake` checks the metadata against the file.

/// `transferFile`'s metadata for one outbox file. Everything the phone needs to deliver it (`CaptureDelivery` records
/// `epoch`/`epochId` in the ledger) without decrypting anything.
public struct WatchTransferMeta: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// The capture's id.
    public var id: UUID
    /// `<id>.capture.age` (`CaptureFile.name`).
    public var name: String
    /// The sealed file's size in bytes.
    public var size: Int
    /// Lowercase hex SHA-256 of the sealed bytes.
    public var sha256: String
    /// The vault the capture is sealed for.
    public var vault: UUID
    /// The epoch of the profile that sealed it, and its id (lowercase hex, 32 bytes).
    public var epoch: Int
    public var epochId: String
    public var version: Int

    public init(id: UUID, name: String, size: Int, sha256: String, vault: UUID, epoch: Int, epochId: String,
                version: Int = WatchTransferMeta.currentVersion) {
        self.id = id; self.name = name; self.size = size; self.sha256 = sha256; self.vault = vault
        self.epoch = epoch; self.epochId = epochId; self.version = version
    }

    /// The metadata of `sealed` (a capture the watch sealed with `profile`).
    public init(sealed: SealedCapture, vault: UUID) throws {
        guard let parsed = CaptureFile.parse(name: sealed.name), parsed.kind == .capture else {
            throw WatchTransferError.notACapture(sealed.name)
        }
        guard let epoch = sealed.epoch, let epochId = sealed.epochId, epochId.count == 32 else {
            throw WatchTransferError.missingEpoch
        }
        self.init(id: parsed.id, name: sealed.name, size: sealed.data.count, sha256: FileDigest.sha256(sealed.data), vault: vault,
                  epoch: epoch, epochId: epochId.map { String(format: "%02x", $0) }.joined())
    }

    enum CodingKeys: String, CodingKey { case id, name, size, sha256, vault, epoch, epochId, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func uuid(_ key: CodingKeys) throws -> UUID {
            guard let u = UUID(uuidString: try c.decode(String.self, forKey: key)) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not a UUID")
            }
            return u
        }
        id = try uuid(.id)
        vault = try uuid(.vault)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(Int.self, forKey: .size)
        sha256 = try c.decode(String.self, forKey: .sha256)
        epoch = try c.decode(Int.self, forKey: .epoch)
        epochId = try c.decode(String.self, forKey: .epochId)
        version = try c.decode(Int.self, forKey: .version)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(vault.uuidString.lowercased(), forKey: .vault)
        try c.encode(name, forKey: .name)
        try c.encode(size, forKey: .size)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(epochId, forKey: .epochId)
        try c.encode(version, forKey: .version)
    }

    /// The epoch id as bytes; nil unless it is 32 bytes of lowercase hex.
    public var epochIdBytes: Data? {
        guard let d = Hex.decode(epochId), d.count == 32 else { return nil }
        return d
    }

    /// The property list WatchConnectivity carries (`transferFile(_:metadata:)`).
    public var dictionary: [String: Any] {
        ["id": id.uuidString.lowercased(), "name": name, "size": size, "sha256": sha256, "vault": vault.uuidString.lowercased(),
         "epoch": epoch, "epochId": epochId, "version": version]
    }

    /// The metadata a dictionary holds; nil when a field is missing or has the wrong type.
    public init?(dictionary d: [String: Any]) {
        guard let id = (d["id"] as? String).flatMap({ UUID(uuidString: $0) }), let name = d["name"] as? String,
              let size = d["size"] as? Int, let sha = d["sha256"] as? String,
              let vault = (d["vault"] as? String).flatMap({ UUID(uuidString: $0) }), let epoch = d["epoch"] as? Int,
              let epochId = d["epochId"] as? String, let version = d["version"] as? Int else { return nil }
        self.init(id: id, name: name, size: size, sha256: sha, vault: vault, epoch: epoch, epochId: epochId, version: version)
    }
}

public enum WatchTransferError: Error, Equatable, Sendable, CustomStringConvertible {
    case notACapture(String)
    case missingEpoch

    public var description: String {
        switch self {
        case .notACapture(let n): return "\(n) is not a capture file name"
        case .missingEpoch: return "the sealed capture carries no epoch"
        }
    }
}

/// The phone's answer: `acked` ids are in the vault (or its queue), so the watch may delete its copies; `have` is what the
/// phone holds, sent at activation so a watch that lost its ack state (a reinstall, a restore) can drop what is there.
/// Both go by `transferUserInfo`, which survives either side being away.
public struct WatchAck: Equatable, Sendable {
    /// The most ids one message carries (and one decode accepts).
    public static let maxIDs = 2_000

    public var acked: [UUID]
    public var have: [UUID]

    public init(acked: [UUID] = [], have: [UUID] = []) {
        self.acked = acked
        self.have = have
    }

    public var isEmpty: Bool { acked.isEmpty && have.isEmpty }

    /// The ids the watch may drop: `acked` and `have` together.
    public var ids: [UUID] { acked + have }

    public var dictionary: [String: Any] {
        var d: [String: Any] = [:]
        if !acked.isEmpty { d["acked"] = acked.prefix(Self.maxIDs).map { $0.uuidString.lowercased() } }
        if !have.isEmpty { d["have"] = have.prefix(Self.maxIDs).map { $0.uuidString.lowercased() } }
        return d
    }

    /// The acknowledgement a dictionary holds; nil when it holds neither list. A malformed id is skipped.
    public init?(dictionary d: [String: Any]) {
        func ids(_ key: String) -> [UUID]? {
            (d[key] as? [String]).map { Array($0.prefix(Self.maxIDs)).compactMap { UUID(uuidString: $0) } }
        }
        let acked = ids("acked"), have = ids("have")
        guard acked != nil || have != nil else { return nil }
        self.init(acked: acked ?? [], have: have ?? [])
    }
}
