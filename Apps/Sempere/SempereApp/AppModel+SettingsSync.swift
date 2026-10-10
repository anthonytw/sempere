import Foundation
import os
import Sempere
import UIKit

private let settingsLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "settings")

/// Why settings sync is not working (docs/settings-sync.md §4.5, §6.2 rule 4).
enum SettingsSyncProblem: Equatable, Sendable {
    /// The vault holds content of a newer format version: nothing is written.
    case readOnly
    /// The vault's device list did not check: nothing is encrypted to it.
    case untrustedRecipients
    /// The file's `$minReaderVersion` is newer than this app: paused, untouched.
    case needsNewerApp
    /// Reading or writing failed; the English detail follows.
    case failed(String)

    var text: String {
        switch self {
        case .readOnly:
            return String(localized: "Settings sync is paused: this vault is read-only on this device.")
        case .untrustedRecipients:
            return String(localized: "Settings sync is paused until the vault's device list is checked.")
        case .needsNewerApp:
            return String(localized: "Settings sync is paused: this vault's settings need a newer Sempere. Update the app to resume.")
        case .failed(let detail):
            return String(localized: "Settings could not be synced: \(detail)",
                          comment: "Settings ▸ Sync Settings; the error text follows (English)")
        }
    }
}

/// The question turning sync on asks when the vault's settings differ from this device's.
struct SettingsSyncPrompt: Identifiable, Equatable {
    let id = UUID()
    var differences: [SettingsSyncState.Difference]
}

/// Settings sync through the vault (docs/settings-sync.md): this device's
/// values follow the vault's `settings.age` while it is open and sync is on.
/// The decisions are `SettingsSyncState`'s (Sources); this runs the passes:
/// read the file (downloaded first in iCloud Drive), reconcile, apply what
/// changed through `SettingsSyncBridge`, write the file when it fell behind.
/// Passes run one at a time; the file is written through `Vault.writeSharedSettings`,
/// which refuses read-only and untrusted vaults like every write.
extension AppModel {
    /// The kind of device this app syncs as.
    var settingsDeviceType: SettingsDeviceType {
        settingsDeviceTypeOverride ?? SettingsSyncBridge.deviceType(isMac: Platform.isMac, isPhone: Platform.isPhone)
    }

    static func settingsSyncKey(_ vaultId: UUID) -> String { "Sempere.settingsSync.\(vaultId.uuidString.lowercased())" }

    /// Loads this device's sync state for the open vault and starts following
    /// local changes; the first pass runs now.
    func startSettingsSync() {
        guard let vault else { return }
        settingsSync = Self.loadSettingsSyncState(settingsDefaults, vaultId: vault.vaultId)
        settingsSyncProblem = nil
        if settingsSyncObserver == nil {
            settingsSyncObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.settingsDefaultsChanged() }
            }
        }
        scheduleSettingsSync(after: .zero)
    }

    /// Stops following changes (the vault closed). The state stays stored.
    func stopSettingsSync() {
        settingsSyncScheduled?.cancel()
        settingsSyncScheduled = nil
        if let observer = settingsSyncObserver { NotificationCenter.default.removeObserver(observer) }
        settingsSyncObserver = nil
        settingsSync = SettingsSyncState()
        settingsSyncProblem = nil
        settingsSyncPrompt = nil
    }

    static func loadSettingsSyncState(_ defaults: UserDefaults, vaultId: UUID) -> SettingsSyncState {
        guard let data = defaults.data(forKey: settingsSyncKey(vaultId)),
              let state = try? JSONDecoder().decode(SettingsSyncState.self, from: data) else { return SettingsSyncState() }
        return state
    }

    func saveSettingsSyncState() {
        guard let vault else { return }
        let key = Self.settingsSyncKey(vault.vaultId)
        guard let data = try? JSONEncoder().encode(settingsSync), settingsDefaults.data(forKey: key) != data else { return }
        settingsDefaults.set(data, forKey: key)
    }

    /// A local value changed somewhere (Settings, the editor, the new-note
    /// sheet, quick capture): a pass runs after `settingsSyncDebounce` when a
    /// synced value differs from what the last pass left.
    func settingsChanged() {
        guard settingsSync.enabled, phase == .unlocked else { return }
        scheduleSettingsSync(after: settingsSyncDebounce)
    }

    /// Any `UserDefaults` change, from anywhere in the app: cheap (no Keychain
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
    func scheduleSettingsSync(after delay: Duration = .zero) {
        settingsSyncScheduled?.cancel()
        settingsSyncScheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.syncSettingsNow()
        }
    }

    /// One pass now (after any running one). Settings, the foreground and the
    /// unlock call it; tests await it.
    func syncSettingsNow() async {
        await runSettingsStep { state, local, file, type, now in
            try state.reconcile(local: local, file: file, type: type, now: now)
        }
    }

    // MARK: - The switch and the rows

    /// Turns sync on or off for the open vault. On: when the vault's settings
    /// differ from this device's, `settingsSyncPrompt` asks which to keep;
    /// otherwise this device's become (or join) the shared set.
    func setSettingsSync(_ on: Bool) async {
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
    func answerSettingsSyncPrompt(_ choice: SettingsSyncState.EnableChoice?) async {
        settingsSyncPrompt = nil
        guard let choice else { return }
        await runSettingsStep(enabling: true) { state, local, file, type, now in
            try state.enable(choice, local: local, file: file, type: type, now: now)
        }
    }

    /// "Only on This Device" (docs/settings-sync.md §4.3).
    func overrideSetting(_ key: String) {
        settingsSync.override(key)
        saveSettingsSyncState()
    }

    /// "Use Synced Value": ends the override.
    func useSyncedSetting(_ key: String) async {
        await runSettingsStep { state, local, file, type, now in
            try state.useSynced(key, local: local, file: file, type: type, now: now)
        }
    }

    /// "Only on iPads" (this device's type): the value goes into the type's block.
    func keepSettingForThisType(_ key: String) async {
        await runSettingsStep { state, local, file, type, now in
            try state.onlyOnThisType(key, local: local, file: file, type: type, now: now)
        }
    }

    /// "Use on All Devices": the type's block lets go of the key.
    func useSettingOnAllDevices(_ key: String) async {
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
        let coordinate = coordinationURL
        let hooks = cloudHooks
        let cloud = isCloudVault
        let url = vault.url
        let file: SharedSettings?
        do {
            if cloud {
                let items = try await offMain {
                    try CloudScan.essentialItems(inVault: url).filter { $0.url.lastPathComponent == SharedSettings.fileName }
                }
                try await CloudVault.download(items: items, hooks: hooks, stallTimeout: .seconds(30)) { _ in }
            }
            file = try await offMain { try CloudVault.coordinatedRead(coordinate) { try vault.readSharedSettings() } }
        } catch SharedSettingsError.needsNewerReader {
            // Rule 4: not read, applied or written; the values last applied stay.
            if (try? ensureCurrent(gen)) != nil { settingsSyncProblem = .needsNewerApp }
            return
        } catch let e as SharedSettingsError {
            // Not this vault's (an older app's copy after a key change, or damaged):
            // this device's copy replaces it at the write below; unless this device's
            // keys are the stale ones (another device changed them while the vault stayed
            // open here), when the file is current and must not be overwritten.
            guard (try? await offMain({ vault.keysMatchManifestOnDisk() })) == true else {
                settingsLog.warning("settings.age does not verify and vault.json changed; not replaced until the vault is reopened")
                return
            }
            settingsLog.warning("settings.age unreadable, will be replaced: \(String(describing: e), privacy: .public)")
            file = nil
        } catch is CancellationError {
            return
        } catch {
            if (try? ensureCurrent(gen)) != nil { settingsSyncProblem = .failed(String(describing: error)) }
            return
        }
        guard (try? ensureCurrent(gen)) != nil, self.vault?.vaultId == vault.vaultId else { return }

        let type = settingsDeviceType
        var state = settingsSync
        let decided: SettingsSyncState.Pass?
        do {
            decided = try await step(&state, currentSettingsValues(), file, type, Date())
        } catch {
            settingsSyncProblem = .failed(String(describing: error))
            return
        }
        guard (try? ensureCurrent(gen)) != nil else { return }
        guard let pass = decided else { return }   // the step asked the user first
        settingsSync = state
        if !pass.warnings.isEmpty {
            settingsLog.warning("settings.age: \(pass.warnings.count) invalid values skipped")
        }
        applySharedSettings(pass.apply)
        saveSettingsSyncState()
        guard let write = pass.write else {
            settingsSyncProblem = nil
            return
        }
        if isVaultReadOnly { settingsSyncProblem = .readOnly; return }
        if recipientsAlert != nil || vault.recipientsStatus.problem != nil { settingsSyncProblem = .untrustedRecipients; return }
        do {
            try await offMain { try CloudVault.coordinatedWrite(coordinate) { try vault.writeSharedSettings(write) } }
            if (try? ensureCurrent(gen)) != nil { settingsSyncProblem = nil }
        } catch VaultError.readOnly {
            settingsSyncProblem = .readOnly
        } catch VaultError.untrustedRecipients {
            settingsSyncProblem = .untrustedRecipients
        } catch {
            settingsSyncProblem = .failed(String(describing: error))
        }
    }

    /// This device's values of the settings it uses (`SettingsSyncBridge`).
    func currentSettingsValues(includingCaptureProfile: Bool = true) -> [String: JSONValue] {
        var extras = SettingsSyncBridge.Extras()
        if let vault {
            extras.backupReminderDays = backupStore.record(for: vault.vaultId).reminderDays
            if includingCaptureProfile, let stored = quickCaptureProfile, stored.profile.vaultId == vault.vaultId {
                extras.quickCapture = (stored.profile.notebook, stored.transcribe)
            }
        }
        if AppIconSettingsSection.isSupported {
            extras.appIcon = AppIconChoice(alternateName: UIApplication.shared.alternateIconName).rawValue
        }
        return SettingsSyncBridge.values(for: settingsDeviceType, defaults: settingsDefaults, extras: extras)
    }

    /// Writes values from the vault on this device.
    func applySharedSettings(_ values: [String: JSONValue]) {
        guard !values.isEmpty else { return }
        let forModel = SettingsSyncBridge.apply(values, defaults: settingsDefaults)
        let standard = settingsDefaults === UserDefaults.standard
        for (key, value) in forModel {
            switch (key, value) {
            case ("handwriting.recognize", .bool(let on)):
                if standard { setHandwritingRecognition(on) } else { settingsDefaults.set(on, forKey: RecognitionPreference.key) }
            case ("search.transcripts", .bool(let on)):
                if standard { setSearchTranscripts(on) } else { settingsDefaults.set(on, forKey: TranscriptSearchPreference.key) }
            case ("backup.reminderDays", .number(let days)):
                let n = Int(days)
                Task { await self.setBackupReminder(days: n) }
            case ("quickCapture.notebook", .string(let name)):
                updateCaptureProfile { $0.profile.notebook = NoteOps.normalizedNotebook(name) ?? CaptureProfile.defaultNotebook }
            case ("quickCapture.transcribe", .bool(let on)):
                updateCaptureProfile { $0.transcribe = on }
            case ("appearance.icon", .string(let name)):
                // iOS tells the user the icon changed; a failure leaves the current icon.
                if AppIconSettingsSection.isSupported, let choice = AppIconChoice(rawValue: name),
                   choice != AppIconChoice(alternateName: UIApplication.shared.alternateIconName) {
                    UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
                        if let error { settingsLog.error("icon not changed: \(error.localizedDescription, privacy: .public)") }
                    }
                }
            default:
                break
            }
        }
        settingsAppliedRevision += 1
    }

    private func updateCaptureProfile(_ change: (inout StoredCaptureProfile) -> Void) {
        guard let vault, var stored = quickCaptureProfile, stored.profile.vaultId == vault.vaultId else { return }
        change(&stored)
        do {
            try quickCapture.store.save(stored)
            quickCapture.publishStatus()
        } catch {
            settingsLog.error("quick capture profile not updated: \(String(describing: error), privacy: .public)")
        }
    }
}
