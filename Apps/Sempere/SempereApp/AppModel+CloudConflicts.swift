import Foundation
import Sempere

/// iCloud Drive conflicts on the open vault's own files, resolved by the app
/// so the system never asks the user to pick a version (`CloudConflicts`,
/// docs/io.md "Conflicting versions").
extension AppModel {
    /// One resolving pass over the open iCloud vault, off the main actor. Notes
    /// another version brought back are read by the next pass; merged settings
    /// are applied; an item no rule can merge shows in the list's bar.
    /// Run before every full pass of the sync loop.
    func resolveCloudConflicts() async {
        guard isCloudVault, webdavFetcher == nil, let vault else { return }
        let gen = generation
        let hooks = cloudHooks
        let coordinate = coordinationURL
        let outcome: CloudConflicts.Outcome
        do {
            outcome = try await offMain(priority: .utility) {
                try CloudConflicts.resolve(vault: vault, hooks: hooks) { body in
                    try CloudVault.coordinatedWrite(coordinate) { try body() }
                }
            }
        } catch {
            guard generation == gen else { return }
            cloudSync?.problem = cloudSource.problem("\(error)")
            return
        }
        guard generation == gen else { return }
        lastConflictOutcome = outcome
        if !outcome.isEmpty {
            Perf.event(.conflicts, "resolved=\(outcome.resolved.count) notes=\(outcome.notes.count) "
                       + "waiting=\(outcome.waitingForKey.count) unresolved=\(outcome.unresolved.count)")
        }
        if !outcome.notes.isEmpty { reportedNoteIDs.formUnion(outcome.notes) }
        if outcome.settingsChanged, phase == .unlocked { scheduleSettingsSync() }
        conflictProblem = outcome.unresolved.keys.sorted().first.map { name in
            String(localized: "iCloud Drive holds two versions of “\(name)” that Sempere cannot merge (both devices changed the vault's keys). The version on this device is used.",
                   comment: "%@ is a vault file name such as vault.json")
        }
        if let conflictProblem { cloudSync?.problem = conflictProblem }
    }
}
