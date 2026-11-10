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
    func load(_ item: WatchSecretItem) throws -> Data?
    func save(_ data: Data, as item: WatchSecretItem) throws
    func delete(_ item: WatchSecretItem) throws
}

struct KeychainWatchSecretStore: WatchSecretStore {
    static let service = "io.github.anthonytw.sempere.watch"

    enum Failure: Error, Equatable { case status(OSStatus) }

    private func query(_ item: WatchSecretItem) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: item.rawValue]
    }

    func load(_ item: WatchSecretItem) throws -> Data? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure.status(status) }
        return data
    }

    func save(_ data: Data, as item: WatchSecretItem) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(item) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(item)
            add.merge(attributes) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    func delete(_ item: WatchSecretItem) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}

/// In memory (tests, and the debug launch that must not touch the Keychain).
final class MemoryWatchSecretStore: WatchSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WatchSecretItem: Data] = [:]
    func load(_ item: WatchSecretItem) throws -> Data? { lock.withLock { items[item] } }
    func save(_ data: Data, as item: WatchSecretItem) throws { lock.withLock { items[item] = data } }
    func delete(_ item: WatchSecretItem) throws { lock.withLock { items[item] = nil } }
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

    /// The stored state; `WatchProfileState()` (no profile, counter -1) when there is none or it does not decode.
    func state() -> WatchProfileState {
        guard let data = try? store.load(.profileState), let state = try? JSONDecoder.watch.decode(WatchProfileState.self, from: data) else {
            return WatchProfileState()
        }
        return state
    }

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
