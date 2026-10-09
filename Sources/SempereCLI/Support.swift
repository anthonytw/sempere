import Age
import ArgumentParser
import Foundation
import Sempere

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
    static let legacyVault: Int32 = 5
    static let untrustedRecipients: Int32 = 6
    static let readOnly: Int32 = 7
}

/// A failure with its exit code. Messages are one line.
enum CLIError: Error {
    /// Exit 1: I/O, bad input, corrupt file, refusing to overwrite.
    case failure(String)
    /// Exit 2: the command line is wrong.
    case usage(String)
    /// Exit 3: unhealthy vault or incomplete rewrap.
    case unhealthy(String)
    /// Exit 4: wrong key or passphrase, or no key available.
    case cannotDecrypt(String)
    /// Exit 5: a legacy vault (classic X25519 recipient): migrate first.
    case legacyVault(String)
    /// Exit 6: vault.json's recipients list does not check (format.md §2.1):
    /// nothing is written until it is repaired.
    case untrustedRecipients(String)
    /// Exit 7: the vault holds content of a newer format version, so this
    /// version may read it but not change it (format.md §7.3).
    case readOnly(String)

    var message: String {
        switch self {
        case .failure(let m), .usage(let m), .unhealthy(let m), .cannotDecrypt(let m), .legacyVault(let m),
             .untrustedRecipients(let m), .readOnly(let m): return m
        }
    }

    var code: Int32 {
        switch self {
        case .failure: return ExitStatus.failure
        case .usage: return ExitStatus.usage
        case .unhealthy: return ExitStatus.unhealthy
        case .cannotDecrypt: return ExitStatus.cannotDecrypt
        case .legacyVault: return ExitStatus.legacyVault
        case .untrustedRecipients: return ExitStatus.untrustedRecipients
        case .readOnly: return ExitStatus.readOnly
        }
    }

    /// Maps a library error to a message and an exit code.
    static func from(_ error: Error) -> CLIError {
        if let e = error as? CLIError { return e }
        let text = "\(error)".split(whereSeparator: \.isNewline).joined(separator: " ")
        switch error {
        case AgeError.noMatchingIdentity, AgeError.noIdentities,
             VaultError.vaultSecretUndecryptable, VaultError.wrongPassphrase,
             VaultError.locked, VaultError.noIdentities, VaultError.classicIdentity:
            return .cannotDecrypt(text)
        case VaultError.classicRecipient:
            return .usage(text)
        case VaultError.legacyVault:
            return .legacyVault(text)
        case VaultError.untrustedRecipients:
            return .untrustedRecipients(text)
        case VaultError.readOnly:
            return .readOnly(text)
        case SharedSettingsError.needsNewerReader(let min):
            return .readOnly("the vault's settings need a newer sempere (settings reader \(min) or later; this is "
                + "\(SharedSettingsMigrations.current)): they are neither read nor written")
        case VaultError.rewrapIncomplete:
            return .unhealthy(text + "; run `sempere vault rewrap-resume`")
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

/// `--vault`, `--identity`, `--passphrase-env`.
struct AccessOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The vault directory (*.sempere).", discussion: "Default: $SEMPERE_VAULT.",
                                            valueName: "path"))
    var vault: String?

    @Option(name: .long, help: ArgumentHelp("An age identity file (age-keygen style). Repeatable.",
                                            discussion: "Default: $SEMPERE_IDENTITY.", valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Name of the environment variable holding the passphrase of the vault's key file.",
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
    static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = [Int](repeating: 0, count: first.count)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        return rows.map { r in
            r.enumerated().map { i, c in
                i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

// MARK: - Files

/// Creates `path` with mode 0600, refusing to overwrite.
func writeNewSecretFile(_ text: String, to path: String) throws {
    try writeNewSecretFile(Data(text.utf8), to: path)
}

/// Creates `path` with mode 0600 holding `data`, refusing to overwrite.
func writeNewSecretFile(_ data: Data, to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd < 0 {
        if errno == EEXIST { throw CLIError.failure("refusing to overwrite \(path)") }
        throw CLIError.failure("cannot create \(path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do { try handle.write(contentsOf: data) } catch {
        throw CLIError.failure("cannot write \(path): \(error.localizedDescription)")
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
func obtainPassphrase(envName: String?, prompt: String = "Vault passphrase: ", confirm: Bool = false,
                      asError: (String) -> CLIError = CLIError.cannotDecrypt) throws -> String {
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

/// A recipient given on the command line: the `age1...` / `age1pq1...`
/// string itself, or the path of a file holding one: a recipients file as
/// `age-keygen -y` writes it (the first line that is not blank or `#`), or
/// an identity file's `# public key:` comment (only that line is used).
/// Post-quantum recipients are 1959 characters, so a file is often handier.
func parseRecipient(_ s: String) throws -> NativeRecipient {
    if let r = try? NativeRecipient(string: s) { return r }
    if !s.hasPrefix("age1"), let text = try? String(contentsOfFile: s, encoding: .utf8) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let publicKey = "# public key:"
        if let line = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
            let r = try? NativeRecipient(string: line) { return r }
        if let line = lines.first(where: { $0.hasPrefix(publicKey) }),
            let r = try? NativeRecipient(string: line.dropFirst(publicKey.count).trimmingCharacters(in: .whitespaces)) {
            return r
        }
        throw CLIError.usage("\(s) holds no age recipient (age1... or age1pq1...)")
    }
    throw CLIError.usage("not an age recipient (age1... or age1pq1...): \(abbreviateKey(s))")
}

/// `age1pq1abcdefgh…stuvwxyz` for a post-quantum recipient (1959
/// characters in full); other strings unchanged.
func abbreviateKey(_ s: String) -> String {
    s.count > 80 ? "\(s.prefix(16))…\(s.suffix(8))" : s
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

    /// `--identity` files plus `$SEMPERE_IDENTITY`.
    func explicitIdentities() throws -> [NativeIdentity] {
        var paths = identity
        if paths.isEmpty, let env = Env.vars["SEMPERE_IDENTITY"], !env.isEmpty { paths = [env] }
        return try paths.map(readIdentityFile)
    }

    /// The identity stored passphrase-wrapped in the vault's `keys/`.
    func identityFromKeyFiles(of locked: Vault, recipient: NativeRecipient? = nil) throws -> NativeIdentity {
        let candidates = try recipient.map { [$0] } ?? locked.identityFiles()
        guard !candidates.isEmpty else {
            throw CLIError.cannotDecrypt("no key: pass --identity FILE (the vault stores no passphrase-wrapped key)")
        }
        let pass = try obtainPassphrase(envName: passphraseEnv)
        var lastError: Error = VaultError.wrongPassphrase
        for r in candidates {
            do { return try locked.readIdentityFile(recipient: r, passphrase: pass) } catch { lastError = error }
        }
        throw lastError
    }

    /// Opens the vault with the identities this invocation provides.
    ///
    /// - Parameter migration: true only for the commands a legacy vault
    ///   (classic X25519 recipient) allows: the recipient changes that migrate
    ///   it, `rewrap-resume` and `info`. Every other command is refused with
    ///   exit 5 (`VaultError.legacyVault`) before any key or passphrase is read.
    func openVault(_ unlock: Unlock, migration: Bool = false) throws -> Vault {
        try openVault(at: try vaultURL(), unlock, migration: migration)
    }

    /// - Parameter trust: this machine's trust records (format.md §2.1); a
    ///   dry run passes a copy so that it keeps nothing.
    func openVault(at url: URL, _ unlock: Unlock, migration: Bool = false,
                   trust: (any RecipientsTrustStore)? = nil) throws -> Vault {
        let locked = try Vault.open(at: url)
        OpenedVaults.shared.record(url)
        if !migration { try locked.requireMigrated() }
        ReadOnlyNotice.warnOnce(locked)
        var ids: [any AgeIdentity] = try explicitIdentities()
        if ids.isEmpty {
            switch unlock {
            case .ifPossible:
                let scripted = passphraseEnv != nil || Env.vars["SEMPERE_PASSPHRASE"] != nil
                guard scripted, !((try? locked.identityFiles()) ?? []).isEmpty else { return locked }
                ids = [try identityFromKeyFiles(of: locked)]
            case .required:
                ids = [try identityFromKeyFiles(of: locked)]
            }
        }
        let vault = try Vault.open(at: url, identities: ids, trust: trust ?? trustStore())
        if case .untagged = vault.recipientsStatus { UntaggedVaults.shared.record(vault) }
        OpenedVaults.shared.recordUnlocked(vault)
        return vault
    }
}

/// This machine's trust records (format.md §2.1), next to `device.json`.
func trustStore() -> FileRecipientsTrustStore {
    FileRecipientsTrustStore(directory: FileRecipientsTrustStore.cliDirectory())
}

/// A copy in memory of this machine's record of `vault`, for dry runs: the
/// same checks, and nothing kept.
func scratchTrustStore(for vault: URL) -> MemoryRecipientsTrustStore {
    let store = MemoryRecipientsTrustStore()
    guard let id = (try? Vault.open(at: vault))?.vaultId else { return store }
    do {
        if let record = try trustStore().record(for: id) { try? store.save(record) }
    } catch {
        store.markUnreadable(id, "\(error)")   // the dry run fails closed as the real one would (R5)
    }
    return store
}

/// Vaults opened untagged (format.md §2.1). The library tags such a vault
/// at its first write; after the command, each one that is now tagged is
/// reported once on stderr (the one-time upgrade).
final class UntaggedVaults: @unchecked Sendable {
    static let shared = UntaggedVaults()
    private let lock = NSLock()
    private var vaults: [URL: [VaultManifest.Recipient]] = [:]

    func record(_ vault: Vault) {
        lock.lock(); defer { lock.unlock() }
        vaults[vault.url.standardizedFileURL] = vault.recipients
    }

    func reportUpgrades() {
        lock.lock()
        let all = vaults
        vaults = [:]
        lock.unlock()
        for (url, recipients) in all.sorted(by: { $0.key.path < $1.key.path }) {
            guard (try? Vault.open(at: url))?.manifest.recipientsTag != nil else { continue }
            printStderr("sempere: vault.json's device list is now authenticated (format.md §2.1); it trusts these "
                + "\(recipients.count) recipient(s), check them with `sempere vault info`: "
                + recipients.map { abbreviateKey($0.key) + ($0.label.isEmpty ? "" : " (\($0.label))") }.joined(separator: ", "))
        }
    }
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
