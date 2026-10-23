import Age
import Crypto
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// The write ledger (docs/design/key-hierarchy.md §5.4, format.md §15.14; phase KH3): device-local, per
// vault, never in the vault. One entry per file this device writes (path, SHA-256 of the exact bytes,
// epoch), appended durably BEFORE the file is placed (intent first), and kept until a record seals it
// for good (`LedgerRule.sealIsFinal`) or the file is re-encrypted under a later epoch. A still-listed
// device that missed a key change re-encrypts exactly the files of its ledger the change did not seal
// (`Vault.catchUp`). The ledger also keeps the key of every epoch this device wrote under, so it can
// re-encrypt its own files of an epoch a takeover dropped.

/// One file this device wrote (design §5.4).
public struct LedgerEntry: Hashable, Sendable, Codable {
    /// The file's path in the vault (`notes/<id>/<name>`, `notes/<id>/att/<name>`, `notebooks/<name>`,
    /// `inbox/<name>`, `settings.age`).
    public var path: String
    /// Lowercase hex SHA-256 of the file's exact bytes.
    public var sha256: String
    /// The epoch it was written under.
    public var epoch: Int
    /// That epoch's id, lowercase hex.
    public var epochId: String
    /// When it was recorded (RFC 3339).
    public var time: String

    public init(path: String, sha256: String, epoch: Int, epochId: Data, time: Date = Date()) {
        self.path = path; self.sha256 = sha256; self.epoch = epoch; self.epochId = Hex.encode(epochId)
        self.time = RFC3339.string(time)
    }

    /// As the precedence rule's ledger functions take it.
    public var fileRef: LedgerRule.FileRef? {
        guard let digest = Hex.decode(sha256), let id = Hex.decode(epochId) else { return nil }
        return LedgerRule.FileRef(path: path, sha256: digest, epochId: id)
    }
}

/// Where a device keeps its write ledger for one vault (design §5.4). Every method fails closed: an
/// unreadable ledger throws, never reads as empty.
public protocol WriteLedgerStore: Sendable {
    /// Appends `entries` durably (intent first: the caller places the files only after this returns).
    func append(_ entries: [LedgerEntry]) throws
    /// Removes `entries` (pruned once sealed for good, re-encrypted under a later epoch, or with no file).
    func remove(_ entries: [LedgerEntry]) throws
    /// Every live entry, in the order appended.
    func entries() throws -> [LedgerEntry]
    /// Remembers the key of an epoch this device writes under (once per epoch).
    func rememberKey(epoch: Int, key: VaultEpochKey) throws
    /// The keys remembered.
    func epochKeys() throws -> [(epoch: Int, key: VaultEpochKey)]
    /// The epoch (id) this device last caught up to (`Vault.catchUp`); nil before any.
    func caughtUp() throws -> Data?
    /// Records that this device caught up to `epochId`.
    func setCaughtUp(_ epochId: Data) throws
}

/// A ledger in memory (tests).
public final class MemoryWriteLedger: WriteLedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [LedgerEntry] = []
    private var keys: [Data: (Int, VaultEpochKey)] = [:]
    private var caught: Data?
    private var unreadable: String?
    /// Test hook: the next append fails (a full disk).
    public var failNextAppend = false

    public init() {}

    public func append(_ entries: [LedgerEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        if let unreadable { throw VaultError.ledgerUnreadable(unreadable) }
        if failNextAppend { failNextAppend = false; throw VaultError.io("ledger: no space left (test)") }
        list += entries
    }

    public func remove(_ entries: [LedgerEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        if let unreadable { throw VaultError.ledgerUnreadable(unreadable) }
        let gone = Set(entries)
        list.removeAll { gone.contains($0) }
    }

    public func entries() throws -> [LedgerEntry] {
        lock.lock(); defer { lock.unlock() }
        if let unreadable { throw VaultError.ledgerUnreadable(unreadable) }
        return list
    }

    public func rememberKey(epoch: Int, key: VaultEpochKey) throws {
        lock.lock(); defer { lock.unlock() }
        if let unreadable { throw VaultError.ledgerUnreadable(unreadable) }
        keys[key.epochId] = (epoch, key)
    }

    public func epochKeys() throws -> [(epoch: Int, key: VaultEpochKey)] {
        lock.lock(); defer { lock.unlock() }
        if let unreadable { throw VaultError.ledgerUnreadable(unreadable) }
        return keys.values.map { (epoch: $0.0, key: $0.1) }.sorted { $0.epoch < $1.epoch }
    }

    public func caughtUp() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let unreadable { throw VaultError.ledgerUnreadable(unreadable) }
        return caught
    }

    public func setCaughtUp(_ epochId: Data) throws {
        lock.lock(); defer { lock.unlock() }
        caught = epochId
    }

    /// Makes the ledger unreadable (`why`) until `repair`.
    public func markUnreadable(_ why: String) {
        lock.lock(); defer { lock.unlock() }
        unreadable = why
    }

    /// Undoes `markUnreadable`.
    public func repair() {
        lock.lock(); defer { lock.unlock() }
        unreadable = nil
    }
}

/// A ledger in files (design §5.4; format.md §15.14): `<directory>/<vaultId>/` (mode 0700) holds
///
/// - `key.age`: 32 random bytes, age-encrypted to the device's key (the CLI) — the app keeps the key in a
///   this-device-only Keychain item instead (KH5) and passes it to `init(directory:vaultId:key:)`;
/// - `log`: the entries, append-only: each record is a 4-byte big-endian length and a ChaCha20-Poly1305
///   box (nonce ‖ ciphertext ‖ tag) of one JSON object, authenticated with the vault id; a record cut off
///   by a crash at the end is ignored (its append did not return, so its file was never placed), any other
///   damage fails closed;
/// - `state`: one such box: the epoch keys this device wrote under and the epoch it last caught up to.
///
/// Appends and rewrites are serialized by a `VaultFileLock` on `<directory>/<vaultId>/lock`.
public final class FileWriteLedger: WriteLedgerStore, @unchecked Sendable {
    public let folder: URL
    let vaultId: UUID
    private let directory: URL
    private enum KeySource {
        case fixed(SymmetricKey), device(MLKEM768X25519Identity)
        case provided(@Sendable () throws -> Data)
    }
    private let source: KeySource
    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?
    private let lock: VaultFileLock

    /// The largest log read (the ledger lives until kit replacements make seals final).
    static let maxLogBytes = 1 << 30
    static let maxRecordBytes = 1 << 20

    /// `$XDG_STATE_HOME/sempere/ledger` (the CLI's).
    public static func cliDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        DeviceState.defaultURL(environment: environment, home: home).deletingLastPathComponent()
            .appendingPathComponent("ledger", isDirectory: true)
    }

    /// The ledger of `vaultId` under `directory`, keyed by `key` (the app's, from a Keychain item).
    public convenience init(directory: URL, vaultId: UUID, key: SymmetricKey) {
        self.init(directory: directory, vaultId: vaultId, source: .fixed(key))
    }

    /// The ledger of `vaultId` under `directory`, keyed by the 32 bytes `key` returns when the ledger is first
    /// used (the app's: a Keychain item of class `AfterFirstUnlockThisDeviceOnly`, design §5.4). A key that
    /// cannot be read, or is not 32 bytes, makes the ledger unreadable: it fails closed.
    public convenience init(directory: URL, vaultId: UUID, keyBytes key: @escaping @Sendable () throws -> Data) {
        self.init(directory: directory, vaultId: vaultId, source: .provided(key))
    }

    /// The ledger of `vaultId`, keyed by a key sealed to `device` in `key.age` (made with the first record).
    /// Nothing is created on disk until something is recorded.
    public convenience init(directory: URL, vaultId: UUID, device: MLKEM768X25519Identity) {
        self.init(directory: directory, vaultId: vaultId, source: .device(device))
    }

    private init(directory: URL, vaultId: UUID, source: KeySource) {
        self.directory = directory
        folder = directory.appendingPathComponent(vaultId.uuidString.lowercased(), isDirectory: true)
        self.vaultId = vaultId
        self.source = source
        lock = VaultFileLock.at(folder.appendingPathComponent("lock"))
    }

    /// The ledger's key; with `creating`, its folder and (for a device-sealed key) `key.age` are made when
    /// missing. Nil when there is none yet and `creating` is false.
    private func key(creating: Bool) throws -> SymmetricKey? {
        keyLock.lock(); defer { keyLock.unlock() }
        if let cachedKey { return cachedKey }
        if creating {
            try FileIO.createPrivateDirectory(directory)
            try FileIO.createPrivateDirectory(folder)
        }
        switch source {
        case .fixed(let k):
            cachedKey = k
        case .provided(let provide):
            let raw: Data
            do { raw = try provide() } catch { throw VaultError.ledgerUnreadable("the ledger key is not available: \(error)") }
            guard raw.count == 32 else { throw VaultError.ledgerUnreadable("the ledger key is not 32 bytes") }
            cachedKey = SymmetricKey(data: raw)
        case .device(let device):
            let keyURL = folder.appendingPathComponent("key.age")
            if !FileIO.exists(keyURL) {
                guard creating else { return nil }
                let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let sealed = try AgeFile.encrypt(raw, to: [NativeRecipient.mlkem768x25519(device.recipient)])
                do { try FileIO.writeAtomically(sealed, to: keyURL, replacing: false) } catch VaultError.alreadyExists {}
            }
            let raw: Data
            do {
                raw = try AgeFile.decrypt(try BoundedRead.contents(of: keyURL, maxBytes: 16 * 1024),
                                          with: [NativeIdentity.mlkem768x25519(device)])
            } catch {
                throw VaultError.ledgerUnreadable("the ledger key \(keyURL.path) does not open with this device's key: \(error)")
            }
            guard raw.count == 32 else { throw VaultError.ledgerUnreadable("the ledger key is not 32 bytes") }
            cachedKey = SymmetricKey(data: raw)
        }
        return cachedKey
    }

    private var logURL: URL { folder.appendingPathComponent("log") }
    private var stateURL: URL { folder.appendingPathComponent("state") }

    private var associated: Data { Data("sempere/1 write ledger \(vaultId.uuidString.lowercased())".utf8) }

    private func box(_ plain: Data) throws -> Data {
        guard let key = try key(creating: true) else { throw VaultError.ledgerUnreadable("no ledger key") }
        return try ChaChaPoly.seal(plain, using: key, authenticating: associated).combined
    }

    private func open(_ sealed: Data) throws -> Data {
        guard let key = try key(creating: false) else { throw VaultError.ledgerUnreadable("the ledger key is missing") }
        do { return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: sealed), using: key, authenticating: associated) } catch {
            throw VaultError.ledgerUnreadable("a ledger record does not authenticate")
        }
    }

    private struct Record: Codable {
        var op: String
        var entry: LedgerEntry
    }

    private func frame(_ records: [Record]) throws -> Data {
        var out = Data()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for r in records {
            let b = try box(try enc.encode(r))
            let n = UInt32(b.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            out.append(b)
        }
        return out
    }

    private func readLog() throws -> [LedgerEntry] {
        guard FileIO.exists(logURL) else { return [] }
        let data: Data
        do { data = try BoundedRead.contents(of: logURL, maxBytes: Self.maxLogBytes) } catch {
            throw VaultError.ledgerUnreadable("\(error)")
        }
        var live: [LedgerEntry] = []
        var i = data.startIndex
        let dec = JSONDecoder()
        while i < data.endIndex {
            guard data.endIndex - i >= 4 else { break }   // a cut length: an append that never returned
            let n = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard n > 0, n <= Self.maxRecordBytes else { throw VaultError.ledgerUnreadable("a ledger record has a bad length") }
            guard data.endIndex - (i + 4) >= n else { break }   // a cut record: the same
            let plain = try open(Data(data[(i + 4)..<(i + 4 + n)]))
            guard let r = try? dec.decode(Record.self, from: plain) else {
                throw VaultError.ledgerUnreadable("a ledger record does not decode")
            }
            switch r.op {
            case "add": live.append(r.entry)
            case "remove": if let k = live.firstIndex(of: r.entry) { live.remove(at: k) }
            default: throw VaultError.ledgerUnreadable("a ledger record has an unknown op")
            }
            i += 4 + n
        }
        return live
    }

    private func appendRecords(_ records: [Record]) throws {
        guard !records.isEmpty else { return }
        let bytes = try frame(records)   // makes the key (and the folder) on first use
        try lock.withLock {
            let fd = logURL.withUnsafeFileSystemRepresentation { p -> Int32 in
                p.map { posixOpen($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600) } ?? -1
            }
            guard fd >= 0 else { throw VaultError.io("ledger: open \(logURL.path): \(FileIO.errnoText(errno))") }
            defer { close(fd) }
            try bytes.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    guard let base = buf.baseAddress else { break }
                    let n = write(fd, base + off, buf.count - off)
                    guard n > 0 else { throw VaultError.io("ledger: write: \(FileIO.errnoText(errno))") }
                    off += n
                }
            }
            guard fsync(fd) == 0 else { throw VaultError.io("ledger: fsync: \(FileIO.errnoText(errno))") }
        }
    }

    public func append(_ entries: [LedgerEntry]) throws {
        try appendRecords(entries.map { Record(op: "add", entry: $0) })
    }

    public func remove(_ entries: [LedgerEntry]) throws {
        guard !entries.isEmpty else { return }
        try lock.withLock {
            // Rewritten whole: removals are rare (catch-up, pruning) and keep the log short.
            var live = try readLog()
            for e in entries { if let k = live.firstIndex(of: e) { live.remove(at: k) } }
            try FileIO.writePrivate(try frame(live.map { Record(op: "add", entry: $0) }), to: logURL)
        }
    }

    public func entries() throws -> [LedgerEntry] { try readLog() }

    private struct State: Codable {
        struct Key: Codable { var epoch: Int; var key: String }
        var keys: [Key] = []
        var caughtUp: String?
    }

    private func readState() throws -> State {
        guard FileIO.exists(stateURL) else { return State() }
        let data: Data
        do { data = try BoundedRead.contents(of: stateURL, maxBytes: Self.maxRecordBytes) } catch {
            throw VaultError.ledgerUnreadable("\(error)")
        }
        guard let s = try? JSONDecoder().decode(State.self, from: try open(data)) else {
            throw VaultError.ledgerUnreadable("the ledger state does not decode")
        }
        return s
    }

    private func updateState(_ change: (inout State) -> Void) throws {
        try lock.withLock {
            var s = try readState()
            change(&s)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try FileIO.writePrivate(try box(try enc.encode(s)), to: stateURL)
        }
    }

    public func rememberKey(epoch: Int, key: VaultEpochKey) throws {
        let hex = Hex.encode(key.bytes)
        if try readState().keys.contains(where: { $0.key == hex }) { return }
        try updateState { $0.keys.append(.init(epoch: epoch, key: hex)) }
    }

    public func epochKeys() throws -> [(epoch: Int, key: VaultEpochKey)] {
        try readState().keys.compactMap { k in Hex.decode(k.key).flatMap { try? VaultEpochKey(bytes: $0) }.map { (k.epoch, $0) } }
    }

    public func caughtUp() throws -> Data? { try readState().caughtUp.flatMap { Hex.decode($0) } }

    public func setCaughtUp(_ epochId: Data) throws { try updateState { $0.caughtUp = Hex.encode(epochId) } }
}

/// `open(2)`, named apart from `FileWriteLedger.open(_:)`.
private func posixOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    open(path, flags, mode)
}

extension Vault {
    /// Records, before a file is placed, that this device wrote `bytes` at `path` under the current epoch
    /// (design §5.4, intent first). Without a ledger it records nothing. A ledger that cannot record stops
    /// the write: a file no ledger knows could not be caught up.
    func recordWrite(path: String, sha256: String) throws {
        guard let ledger, let secret else { return }
        if ledgerMemo.needsKey(secret.epochId) {
            try ledger.rememberKey(epoch: manifest.epoch, key: secret)
            ledgerMemo.keyRemembered(secret.epochId)
        }
        try ledger.append([LedgerEntry(path: path, sha256: sha256, epoch: manifest.epoch, epochId: secret.epochId)])
        try faults.check(.afterLedgerIntent)
    }

    func recordWrite(path: String, bytes: Data) throws {
        try recordWrite(path: path, sha256: FileDigest.sha256(bytes))
    }
}

/// Which epoch keys a vault value already gave its ledger (shared by copies).
final class LedgerMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var remembered: Set<Data> = []
    func needsKey(_ id: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return !remembered.contains(id) }
    func keyRemembered(_ id: Data) { lock.lock(); remembered.insert(id); lock.unlock() }
}
