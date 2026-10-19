import Foundation

/// Where a remembered vault stands right now: the welcome list's rows and the reopen at launch
/// (docs/io.md "Recent vaults after a restart").
///
/// After a restart, iCloud Drive (or another provider) can take a while before a vault folder in it can
/// be reached: the bookmark does not resolve yet, or it resolves to a folder iCloud has not listed yet.
/// Such an entry stays in the list as waiting, is checked again with a backoff (and when the scene
/// becomes active or the iCloud account changes), and opens by itself once it arrives when the launch
/// reopen or a tap asked for it. Only after `RecentVaultCheck.patience` does it count as gone, and even
/// then it is kept (the user removes it) and still checked now and then.
enum RecentVaultState: Equatable, Sendable {
    /// Not checked yet.
    case unknown
    /// The vault folder is there.
    case available
    /// Not reachable yet (iCloud or the provider is still starting up); checked again.
    case waiting
    /// The bookmark resolves, the folder it names is gone and its parent is there: moved or deleted.
    case missing
    /// Neither the vault nor its folder can be reached after waiting: iCloud Drive (or the provider)
    /// is off or signed out, or the vault went away with its folder.
    case unreachable

    /// Missing or unreachable: shown as a problem, not as waiting.
    var isGone: Bool { self == .missing || self == .unreachable }
}

/// What looking at a recent vault's bookmark found (`RecentVaultCheck.probe`).
struct RecentVaultProbe: Equatable, Sendable {
    /// Where the bookmark points; nil when it did not resolve.
    var url: URL?
    /// A fresh bookmark when the stored one was stale.
    var refreshed: Data?
    /// The folder is there and holds a vault (`vault.json` or iCloud's stand-in for it).
    var vaultPresent: Bool
    /// The folder holding the vault is there.
    var parentPresent: Bool

    /// The bookmark did not resolve.
    static let unresolved = RecentVaultProbe(url: nil, refreshed: nil, vaultPresent: false, parentPresent: false)
}

/// The pure rules for `RecentVaultState`, and the real probe.
enum RecentVaultCheck {
    /// How long a vault that may live in a cloud provider counts as waiting before it is reported gone.
    static let patience: TimeInterval = 180

    /// How many times in a row a check runs while the only vaults left are gone (a minute apart).
    static let goneChecks = 10

    /// The state of a vault the probe found as `probe`, after it has been unreachable for `waited`
    /// seconds. `cloud` is false only for a vault known to be outside any cloud provider (on this
    /// device, an external drive): that one has nothing to wait for.
    static func state(of probe: RecentVaultProbe, cloud: Bool, waited: TimeInterval) -> RecentVaultState {
        if probe.vaultPresent { return .available }
        if cloud, waited < patience { return .waiting }
        return probe.url != nil && probe.parentPresent ? .missing : .unreachable
    }

    /// The next check after `attempt` checks in a row found something not available: 1, 2, 4, 8, 16, 30,
    /// 30 … seconds while a vault is waiting, once a minute when the only ones left are gone (iCloud may
    /// come back on; `goneChecks` times).
    static func delay(attempt: Int, waiting: Bool) -> Duration {
        guard waiting else { return .seconds(60) }
        return .seconds(min(30, 1 << min(max(attempt, 0), 5)))
    }

    /// Whether a recent vault may live in a cloud provider (so is worth waiting for). An entry saved
    /// before paths were kept may be anywhere: it is waited for.
    static func mayBeCloud(_ entry: RecentVault) -> Bool {
        guard let path = entry.path else { return true }
        return StorageLocation.classify(URL(fileURLWithPath: path)).needsCoordination
    }

    /// Whether a recent vault is (or may be) in iCloud Drive, for the "Waiting for iCloud…" wording.
    static func mayBeICloud(_ entry: RecentVault) -> Bool {
        guard let path = entry.path else { return true }
        return StorageLocation.classify(URL(fileURLWithPath: path)) == .iCloudDrive
    }

    /// Resolves `bookmark` and looks for the vault, under the bookmark's scope. Blocking (bookmark
    /// resolution waits on the file provider): never call it on the main actor.
    static func probe(_ bookmark: Data) -> RecentVaultProbe {
        guard let resolved = try? VaultBookmark.resolve(bookmark) else { return .unresolved }
        let url = resolved.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let folder = fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let present = folder
            && (fm.fileExists(atPath: url.appendingPathComponent("vault.json").path)
                || fm.fileExists(atPath: url.appendingPathComponent(CloudPlaceholder.placeholderName(for: "vault.json")).path))
        let parent = present || fm.fileExists(atPath: url.deletingLastPathComponent().path)
        return RecentVaultProbe(url: url, refreshed: resolved.refreshed, vaultPresent: present, parentPresent: parent)
    }
}

extension VaultLibrary {
    /// Where `entry` stands. A WebDAV entry is always available (its copy is local).
    func state(of entry: RecentVault) -> RecentVaultState {
        if entry.webdav != nil { return .available }
        return states[entry.id] ?? .unknown
    }

    /// Checks every recent vault (off the main actor) and updates `states`. While one is waiting or
    /// gone, the next check is scheduled (`RecentVaultCheck.delay`). A check already running is joined.
    func checkRecents() async {
        if let running = checkTask {
            await running.value
            return
        }
        let task = Task { await runCheck() }
        checkTask = task
        await task.value
        checkTask = nil
    }

    /// Checks again now, from the first backoff step: the scene became active, the iCloud account
    /// changed, or the user is waiting for a vault.
    func refreshRecents() {
        checkAttempt = 0
        Task { await checkRecents() }
    }

    /// Opens `entry` as soon as it is available (`takeReadyPendingOpen`), and checks again now.
    func openWhenAvailable(_ entry: RecentVault) {
        pendingOpen = entry.id
        refreshRecents()
    }

    /// Stops waiting to open a vault (another vault opened, or the entry was removed).
    func cancelPendingOpen() {
        pendingOpen = nil
    }

    /// The vault waited for (`openWhenAvailable`) once it can be opened; the request is used up.
    func takeReadyPendingOpen() -> RecentVault? {
        guard let id = pendingOpen, states[id] == .available,
              let entry = recents.first(where: { $0.id == id }) else { return nil }
        pendingOpen = nil
        return entry
    }

    /// Checks again whenever the iCloud account changes (signed in, out, or iCloud Drive turned on).
    func watchICloudAccount() {
        guard identityObserver == nil else { return }
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRecents() }
        }
    }

    private func runCheck() async {
        retryTask?.cancel()
        retryTask = nil
        let probe = self.probe
        let inputs = recents.filter { $0.webdav == nil }.map { (id: $0.id, bookmark: $0.bookmark) }
        let results = await Task.detached(priority: .utility) {
            inputs.map { (id: $0.id, probe: probe($0.bookmark)) }
        }.value
        let now = clock()
        var changed = false
        var waiting = false
        var gone = false
        for (id, found) in results {
            guard let i = recents.firstIndex(where: { $0.id == id }) else { continue }   // forgotten meanwhile
            if let fresh = found.refreshed {
                recents[i].bookmark = fresh
                changed = true
            }
            if found.vaultPresent, let url = found.url {
                let path = url.standardizedFileURL.path
                if recents[i].path != path {
                    recents[i].path = path
                    changed = true
                }
            }
            let since = found.vaultPresent ? nil : (firstMiss[id] ?? now)
            firstMiss[id] = since
            let state = RecentVaultCheck.state(of: found, cloud: RecentVaultCheck.mayBeCloud(recents[i]),
                                               waited: since.map { now.timeIntervalSince($0) } ?? 0)
            if states[id] != state { states[id] = state }
            waiting = waiting || state == .waiting
            gone = gone || state.isGone
        }
        if changed { save() }
        // Gone vaults are looked at for `goneChecks` minutes; the scene becoming active or the
        // account changing starts over (`refreshRecents`).
        guard waiting || (gone && checkAttempt < RecentVaultCheck.goneChecks) else {
            checkAttempt = 0
            return
        }
        let delay = retryDelay(checkAttempt, waiting)
        checkAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.checkRecents()
        }
    }
}
