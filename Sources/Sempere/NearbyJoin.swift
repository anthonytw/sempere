import Age
import Crypto
import Foundation

// Joining nearby (docs/design/nearby-join.md; key-hierarchy design §6.2.1): the join request and the approval travel
// over a direct link between the two devices (the app's peer-to-peer Wi-Fi, Network.framework) as well as through the
// sync target. This file is the transport-agnostic half: the framing, the messages, the sealed reply, and what each
// side does with them in a vault. The link is untrusted transport, like a sync target: every check is the one the
// target path makes (the six words or the QR code on home, the reply words on the new device).

/// What a nearby join fails with: the link's framing and timing, and a reply that is not this session's.
public enum NearbyJoinError: Error, Equatable, Sendable {
    /// The stream does not start with `NearbyJoin.magic`.
    case badMagic
    /// A frame longer than its direction allows (the length it claims).
    case oversized(Int)
    /// A frame or a reply that does not parse.
    case malformed(String)
    /// A message the other side may not send at this point.
    case unexpected(String)
    /// The other side took longer than the session's timeouts allow.
    case timedOut
    /// The stream ended before the session did.
    case closed
    /// A reply whose nonce or commitment is not this session's request (replayed, or meant for another device).
    case replayed
    /// The approver's `proof` is not of the vault the request names: another vault's Add Device, or a device that does
    /// not know the vault's id. The request was not sent (design N13).
    case notThisVault
    /// The reply's `vault.json` is not an approval of this device (`Vault.isJoinApproval`).
    case notAnApproval
    /// The reply's epoch record is missing, or not the one its `vault.json` names.
    case recordMismatch
}

/// Why the approving device ends a session without a reply (one byte on the wire).
public enum NearbyJoinRefusal: UInt8, Sendable, CaseIterable {
    /// The request names another vault (another person's Add Device nearby).
    case otherVault = 1
    /// Another device is in a session with the approver; try again shortly.
    case busy = 2
    /// The request did not parse.
    case malformed = 3
    /// The user declined the request on the approver.
    case declined = 4
    /// The approver cannot approve now (locked, not home, read-only).
    case cannotApprove = 5
    /// The approver closed Add Device, or its session ran out of time.
    case closed = 6
}

/// The link's constants and limits.
public enum NearbyJoin {
    /// The Bonjour service type (the app's `NSBonjourServices`). The instance name is random
    /// (`instanceName`), and there is no TXT record: nothing names the vault or a device.
    public static let serviceType = "_sempere-join._tcp"
    /// Every stream starts with these 16 bytes, in both directions.
    public static let magic = Data("sempere-nearby/1".utf8)
    /// The joining device's per-session nonce, which the sealed reply carries back.
    public static let nonceBytes = 32
    /// The largest current epoch record a reply carries; a larger one (a chain of tens of thousands of epochs) is
    /// left to the sync target.
    public static let maxRecordBytes = 8 << 20
    /// The largest frame body the approver reads: the type, the nonce and a request (`JoinRequest.maxBytes`).
    public static let maxRequestBody = 1 + nonceBytes + JoinRequest.maxBytes
    /// The largest reply plaintext: `vault.json` (`BoundedRead.maxManifestBytes`), one record and the small fields.
    public static let maxReplyPlaintext = BoundedRead.maxManifestBytes + maxRecordBytes + 4096
    /// The largest frame body the joining device reads: the type and the sealed reply (age's header and 16 bytes per
    /// 64 KiB chunk fit in the margin).
    public static let maxReplyBody = 1 + maxReplyPlaintext + 256 * 1024

    /// How long each side waits.
    public struct Timeouts: Sendable, Equatable {
        /// From the connection to the first message each side expects (the request; the approver's first answer).
        public var handshake: Duration
        /// The whole session, approval included: the user types six words on the approver meanwhile.
        public var session: Duration

        public init(handshake: Duration, session: Duration) {
            self.handshake = handshake
            self.session = session
        }

        /// 10 seconds to start, 10 minutes in all.
        public static let standard = Timeouts(handshake: .seconds(10), session: .seconds(600))
    }

    /// A random Bonjour instance name: `Sempere-` and 12 hex digits, new for every advertisement, naming no vault and
    /// no device.
    public static func instanceName() -> String {
        "Sempere-" + Hex.encode(randomBytes(6))
    }

    /// The approver's answer to `hello` (design N13): `HMAC-SHA256(key: the vault id's 16 bytes (RFC 4122 order),
    /// "sempere-nearby/1 home" ‖ nonce)`. It proves only that the approver knows the vault's id, which is not secret
    /// (storage holds it): it keeps the joining device's request from devices of other vaults and from advertisers that
    /// do not know the id, and authenticates nothing.
    public static func proof(vaultId: UUID, nonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("sempere-nearby/1 home".utf8) + nonce, using: proofKey(vaultId)))
    }

    /// Whether `tag` is `proof(vaultId:nonce:)`, compared in constant time.
    public static func checkProof(_ tag: Data, vaultId: UUID, nonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data("sempere-nearby/1 home".utf8) + nonce,
                                               using: proofKey(vaultId))
    }

    static func proofKey(_ vaultId: UUID) -> SymmetricKey {
        var u = vaultId.uuid
        return SymmetricKey(data: withUnsafeBytes(of: &u) { Data($0) })
    }

    /// `count` bytes from the system's secure generator.
    public static func randomBytes(_ count: Int) -> Data {
        var out = Data()
        while out.count < count {
            out.append(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }
        return out.prefix(count)
    }
}

/// One message on the link. A frame is a 4-byte big-endian body length, then the body: one type byte and the payload.
///
/// The joining device speaks first with `hello` (its session nonce, nothing that names it or the vault); the approver
/// answers with `proof` (`NearbyJoin.proof`: it knows the vault's id); only then does the joining device send its
/// `request` (design N13).
public enum NearbyJoinMessage: Equatable, Sendable {
    /// The joining device's request (type 1): the bytes of its `joins/<id>.join.json`, sent only after a good `proof`.
    case request(Data)
    /// The approver has the request; the approval waits for the user (type 2, no payload).
    case waiting
    /// The approval (type 3): a `NearbyJoinReply` sealed to the request's key.
    case reply(Data)
    /// No reply in this session (type 4, one byte).
    case refused(NearbyJoinRefusal)
    /// The joining device's first message (type 5): its 32-byte session nonce.
    case hello(nonce: Data)
    /// The approver's answer to `hello` (type 6): `NearbyJoin.proof` of its open vault's id, 32 bytes.
    case proof(Data)

    var type: UInt8 {
        switch self {
        case .request: return 1
        case .waiting: return 2
        case .reply: return 3
        case .refused: return 4
        case .hello: return 5
        case .proof: return 6
        }
    }

    /// The message as a frame.
    public func frame() -> Data {
        var body = Data([type])
        switch self {
        case .request(let request): body.append(request)
        case .waiting: break
        case .reply(let sealed): body.append(sealed)
        case .refused(let why): body.append(why.rawValue)
        case .hello(let nonce): body.append(nonce)
        case .proof(let tag): body.append(tag)
        }
        let n = UInt32(body.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) + body
    }
}

/// Reads one side's stream: the magic, then frames, each bounded by what the other side may send. Untrusted input
/// (format.md §9): every failure is a typed `NearbyJoinError`, and nothing is held beyond one frame.
public struct NearbyFrameReader: Sendable {
    /// Whose frames are read.
    public enum Sender: Sendable {
        /// The joining device's (read by the approver): requests only.
        case joiner
        /// The approver's (read by the joining device): waiting, reply, refused.
        case approver
    }

    public let sender: Sender
    private var buffer = Data()
    private var sawMagic = false

    public init(reading sender: Sender) { self.sender = sender }

    /// The largest body `sender` may send.
    public var maxBody: Int { sender == .joiner ? NearbyJoin.maxRequestBody : NearbyJoin.maxReplyBody }

    /// Bytes held at most: the magic and one whole frame.
    var capacity: Int { NearbyJoin.magic.count + 4 + maxBody }

    /// Takes bytes received.
    ///
    /// - Throws: `oversized` when more bytes are held than one frame may have.
    public mutating func push(_ bytes: Data) throws {
        guard buffer.count + bytes.count <= capacity else { throw NearbyJoinError.oversized(buffer.count + bytes.count) }
        buffer.append(bytes)
    }

    /// The next whole message, or nil until more bytes arrive.
    ///
    /// - Throws: `badMagic`, `oversized` (a claimed length beyond `maxBody`, before its body arrives), `malformed`,
    ///   `unexpected` (a type `sender` may not send).
    public mutating func next() throws -> NearbyJoinMessage? {
        if !sawMagic {
            let m = NearbyJoin.magic
            guard buffer.count >= m.count else {
                if !m.starts(with: buffer) { throw NearbyJoinError.badMagic }
                return nil
            }
            guard buffer.prefix(m.count) == m else { throw NearbyJoinError.badMagic }
            buffer = Data(buffer.dropFirst(m.count))
            sawMagic = true
        }
        guard buffer.count >= 4 else { return nil }
        let b = [UInt8](buffer.prefix(4))
        let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard length >= 1 else { throw NearbyJoinError.malformed("an empty frame") }
        guard length <= maxBody else { throw NearbyJoinError.oversized(length) }
        guard buffer.count >= 4 + length else { return nil }
        let body = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return try Self.decode(body, from: sender)
    }

    /// Whether the next frame's header (the magic before the first, its length and type byte) has arrived, checked:
    /// the session times the header and the body apart (a reply of megabytes gets the session's time, not the
    /// handshake's).
    ///
    /// - Throws: what `next()` throws for a bad magic, a bad length or a type `sender` may not send.
    public mutating func headerReady() throws -> Bool {
        let m = NearbyJoin.magic
        let start = sawMagic ? 0 : m.count
        if !sawMagic {
            guard m.starts(with: buffer.prefix(m.count)) else { throw NearbyJoinError.badMagic }
            guard buffer.count >= m.count else { return false }
        }
        guard buffer.count >= start + 5 else { return false }
        let b = [UInt8](buffer.dropFirst(start).prefix(5))
        let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard length >= 1 else { throw NearbyJoinError.malformed("an empty frame") }
        guard length <= maxBody else { throw NearbyJoinError.oversized(length) }
        let known: Set<UInt8> = sender == .joiner ? [1, 5] : [2, 3, 4, 6]
        guard known.contains(b[4]) else { throw NearbyJoinError.unexpected("message type \(b[4])") }
        return true
    }

    static func decode(_ body: Data, from sender: Sender) throws -> NearbyJoinMessage {
        guard let type = body.first else { throw NearbyJoinError.malformed("an empty frame") }
        let payload = Data(body.dropFirst())
        switch (sender, type) {
        case (.joiner, 1):
            guard !payload.isEmpty else { throw NearbyJoinError.malformed("a request without its file") }
            return .request(payload)
        case (.joiner, 5):
            guard payload.count == NearbyJoin.nonceBytes else { throw NearbyJoinError.malformed("a nonce of the wrong size") }
            return .hello(nonce: payload)
        case (.approver, 6):
            guard payload.count == 32 else { throw NearbyJoinError.malformed("a proof of the wrong size") }
            return .proof(payload)
        case (.approver, 2):
            guard payload.isEmpty else { throw NearbyJoinError.malformed("waiting carries no payload") }
            return .waiting
        case (.approver, 3):
            guard !payload.isEmpty else { throw NearbyJoinError.malformed("an empty reply") }
            return .reply(payload)
        case (.approver, 4):
            guard payload.count == 1, let why = NearbyJoinRefusal(rawValue: payload[payload.startIndex]) else {
                throw NearbyJoinError.malformed("an unknown refusal")
            }
            return .refused(why)
        default:
            throw NearbyJoinError.unexpected("message type \(type)")
        }
    }
}

/// What the approver sends a device it approved (design §6.2.1): exactly what the new device would otherwise take from
/// the target between the approval and its confirmation, `vault.json` and the current epoch's record, plus the
/// session's nonce and the request's commitment, all sealed (age) to the request's device key.
public struct NearbyJoinReply: Equatable, Sendable {
    /// The joining device's nonce of this session.
    public var nonce: Data
    /// The commitment of the request it answers (`JoinRequest.commitment`).
    public var commitment: Data
    /// `vault.json` as on the approver's disk, listing the device.
    public var manifest: Data
    /// The current epoch record's file name under `epochs/`, as `vault.json` names it.
    public var recordName: String
    /// That record's bytes; nil when it is larger than `NearbyJoin.maxRecordBytes` (it comes with the sync).
    public var record: Data?

    public init(nonce: Data, commitment: Data, manifest: Data, recordName: String, record: Data?) {
        self.nonce = nonce
        self.commitment = commitment
        self.manifest = manifest
        self.recordName = recordName
        self.record = record
    }

    static let label = "sempere-nearby-reply/1\n"

    /// The plaintext: the label, then `lp(nonce) ‖ lp(commitment) ‖ lp(manifest) ‖ lp(recordName) ‖ lp(record)` (an
    /// empty record: none).
    func plaintext() -> Data {
        var m = LPMessage(Self.label)
        m.field(nonce); m.field(commitment); m.field(manifest); m.field(recordName); m.field(record ?? Data())
        return m.bytes
    }

    /// Sealed to `key` (an `age1pq1…` device key, the request's): only that device opens it, so a device in the
    /// middle of the link learns nothing of the vault's list.
    public func seal(to key: String) throws -> Data {
        guard let recipient = try? NativeRecipient(string: key), recipient.isPostQuantum else {
            throw NearbyJoinError.malformed("not a post-quantum key")
        }
        return try AgeFile.encrypt(plaintext(), to: [recipient])
    }

    /// Opens a sealed reply with this device's key.
    ///
    /// - Throws: `malformed` (also for one this key does not open), `oversized`.
    public static func open(_ sealed: Data, identity: NativeIdentity) throws -> NearbyJoinReply {
        guard sealed.count <= NearbyJoin.maxReplyBody else { throw NearbyJoinError.oversized(sealed.count) }
        let plain: Data
        do { plain = try AgeFile.decrypt(sealed, with: [identity]) } catch { throw NearbyJoinError.malformed("not sealed to this device") }
        return try parse(plain)
    }

    /// Parses a reply's plaintext (bounded: every length is checked against what is left, and against its field's limit).
    static func parse(_ plain: Data) throws -> NearbyJoinReply {
        guard plain.count <= NearbyJoin.maxReplyPlaintext else { throw NearbyJoinError.oversized(plain.count) }
        let label = Data(Self.label.utf8)
        guard plain.starts(with: label) else { throw NearbyJoinError.malformed("not a nearby reply") }
        let bytes = [UInt8](plain)
        var at = label.count
        func field(max: Int) throws -> Data {
            guard bytes.count - at >= 4 else { throw NearbyJoinError.malformed("cut short") }
            let n = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            at += 4
            guard n <= max, n <= bytes.count - at else { throw NearbyJoinError.malformed("a field longer than it may be") }
            defer { at += n }
            return Data(bytes[at..<at + n])
        }
        let nonce = try field(max: NearbyJoin.nonceBytes)
        let commitment = try field(max: 32)
        let manifest = try field(max: BoundedRead.maxManifestBytes)
        let name = try field(max: 64)
        let record = try field(max: NearbyJoin.maxRecordBytes)
        guard at == bytes.count else { throw NearbyJoinError.malformed("bytes after the reply") }
        guard nonce.count == NearbyJoin.nonceBytes, commitment.count == 32 else {
            throw NearbyJoinError.malformed("a nonce or commitment of the wrong size")
        }
        guard let recordName = String(data: name, encoding: .utf8), Vault.isEpochRecordFileName(recordName) else {
            throw NearbyJoinError.malformed("not an epoch record name")
        }
        return NearbyJoinReply(nonce: nonce, commitment: commitment, manifest: manifest, recordName: recordName,
                               record: record.isEmpty ? nil : record)
    }
}

extension Vault {
    // MARK: - The approver (home)

    // A request that came nearby is never written to `joins/` (design N5): Add Device keeps it in memory while it
    // shows, and approves it by value (`approveDevice(_:)`); the joining device's own file still arrives by sync.

    /// The reply for `request` once `vault.json` on disk lists its key (approved by either route): that file's bytes and
    /// the current epoch's record (left out above `NearbyJoin.maxRecordBytes`). Nil while the key is not listed.
    public func nearbyReply(for request: JoinRequest, nonce: Data) throws -> NearbyJoinReply? {
        let data = try BoundedRead.contents(of: manifestURL, maxBytes: BoundedRead.maxManifestBytes)
        let m = try EpochManifest.parse(data)
        guard m.vaultId == vaultId, m.keys.contains(where: { $0.role == .device && $0.key == request.key }) else { return nil }
        let name = String(m.epochRecord.dropFirst(Self.epochsName.count + 1))
        let recordURL = epochsURL.appendingPathComponent(name)
        var record: Data?
        if let size = (try? FileManager.default.attributesOfItem(atPath: recordURL.path))?[.size] as? Int,
           size <= NearbyJoin.maxRecordBytes {
            record = try? BoundedRead.contents(of: recordURL, maxBytes: NearbyJoin.maxRecordBytes)
        }
        return NearbyJoinReply(nonce: nonce, commitment: request.commitment, manifest: data, recordName: name, record: record)
    }

    // MARK: - The joining device

    /// Takes an approval received nearby into the locked copy at `url` (design §6.2.1), as a join run takes one from a
    /// target: the reply must answer this session (`nonce`) and this device's request (`commitment`), its `vault.json`
    /// must be an approval of a key in `identities` (`isJoinApproval`, the sync engine's own test), and the epoch record
    /// it names must be in the copy or in the reply with the hash `vault.json` gives it (the record first, create-only;
    /// then `vault.json`). Taking it pins nothing: the device still confirms with the reply words. The caller holds the
    /// copy's write lock.
    ///
    /// - Parameter unconfirmed: this device keeps no trust record of the vault yet (`isJoinApproval`).
    /// - Returns: true when `vault.json` was replaced; false when the copy already holds these bytes.
    /// - Throws: `replayed`, `notAnApproval`, `recordMismatch`, `io`.
    @discardableResult
    public static func takeNearbyReply(_ reply: NearbyJoinReply, at url: URL, nonce: Data, commitment: Data,
                                       identities: [any AgeIdentity], unconfirmed: Bool) throws -> Bool {
        guard reply.nonce == nonce, reply.commitment == commitment else { throw NearbyJoinError.replayed }
        let manifestURL = url.appendingPathComponent(manifestName)
        let local = try BoundedRead.contents(of: manifestURL, maxBytes: BoundedRead.maxManifestBytes)
        if reply.manifest == local { return false }
        guard isJoinApproval(reply.manifest, local: local, identities: identities, unconfirmed: unconfirmed),
              let m = try? EpochManifest.parse(reply.manifest) else { throw NearbyJoinError.notAnApproval }
        let name = String(m.epochRecord.dropFirst(epochsName.count + 1))
        let epochs = url.appendingPathComponent(epochsName)
        let recordURL = epochs.appendingPathComponent(name)
        if !FileIO.exists(recordURL) {
            guard let record = reply.record, reply.recordName == name, Data(SHA256.hash(data: record)) == m.epochRecordHash,
                  (try? checkIncomingEpochRecord(record, name: name)) != nil else { throw NearbyJoinError.recordMismatch }
            try FileIO.createDirectory(epochs)
            do { try FileIO.writeAtomically(record, to: recordURL, replacing: false) } catch VaultError.alreadyExists {}
        }
        try FileIO.writeAtomically(reply.manifest, to: manifestURL, replacing: true)
        return true
    }
}
