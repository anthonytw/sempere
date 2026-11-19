import Foundation
import Sempere

/// A change to the palette's saved tools (docs/design/1.3-custom-tools.md).
public enum SavedToolChange: Sendable {
    case add(SavedTool)
    /// Rewrites the tool with the same id.
    case update(SavedTool)
    case remove(String)
    case move(String, SavedToolList.Destination)
    /// Replaces every saved tool with this list (Settings ▸ Writing ▸ Saved Tools ▸ Replace the Vault's).
    case replaceAll(SavedToolList)
}

/// What a change did.
public enum SavedToolsOutcome: Equatable, Sendable {
    case done
    /// Refused: a value that is not valid, or the 64th-plus tool.
    case refused(SavedToolError)
    /// Not saved: the vault's settings cannot be written now (read-only, untrusted list, a newer app is needed), the same
    /// reasons as settings sync. With sync off nothing is ever paused.
    case paused(SettingsSyncProblem)
}

/// Saved tools (docs/design/1.3-custom-tools.md §3.3): with Sync Settings with This Vault off the device's own list
/// (`services.settings`, `savedToolsKey`); on, the open vault's (the shared settings' `palette.tool.*`). The rules are
/// `SavedToolList`'s (Sempere), which `sempere tools` shares.
extension AppModelCore {
    /// Where the device's list is kept in `services.settings`.
    public nonisolated static var savedToolsKey: String { "Sempere.savedTools" }

    /// This device's own list (the one shown with sync off).
    public var localSavedTools: SavedToolList {
        SavedToolList(decoding: services.settings.data(forKey: Self.savedToolsKey))
    }

    /// Whether the palette shows the open vault's tools (sync on) rather than this device's.
    public var savedToolsFollowVault: Bool { settingsSync.enabled && vault != nil && phase == .unlocked }

    /// Shows the right list: the vault's `file` when sync is on (a pass has just read it; none: no tools), else the device's.
    func refreshSavedTools(file: SharedSettings? = nil) {
        if savedToolsFollowVault {
            savedTools = file.map(SavedToolList.init(settings:)) ?? SavedToolList()
        } else {
            savedTools = localSavedTools
        }
    }

    /// Applies `change`: to the vault's settings (merged with what other devices wrote, under the vault's write lock) when
    /// sync is on, else to this device's list.
    @discardableResult
    public func changeSavedTools(_ change: SavedToolChange) async -> SavedToolsOutcome {
        guard savedToolsFollowVault, let vault else { return changeLocalSavedTools(change) }
        // A list that does not check is said as such, before the read-only state it also causes.
        if listAlert != nil || listProblem != nil { settingsSyncProblem = .untrustedRecipients; return .paused(.untrustedRecipients) }
        if isVaultReadOnly { settingsSyncProblem = .readOnly; return .paused(.readOnly) }
        let type = settingsDeviceType
        let lock = vaultWriteLock
        let gen = generation
        do {
            let written = try await offMain { () throws -> SharedSettings in
                try Self.withWriteLock(lock) {
                    try vault.updateSharedSettings { s in try Self.apply(change, to: &s, type: type) }
                }
            }
            guard (try? ensureCurrent(gen)) != nil else { return .done }
            savedTools = SavedToolList(settings: written)
            return .done
        } catch let e as SavedToolError {
            return .refused(e)
        } catch SharedSettingsError.needsNewerReader {
            settingsSyncProblem = .needsNewerApp
            return .paused(.needsNewerApp)
        } catch VaultError.readOnly {
            settingsSyncProblem = .readOnly
            return .paused(.readOnly)
        } catch VaultError.untrustedList {
            settingsSyncProblem = .untrustedRecipients
            return .paused(.untrustedRecipients)
        } catch {
            let problem = SettingsSyncProblem.failed(services.describeError(error))
            settingsSyncProblem = problem
            return .paused(problem)
        }
    }

    private func changeLocalSavedTools(_ change: SavedToolChange) -> SavedToolsOutcome {
        var list = localSavedTools
        do {
            switch change {
            case .add(let t): try list.add(t)
            case .update(let t): try list.update(t)
            case .remove(let id): list.remove(id: id)
            case .move(let id, let to): try list.move(id: id, to: to)
            case .replaceAll(let all): list = all
            }
        } catch let e as SavedToolError {
            return .refused(e)
        } catch {
            return .refused(.invalid("\(error)"))
        }
        services.settings.set(list.encoded(), forKey: Self.savedToolsKey)
        savedTools = list
        return .done
    }

    nonisolated static func apply(_ change: SavedToolChange, to settings: inout SharedSettings, type: SettingsDeviceType) throws {
        let now = Date()
        switch change {
        case .add(let t): try SavedToolList.add(t, to: &settings, type: type, now: now)
        case .update(let t): try SavedToolList.update(t, in: &settings, type: type, now: now)
        case .remove(let id): try SavedToolList.remove(id: id, from: &settings, type: type, now: now)
        case .move(let id, let to): try SavedToolList.move(id: id, to: to, in: &settings, type: type, now: now)
        case .replaceAll(let list):
            let live = settings.slots.filter { $0.key.block == nil && $0.key.key.hasPrefix(SavedTool.keyPrefix) && $0.value.value != nil }
            for slot in live.keys { try settings.set(slot, to: nil, type: type, now: now) }
            try list.seed(into: &settings, type: type, now: now)
        }
    }

    /// Sync was just turned on (docs/design/1.3-custom-tools.md §3.3): the saved tools count as one setting. A vault with
    /// none (not even a deleted one) takes this device's list; a vault with some keeps them, and this device's list stays
    /// on the device (Settings ▸ Writing ▸ Saved Tools can replace the vault's with it).
    func adoptSavedToolsAfterEnabling() async {
        guard savedToolsFollowVault, let vault else { return }
        let file = try? await offMain { try vault.readSharedSettings() }
        let local = localSavedTools
        if !SavedToolList.hasSlots(in: file ?? SharedSettings()), !local.isEmpty {
            await changeSavedTools(.replaceAll(local))
        } else if let file {
            refreshSavedTools(file: file)
        }
    }

    /// "Replace the Vault's Saved Tools with This Device's": the vault's list becomes this device's own list.
    @discardableResult
    public func replaceVaultSavedToolsWithLocal() async -> SavedToolsOutcome {
        guard savedToolsFollowVault else { return .done }
        return await changeSavedTools(.replaceAll(localSavedTools))
    }
}
