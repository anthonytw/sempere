import Age
import Foundation
import Sempere

// Provisioning an Apple Watch with the iPhone's capture profile over WatchConnectivity (docs/design/1.1-watch.md §3.4,
// D3). The watch has a provisioning key pair of its own (`age1pq1…`); the phone age-encrypts the profile to the watch's
// recipient, so the capture key never sits in WatchConnectivity's persisted context (which is outside the Keychain) as
// plaintext. The watch holds the profile and nothing else: no identity, no vault key, no device key.

/// Why a provisioning payload is not accepted.
public enum WatchPayloadError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not encrypted to this watch, or damaged.
    case cannotOpen(String)
    /// Decrypted but not a payload this version reads.
    case malformed(String)
    case unsupportedVersion(Int)
    /// The profile inside does not validate (`CaptureWriter(profile:)` would refuse it).
    case invalidProfile(String)
    case tooLarge

    public var description: String {
        switch self {
        case .cannotOpen(let why): return "the provisioning payload cannot be opened: \(why)"
        case .malformed(let why): return "malformed provisioning payload: \(why)"
        case .unsupportedVersion(let v): return "provisioning payload version \(v) is not supported"
        case .invalidProfile(let why): return "the provisioned capture profile is not valid: \(why)"
        case .tooLarge: return "the provisioning payload is too large"
        }
    }
}

/// What the phone sends the watch: the profile quick voice notes seal with, the vault's name for the watch's screen, and a
/// sequence number (the newest payload wins). The wire format has a `profiles` array from day one, so a watch that follows
/// several vaults is not a break; 1.1 sends, and accepts, exactly one.
public struct WatchProfilePayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// The most a payload (decrypted) or its ciphertext may be.
    public static let maxBytes = 1 << 20

    public struct Entry: Codable, Equatable, Sendable {
        public var profile: CaptureProfile
        /// The vault's name, shown on the watch ("Saving to <name>").
        public var vaultName: String

        public init(profile: CaptureProfile, vaultName: String) {
            self.profile = profile
            self.vaultName = vaultName
        }
    }

    public var version: Int
    /// The phone's counter: a payload or a clear is only taken when it is newer than what the watch has seen.
    public var seq: Int
    public var issued: Date
    public var profiles: [Entry]

    public init(profile: CaptureProfile, vaultName: String, seq: Int, issued: Date) {
        self.version = Self.currentVersion
        self.seq = seq
        self.issued = issued
        self.profiles = [Entry(profile: profile, vaultName: vaultName)]
    }

    /// The profile the watch seals with.
    public var profile: CaptureProfile { profiles[0].profile }
    public var vaultName: String { profiles[0].vaultName }

    /// The longest vault name kept (it is shown on a watch face).
    static let maxNameLength = 200

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The payload age-encrypted to the watch's provisioning recipient.
    public func sealed(to recipient: NativeRecipient) throws -> Data {
        try validate()
        // Post-quantum only, like every key here (format.md §3.1).
        guard recipient.isPostQuantum else { throw WatchPayloadError.invalidProfile("the watch's key is not post-quantum") }
        return try AgeFile.encrypt(try Self.encoder().encode(self), to: [recipient])
    }

    /// Opens `ciphertext` with the watch's provisioning identity and validates what is inside.
    public static func open(_ ciphertext: Data, with identity: NativeIdentity) throws -> WatchProfilePayload {
        guard ciphertext.count <= maxBytes else { throw WatchPayloadError.tooLarge }
        let plain: Data
        do { plain = try AgeFile.decrypt(ciphertext, with: [identity]) } catch { throw WatchPayloadError.cannotOpen("\(error)") }
        guard plain.count <= maxBytes else { throw WatchPayloadError.tooLarge }
        let payload: WatchProfilePayload
        do { payload = try decoder().decode(WatchProfilePayload.self, from: plain) } catch {
            throw WatchPayloadError.malformed("\(error)")
        }
        try payload.validate()
        return payload
    }

    /// The checks of the design (§3.4 step 4): a known version, exactly one profile that `CaptureWriter` accepts (the
    /// vault id is a UUID by type; the epoch id is 32 bytes of hex; the key is 32 bytes; the recipients parse), a device id
    /// of 8 hex digits and a sane counter.
    public func validate() throws {
        guard version == Self.currentVersion else { throw WatchPayloadError.unsupportedVersion(version) }
        guard (0...Int(Int32.max)).contains(seq) else { throw WatchPayloadError.malformed("seq out of range") }
        guard profiles.count == 1 else { throw WatchPayloadError.malformed("\(profiles.count) profiles (exactly one is read)") }
        guard vaultName.count <= Self.maxNameLength else { throw WatchPayloadError.malformed("the vault name is too long") }
        guard DeviceID(profile.device) != nil else { throw WatchPayloadError.invalidProfile("bad device id") }
        guard profile.epoch >= 0 else { throw WatchPayloadError.invalidProfile("bad epoch") }
        do { _ = try CaptureWriter(profile: profile) } catch {
            throw WatchPayloadError.invalidProfile("\(error)")
        }
    }
}

/// What the watch keeps of provisioning: the newest counter it has seen (a clear included, so an older payload that
/// WatchConnectivity redelivers cannot bring a cleared profile back) and the profile, if any.
public struct WatchProfileState: Codable, Equatable, Sendable {
    public var seq: Int
    public var payload: WatchProfilePayload?

    public init(seq: Int = -1, payload: WatchProfilePayload? = nil) {
        self.seq = seq
        self.payload = payload
    }
}

/// The messages of provisioning, as WatchConnectivity's property-list dictionaries carry them.
public enum WatchProvisioning {
    /// Watch to phone: "here is my recipient, provision me" (`transferUserInfo`).
    /// Phone to watch: the profile, encrypted (`updateApplicationContext`), or a clear (carries nothing secret).
    public enum Message: Equatable, Sendable {
        case request(recipient: String, version: Int)
        case profile(Data)
        case clear(seq: Int)
    }

    /// What applying a message did.
    public enum Outcome: Equatable, Sendable {
        case stored(WatchProfilePayload)
        case cleared
        /// Older than, or the same as, what the watch has seen; or a clear with nothing to clear.
        case ignored
        /// A request is the phone's to answer, not the watch's.
        case notForTheWatch
    }

    static let requestKey = "provisionRequest"
    static let versionKey = "version"
    static let profileKey = "profile"
    static let clearKey = "clear"

    public static func request(recipient: NativeRecipient) -> Message {
        .request(recipient: recipient.string, version: WatchProfilePayload.currentVersion)
    }

    /// The message that gives `profile` to the watch whose provisioning key is `recipient`.
    public static func provision(profile: CaptureProfile, vaultName: String, seq: Int, issued: Date,
                                 to recipient: NativeRecipient) throws -> Message {
        .profile(try WatchProfilePayload(profile: profile, vaultName: vaultName, seq: seq, issued: issued).sealed(to: recipient))
    }

    public static func dictionary(_ message: Message) -> [String: Any] {
        switch message {
        case .request(let recipient, let version): return [requestKey: recipient, versionKey: version]
        case .profile(let data): return [profileKey: data]
        case .clear(let seq): return [clearKey: seq]
        }
    }

    /// The message a dictionary holds; nil for any other (WatchConnectivity carries other messages on the same channel).
    public static func message(_ dictionary: [String: Any]) -> Message? {
        if let recipient = dictionary[requestKey] as? String, recipient.count <= 4096 {
            return .request(recipient: recipient, version: dictionary[versionKey] as? Int ?? 0)
        }
        if let data = dictionary[profileKey] as? Data { return .profile(data) }
        if let seq = dictionary[clearKey] as? Int { return .clear(seq: seq) }
        return nil
    }

    /// The watch's side: applies `message` to `state` with the watch's provisioning `identity`.
    public static func apply(_ message: Message, identity: NativeIdentity, to state: inout WatchProfileState) throws -> Outcome {
        switch message {
        case .request:
            return .notForTheWatch
        case .profile(let ciphertext):
            let payload = try WatchProfilePayload.open(ciphertext, with: identity)
            guard payload.seq > state.seq else { return .ignored }
            state = WatchProfileState(seq: payload.seq, payload: payload)
            return .stored(payload)
        case .clear(let seq):
            guard (0...Int(Int32.max)).contains(seq) else { throw WatchPayloadError.malformed("seq out of range") }
            guard seq > state.seq || (seq == state.seq && state.payload != nil) else { return .ignored }
            let had = state.payload != nil
            state = WatchProfileState(seq: seq, payload: nil)
            return had ? .cleared : .ignored
        }
    }
}
