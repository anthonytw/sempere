import Age
import Foundation
import Security
import Sempere
import SempereCapture

// What the watch keeps in its Keychain (docs/design/1.1-watch.md §3.3): its provisioning key pair (an `age1pq1…` identity,
// made on first launch, used only to open the profile the phone sends) and the provisioned profile with its counter
// (`WatchProfileState`). Readable after the first unlock, on this watch only (`AfterFirstUnlockThisDeviceOnly`: a voice
// note starts from a surface while the watch is locked). It holds no vault identity, no `K_e`, no device key.

enum WatchSecretItem: String, Sendable {
    case provisioningKey = "provisioning-identity"
    case profileState = "profile-state"
}

protocol WatchSecretStore: Sendable {
    func load(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
    /// The accounts that start with `prefix`.
    func accounts(prefix: String) throws -> [String]
}

extension WatchSecretStore {
    func load(_ item: WatchSecretItem) throws -> Data? { try load(account: item.rawValue) }
    func save(_ data: Data, as item: WatchSecretItem) throws { try save(data, account: item.rawValue) }
    func delete(_ item: WatchSecretItem) throws { try delete(account: item.rawValue) }
}

struct KeychainWatchSecretStore: WatchSecretStore {
    static let service = "io.github.anthonytw.sempere.watch"

    enum Failure: Error, Equatable { case status(OSStatus) }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func load(account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure.status(status) }
        return data
    }

    func save(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    func accounts(prefix: String) throws -> [String] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        q = [:]
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { throw Failure.status(status) }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }
}

/// In memory (tests, and the debug launch that must not touch the Keychain).
final class MemoryWatchSecretStore: WatchSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// Tests: the profile state cannot be read (the Keychain before the first unlock).
    var failProfileStateLoads = false
    struct Locked: Error {}
    func load(account: String) throws -> Data? {
        try lock.withLock {
            if failProfileStateLoads, account == WatchSecretItem.profileState.rawValue { throw Locked() }
            return items[account]
        }
    }
    /// Tests: the profile state cannot be written.
    var failProfileStateSaves = false
    func save(_ data: Data, account: String) throws {
        try lock.withLock {
            if failProfileStateSaves, account == WatchSecretItem.profileState.rawValue { throw Locked() }
            items[account] = data
        }
    }
    func delete(account: String) throws { lock.withLock { items[account] = nil } }
    func accounts(prefix: String) throws -> [String] { lock.withLock { items.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
}

/// The profile each recording in progress started with (`RecordingProfileKeeper`), one Keychain item per recording id,
/// deleted after the seal (docs/design/1.1-watch.md §3.5).
struct KeychainRecordingProfileKeeper: RecordingProfileKeeper {
    static let prefix = "recording-profile-"
    let store: any WatchSecretStore

    private func account(_ id: UUID) -> String { Self.prefix + id.uuidString.lowercased() }

    func keep(_ payload: WatchProfilePayload, for recording: UUID) throws {
        try store.save(try JSONEncoder.watch.encode(payload), account: account(recording))
    }

    func load(for recording: UUID) -> WatchProfilePayload? {
        guard let data = try? store.load(account: account(recording)) else { return nil }
        return try? JSONDecoder.watch.decode(WatchProfilePayload.self, from: data)
    }

    func discard(_ recording: UUID) { try? store.delete(account: account(recording)) }

    func recordings() -> [UUID] {
        ((try? store.accounts(prefix: Self.prefix)) ?? []).compactMap { UUID(uuidString: String($0.dropFirst(Self.prefix.count))) }
    }

    func discardAll() {
        for a in (try? store.accounts(prefix: Self.prefix)) ?? [] { try? store.delete(account: a) }
    }
}

/// The watch's provisioning identity and profile state over a `WatchSecretStore`.
struct WatchSecrets: Sendable {
    let store: any WatchSecretStore

    /// The provisioning identity: the one stored, or a new post-quantum one, stored. A stored one that does not parse is
    /// replaced (the phone is asked again, and gives the profile to the new key).
    func identity() throws -> NativeIdentity {
        if let data = try store.load(.provisioningKey), let text = String(data: data, encoding: .utf8),
           let identity = try? NativeIdentity(string: text), identity.isPostQuantum {
            return identity
        }
        let identity = try NativeIdentity.generate(.postQuantum)
        try store.save(Data(identity.string.utf8), as: .provisioningKey)
        return identity
    }

    /// The stored state; `WatchProfileState()` (no profile, counter -1) when there is none. Throws when it exists and cannot
    /// be read or does not decode (the Keychain before the first unlock): "unreadable" is not "absent".
    func loadState() throws -> WatchProfileState {
        guard let data = try store.load(.profileState) else { return WatchProfileState() }
        return try JSONDecoder.watch.decode(WatchProfileState.self, from: data)
    }

    /// `loadState()`, or the empty state when it cannot be read.
    func state() -> WatchProfileState { (try? loadState()) ?? WatchProfileState() }

    func save(_ state: WatchProfileState) throws {
        try store.save(try JSONEncoder.watch.encode(state), as: .profileState)
    }
}

extension JSONEncoder {
    static var watch: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var watch: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
