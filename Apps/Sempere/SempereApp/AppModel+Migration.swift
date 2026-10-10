import Age
import Foundation
import Sempere

/// What the migration screen shows for a legacy vault (format.md §3.3.2):
/// one that still lists a classic X25519 key, or whose last key change was
/// interrupted. Nothing else of the vault is usable meanwhile.
struct VaultMigration: Equatable {
    enum Step: Equatable {
        /// Waiting for the user to save the key (and start).
        case ready
        /// Working; the text says on what.
        case running(String)
        /// Stopped with this reason. Starting again resumes where it stopped.
        case failed(String)
    }

    /// The classic recipients still listed (empty when only an interrupted
    /// key change is to be finished).
    var classicRecipients: [String]
    /// The post-quantum key the vault moves to; nil when only an interrupted
    /// key change is to be finished with the key that unlocked it.
    var key: NativeIdentity?
    /// True when `key` was generated here: the user must save it, nothing
    /// else holds it (unless a passphrase wraps it into `keys/`).
    var keyIsNew: Bool
    var step: Step = .ready

    /// Only an interrupted key change remains (no classic key listed).
    var finishingOnly: Bool { classicRecipients.isEmpty }
    var isRunning: Bool { if case .running = step { return true } else { return false } }
}

/// Migrating a legacy vault in the app (docs/post-quantum.md): add the
/// post-quantum key, then remove every classic key, through the library's
/// recipient API (`Vault.addRecipient` / `removeRecipient` / `resumeRewrap`).
/// Adding first means an interruption at any point is finished with the one
/// key the user holds at that moment: the classic key while one is still
/// listed (the vault is still legacy and unlocks into this screen again), the
/// new key afterwards (the files not yet rewrapped are encrypted to both).
extension AppModel {
    /// Errors of the migration, for the screen.
    enum MigrationError: Error, Equatable, CustomStringConvertible {
        case notMigrating
        case notPostQuantum
        /// Some files could not be re-encrypted (yet): the change stays pending.
        case incomplete(Int)
        /// iCloud Drive has not delivered every note in time.
        case notDownloaded(Int)

        var description: String {
            switch self {
            case .notMigrating: return String(localized: "No migration is in progress.")
            case .notPostQuantum:
                return String(localized: "That is not a post-quantum key (AGE-SECRET-KEY-PQ-1…). Create a new key instead.")
            case .incomplete(let n):
                return String(localized: "\(n) files could not be re-encrypted. If this vault is in iCloud Drive, wait until it has downloaded and try again; otherwise unlock it with the key it was encrypted to (the classic key while one is listed) and try again.")
            case .notDownloaded(let n):
                return String(localized: "iCloud Drive has not delivered \(n) notes yet. Every note must be on this device before the vault can be re-encrypted. Check that it is online and try again.")
            }
        }
    }

    /// Uses a post-quantum key the user already has instead of the
    /// generated one.
    func useMigrationKey(identityText: String) throws {
        guard phase == .migrating, var migration, !migration.isRunning else { throw MigrationError.notMigrating }
        let identity: NativeIdentity
        do { identity = try IdentityFile.parse(identityText) } catch { throw ModelError.notAnIdentity }
        guard identity.isPostQuantum else { throw MigrationError.notPostQuantum }
        migration.key = identity
        migration.keyIsNew = false
        migration.step = .ready
        self.migration = migration
    }

    /// Runs the migration (or resumes it), then opens the vault normally
    /// with the post-quantum key. With a non-empty `passphrase` the key is
    /// also stored passphrase-wrapped in `keys/` first (the classic key's file
    /// is then no longer offered: only current recipients' key files are).
    /// On failure the screen shows why (`step`) and calling again resumes.
    func migrate(passphrase: String? = nil) async throws {
        guard phase == .migrating, let start = vault, var plan = migration, !plan.isRunning else {
            throw MigrationError.notMigrating
        }
        try requireLocalKeyChanges()   // a WebDAV copy: the rewrap would never reach the server
        // Never remove the classic key without a post-quantum one to replace it.
        guard plan.finishingOnly || plan.key?.isPostQuantum == true else { throw MigrationError.notPostQuantum }
        let gen = generation
        let coordinate = coordinationURL
        let url = start.url
        var current = start
        func show(_ text: String) {
            plan.step = .running(text)
            migration = plan
        }
        do {
            if isCloudVault {
                show(String(localized: "Downloading every note from iCloud Drive…"))
                try await downloadEverything(url, gen: gen) { text in show(text) }
            }
            if let key = plan.key, let passphrase, !passphrase.isEmpty {
                show(String(localized: "Storing your key under the passphrase…"))
                let v = current
                _ = try await offMain {
                    try CloudVault.coordinatedWrite(coordinate) {
                        try v.writeIdentityFile(key, passphrase: passphrase, replace: true)
                    }
                }
                try ensureCurrent(gen)
            }
            if current.pendingRewrap {
                show(String(localized: "Finishing the interrupted key change…"))
                current = try await rewrap(current, gen: gen) { try $0.resumeRewrap() }
            }
            if let key = plan.key, !current.recipients.contains(where: { $0.key == key.recipient.string }),
                !current.classicRecipients.isEmpty {
                show(String(localized: "Adding your post-quantum key: re-encrypting every note…"))
                let policy = RewrapSettings.policy()
                current = try await rewrap(current, gen: gen) {
                    try $0.addRecipient(key.recipient, label: "This device (post-quantum)", policy: policy)
                }
            }
            for old in current.classicRecipients {
                show(String(localized: "Removing the classic key: re-encrypting every note…"))
                let recipient = try NativeRecipient(string: old)
                let policy = RewrapSettings.policy()
                current = try await rewrap(current, gen: gen) { try $0.removeRecipient(recipient, policy: policy) }
            }
            show(String(localized: "Opening the vault…"))
            let identities: [any AgeIdentity]
            if let key = plan.key { identities = [key] } else { identities = unlockIdentities }
            let trust = recipientsTrust
            let reopened = try await offMain {
                try CloudVault.coordinatedRead(coordinate) { try Vault.open(at: url, identities: identities, trust: trust) }
            }
            try ensureCurrent(gen)
            guard !reopened.isLegacy, !reopened.pendingRewrap else {
                throw MigrationError.incomplete(0)
            }
            try await finishUnlock(reopened, identities: identities)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if gen == generation {
                plan.step = .failed("\(error)")
                plan.classicRecipients = current.classicRecipients
                migration = plan
            }
            throw error
        }
    }

    /// One recipient change through the library, coordinated in iCloud
    /// Drive; the vault is updated even when files remain (the change stays
    /// pending and the next attempt resumes it).
    private func rewrap(_ vault: Vault, gen: Int,
                        _ change: @escaping @Sendable (inout Vault) throws -> Vault.RewrapReport) async throws -> Vault {
        let coordinate = coordinationURL
        let (next, report) = try await offMain { () throws -> (Vault, Vault.RewrapReport) in
            try CloudVault.coordinatedWrite(coordinate) { () throws -> (Vault, Vault.RewrapReport) in
                var copy = vault
                let report = try change(&copy)
                return (copy, report)
            }
        }
        try ensureCurrent(gen)
        replaceMigratingVault(next)
        guard report.isComplete else { throw MigrationError.incomplete(report.failures.count) }
        return next
    }

    /// Waits until every note folder is listed and every revision file is
    /// local (a rewrap must see them all: a file it cannot see would stay
    /// encrypted to the classic key only), requesting the downloads.
    func downloadEverything(_ url: URL, gen: Int, progress: (String) -> Void) async throws {
        let hooks = cloudHooks
        let window = cloudWindow
        let clock = ContinuousClock()
        var lastChange = clock.now
        var lastLocal = -1
        while true {
            let pass = try await offMain { try ProgressiveLoad.pass(vault: url, window: window, hooks: hooks) }
            try ensureCurrent(gen)
            if pass.pending.isEmpty {
                // The rewrap re-tags voice notes waiting in `inbox/` too (format.md
                // §3.3.1): an evicted one it could not see would never be adopted.
                let inbox = try await offMain { try CloudScan.inboxItems(inVault: url) }
                if !inbox.isEmpty {
                    try await CloudVault.download(items: inbox.map(\.item), hooks: hooks, stallTimeout: cloudStallTimeout,
                                                  pollInterval: cloudPollInterval) { _ in }
                    try ensureCurrent(gen)
                }
                return
            }
            progress(String(localized: "Downloading from iCloud Drive: \(pass.ready.count) of \(pass.all.count) notes…",
                                    comment: "Progress: notes downloaded so far of all notes"))
            if pass.localFiles != lastLocal {
                lastLocal = pass.localFiles
                lastChange = clock.now
            } else if clock.now - lastChange > cloudStallTimeout {
                throw MigrationError.notDownloaded(pass.pending.count)
            }
            try await Task.sleep(for: cloudPollInterval)
            try ensureCurrent(gen)
        }
    }
}
