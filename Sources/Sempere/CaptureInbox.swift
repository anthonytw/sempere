import Age
import Crypto
import Foundation

// Quick capture without unlocking (format.md §11, docs/quick-capture.md).
//
// A device that may capture keeps a `CaptureProfile`: the vault's public
// recipients and a capture key derived from the vault secret (never the
// secret itself, never an identity). With it, a voice note is sealed into
// `inbox/<id>.capture.age`: encrypted to the recipients like every vault
// file, and authenticated with the capture key so that nobody without the
// vault secret can plant one. The next device that unlocks the vault adopts
// it: the audio becomes a blob of a new note in the inbox notebook, with a
// title from the date, in one delta; a transcript sealed later the same way
// (`inbox/<id>.transcript.age`) is added to that recording.

/// Why a capture cannot be written or adopted.
public enum CaptureError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Not a capture file: wrong magic, version, length or layout.
    case notCapture(String)
    /// The tag does not verify: forged, damaged, or sealed under another
    /// vault secret (one rotated since, format.md §3.3).
    case badTag
    /// The manifest or transcript inside does not parse or breaks a rule.
    case invalidContent(String)
    /// The audio's size or hash differs from the manifest.
    case audioMismatch
    /// Larger than `CaptureFile.maxBytes`.
    case tooLarge(Int)
    /// The capture names another vault.
    case wrongVault
    /// The profile has no usable recipient.
    case noRecipients
    /// A capture key that is not 32 bytes.
    case invalidKey
    /// An inbox file that failed `failures` times before and is not read
    /// again until `retryAfter` (unless it changes): the device-local
    /// back-off of format.md §11.3 (security review 2026-10, C5).
    case backedOff(failures: Int, retryAfter: Date, lastError: String)
    /// A capture profile asked for with a key that is not one of the vault's
    /// recipients: captures are attributed to a listed device (format.md §11.1).
    case notARecipient

    public var description: String {
        switch self {
        case .notCapture(let why): return "not a capture file: \(why)"
        case .badTag:
            return "the capture does not verify (forged, damaged, sealed before the vault's keys changed, or by a device "
                + "no longer in the vault)"
        case .invalidContent(let why): return "invalid capture: \(why)"
        case .audioMismatch: return "the capture's audio does not match its manifest"
        case .tooLarge(let n): return "the capture is larger than \(n >> 20) MiB"
        case .wrongVault: return "the capture belongs to another vault"
        case .noRecipients: return "the capture profile has no usable recipient"
        case .invalidKey: return "a capture key must be 32 bytes"
        case .backedOff(let n, let after, let last):
            return "failed \(n) time(s) (\(last)); not read again before \(RFC3339.string(from: after) ?? "later") unless it changes"
        case .notARecipient: return "the key is not one of the vault's recipients, so captures could not be attributed to it"
        }
    }
}

/// The key that authenticates captures (format.md §11.1): HKDF-SHA256 of
/// the vault secret with `info` `sempere/1 capture key`. It cannot decrypt
/// anything, cannot tag revisions or name blobs, and reveals nothing about the
/// secret; it only lets its holder put captures in the inbox. It changes with
/// the secret, so removing a device's recipient also revokes its captures.
public struct CaptureKey: Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 32 else { throw CaptureError.invalidKey }
        self.bytes = bytes
    }

    static let info = "sempere/1 capture key"
    static let deviceInfo = "sempere/1 device capture key"

    /// The vault capture key of a vault secret (format.md §11.1): what
    /// profiles made before attribution hold. Captures it tags are
    /// unattributed.
    public static func derive(from secret: VaultSecret) -> CaptureKey {
        derive(secret, info: Data(info.utf8))
    }

    /// The device capture key of the recipient whose fingerprint is
    /// `device` (format.md §11.1): HKDF-SHA256 of the secret with `info`
    /// `sempere/1 device capture key ‖ 0x00 ‖ fingerprint`. Of the profiles,
    /// only that device's holds it, so a capture it tags is attributed to that
    /// recipient (security review 2026-10, C2); a holder of the vault secret
    /// can derive it too, as it can write any revision.
    public static func derive(from secret: VaultSecret, device fingerprint: String) -> CaptureKey {
        var info = Data(deviceInfo.utf8)
        info.append(0)
        info.append(contentsOf: fingerprint.utf8)
        return derive(secret, info: info)
    }

    private static func derive(_ secret: VaultSecret, info: Data) -> CaptureKey {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: info, outputByteCount: 32)
        return CaptureKey(valid: k.withUnsafeBytes { Data($0) })
    }

    /// A recipient's fingerprint (format.md §11.1): the lowercase hex SHA-256
    /// of its key string as written in `vault.json`, as in the names of
    /// post-quantum key files (§3.2).
    public static func fingerprint(of recipient: String) -> String {
        FileDigest.sha256(Data(recipient.utf8))
    }

    private init(valid: Data) { bytes = valid }
}

/// What a device keeps so it can capture while the vault is locked (and the
/// device itself may be): no identity and no vault secret. The app keeps it
/// in the Keychain (this device only, readable after the first unlock).
public struct CaptureProfile: Codable, Hashable, Sendable {
    public var vaultId: UUID
    /// The vault's recipients (`age1pq1…`), public.
    public var recipients: [String]
    /// `CaptureKey.bytes`: the device capture key of `recipient`, or the
    /// vault capture key for a profile made before attribution.
    public var key: Data
    /// The capturing device's id (format.md §5), recorded in each capture.
    public var device: String
    /// The notebook adopted captures go to.
    public var notebook: String
    /// The fingerprint (`CaptureKey.fingerprint`) of the vault recipient this
    /// profile was made for (format.md §11.1); nil in a profile made before
    /// attribution, whose captures are unattributed.
    public var recipient: String?

    public init(vaultId: UUID, recipients: [String], key: Data, device: String, notebook: String, recipient: String? = nil) {
        self.vaultId = vaultId; self.recipients = recipients; self.key = key; self.device = device
        self.notebook = notebook; self.recipient = recipient
    }

    /// False for a profile made before attribution (no `recipient`): it
    /// should be made again (`Vault.captureProfile`) by a device that unlocks.
    public var isAttributed: Bool { recipient != nil }

    /// The default inbox notebook.
    public static let defaultNotebook = "Inbox"
}

extension Vault {
    /// The vault capture key (format.md §11.1). Needs the vault secret.
    public func captureKey() throws -> CaptureKey { CaptureKey.derive(from: try requireSecret()) }

    /// The recipient key of an identity this vault holds, if it is listed.
    func listedRecipient(of identity: any AgeIdentity) -> String? {
        let key: String?
        if let n = identity as? NativeIdentity { key = n.recipient.string } else if let x = identity as? X25519Identity {
            key = x.recipient.string
        } else { key = nil }
        guard let key, manifest.recipients.contains(where: { $0.key == key }) else { return nil }
        return key
    }

    /// A capture profile for this device: the recipients and the device
    /// capture key of `recipient` (format.md §11.1). Needs the vault unlocked
    /// once; afterwards captures need nothing else.
    ///
    /// - Parameter recipient: the listed key the profile is made for; nil
    ///   takes that of the first identity the vault was opened with that is
    ///   listed (the key this device unlocked with).
    /// - Throws: `VaultError.untrustedRecipients` when the recipients list
    ///   does not check (format.md §2.1); `CaptureError.notARecipient` when
    ///   no listed key is known.
    public func captureProfile(device: DeviceID, notebook: String = CaptureProfile.defaultNotebook,
                               recipient: String? = nil) throws -> CaptureProfile {
        try requireMigrated()
        // A profile lets captures be written into inbox/ (format.md §7.3), and they are
        // sealed to these keys alone (§11.1): never to a list that does not check.
        try requireNotReadOnly()
        try requireTrustedRecipients()
        let secret = try requireSecret()
        guard let key = recipient ?? identities.lazy.compactMap({ self.listedRecipient(of: $0) }).first,
              recipients.contains(where: { $0.key == key }) else { throw CaptureError.notARecipient }
        let fingerprint = CaptureKey.fingerprint(of: key)
        let nb = NoteOps.normalizedNotebook(notebook) ?? CaptureProfile.defaultNotebook
        return CaptureProfile(vaultId: vaultId, recipients: recipients.map(\.key),
                              key: CaptureKey.derive(from: secret, device: fingerprint).bytes,
                              device: device.rawValue, notebook: nb, recipient: fingerprint)
    }

    /// The capture keys a reader tries (format.md §11.2), in one streamed pass:
    /// the vault capture key and the device capture key of every listed
    /// recipient, under the current secret; during an unfinished rewrap,
    /// the listed recipients' device capture keys under the outgoing secret
    /// too, and its vault capture key only when `legacyPrevious` (the run
    /// that rotated the secret, security review 2026-10, C3). A recipient
    /// no longer listed has no key here: its captures never verify.
    func captureKeyRing(legacyPrevious: Bool = false) throws -> [CaptureKeyEntry] {
        let secret = try requireSecret()
        let devices = manifest.recipients.map { CaptureKey.fingerprint(of: $0.key) }
        var ring = [CaptureKeyEntry(key: .derive(from: secret), recipient: nil, previous: false)]
        ring += devices.map { CaptureKeyEntry(key: .derive(from: secret, device: $0), recipient: $0, previous: false) }
        if let previousSecret {
            if legacyPrevious { ring.append(CaptureKeyEntry(key: .derive(from: previousSecret), recipient: nil, previous: true)) }
            ring += devices.map { CaptureKeyEntry(key: .derive(from: previousSecret, device: $0), recipient: $0, previous: true) }
        }
        return ring
    }
}

/// One key of `Vault.captureKeyRing`.
struct CaptureKeyEntry: Sendable {
    var key: CaptureKey
    /// The recipient fingerprint it attributes to; nil for a vault capture key.
    var recipient: String?
    /// Derived from the outgoing secret of an unfinished rewrap.
    var previous: Bool
}

extension Vault {

    /// The vault's inbox folder (format.md §1).
    public var inboxURL: URL { url.appendingPathComponent(CaptureFile.folderName, isDirectory: true) }
}

/// A capture's manifest (format.md §11.2): one line of JSON before the audio.
public struct CaptureManifest: Codable, Hashable, Sendable {
    public static let formatName = "sempere-capture/1"

    public var id: UUID
    /// The capturing device (8 lowercase hex digits).
    public var device: String
    public var vault: UUID
    /// When the capture was sealed.
    public var created: Date
    /// Wall time of the first sample.
    public var started: Date
    /// The note's title.
    public var title: String
    /// The notebook to adopt into; absent means `Inbox`.
    public var notebook: String?
    /// The fingerprint of the vault recipient whose device capture key
    /// sealed it (format.md §11.2); absent when sealed with the vault capture
    /// key (unattributed). A reader checks it against the key that verified.
    public var recipient: String?
    /// The audio that follows the manifest: its media type, size and SHA-256.
    public var audio: BlobRef
    /// Informational, as on recordings (format.md §8.3.1).
    public var duration: Double?
    public var codec: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitRate: Int?

    public init(id: UUID, device: String, vault: UUID, created: Date, started: Date, title: String, notebook: String?,
                audio: BlobRef, info: AudioInfo? = nil, recipient: String? = nil) {
        self.id = id; self.device = device; self.vault = vault; self.created = created; self.started = started
        self.title = title; self.notebook = notebook; self.audio = audio; self.recipient = recipient
        duration = info?.duration; codec = info?.codec; sampleRate = info?.sampleRate; channels = info?.channels
        bitRate = info?.bitRate
    }

    /// The recording's informational fields.
    public var info: AudioInfo {
        var i = AudioInfo()
        i.duration = duration; i.codec = codec; i.sampleRate = sampleRate; i.channels = channels; i.bitRate = bitRate
        return i
    }

    enum CodingKeys: String, CodingKey {
        case format, id, device, vault, created, started, title, notebook, recipient, audio, duration, codec, sampleRate, channels, bitRate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "unknown capture format")
        }
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        device = try c.decode(String.self, forKey: .device)
        guard DeviceID(device) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .device, in: c, debugDescription: "bad device id")
        }
        vault = try c.decode(LowercaseUUID.self, forKey: .vault).uuid
        created = try c.decode(Date.self, forKey: .created)
        started = try c.decode(Date.self, forKey: .started)
        title = try c.decode(String.self, forKey: .title)
        notebook = try c.decodeIfPresent(String.self, forKey: .notebook)
        recipient = try c.decodeIfPresent(String.self, forKey: .recipient)
        if let recipient, Hex.decode(recipient) == nil {
            throw DecodingError.dataCorruptedError(forKey: .recipient, in: c, debugDescription: "not 64 lowercase hex digits")
        }
        audio = try c.decode(BlobRef.self, forKey: .audio)
        guard audio.isValid, audio.type.lowercased().hasPrefix("audio/") else {
            throw DecodingError.dataCorruptedError(forKey: .audio, in: c, debugDescription: "bad audio reference")
        }
        duration = try c.decodeIfPresent(Double.self, forKey: .duration).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate).flatMap { $0 > 0 ? $0 : nil }
        channels = try c.decodeIfPresent(Int.self, forKey: .channels).flatMap { $0 > 0 ? $0 : nil }
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate).flatMap { $0 > 0 ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(device, forKey: .device)
        try c.encode(LowercaseUUID(vault), forKey: .vault)
        try c.encode(created, forKey: .created)
        try c.encode(started, forKey: .started)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notebook, forKey: .notebook)
        try c.encodeIfPresent(recipient, forKey: .recipient)
        try c.encode(audio, forKey: .audio)
        try c.encodeIfPresent(duration.map(InkJSON.round3), forKey: .duration)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try c.encodeIfPresent(channels, forKey: .channels)
        try c.encodeIfPresent(bitRate, forKey: .bitRate)
    }
}

/// The plaintext layout of inbox files (format.md §11.2):
///
/// | Offset | Size | Content |
/// | --- | --- | --- |
/// | 0 | 4 | ASCII `SMPC` |
/// | 4 | 1 | version `0x01` |
/// | 5 | 32 | HMAC-SHA256(capture key, `"sempere/1" ‖ 0x00 ‖ "capture" ‖ 0x00 ‖ filename ‖ 0x00 ‖ rest`) |
/// | 37 | rest | one line of JSON (no raw newline), `0x0A`, then the payload |
///
/// so `age -d -i key F | tail -c +38 | head -n 1 | jq .` reads the manifest and
/// `… | tail -c +38 | tail -n +2 > audio.m4a` the audio.
public enum CaptureFile {
    /// The vault folder that holds captures (format.md §1).
    public static let folderName = "inbox"
    static let magic: [UInt8] = Array("SMPC".utf8)
    static let version: UInt8 = 1
    public static let headerSize = 37
    /// Largest plaintext an inbox file may have (the audio of a few hours).
    public static let maxBytes = 256 << 20
    /// Largest JSON line.
    public static let maxLineBytes = Transcript.maxSize

    public enum Kind: String, Sendable, CaseIterable {
        case capture, transcript
    }

    /// `<id>.<kind>.age`.
    public static func name(_ id: UUID, _ kind: Kind) -> String { "\(id.uuidString.lowercased()).\(kind.rawValue).age" }

    /// The id and kind of an inbox file name; nil for anything else (an unknown file, ignored).
    public static func parse(name: String) -> (id: UUID, kind: Kind)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "age", let kind = Kind(rawValue: String(parts[1])),
              parts[0].count == 36, parts[0] == parts[0].lowercased(), let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, kind)
    }

    /// Computed incrementally: `rest` (up to `maxBytes`) is never copied.
    static func tag<D: DataProtocol>(_ key: CaptureKey, filename: String, rest: D) -> Data {
        var hmac = tagHMAC(key, filename: filename)
        hmac.update(data: rest)
        return Data(hmac.finalize())
    }

    /// The tag's HMAC with everything before `rest` fed in.
    static func tagHMAC(_ key: CaptureKey, filename: String) -> HMAC<SHA256> {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "capture".utf8); m.append(0); m.append(contentsOf: filename.utf8); m.append(0)
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: key.bytes))
        hmac.update(data: m)
        return hmac
    }

    /// Largest plaintext of an inbox file of `kind`: a transcript holds one
    /// JSON line (at most `maxLineBytes`) and a 64-digit hash, so it gets a
    /// much smaller bound than a capture's audio (security review 2026-10, C5).
    public static func maxPlaintextBytes(_ kind: Kind) -> Int {
        switch kind {
        case .capture: return maxBytes
        case .transcript: return min(maxBytes, headerSize + maxLineBytes + 1 + 64)
        }
    }

    /// Largest file of `kind` read at all: its plaintext bound plus age's
    /// header and per-chunk overhead (16 bytes per 64 KiB) with room to spare.
    public static func maxSealedBytes(_ kind: Kind) -> Int {
        let plain = maxPlaintextBytes(kind)
        return plain + plain / 4096 + (1 << 20)
    }

    /// The plaintext of an inbox file named `filename`.
    public static func frame(line: Data, payload: Data, filename: String, key: CaptureKey) throws -> Data {
        guard !line.contains(0x0A), line.count <= maxLineBytes else { throw CaptureError.invalidContent("the JSON is not one line") }
        var rest = line
        rest.append(0x0A)
        rest.append(payload)
        guard headerSize + rest.count <= maxBytes else { throw CaptureError.tooLarge(maxBytes) }
        var out = Data(magic)
        out.append(version)
        out.append(tag(key, filename: filename, rest: rest))
        out.append(rest)
        return out
    }

    /// The JSON line and payload of an inbox file's plaintext, once its tag
    /// verifies under `key` for `filename`.
    public static func unframe(_ plaintext: Data, filename: String, key: CaptureKey) throws -> (line: Data, payload: Data) {
        guard plaintext.count <= maxBytes else { throw CaptureError.tooLarge(maxBytes) }
        guard plaintext.count > headerSize else { throw CaptureError.notCapture("too short") }
        let b = plaintext.startIndex
        guard Array(plaintext[b..<b + 4]) == magic else { throw CaptureError.notCapture("bad magic") }
        guard plaintext[b + 4] == version else { throw CaptureError.notCapture("unknown version \(plaintext[b + 4])") }
        let stored = plaintext[b + 5..<b + headerSize]
        let rest = plaintext[(b + headerSize)...]
        let expected = tag(key, filename: filename, rest: rest)
        guard RecipientsAuth.constantTimeEqual(Data(stored), expected) else { throw CaptureError.badTag }
        guard let nl = rest.prefix(maxLineBytes + 1).firstIndex(of: 0x0A) else {
            throw CaptureError.notCapture("no JSON line")
        }
        return (Data(rest[rest.startIndex..<nl]), Data(rest[(nl + 1)...]))
    }

    /// The plaintext of inbox file `filename` tagged under `key` instead: the
    /// same bytes after the tag, once the old tag verifies under `old`
    /// (format.md §11.1, a recipient change). Nil when it does not.
    static func retag(_ plaintext: Data, filename: String, verifiedBy old: CaptureKey, to key: CaptureKey) -> Data? {
        guard (try? unframe(plaintext, filename: filename, key: old)) != nil else { return nil }
        let rest = plaintext[(plaintext.startIndex + headerSize)...]
        var out = Data(magic)
        out.append(version)
        out.append(tag(key, filename: filename, rest: rest))
        out.append(rest)
        return out
    }

    /// How much of a capture's JSON line is scanned for its device claim:
    /// the keys before `recipient` (sorted, InkJSON) are short, except
    /// `notebook`, which writers bound (`CaptureAdoption.boundedName`: at most
    /// 1200 scalars, under 10 KB even JSON-escaped).
    static let claimWindow = 64 << 10
    /// At most this many claims are taken (a writer makes one).
    static let maxClaims = 2

    /// The device fingerprints a capture's JSON line claims, before its tag
    /// is checked (format.md §11.2): each `"recipient":"<64 lowercase hex>"`
    /// (JSON whitespace allowed around the colon) in the first `claimWindow`
    /// bytes, up to the first newline, at most `maxClaims`. A byte scan, not a
    /// JSON parse: it only picks which device capture keys the reader tries,
    /// so that the work is bounded by the vault capture keys and one device's,
    /// not by the length of the list (review of #125). The tag and the parsed
    /// manifest's `recipient` stay the authority; a claim that is wrong only
    /// makes the file fail.
    static func claimedDevices<D: DataProtocol>(in bytes: D) -> Set<String> {
        var b = Array(bytes.prefix(claimWindow))
        if let nl = b.firstIndex(of: 0x0A) { b = Array(b[..<nl]) }
        let needle = Array("\"recipient\"".utf8)
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }
        func isHex(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x61...0x66).contains(c) }
        var out = Set<String>()
        var i = 0
        while i + needle.count <= b.count, out.count < maxClaims {
            guard Array(b[i..<i + needle.count]) == needle else { i += 1; continue }
            var j = i + needle.count
            while j < b.count, isSpace(b[j]) { j += 1 }
            guard j < b.count, b[j] == 0x3A else { i += 1; continue }
            j += 1
            while j < b.count, isSpace(b[j]) { j += 1 }
            guard j + 66 <= b.count, b[j] == 0x22, b[j + 65] == 0x22, b[(j + 1)...(j + 64)].allSatisfy(isHex) else {
                i += 1; continue
            }
            out.insert(String(decoding: b[(j + 1)...(j + 64)], as: UTF8.self))
            i = j + 66
        }
        return out
    }
}

/// A sealed inbox file: its name and its bytes (an age file).
public struct SealedCapture: Hashable, Sendable {
    public var name: String
    public var data: Data

    /// A sealed file as read back, e.g. from a device-local queue.
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Seals captures with a `CaptureProfile` alone: no identity, no vault
/// secret (format.md §11.2). What it writes is age-encrypted to the vault's
/// recipients before it touches a disk.
public struct CaptureWriter: Sendable {
    public let profile: CaptureProfile
    let key: CaptureKey
    let recipients: [NativeRecipient]

    public init(profile: CaptureProfile) throws {
        self.profile = profile
        key = try CaptureKey(bytes: profile.key)
        recipients = profile.recipients.compactMap { try? NativeRecipient(string: $0) }
        guard !recipients.isEmpty, recipients.count == profile.recipients.count else { throw CaptureError.noRecipients }
    }

    /// A title from the start time, e.g. `Voice note 2026-10-07 14:32`
    /// (in `timeZone`); the app passes a localized one.
    public static func defaultTitle(_ started: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: started)
        return String(format: "Voice note %04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Seals `audio` (an `audio/mp4` recording by default) as capture `id`.
    public func seal(audio: Data, type: String = "audio/mp4", started: Date, info: AudioInfo? = nil, title: String? = nil,
                     id: UUID = UUID(), created: Date = Date()) throws -> SealedCapture {
        let manifest = CaptureManifest(id: id, device: profile.device, vault: profile.vaultId, created: created, started: started,
                                       title: title ?? Self.defaultTitle(started),
                                       notebook: CaptureAdoption.boundedName(profile.notebook),
                                       audio: BlobRef(content: audio, type: type), info: info, recipient: profile.recipient)
        let name = CaptureFile.name(id, .capture)
        let plain = try CaptureFile.frame(line: try InkJSON.encoder().encode(manifest), payload: audio, filename: name, key: key)
        return SealedCapture(name: name, data: try Vault.encrypt(plain, to: recipients))
    }

    /// Seals the transcript of capture `id` (its `recording` must be the
    /// capture's recording id, `CaptureAdoption.ids(for:)`), bound to the
    /// capture's `audio` (the manifest's reference): the payload is its
    /// SHA-256, which only whoever had the audio knows (format.md §11.2), so
    /// another holder of the capture key cannot attach a transcript of its
    /// own to the voice note.
    public func seal(transcript: Transcript, capture id: UUID, audio: BlobRef) throws -> SealedCapture {
        guard transcript.recording == CaptureAdoption.ids(for: id).recording else {
            throw CaptureError.invalidContent("the transcript names another recording")
        }
        guard audio.isValid else { throw CaptureError.invalidContent("bad audio reference") }
        let name = CaptureFile.name(id, .transcript)
        let plain = try CaptureFile.frame(line: try transcript.encoded(), payload: Data(audio.sha256.utf8), filename: name,
                                          key: key)
        return SealedCapture(name: name, data: try Vault.encrypt(plain, to: recipients))
    }

    /// Writes `sealed` into the folder `inbox` (created if missing) under its
    /// name, atomically and durably (`FileIO`'s temporary name, `fsync`,
    /// `placeNew`), never over an existing file (inbox files are written once).
    public static func store(_ sealed: SealedCapture, in inbox: URL) throws {
        try FileIO.createDirectory(inbox)
        let final = inbox.appendingPathComponent(sealed.name)
        guard !FileIO.exists(final) else { return }
        let tmp = FileIO.tempURL(in: inbox)
        try FileIO.writeNewFile(tmp) { try $0(sealed.data) }
        do { try FileIO.placeNew(tmp, at: final) } catch VaultError.alreadyExists {}
    }
}

/// An inbox entry read and verified: the capture (if its file is there) and
/// its transcript (if one was sealed).
public struct PendingCapture: Sendable {
    public var id: UUID
    public var manifest: CaptureManifest?
    public var audio: Data?
    public var transcript: Transcript?
    /// Transcript content as stored (for the blob).
    public var transcriptContent: Data?
    /// The SHA-256 (lowercase hex) of the audio the transcript is bound to
    /// (format.md §11.2); nil when there is no usable transcript.
    public var transcriptAudio: String?
    /// The recipient fingerprint the capture is attributed to: the device
    /// whose capture key verified it (format.md §11.2); nil when sealed with
    /// the vault capture key, or when only the transcript was read.
    public var recipient: String?
    /// The same for the transcript file.
    public var transcriptRecipient: String?
    /// The inbox files read.
    public var files: [String]
}

/// Turning captures into notes (format.md §11.3).
public enum CaptureAdoption {
    /// The note, page and recording ids of capture `id`: derived from it, so
    /// two devices that adopt the same capture write the same note, and an
    /// adoption interrupted before the inbox file was deleted is not doubled.
    public static func ids(for id: UUID) -> (note: UUID, page: UUID, recording: UUID) {
        let base = "sempere-capture/1 " + id.uuidString.lowercased()
        return (UUID.derived(from: base + " note"), UUID.derived(from: base + " page"), UUID.derived(from: base + " recording"))
    }

    /// The inbox files of `pending` that may be deleted once its note is
    /// `after` (nil: no note): the capture once the note exists; the
    /// transcript once the recording has one (or is gone: removed by the user).
    public static func consumed(_ pending: PendingCapture, after: NoteState?) -> [String] {
        guard let after, !after.pages.isEmpty || !after.recordings.isEmpty else { return [] }
        var done = pending.files.filter { CaptureFile.parse(name: $0)?.kind == .capture }
        let rec = after.recordings.first { $0.id == ids(for: pending.id).recording }
        // A transcript that is not bound to this recording's audio is never adopted.
        if rec == nil || rec?.transcript != nil || rec?.blob.sha256 != pending.transcriptAudio
            || rec?.captured?.recipient != pending.transcriptRecipient {
            done += pending.files.filter { CaptureFile.parse(name: $0)?.kind == .transcript }
        }
        return done
    }

    /// The ops that adopt `pending` into its note, whose current state is
    /// `current` (nil: no revision yet). A new note gets its title, notebook,
    /// one page, the recording (`audio` is its blob) and the transcript when
    /// there is one, in one delta. A note that exists only gets the
    /// transcript, if its recording is there without one. Nothing when there
    /// is nothing to add (a transcript whose capture has not arrived yet waits).
    /// A transcript is only added to the recording whose audio it is bound to
    /// (`PendingCapture.transcriptAudio`, format.md §11.2).
    /// Longest title or notebook a capture gives its note, in characters.
    public static let maxNameLength = 300
    /// ... and in Unicode scalars: one character (grapheme cluster) has no
    /// length limit, a letter followed by any number of combining marks.
    public static let maxNameScalars = 4 * maxNameLength

    /// A manifest's title or notebook as the note gets it (format.md §11.3):
    /// control characters (newlines included) become spaces, and it is cut
    /// at `maxNameLength` characters and `maxNameScalars` scalars (whole
    /// characters, except one that alone is longer than that). The manifest's
    /// own limit is only its 64 MiB line, and any capture-key holder writes
    /// it (security review 2026-10, C2).
    public static func boundedName(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        var characters = 0, scalars = 0
        for ch in name {
            guard characters < maxNameLength, scalars < maxNameScalars else { break }
            let s = ch.unicodeScalars
            if s.contains(where: { $0.properties.generalCategory == .control }) {
                out.append(" "); scalars += 1
            } else if scalars + s.count <= maxNameScalars {
                out.append(contentsOf: s); scalars += s.count
            } else {
                if characters == 0 { out.append(contentsOf: s.prefix(maxNameScalars)) }
                break
            }
            characters += 1
        }
        return String(out)
    }

    public static func ops(_ pending: PendingCapture, audio: BlobRef?, transcript: BlobRef?, current: NoteState?,
                           paper: Paper = .ruled, pageSize: PageSize = .letter) -> [Op] {
        let ids = ids(for: pending.id)
        if let current, !current.recordings.isEmpty || !current.pages.isEmpty || !current.meta.title.isEmpty {
            // Only from the device the capture is attributed to (format.md §11.3).
            guard let transcript, let r = current.recordings.first(where: { $0.id == ids.recording }), r.transcript == nil,
                  r.blob.sha256 == pending.transcriptAudio, r.captured?.recipient == pending.transcriptRecipient
            else { return [] }
            return [.setRecording(recordingId: ids.recording, change: .transcript(transcript))]
        }
        guard let m = pending.manifest, let audio else { return [] }
        let transcript = m.audio.sha256 == pending.transcriptAudio && pending.transcriptRecipient == pending.recipient
            ? transcript : nil
        var ops = NoteOps.newNote(title: boundedName(m.title), paper: paper, pageSize: pageSize,
                                  notebook: boundedName(m.notebook ?? CaptureProfile.defaultNotebook), pageId: ids.page)
        var recording = NoteOps.recording(blob: audio, started: m.started, info: m.info, id: ids.recording)
        recording.transcript = transcript
        // Who captured it (format.md §8.3.1, §11.3): the adopter writes the delta.
        recording.captured = CaptureAttribution(device: m.device, recipient: pending.recipient)
        ops.append(.addRecording(recording))
        return ops
    }
}

extension Vault {
    /// The inbox's capture ids, with the kinds of file each has, sorted.
    /// Unknown files are ignored (format.md §1).
    public func inboxEntries() throws -> [(id: UUID, kinds: Set<CaptureFile.Kind>)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inboxURL.path)) ?? []
        var byID: [UUID: Set<CaptureFile.Kind>] = [:]
        for n in names { if let p = CaptureFile.parse(name: n) { byID[p.id, default: []].insert(p.kind) } }
        return byID.map { ($0.key, $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Reads and verifies the inbox files of capture `id` (format.md §11.2):
    /// decrypted with the vault's identities, the tag checked under the
    /// capture key (the current vault secret's, or the previous one during a
    /// rewrap), the manifest and the audio's hash and size, the transcript
    /// against format.md §8.3.2 and the capture's recording id.
    ///
    /// - Parameters:
    ///   - backoff: this device's record of inbox files that failed before
    ///     (format.md §11.3): one that failed and has not changed is not read
    ///     again before its back-off ends (`CaptureError.backedOff`), and a new
    ///     failure of the tag check (or decryption, framing, size) is
    ///     recorded. Nil reads every file (tests, an explicit retry).
    ///   - now: the clock for the back-off.
    public func readCapture(_ id: UUID, backoff: InboxBackoff? = nil, now: Date = Date()) throws -> PendingCapture {
        try requireMigrated()
        guard canRead else { throw isLocked ? VaultError.locked : VaultError.noIdentities }
        // Captures are attributed against the authenticated device list (format.md §2.1, §11.2).
        try requireTrustedRecipients()
        let ring = try captureKeyRing()
        var pending = PendingCapture(id: id, files: [])
        for kind in CaptureFile.Kind.allCases {
            let name = CaptureFile.name(id, kind)
            let url = inboxURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let mark = backoff == nil ? nil : InboxBackoff.FileMark(url)
            if let backoff, let mark, let e = backoff.pending(vault: vaultId, name: name, mark: mark, now: now) {
                throw CaptureError.backedOff(failures: e.failures, retryAfter: e.retryAfter, lastError: e.lastError)
            }
            let entry: CaptureKeyEntry
            do {
                // The tag first, streamed in constant memory: only a file that
                // verifies is then read whole (security review 2026-10, C5).
                // The key that verifies says which device sealed it (C2).
                entry = try verifyInboxFile(url, name: name, kind: kind, ring: ring)
            } catch let e as CaptureError {
                if let backoff, let mark { backoff.recordFailure(vault: vaultId, name: name, mark: mark, error: e.description, now: now) }
                throw e
            }
            if let backoff { backoff.clear(vault: vaultId, name: name) }
            let sealed = try FileIO.read(url, maxBytes: CaptureFile.maxSealedBytes(kind))
            let plain: Data
            do { plain = try AgeFile.decrypt(sealed, with: identities) } catch {
                throw CaptureError.notCapture("cannot decrypt: \(error)")
            }
            let (line, payload) = try CaptureFile.unframe(plain, filename: name, key: entry.key)
            switch kind {
            case .capture:
                let m: CaptureManifest
                do { m = try InkJSON.decoder().decode(CaptureManifest.self, from: line) } catch {
                    throw CaptureError.invalidContent("\(error)")
                }
                guard m.id == id else { throw CaptureError.invalidContent("the manifest names another capture") }
                guard m.vault == vaultId else { throw CaptureError.wrongVault }
                guard BlobRef(content: payload, type: m.audio.type) == m.audio else { throw CaptureError.audioMismatch }
                // The device it names is the one whose key sealed it, or none (C2).
                guard m.recipient == entry.recipient else {
                    throw CaptureError.invalidContent("the manifest names another device than the key that sealed it")
                }
                pending.manifest = m
                pending.recipient = entry.recipient
                pending.audio = payload
            case .transcript:
                let t: Transcript
                do { t = try Transcript.decode(line) } catch { throw CaptureError.invalidContent("\(error)") }
                guard t.recording == CaptureAdoption.ids(for: id).recording else {
                    throw CaptureError.invalidContent("the transcript names another recording")
                }
                // Bound to the capture's audio (format.md §11.2). One that is
                // not (an empty payload, written before the binding, or another
                // audio's hash) is never adopted, and is deleted with the
                // capture: the app transcribes the recording itself then.
                // It must also come from the device the capture is attributed to (C2).
                let bound = String(decoding: payload, as: UTF8.self)
                if Hex.decode(bound) != nil, pending.manifest.map({ $0.audio.sha256 == bound }) ?? true,
                   pending.manifest == nil || pending.recipient == entry.recipient {
                    pending.transcript = t
                    pending.transcriptContent = line
                    pending.transcriptAudio = bound
                    pending.transcriptRecipient = entry.recipient
                }
            }
            pending.files.append(name)
        }
        return pending
    }

    /// Streams inbox file `url` (named `name`) through age and the tag's
    /// HMAC under each of `keys` in constant memory, without keeping the
    /// plaintext (format.md §11.2): its size against the bound of its kind
    /// first, then magic, version and tag. Returns the index of the key the
    /// tag verified under.
    ///
    /// - Throws: `CaptureError` (`tooLarge`, `notCapture`, `badTag`) for the
    ///   file's own faults; `VaultError.io` when it cannot be read.
    func verifyInboxFile(_ url: URL, name: String, kind: CaptureFile.Kind, ring: [CaptureKeyEntry]) throws -> CaptureKeyEntry {
        let sealedCap = CaptureFile.maxSealedBytes(kind), plainCap = CaptureFile.maxPlaintextBytes(kind)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue > sealedCap {
            throw CaptureError.tooLarge(plainCap)
        }
        let decryptor: AgeDecryptor, handle: FileHandle
        do { (decryptor, handle) = try Self.openBlobFile(url, identities: identities) } catch BlobError.unreadable(let why) {
            throw VaultError.io(why)   // I/O, not the file's fault: never backed off
        } catch {
            throw CaptureError.notCapture("cannot decrypt: \(error)")
        }
        defer { try? handle.close() }
        var head = Data()
        // A capture's keys are chosen once the start of its JSON line is in
        // (`CaptureFile.claimedDevices`); until then the bytes wait here. A
        // transcript (small, and it names no device) gets the whole ring.
        var waiting: Data? = kind == .capture ? Data() : nil
        var chosen: [CaptureKeyEntry] = kind == .capture ? [] : ring
        var hmacs = chosen.map { CaptureFile.tagHMAC($0.key, filename: name) }
        func choose() {
            guard let bytes = waiting else { return }
            let claims = CaptureFile.claimedDevices(in: bytes)
            chosen = ring.filter { $0.recipient.map(claims.contains) ?? true }
            hmacs = chosen.map { CaptureFile.tagHMAC($0.key, filename: name) }
            if !bytes.isEmpty { for i in hmacs.indices { hmacs[i].update(data: bytes) } }
            waiting = nil
        }
        var total = 0
        while true {
            let chunk: Data?
            do { chunk = try decryptor.next() } catch BlobError.unreadable(let why) { throw VaultError.io(why) } catch {
                throw CaptureError.notCapture("cannot decrypt: \(error)")
            }
            guard let chunk else { break }
            total += chunk.count
            guard total <= plainCap else { throw CaptureError.tooLarge(plainCap) }
            var rest = chunk[...]
            if head.count < CaptureFile.headerSize {
                let need = CaptureFile.headerSize - head.count
                head += rest.prefix(need)
                rest = rest.dropFirst(need)
                if head.count == CaptureFile.headerSize {
                    guard Array(head.prefix(4)) == CaptureFile.magic else { throw CaptureError.notCapture("bad magic") }
                    guard head[4] == CaptureFile.version else { throw CaptureError.notCapture("unknown version \(head[4])") }
                }
            }
            guard !rest.isEmpty else { continue }
            if waiting != nil {
                waiting?.append(contentsOf: rest)
                if let w = waiting, w.count >= CaptureFile.claimWindow || w.contains(0x0A) { choose() }
                continue
            }
            for i in hmacs.indices { hmacs[i].update(data: rest) }
        }
        choose()
        guard head.count == CaptureFile.headerSize, total > CaptureFile.headerSize else {
            throw CaptureError.notCapture("too short")
        }
        let stored = Data(head.suffix(32))
        for (i, h) in hmacs.enumerated() where RecipientsAuth.constantTimeEqual(Data(h.finalize()), stored) { return chosen[i] }
        throw CaptureError.badTag
    }

    /// Writes the blobs `pending` brings into its note (format.md §8.1.4:
    /// before the delta): the audio and the transcript.
    public func writeCaptureBlobs(_ pending: PendingCapture) throws -> (audio: BlobRef?, transcript: BlobRef?) {
        let note = CaptureAdoption.ids(for: pending.id).note
        var audioRef: BlobRef?
        if let audio = pending.audio, let m = pending.manifest {
            audioRef = try writeBlob(note: note, audio, type: m.audio.type)
        }
        var transcriptRef: BlobRef?
        if let content = pending.transcriptContent {
            transcriptRef = try writeBlob(note: note, content, type: BlobRef.transcriptType)
        }
        return (audioRef, transcriptRef)
    }

    /// Deletes inbox files once what they hold is in the vault.
    public func removeInboxFiles(_ names: [String]) {
        guard !isReadOnly else { return }   // format.md §7.3
        for n in names where CaptureFile.parse(name: n) != nil {
            try? FileManager.default.removeItem(at: inboxURL.appendingPathComponent(n))
        }
    }

    /// What adopting one capture did.
    public struct CaptureAdoptionResult: Sendable, Encodable {
        public var capture: String
        public var note: String
        public var title: String?
        /// The note was created by this adoption.
        public var created: Bool
        public var transcript: Bool
        /// The delta written (a file name in the note's folder); nil when none was needed.
        public var file: String?
        /// The inbox files deleted.
        public var removed: [String]
        public var error: String?
        /// Who captured it (format.md §11.3): the manifest's device and the
        /// recipient the capture is attributed to (nil: unattributed).
        public var captured: CaptureAttribution?
        /// That recipient's label in vault.json.
        public var capturedBy: String?
    }

    /// Adopts capture `id` as this device (the CLI's `inbox import`): reads
    /// and verifies it, writes its blobs, then one delta (format.md §11.3),
    /// then deletes the inbox files it consumed. A transcript whose capture
    /// is neither in the inbox nor adopted yet stays. With `dryRun` only the
    /// reading and verifying are done.
    public func adoptCapture(_ id: UUID, deviceState: URL, app: String, dryRun: Bool = false,
                             backoff: InboxBackoff? = nil, now: Date = Date()) -> CaptureAdoptionResult {
        let ids = CaptureAdoption.ids(for: id)
        var result = CaptureAdoptionResult(capture: id.uuidString.lowercased(), note: ids.note.uuidString.lowercased(),
                                           created: false, transcript: false, removed: [])
        do {
            let pending = try readCapture(id, backoff: backoff, now: now)
            result.title = pending.manifest?.title
            if let m = pending.manifest {
                let who = CaptureAttribution(device: m.device, recipient: pending.recipient)
                result.captured = who
                result.capturedBy = who.label(in: recipients)
            }
            // A note exists once it has a revision: a folder holding only the
            // blobs of an adoption interrupted before its delta is still new.
            let exists = try !revisionNames(of: ids.note).isEmpty
            let current = exists ? try reconstruct(try loadNote(ids.note)) : nil
            let planned = CaptureAdoption.ops(pending, audio: pending.manifest?.audio,
                                              transcript: pending.transcriptContent.map { BlobRef(content: $0, type: BlobRef.transcriptType) },
                                              current: current)
            result.created = !exists && pending.manifest != nil
            result.transcript = planned.contains { if case .setRecording = $0 { return true }
                                                   if case .addRecording(let r) = $0 { return r.transcript != nil }
                                                   return false }
            if dryRun { return result }
            try requireWritable()
            if !planned.isEmpty {
                let refs = try writeCaptureBlobs(pending)
                let revision: Revision?
                if exists {
                    revision = try apply(to: ids.note, deviceState: deviceState, app: app) { state in
                        CaptureAdoption.ops(pending, audio: refs.audio, transcript: refs.transcript, current: state)
                    }
                } else {
                    revision = try apply(CaptureAdoption.ops(pending, audio: refs.audio, transcript: refs.transcript, current: nil),
                                         to: ids.note, deviceState: deviceState, app: app)
                }
                result.file = revision?.name.filename
            }
            let after = try revisionNames(of: ids.note).isEmpty ? nil : try reconstruct(try loadNote(ids.note))
            let done = CaptureAdoption.consumed(pending, after: after)
            removeInboxFiles(done)
            result.removed = done
        } catch {
            result.error = (error as? CaptureError)?.description ?? "\(error)"
        }
        return result
    }
}

extension Vault {
    /// Step 3 of a recipient change (format.md §3.3.1) for `inbox/` (§11.1):
    /// a capture still waiting there was sealed with the capture key of the
    /// outgoing secret, so once the change finishes (and the journal with
    /// that secret is gone) nothing could adopt it. Each inbox file that
    /// verifies under the current or the outgoing capture key is re-tagged
    /// under the current one and re-encrypted to the current recipients (a
    /// new device can then adopt it too); one already current is skipped.
    /// Files that verify under neither key, or that this device cannot
    /// decrypt, are left untouched and listed in `inboxSkipped`: they are
    /// never adopted anyway, and must not keep the journal (and the
    /// outgoing secret) alive. Only a file that cannot be read keeps it.
    ///
    /// Each file keeps its attribution: one sealed with a device's key is
    /// re-tagged under that device's current key, and one of a device no
    /// longer listed verifies under no key here and is skipped (security
    /// review 2026-10, C3). Unattributed files under the outgoing secret are
    /// re-tagged only by the run that rotated it (`legacyPrevious`), never
    /// by a resumed one: a removed device holds that secret's vault capture
    /// key and could have sealed them since.
    func rewrapInbox(recipients: [NativeRecipient], report: inout RewrapReport, stopAfter: Int?,
                     legacyPrevious: Bool = false) throws {
        let dir = inboxURL
        guard FileIO.isDirectory(dir) else { return }
        let ring = try captureKeyRing(legacyPrevious: legacyPrevious)
        let expected = Self.expectedStanzas(recipients)
        for name in try FileIO.entries(dir) where CaptureFile.parse(name: name) != nil {
            let path = "\(CaptureFile.folderName)/\(name)"
            let file = dir.appendingPathComponent(name)
            guard !FileIO.isDirectory(file), let kind = CaptureFile.parse(name: name)?.kind else { continue }
            // The tag is checked streamed first: a file that verifies under
            // neither key is skipped without being read whole (C5).
            let entry: CaptureKeyEntry
            do { entry = try verifyInboxFile(file, name: name, kind: kind, ring: ring) } catch is CaptureError {
                report.inboxSkipped.append(path); continue
            } catch {
                report.failures[path] = .unreadable("\(error)"); continue
            }
            let data: Data
            do { data = try FileIO.read(file, maxBytes: CaptureFile.maxSealedBytes(kind)) } catch {
                report.failures[path] = .unreadable("\(error)"); continue
            }
            let stanzas: [String: Int]
            let plain: Data
            do {
                stanzas = try Self.stanzaCounts(data)
                plain = try AgeFile.decrypt(data, with: identities)
            } catch {
                report.inboxSkipped.append(path); continue
            }
            if stanzas == expected, !entry.previous {
                report.alreadyCurrent.append(path); continue
            }
            guard let target = ring.first(where: { !$0.previous && $0.recipient == entry.recipient }),
                  let retagged = CaptureFile.retag(plain, filename: name, verifiedBy: entry.key, to: target.key) else {
                report.inboxSkipped.append(path); continue
            }
            if let stopAfter, report.rewrapped.count >= stopAfter { throw VaultError.interrupted }
            try FileIO.writeAtomically(try Self.encrypt(retagged, to: recipients), to: file, replacing: true)
            report.rewrapped.append(path)
        }
    }
}
