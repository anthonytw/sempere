import Age
import ArgumentParser
import Foundation
import Sempere
import SempereImport

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Errors and exit codes

/// Exit codes shared by the commands (docs/cli.md).
enum ExitStatus {
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let unhealthy: Int32 = 3
    static let cannotDecrypt: Int32 = 4
    // 5 is unused.
    static let untrustedList: Int32 = 6
    static let readOnly: Int32 = 7
    static let removed: Int32 = 8
}

/// A failure with its exit code. Messages are one line.
enum CLIError: Error {
    /// Exit 1: I/O, bad input, corrupt file, refusing to overwrite.
    case failure(String)
    /// Exit 2: the command line is wrong.
    case usage(String)
    /// Exit 3: unhealthy vault or backup.
    case unhealthy(String)
    /// Exit 4: wrong key or passphrase, or no key available.
    case cannotDecrypt(String)
    /// Exit 6: vault.json does not check on this machine (design §4.3):
    /// nothing is written to the vault.
    case untrustedList(String)
    /// Exit 7: the vault holds content of a newer format version, so this
    /// version may read it but not change it (format.md §7.3); or it was
    /// opened with the recovery key, which never writes.
    case readOnly(String)
    /// Exit 8: this machine's device is not on the vault's newest device list (key-hierarchy design §5.5).
    case removed(String)

    var message: String {
        switch self {
        case .failure(let m), .usage(let m), .unhealthy(let m), .cannotDecrypt(let m),
             .untrustedList(let m), .readOnly(let m), .removed(let m): return m
        }
    }

    var code: Int32 {
        switch self {
        case .failure: return ExitStatus.failure
        case .usage: return ExitStatus.usage
        case .unhealthy: return ExitStatus.unhealthy
        case .cannotDecrypt: return ExitStatus.cannotDecrypt
        case .untrustedList: return ExitStatus.untrustedList
        case .readOnly: return ExitStatus.readOnly
        case .removed: return ExitStatus.removed
        }
    }

    /// Maps a library error to a message and an exit code.
    static func from(_ error: Error) -> CLIError {
        if let e = error as? CLIError { return e }
        let text = "\(error)".split(whereSeparator: \.isNewline).joined(separator: " ")
        switch error {
        case AgeError.noMatchingIdentity, AgeError.noIdentities,
             VaultError.keyNotListed, VaultError.wrongPassphrase,
             VaultError.locked, VaultError.classicIdentity:
            return .cannotDecrypt(text)
        case VaultError.classicRecipient, VaultError.emptyPassphrase, VaultStoreError.invalidName:
            return .usage(text)
        case VaultError.untrustedList:
            return .untrustedList(text)
        case VaultError.readOnly, VaultError.recoveryKeyReadOnly:
            return .readOnly(text)
        case VaultError.removedFromVault:
            return .removed(text)
        case SharedSettingsError.needsNewerReader(let min):
            return .readOnly("the vault's settings need a newer sempere (settings reader \(min) or later; this is "
                + "\(SharedSettingsMigrations.current)): they are neither read nor written")
        case let e as NoteSummary.LookupError:
            switch e {
            case .notFound(let q): return .failure("no note matches '\(q)'")
            case .ambiguous(let q, let ids):
                return .failure("'\(q)' is ambiguous: \(ids.map { $0.uuidString.lowercased() }.joined(separator: ", "))")
            }
        case let e as LocalizedError where e.errorDescription != nil:
            return .failure((e.errorDescription ?? "").split(whereSeparator: \.isNewline).joined(separator: " "))
        default:
            return .failure(text)
        }
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("sempere: " + message + "\n").utf8))
}

func printStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Shared options

/// `--json`, `-q`, `-v`.
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON output.")
    var json = false

    @Flag(name: .shortAndLong, help: "Print only what was asked for (and errors).")
    var quiet = false

    @Flag(name: .shortAndLong, help: "Print extra detail.")
    var verbose = false

    /// Prints an informational line unless `-q`.
    func info(_ text: @autoclosure () -> String) {
        if !quiet && !json { print(text()) }
    }

    func emitJSON<T: Encodable>(_ value: T) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Format.utc(date))
        }
        print(String(decoding: try enc.encode(value), as: UTF8.self))
    }
}

/// `--vault`, `--identity`, `--recovery-key`, `--root`, `--passphrase-env`.
struct AccessOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The vault directory (*.sempere).", discussion: "Default: $SEMPERE_VAULT.",
                                            valueName: "path"))
    var vault: String?

    @Option(name: .long, help: ArgumentHelp("This device's key file (sempere device init), or any age identity file.",
                                            discussion: "Default: $SEMPERE_IDENTITY, else this machine's device key for "
                                                + "the vault ($XDG_STATE_HOME/sempere/devices/<vault id>/).",
                                            valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("recovery-key"),
            help: ArgumentHelp("Read the vault with its recovery key (the kit's identity file, or the vault's passphrase "
                               + "copy keys/recovery-*.key.age): read-only.", valueName: "file"))
    var recoveryKey: String?

    @Option(name: .long, help: ArgumentHelp("The vault's root fingerprint (64 hex digits, or the kit's 16 groups) to check "
                                            + "a --recovery-key read against.", valueName: "hex"))
    var root: String?

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Name of the environment variable holding the passphrase (a passphrase-wrapped device key, "
                               + "or the recovery key's passphrase copy).",
                               discussion: "Without it $SEMPERE_PASSPHRASE is used, else the terminal is asked.",
                               valueName: "var"))
    var passphraseEnv: String?
}

/// The per-device summary cache (`SummaryCache`, format.md §10) for listings.
struct CacheOptions: ParsableArguments {
    @Flag(name: .customLong("no-cache"),
          help: ArgumentHelp("Read every note instead of using (and updating) the summary cache.",
                             discussion: "The cache is encrypted and kept in $XDG_CACHE_HOME/sempere (default ~/.cache/sempere)."))
    var noCache = false

    /// The vault's cache, or nil with --no-cache. A cache that cannot be set
    /// up (no secret) is skipped; a damaged file is ignored and rewritten.
    func cache(for vault: Vault) -> SummaryCache? {
        noCache ? nil : try? SummaryCache(directory: SummaryCache.cliDirectory(), vault: vault)
    }
}

// MARK: - Formatting

enum Format {
    static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Local time with an explicit offset, for people.
    static func local(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// A byte count for people: `512 B`, `1.5 KB`, `2.0 MB` (powers of 1000).
    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(n) / 1000, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return "\(String(format: "%.1f", v)) \(units[i])"
    }

    /// Left-aligned columns separated by two spaces; the last column is not padded.
    static func table(_ rows: [[String]]) -> String { ImporterPresentation.table(rows) }
}

// MARK: - Files

/// Creates `path` with mode 0600, refusing to overwrite.
func writeNewSecretFile(_ text: String, to path: String) throws {
    try writeNewSecretFile(Data(text.utf8), to: path)
}

/// Creates `path` with mode 0600 holding `data`, refusing to overwrite. A
/// write that fails leaves nothing at `path` (`writeNewFileAtomically`).
func writeNewSecretFile(_ data: Data, to path: String) throws {
    try writeNewFileAtomically(URL(fileURLWithPath: path)) { write in try write(data) }
}

/// Creates `url` with the bytes `body` writes: a private temporary file next
/// to it, put in place only once `body` succeeded and never over an existing
/// file (`FileIO.placeNew`, which also works where there are no hard links).
func writeNewFileAtomically(_ url: URL, _ body: (_ write: (Data) throws -> Void) throws -> Void) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw CLIError.failure("refusing to overwrite \(url.path)") }
    let tmp = FileIO.tempURL(in: url.deletingLastPathComponent())
    do {
        try FileIO.writeNewFile(tmp, body)
        try FileIO.placeNew(tmp, at: url)
    } catch VaultError.alreadyExists {
        throw CLIError.failure("refusing to overwrite \(url.path)")
    }
}

/// Writes `data` to `url`, replacing it, readable by the owner only: a
/// temporary file in the same directory is created with mode 0600 (`O_EXCL`,
/// so the bytes never sit in a file anyone else can open), written, flushed
/// and renamed over `url`. An existing file at `url` is replaced, not
/// rewritten, so it ends at 0600 whatever its mode was; a symlink at `url`
/// is replaced itself, never followed. For plaintext the user asked for.
func writePrivateFile(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".sempere-tmp-" + UUID().uuidString.lowercased())
    let fd = tmp.withUnsafeFileSystemRepresentation { p -> Int32 in
        p.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) } ?? -1
    }
    guard fd >= 0 else {
        throw CLIError.failure("cannot create a file next to \(url.path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: tmp)
        throw CLIError.failure("cannot write \(url.path): \(error.localizedDescription)")
    }
    let rc = tmp.withUnsafeFileSystemRepresentation { src in
        url.withUnsafeFileSystemRepresentation { dst -> Int32 in
            guard let src, let dst else { return -1 }
            return rename(src, dst)
        }
    }
    guard rc == 0 else {
        let reason = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: tmp)
        throw CLIError.failure("cannot write \(url.path): \(reason)")
    }
}

func readIdentityFile(_ path: String) throws -> NativeIdentity {
    let text: String
    do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
        throw CLIError.failure("cannot read \(path): \(error.localizedDescription)")
    }
    do { return try IdentityFile.parse(text) } catch AgeError.postQuantumUnavailable {
        throw CLIError.failure("\(path): \(AgeError.postQuantumUnavailable)")
    } catch {
        throw CLIError.failure("\(path) holds no AGE-SECRET-KEY identity")
    }
}

/// An identity file given to `--identity`: a device key file (`DeviceKeys`, with its signing keys) or a
/// plain age identity file.
func readAccessKeyFile(_ path: String) throws -> (identity: NativeIdentity, signing: DeviceSigningKeys?) {
    let text: String
    do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
        throw CLIError.failure("cannot read \(path): \(error.localizedDescription)")
    }
    if DeviceKeys.isDeviceKeyFile(text) {
        do {
            let keys = try DeviceKeys.parse(text)
            return (keys.nativeIdentity, keys.signing)
        } catch {
            throw CLIError.failure("\(path) is not a valid device key file: \(error)")
        }
    }
    return (try readIdentityFile(path), nil)
}

/// Refuses a passphrase for the recovery key's passphrase copy that is easy to guess (design §8.2: about
/// 70 bits, no override): whoever can read the vault's storage can try passphrases offline.
func requireStoredKeyPassphrase(_ passphrase: String) throws {
    if let problem = PassphraseStrength.storedKeyProblem(passphrase) { throw CLIError.usage(problem) }
}

// MARK: - Passphrase and vault access

enum Env {
    static var vars: [String: String] { ProcessInfo.processInfo.environment }
}

/// Reads a line from the terminal with echo off; nil when stdin is not a terminal.
func promptSecret(_ prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1 else { return nil }
    var old = termios()
    guard tcgetattr(STDIN_FILENO, &old) == 0 else { return nil }
    var raw = old
    raw.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    defer {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &old)
        FileHandle.standardError.write(Data("\n".utf8))
    }
    FileHandle.standardError.write(Data(prompt.utf8))
    return readLine()
}

/// `--passphrase-env VAR`, else `$SEMPERE_PASSPHRASE`, else the terminal.
/// Failing to get one is exit 4 (no key available) unless `asError` says otherwise.
///
/// - Parameter confirm: a new passphrase (one that will wrap a key): the
///   terminal asks twice, and an empty one is refused (exit 2), as in the app.
func obtainPassphrase(envName: String?, prompt: String = "Vault passphrase: ", confirm: Bool = false,
                      asError: (String) -> CLIError = CLIError.cannotDecrypt) throws -> String {
    let pass = try readPassphrase(envName: envName, prompt: prompt, confirm: confirm, asError: asError)
    if confirm && pass.isEmpty { throw CLIError.usage("the passphrase is empty") }
    return pass
}

private func readPassphrase(envName: String?, prompt: String, confirm: Bool,
                            asError: (String) -> CLIError) throws -> String {
    if let envName {
        guard let v = Env.vars[envName] else { throw asError("environment variable \(envName) is not set") }
        return v
    }
    if let v = Env.vars["SEMPERE_PASSPHRASE"] { return v }
    guard let first = promptSecret(prompt) else {
        throw asError("no passphrase: set SEMPERE_PASSPHRASE or --passphrase-env VAR (stdin is not a terminal)")
    }
    if confirm {
        guard promptSecret("Repeat passphrase: ") == first else { throw asError("passphrases differ") }
    }
    return first
}

/// The element of `all` that `query` names: its whole id, or a unique
/// prefix of 4 or more characters, case-insensitive. Items, recordings and
/// strokes all resolve here, with the same messages. When no id matches,
/// `fallback` (if any) gives the matches by other means (a recording's title).
func resolveIDPrefix<T>(_ query: String, kind: String, among all: [T], place: String = "in this note",
                        id: (T) -> UUID, fallback: (() -> [T])? = nil) throws -> T {
    let q = query.lowercased()
    if let exact = all.first(where: { id($0).uuidString.lowercased() == q }) { return exact }
    var matches = q.count >= 4 ? all.filter { id($0).uuidString.lowercased().hasPrefix(q) } : []
    if matches.isEmpty, let fallback { matches = fallback() }
    guard let first = matches.first else {
        guard q.count >= 4 else { throw CLIError.failure("\(kind) \(query): give a whole id or at least 4 characters") }
        throw CLIError.failure("no \(kind) \(query) \(place)")
    }
    guard matches.count == 1 else {
        let ids = matches.map { id($0).uuidString.lowercased() }.joined(separator: ", ")
        throw CLIError.failure("'\(query)' matches \(matches.count) \(kind)s: \(ids)")
    }
    return first
}

/// How much unlocking a command needs.
enum Unlock {
    /// The vault must be readable.
    case required
    /// Unlock only without asking anyone: identities, a scripted passphrase,
    /// or an explicitly named `--passphrase-env` (which must then be set).
    case ifPossible
}

extension AccessOptions {
    func vaultURL() throws -> URL {
        guard let path = vault ?? Env.vars["SEMPERE_VAULT"], !path.isEmpty else {
            throw CLIError.usage("no vault: pass --vault PATH or set SEMPERE_VAULT")
        }
        return URL(fileURLWithPath: path)
    }

    /// `--identity` files plus `$SEMPERE_IDENTITY`, with the signing keys of device key files.
    func explicitKeys() throws -> [(identity: NativeIdentity, signing: DeviceSigningKeys?)] {
        var paths = identity
        if paths.isEmpty, let env = Env.vars["SEMPERE_IDENTITY"], !env.isEmpty { paths = [env] }
        return try paths.map(readAccessKeyFile)
    }

    /// `--identity` files plus `$SEMPERE_IDENTITY`.
    func explicitIdentities() throws -> [NativeIdentity] { try explicitKeys().map(\.identity) }

    /// The keys that read vault `vaultId` (a backup's, a copy's): `--identity` files, `--recovery-key`,
    /// else this machine's device key for it (a passphrase-wrapped one only when the passphrase is
    /// scripted). Empty when there is none.
    func readingIdentities(vaultId: UUID) throws -> [any AgeIdentity] {
        var ids: [any AgeIdentity] = try explicitIdentities()
        if let (recovery, _) = try recoveryIdentity() { ids.append(recovery) }
        guard ids.isEmpty else { return ids }
        let scripted = passphraseEnv != nil || Env.vars["SEMPERE_PASSPHRASE"] != nil
        switch DeviceKeyStore.stored(vaultId: vaultId) {
        case .none: return []
        case .plain: return try DeviceKeyStore.load(vaultId: vaultId, passphraseEnv: passphraseEnv).map { [$0.nativeIdentity] } ?? []
        case .wrapped:
            guard scripted else { return [] }
            return try DeviceKeyStore.load(vaultId: vaultId, passphraseEnv: passphraseEnv).map { [$0.nativeIdentity] } ?? []
        }
    }

    /// The root given with `--root`: 64 hex digits, spaces and the kit's line checksums in parentheses
    /// ignored.
    func givenRoot() throws -> Data? {
        guard let root else { return nil }
        let hex = root.replacingOccurrences(of: #"\([0-9a-fA-F]{4}\)"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }.lowercased()
        guard let data = Hex.decode(hex), data.count == 32 else {
            throw CLIError.usage("--root is not 64 hex digits (the kit's 16 groups)")
        }
        return data
    }

    /// Opens the vault with the identities this invocation provides.
    func openVault(_ unlock: Unlock) throws -> Vault {
        try openVault(at: try vaultURL(), unlock)
    }

    /// The identity of `--recovery-key` and the root that comes with it: a plain identity file, or the
    /// vault's passphrase copy (the passphrase from `--passphrase-env`, `$SEMPERE_PASSPHRASE` or the
    /// terminal), which carries the root.
    func recoveryIdentity() throws -> (identity: NativeIdentity, root: Data?)? {
        guard let recoveryKey else { return nil }
        let url = URL(fileURLWithPath: recoveryKey)
        let data: Data
        do { data = try BoundedRead.contents(of: url, maxBytes: KeyText.maximumBytes) } catch {
            throw CLIError.failure("cannot read \(recoveryKey): \(error)")
        }
        if case .success(.passphraseWrapped(let binary)) = KeyText.classify(data) {
            let pass = try obtainPassphrase(envName: passphraseEnv, prompt: "Recovery passphrase: ")
            let copy = try Vault.openPassphraseCopy(binary, passphrase: pass)
            return (.mlkem768x25519(copy.identity), copy.root)
        }
        return (try readIdentityFile(recoveryKey), nil)
    }

    /// - Parameter trust: this machine's trust records; a dry run passes a copy so that it keeps nothing.
    func openVault(at url: URL, _ unlock: Unlock, trust: (any EpochTrustStore)? = nil) throws -> Vault {
        let locked = try Vault.open(at: url)
        OpenedVaults.shared.record(url)
        ReadOnlyNotice.warnOnce(locked)
        let given = try givenRoot()
        if let (recovery, copyRoot) = try recoveryIdentity() {
            let root = given ?? copyRoot
            if root == nil {
                printStderr("sempere: warning: no --root: the vault is read without checking it against the kit's root")
            }
            // Read-only: no trust record is read or written; the root is the one given (design §4.3 step 4).
            let vault = try Vault.open(at: url, identities: [recovery], root: root)
            if let problem = vault.listStatus.problem, problem.reason != .rootUnconfirmed {
                throw CLIError.untrustedList("vault.json does not check against the recovery key: \(problem)")
            }
            OpenedVaults.shared.recordUnlocked(vault)
            return vault
        }
        var keys = try explicitKeys()
        if keys.isEmpty {
            let scripted = passphraseEnv != nil || Env.vars["SEMPERE_PASSPHRASE"] != nil
            switch DeviceKeyStore.stored(vaultId: locked.vaultId) {
            case .none:
                guard unlock == .required else { return locked }
                throw CLIError.cannotDecrypt("this machine has no device key for the vault: join it (sempere device init), "
                    + "pass --identity FILE, or read it with --recovery-key FILE")
            case .plain(let path):
                let k = try readAccessKeyFile(path)
                keys = [k]
            case .wrapped:
                guard unlock == .required || scripted else { return locked }
                let pass = try obtainPassphrase(envName: passphraseEnv, prompt: "Device key passphrase: ")
                let device = try DeviceKeyStore.unwrap(vaultId: locked.vaultId, passphrase: pass)
                keys = [(device.nativeIdentity, device.signing)]
            }
        }
        // This device's write ledger and set-aside store (design §5.4, §5.8), sealed to its key.
        let ledger = keys.lazy.compactMap { k -> FileWriteLedger? in
            guard case .mlkem768x25519(let pq) = k.identity else { return nil }
            return FileWriteLedger(directory: FileWriteLedger.cliDirectory(environment: Env.vars), vaultId: locked.vaultId,
                                   device: pq)
        }.first
        let vault = try Vault.open(at: url, identities: keys.map(\.identity), signing: keys.compactMap(\.signing).first,
                                   trust: trust ?? trustStore(), root: given, ledger: ledger,
                                   setAside: SetAsideStore(directory: SetAsideStore.cliDirectory(environment: Env.vars)))
        OpenedVaults.shared.recordUnlocked(vault)
        return vault
    }
}

/// This machine's trust records (format.md §15.10), next to `device.json`.
func trustStore() -> FileEpochTrustStore {
    FileEpochTrustStore(directory: FileEpochTrustStore.cliDirectory())
}

/// A copy in memory of this machine's record of `vault`, for dry runs: the
/// same checks, and nothing kept.
func scratchTrustStore(for vault: URL) -> MemoryEpochTrustStore {
    let store = MemoryEpochTrustStore()
    guard let id = (try? Vault.open(at: vault))?.vaultId else { return store }
    do {
        if let record = try trustStore().record(for: id) { try? store.save(record) }
    } catch {
        store.markUnreadable(id, "\(error)")   // the dry run fails closed as the real one would (R5)
    }
    return store
}

// MARK: - Read-only vaults (format.md §7.3)

/// What `--json` outputs say about a read-only vault.
enum ReadOnlyNotice {
    nonisolated(unsafe) private static var warned = false

    /// One stderr line, once per run, when the vault is read-only from its
    /// manifest (a later `format` or unknown `features`). Writes then fail
    /// with exit 7.
    static func warnOnce(_ vault: Vault) {
        guard !warned, vault.isReadOnly else { return }
        warned = true
        printStderr("sempere: warning: read-only: " + vault.readOnlyReasons.descriptions.joined(separator: "; ")
            + "; this version can read it but not change it")
    }
}
