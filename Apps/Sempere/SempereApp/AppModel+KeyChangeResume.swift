import Age
import Foundation
import Sempere

/// What the "finish key change" screen shows: the vault's last key change
/// (format.md §3.3.1) was interrupted, and nothing else of the vault is
/// usable until it is finished.
struct KeyChangeResume: Equatable {
    enum Step: Equatable {
        /// Waiting for the user to start.
        case ready
        /// Working; the text says on what.
        case running(String)
        /// Stopped with this reason. Starting again resumes where it stopped.
        case failed(String)
    }

    var step: Step = .ready

    var isRunning: Bool { if case .running = step { return true } else { return false } }
}

/// Finishing an interrupted key change in the app, through the library
/// (`Vault.resumeRewrap`), with the keys the vault was unlocked with.
extension AppModel {
    /// Errors of finishing a key change, for the screen.
    enum KeyChangeError: Error, Equatable, CustomStringConvertible {
        case notFinishing
        /// Some files could not be re-encrypted (yet): the change stays pending.
        case incomplete(Int)

        var description: String {
            switch self {
            case .notFinishing: return String(localized: "No interrupted key change is being finished.")
            case .incomplete(let n):
                return String(localized: "\(n) files could not be re-encrypted. If this vault is in iCloud Drive, wait until it has downloaded and try again; otherwise unlock it with every key it was encrypted to before the change and try again.",
                              comment: "Finishing an interrupted key change")
            }
        }
    }

    /// Finishes the interrupted key change, then opens the vault normally.
    /// On failure the screen shows why (`step`) and calling again resumes.
    func finishKeyChange() async throws {
        guard phase == .finishingKeyChange, let start = vault, var plan = keyChangeResume, !plan.isRunning else {
            throw KeyChangeError.notFinishing
        }
        try requireLocalKeyChanges()   // a WebDAV copy: the rewrap would never reach the server
        let gen = generation
        let coordinate = coordinationURL
        let url = start.url
        var current = start
        func show(_ text: String) {
            plan.step = .running(text)
            keyChangeResume = plan
        }
        do {
            if isCloudVault {
                show(String(localized: "Downloading every note from iCloud Drive…"))
                try await downloadEverything(url, gen: gen) { text in show(text) }
            }
            if current.pendingRewrap, current.journalRefused {
                // Not this vault's change (format.md §3.3.1): nothing to finish, it only blocks the next one.
                let v = current
                current = try await offMain {
                    try CloudVault.coordinatedWrite(coordinate) { () throws -> Vault in
                        var copy = v
                        try copy.discardRefusedJournal()
                        return copy
                    }
                }
                try ensureCurrent(gen)
                replaceResumingVault(current)
            } else if current.pendingRewrap {
                show(String(localized: "Finishing the interrupted key change…"))
                current = try await rewrap(current, gen: gen) { try $0.resumeRewrap() }
            }
            show(String(localized: "Opening the vault…"))
            let identities = unlockIdentities
            let trust = recipientsTrust
            let reopened = try await offMain {
                try CloudVault.coordinatedRead(coordinate) { try Vault.open(at: url, identities: identities, trust: trust) }
            }
            try ensureCurrent(gen)
            guard !reopened.pendingRewrap else { throw KeyChangeError.incomplete(0) }
            try await finishUnlock(reopened, identities: identities)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if gen == generation {
                plan.step = .failed("\(error)")
                keyChangeResume = plan
            }
            throw error
        }
    }

    /// One rewrap through the library, coordinated in iCloud Drive; the
    /// vault is updated even when files remain (the change stays pending and
    /// the next attempt resumes it).
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
        replaceResumingVault(next)
        guard report.isComplete else { throw KeyChangeError.incomplete(report.failures.count) }
        return next
    }
}
