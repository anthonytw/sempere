import Foundation
import Sempere

/// Settings sync through the vault (docs/settings-sync.md): this device's
/// values follow the vault's `settings.age` while it is open and sync is on.
/// The decisions are `SettingsSyncState`'s (Sempere); this runs the passes:
/// read the file, reconcile, apply what changed through `SettingsSyncBridge`
/// (this device's values in `services.settings`, kept by `services.settingsStorage`), write the file when it fell
/// behind. Passes run one at a time; the file is written through `Vault.writeSharedSettings`,
/// which refuses read-only and untrusted vaults like every write.
extension AppModelCore {
    /// The kind of device this app syncs as.
    public var settingsDeviceType: SettingsDeviceType {
        settingsDeviceTypeOverride ?? SettingsSyncBridge.deviceType(isMac: services.platform.isMac,
                                                                    isPhone: services.platform.isPhone)
    }

    nonisolated static func settingsSyncKey(_ vaultId: UUID) -> String {
        "Sempere.settingsSync.\(vaultId.uuidString.lowercased())"
    }

    /// Loads this device's sync state for the open vault and starts following
    /// local changes; the first pass runs now.
    func startSettingsSync() {
        guard let vault else { return }
        settingsSync = Self.loadSettingsSyncState(services.settings, vaultId: vault.vaultId)
        settingsSyncProblem = nil
        if settingsSyncObserver == nil {
            settingsSyncObserver = services.settings.observeChanges { [weak self] in
                Task { @MainActor [weak self] in self?.settingsDefaultsChanged() }
            }
        }
        scheduleSettingsSync(after: .zero)
    }

    /// Stops following changes (the vault closed). The state stays stored.
    func stopSettingsSync() {
        settingsSyncScheduled?.cancel()
        settingsSyncScheduled = nil
        settingsSyncObserver?.cancel()
        settingsSyncObserver = nil
        settingsSync = SettingsSyncState()
        settingsSyncProblem = nil
        settingsSyncPrompt = nil
    }

    nonisolated static func loadSettingsSyncState(_ defaults: any KeyValueStore, vaultId: UUID) -> SettingsSyncState {
        guard let data = defaults.data(forKey: settingsSyncKey(vaultId)),
              let state = try? JSONDecoder().decode(SettingsSyncState.self, from: data) else { return SettingsSyncState() }
        return state
    }

    func saveSettingsSyncState() {
        guard let vault else { return }
        let key = Self.settingsSyncKey(vault.vaultId)
        guard let data = try? JSONEncoder().encode(settingsSync), services.settings.data(forKey: key) != data else { return }
        services.settings.set(data, forKey: key)
    }

    /// A local value changed somewhere (Settings, the editor, the new-note
    /// sheet, quick capture): a pass runs after `settingsSyncDebounce` when a
    /// synced value differs from what the last pass left.
    public func settingsChanged() {
        guard settingsSync.enabled, phase == .unlocked else { return }
        scheduleSettingsSync(after: settingsSyncDebounce)
    }

    /// Any change to `services.settings`, from anywhere in the app: cheap (no Keychain
    /// read, so the quick-capture keys are left to `settingsChanged`).
    func settingsDefaultsChanged() {
        guard settingsSync.enabled, phase == .unlocked else { return }
        let local = currentSettingsValues(includingCaptureProfile: false)
        let changed = local.contains { key, value in
            !settingsSync.isOverridden(key) && settingsSync.applied[key].map { $0 != value } ?? false
        }
        if changed { scheduleSettingsSync(after: settingsSyncDebounce) }
    }

    /// Runs a pass after `delay` (replacing one already scheduled).
    public func scheduleSettingsSync(after delay: Duration = .zero) {
        settingsSyncScheduled?.cancel()
        settingsSyncScheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.syncSettingsNow()
        }
    }

    /// One pass now (after any running one). Settings, the foreground and the
    /// unlock call it; tests await it.
    public func syncSettingsNow() async {
        await runSettingsStep { state, local, file, type, now in
            try state.reconcile(local: local, file: file, type: type, now: now)
        }
    }

    // MARK: - The switch and the rows

    /// Turns sync on or off for the open vault. On: when the vault's settings
    /// differ from this device's, `settingsSyncPrompt` asks which to keep;
    /// otherwise this device's become (or join) the shared set.
    public func setSettingsSync(_ on: Bool) async {
        guard on else {
            settingsSync.disable()
            settingsSyncProblem = nil
            saveSettingsSyncState()
            return
        }
        guard !settingsSync.enabled else { return }
        await runSettingsStep(enabling: true) { [weak self] state, local, file, type, now in
            switch SettingsSyncState.discover(local: local, file: file, type: type) {
            case .differs(let differences):
                self?.settingsSyncPrompt = SettingsSyncPrompt(differences: differences)
                return nil
            case .empty, .agrees:
                return try state.enable(.useVault, local: local, file: file, type: type, now: now)
            }
        }
    }

    /// The answer to `settingsSyncPrompt` (nil: cancel, sync stays off).
    public func answerSettingsSyncPrompt(_ choice: SettingsSyncState.EnableChoice?) async {
        settingsSyncPrompt = nil
        guard let choice else { return }
        await runSettingsStep(enabling: true) { state, local, file, type, now in
            try state.enable(choice, local: local, file: file, type: type, now: now)
        }
    }

    /// "Only on This Device" (docs/settings-sync.md §4.3).
    public func overrideSetting(_ key: String) {
        settingsSync.override(key)
        saveSettingsSyncState()
    }

    /// "Use Synced Value": ends the override.
    public func useSyncedSetting(_ key: String) async {
        await runSettingsStep { state, local, file, type, now in
            try state.useSynced(key, local: local, file: file, type: type, now: now)
        }
    }

    /// "Only on iPads" (this device's type): the value goes into the type's block.
    public func keepSettingForThisType(_ key: String) async {
        await runSettingsStep { state, local, file, type, now in
            try state.onlyOnThisType(key, local: local, file: file, type: type, now: now)
        }
    }

    /// "Use on All Devices": the type's block lets go of the key.
    public func useSettingOnAllDevices(_ key: String) async {
        await runSettingsStep { state, local, file, type, now in
            try state.useOnAllDevices(key, local: local, file: file, type: type, now: now)
        }
    }

    // MARK: - Passes

    typealias SettingsStep = @MainActor (inout SettingsSyncState, [String: JSONValue], SharedSettings?,
                                                SettingsDeviceType, Date) async throws -> SettingsSyncState.Pass?

    /// Runs `step` on the current state with this device's values and the
    /// vault's file, applies and writes what it decides. One pass at a time:
    /// a pass asked for while one runs runs after it.
    func runSettingsStep(enabling: Bool = false, _ step: @escaping SettingsStep) async {
        while settingsSyncRunning { try? await Task.sleep(for: .milliseconds(20)) }
        settingsSyncRunning = true
        defer { settingsSyncRunning = false }
        await settingsPass(enabling: enabling, step)
    }

    private func settingsPass(enabling: Bool, _ step: SettingsStep) async {
        guard phase == .unlocked, let vault, !isChangingKeys, enabling || settingsSync.enabled else { return }
        let gen = generation
        let log = services.perf
        let file: SharedSettings?
        do {
            file = try await offMain { try vault.readSharedSettings() }
        } catch SharedSettingsError.needsNewerReader {
            // Rule 4: not read, applied or written; the values last applied stay.
            if (try? ensureCurrent(gen)) != nil { settingsSyncProblem = .needsNewerApp }
            return
        } catch let e as SharedSettingsError {
            // Not this vault's (damaged, or sealed under other keys):
            // this device's copy replaces it at the write below; unless this device's
            // keys are the stale ones (another device changed them while the vault stayed
            // open here), when the file is current and must not be overwritten.
            guard (try? await offMain({ vault.keysMatchManifestOnDisk() })) == true else {
                log.log(.error, "settings", "settings.age does not verify and vault.json changed; not replaced until the vault is reopened")
                return
            }
            log.log(.error, "settings", "settings.age unreadable, will be replaced: \(LogSafe.describe(e))")
            file = nil
        } catch is CancellationError {
            return
        } catch {
            if (try? ensureCurrent(gen)) != nil { settingsSyncProblem = .failed(services.describeError(error)) }
            return
        }
        guard (try? ensureCurrent(gen)) != nil, self.vault?.vaultId == vault.vaultId else { return }

        let type = settingsDeviceType
        var state = settingsSync
        let decided: SettingsSyncState.Pass?
        do {
            decided = try await step(&state, currentSettingsValues(), file, type, Date())
        } catch {
            settingsSyncProblem = .failed(services.describeError(error))
            return
        }
        guard (try? ensureCurrent(gen)) != nil else { return }
        guard let pass = decided else { return }   // the step asked the user first
        settingsSync = state
        if !pass.warnings.isEmpty {
            log.log(.error, "settings", "settings.age: \(pass.warnings.count) invalid values skipped")
        }
        applySharedSettings(pass.apply)
        saveSettingsSyncState()
        guard let write = pass.write else {
            settingsSyncProblem = nil
            return
        }
        // A list that does not check is said as such, before the read-only state it also causes.
        if listAlert != nil || listProblem != nil { settingsSyncProblem = .untrustedRecipients; return }
        if isVaultReadOnly { settingsSyncProblem = .readOnly; return }
        do {
            // Under the copy's write lock: a sync run merging `settings.age` never interleaves (`VaultFileLock`).
            // Read again under the lock (F3): a sync run that merged another device's change since this pass
            // read the file is never overwritten; the pass runs again on what is there now.
            let lock = vaultWriteLock
            let started = file
            let written = try await offMain { () throws -> Bool in
                try Self.withWriteLock(lock) { () throws -> Bool in
                    if lock != nil, ((try? vault.readSharedSettings()) ?? nil) != started { return false }
                    try vault.writeSharedSettings(write)
                    return true
                }
            }
            if !written {
                scheduleSettingsSync()
                return
            }
            if (try? ensureCurrent(gen)) != nil { settingsSyncProblem = nil }
        } catch VaultError.readOnly {
            settingsSyncProblem = .readOnly
        } catch VaultError.untrustedList {
            settingsSyncProblem = .untrustedRecipients
        } catch {
            settingsSyncProblem = .failed(services.describeError(error))
        }
    }

    /// This device's values of the settings it uses (`SettingsSyncBridge`).
    func currentSettingsValues(includingCaptureProfile: Bool = true) -> [String: JSONValue] {
        var extras = SettingsSyncBridge.Extras()
        if let vault {
            extras.backupReminderDays = backupStore.record(for: vault.vaultId).reminderDays
            if includingCaptureProfile, case .on(let stored) = quickCaptureSetting, stored.profile.vaultId == vault.vaultId {
                extras.quickCapture = (stored.profile.notebook, stored.transcribe)
            }
        }
        extras.appIcon = services.platform.appIcon
        return SettingsSyncBridge.values(for: settingsDeviceType, defaults: services.settings, extras: extras,
                                         storage: services.settingsStorage)
    }

    /// Writes values from the vault on this device.
    func applySharedSettings(_ values: [String: JSONValue]) {
        guard !values.isEmpty else { return }
        let forModel = SettingsSyncBridge.apply(values, defaults: services.settings, storage: services.settingsStorage)
        for (key, value) in forModel {
            switch (key, value) {
            case ("handwriting.recognize", .bool(let on)):
                setHandwritingRecognition(on)
            case ("search.transcripts", .bool(let on)):
                setSearchTranscripts(on)
            case ("backup.reminderDays", .number(let days)):
                let n = Int(days)
                Task { await self.setBackupReminder(days: n, ask: false) }   // no prompt for another device's setting
            case ("quickCapture.notebook", .string(let name)):
                updateCaptureProfile { $0.profile.notebook = NoteOps.normalizedNotebook(name) ?? CaptureProfile.defaultNotebook }
            case ("quickCapture.transcribe", .bool(let on)):
                updateCaptureProfile { $0.transcribe = on }
            case ("appearance.icon", .string(let name)):
                // iOS tells the user the icon changed; a failure leaves the current icon.
                if let current = services.platform.appIcon, current != name { services.platform.setAppIcon(name) }
            default:
                break
            }
        }
        settingsAppliedRevision += 1
    }

    /// Turns handwriting recognition on or off (remembered in `services.settings`), for the open
    /// note and every note opened from now on.
    public func setHandwritingRecognition(_ on: Bool) {
        services.settings.set(on, forKey: RecognitionPreference.key)
        recognizer = on ? services.makePageRecognizer() : nil
        if !on { cancelRecognizingNotes() }
    }

    private func updateCaptureProfile(_ change: (inout StoredCaptureProfile) -> Void) {
        do {
            // A profile that cannot be read is left as it is (not replaced by the synced values alone).
            guard let vault, var stored = try storedQuickCaptureProfile(), stored.profile.vaultId == vault.vaultId else { return }
            change(&stored)
            try quickCapture.store.save(stored)
            quickCapture.publishStatus()
        } catch {
            services.perf.log(.error, "settings", "quick capture profile not updated: \(LogSafe.describe(error))")
        }
    }
}
