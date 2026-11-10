import Age
import Foundation
import Sempere

// "Use on Apple Watch" (Settings ▸ Quick Voice Notes; docs/design/1.1-watch.md §3.4): the model half. It decides what the
// phone sends the watch (the capture profile age-encrypted to the watch's provisioning key, or a clear) from the toggle, the
// stored profile and what the watch already holds, and keeps the monotonic counter every message carries. The wire messages
// and the watch's side are `WatchProvisioning` (SempereCapture). The app's WatchConnectivity delegate sends what this
// returns and words the status; nothing here knows WatchConnectivity.

/// What `WatchProvisioner` keeps between runs (`Application Support/Sempere/WatchLink.json`). No secret: the watch's PUBLIC
/// recipient, a hash, a counter and a date.
public struct WatchLinkState: Codable, Equatable, Sendable {
    /// The "Use on Apple Watch" toggle. Off by default.
    public var enabled = false
    /// The watch's provisioning recipient (`age1pq1…`), from its last request.
    public var recipient: String?
    /// The last counter issued. Monotonic and persisted before a message is returned: never time-based (a time in seconds
    /// overflows a 32-bit `Int` in 2038, and a clock that goes back would make the watch ignore a payload). -1: none yet.
    public var seq = -1
    /// A hash of what the watch was last given (profile, vault name, recipient); nil when it holds nothing.
    public var sent: String?
    /// When the last note from the watch arrived ("Last note from Watch").
    public var lastNote: Date?

    public init(enabled: Bool = false, recipient: String? = nil, seq: Int = -1, sent: String? = nil, lastNote: Date? = nil) {
        self.enabled = enabled
        self.recipient = recipient
        self.seq = seq
        self.sent = sent
        self.lastNote = lastNote
    }
}

/// Where the state lives: a file in the app, memory in tests.
public protocol WatchLinkStore: Sendable {
    func load() -> WatchLinkState
    func save(_ state: WatchLinkState) throws
}

public final class MemoryWatchLinkStore: WatchLinkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: WatchLinkState
    /// Makes the next `save` fail (tests).
    public var failing = false
    public init(_ state: WatchLinkState = WatchLinkState()) { self.state = state }
    public func load() -> WatchLinkState { lock.withLock { state } }
    public func save(_ state: WatchLinkState) throws {
        try lock.withLock {
            if failing { throw WatchProvisionerError.cannotSave("failing store") }
            self.state = state
        }
    }
}

public struct FileWatchLinkStore: WatchLinkStore {
    static let maxBytes = 64 << 10
    public let url: URL
    public init(url: URL = AppSupport.sempere.appendingPathComponent("WatchLink.json")) { self.url = url }

    public func load() -> WatchLinkState {
        guard let data = try? BoundedRead.contents(of: url, maxBytes: Self.maxBytes),
              let state = try? JSONDecoder().decode(WatchLinkState.self, from: data) else { return WatchLinkState() }
        return state
    }

    public func save(_ state: WatchLinkState) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        do {
            try FileIO.createDirectory(url.deletingLastPathComponent())
            try FileIO.writePrivate(try e.encode(state), to: url)
        } catch { throw WatchProvisionerError.cannotSave("\(error)") }
    }
}

public enum WatchProvisionerError: Error, Equatable, Sendable {
    /// The request's recipient is not a post-quantum age key.
    case badRecipient
    case counterExhausted
    case cannotSave(String)
}

public final class WatchProvisioner: @unchecked Sendable {
    /// What Settings shows under the toggle.
    public enum Status: Equatable, Sendable {
        /// The toggle is off.
        case off
        /// On, but quick voice notes are not set up (no profile): nothing to give the watch.
        case needsQuickVoiceNotes
        /// On, but this device's profile is suspended (it was removed from the vault's list): the watch has none.
        case suspended
        /// On, with a profile, and the watch has not asked yet (its app is not open, or not installed).
        case waitingForWatch
        /// The watch holds the current profile, for `vaultName`.
        case provisioned(vaultName: String)
        /// On, with a profile and a watch, but the profile is not sent yet (a send failed).
        case notSent
    }

    private let store: any WatchLinkStore
    private let lock = NSLock()

    public init(store: any WatchLinkStore = FileWatchLinkStore()) { self.store = store }

    public var state: WatchLinkState { lock.withLock { store.load() } }
    public var enabled: Bool { state.enabled }
    public var lastNote: Date? { state.lastNote }

    // MARK: Settings

    public func setEnabled(_ on: Bool) throws {
        try update { $0.enabled = on }
    }

    /// The note that arrived last (`WatchReceiver` receipts).
    public func noteReceived(at date: Date) {
        try? update { $0.lastNote = max($0.lastNote ?? .distantPast, date) }
    }

    public func status(stored: StoredCaptureProfile?) -> Status {
        let s = state
        guard s.enabled else { return .off }
        guard let stored else { return .needsQuickVoiceNotes }
        if stored.suspended == true { return .suspended }
        guard s.recipient != nil else { return .waitingForWatch }
        return s.sent != nil ? .provisioned(vaultName: stored.vaultName) : .notSent
    }

    // MARK: The watch's request

    /// The watch asked (`transferUserInfo`): remember its recipient and give it the profile again, whether or not it holds
    /// it (a reset or a reinstalled watch app has none and a new key). A request that is not a post-quantum age recipient is
    /// refused. The request is not authenticated beyond WatchConnectivity's own pairing (docs/security.md).
    public func watchRequested(recipient: String) throws {
        guard recipient.count <= 4096, let r = try? NativeRecipient(string: recipient), r.isPostQuantum else {
            throw WatchProvisionerError.badRecipient
        }
        try update {
            $0.recipient = r.string
            $0.sent = nil
        }
    }

    // MARK: What to send

    /// The message the watch needs now, or nil when it already has the right thing: the profile when the toggle is on and a
    /// listed profile exists and the watch's key is known and the watch does not hold it yet, a clear when the watch holds a
    /// profile that should be gone (toggle off, quick voice notes off, a suspended profile). The counter is saved BEFORE the
    /// message is returned. If the send then fails, call `sendFailed()`.
    public func nextMessage(stored: StoredCaptureProfile?, issued: Date = Date()) throws -> WatchProvisioning.Message? {
        try lock.withLock {
            var s = store.load()
            if s.enabled, let stored, stored.suspended != true {
                guard let text = s.recipient, let recipient = try? NativeRecipient(string: text) else { return nil }
                let fingerprint = Self.fingerprint(stored, recipient: text)
                guard s.sent != fingerprint else { return nil }
                guard s.seq < Int(Int32.max) else { throw WatchProvisionerError.counterExhausted }
                let seq = s.seq + 1
                let message = try WatchProvisioning.provision(profile: stored.profile, vaultName: stored.vaultName, seq: seq,
                                                              issued: issued, to: recipient)
                s.seq = seq
                s.sent = fingerprint
                try store.save(s)
                return message
            }
            guard s.sent != nil else { return nil }
            guard s.seq < Int(Int32.max) else { throw WatchProvisionerError.counterExhausted }
            s.seq += 1
            s.sent = nil
            try store.save(s)
            return .clear(seq: s.seq)
        }
    }

    /// A message `nextMessage` returned could not be sent: the next call gives it again (with the next counter).
    public func sendFailed() {
        try? update { $0.sent = nil }
    }

    private func update(_ change: (inout WatchLinkState) -> Void) throws {
        try lock.withLock {
            var s = store.load()
            change(&s)
            try store.save(s)
        }
    }

    /// What the watch holds, as a hash: the profile (every field of it), the vault's name and the watch's recipient. A new
    /// epoch, notebook or vault, or a new watch key, changes it.
    static func fingerprint(_ stored: StoredCaptureProfile, recipient: String) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        let entry = (try? e.encode(WatchProfilePayload.Entry(profile: stored.profile, vaultName: stored.vaultName))) ?? Data()
        return FileDigest.sha256(entry + Data(recipient.utf8))
    }
}
