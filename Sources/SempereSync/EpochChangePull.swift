import Foundation
import Sempere

/// The remover's best-effort pull (docs/design/key-hierarchy.md §5.2 step 2; KH4): before a device change
/// (a removal, a handoff, a kit replacement, a takeover), a download-only pass on every target the device can
/// reach within a short bound, placing what verifies, so the change seals as much as it can. A target that
/// cannot be reached is reported, never waited for: files there are caught up by their writers (their
/// ledgers live until sealed, §5.4), which is why the bound is only a quality knob.
///
/// Each pass is a pull-only run (`SyncOptions.pullOnly`: nothing reaches the target) with a fresh, throwaway
/// sync state, so it is a union that deletes nothing and records nothing about the target.
public enum EpochChangePull {
    /// 10 seconds per target (design §5.2 step 2).
    public static let defaultBound: TimeInterval = 10

    /// One target to pull from.
    public struct Target: Sendable {
        public var name: String
        public var remote: any SyncRemote
        /// Where files that fail their checks go (the target's own quarantine); nil: beside the throwaway state.
        public var quarantine: URL?

        public init(name: String, remote: any SyncRemote, quarantine: URL? = nil) {
            self.name = name; self.remote = remote; self.quarantine = quarantine
        }
    }

    /// What one pass did.
    public struct Outcome: Sendable {
        public var target: String
        /// The pass's report; nil when the target could not be reached.
        public var report: SyncReport?
        /// Why the target could not be reached (or the pass stopped).
        public var error: String?

        /// True when the pass ran to its end.
        public var reached: Bool { report != nil && report?.stoppedEarly == nil }
    }

    /// Pulls from each of `targets` into the working copy `folder` of `vault` (opened with its device key), one
    /// after the other, each bounded by `bound` seconds and `isCancelled`. `scratch` holds the throwaway states.
    public static func run(vault: Vault, folder: URL, targets: [Target], scratch: URL, bound: TimeInterval = defaultBound,
                           options base: SyncOptions = SyncOptions(),
                           isCancelled: (@Sendable () -> Bool)? = nil) -> [Outcome] {
        targets.map { t in
            let state = scratch.appendingPathComponent("pull-\(UUID().uuidString.lowercased()).json")
            defer {
                try? FileManager.default.removeItem(at: state)
                SyncState.removeTransfers(state)
                if t.quarantine == nil {
                    try? FileManager.default.removeItem(at: state.deletingPathExtension().appendingPathExtension("quarantine"))
                }
            }
            var o = base
            o.pullOnly = true
            o.pushOnly = false
            o.dryRun = false
            o.deleteExtraneous = false
            o.publishForWebViewer = false
            o.publishSummaries = false
            o.limits.maxDuration = bound
            o.arrivalWait = min(o.arrivalWait, bound / 2)
            o.isCancelled = isCancelled
            if let q = t.quarantine { o.quarantineDirectory = q }
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let report = try SyncEngine(directory: folder, vault: vault, remote: t.remote, stateURL: state, options: o).run()
                return Outcome(target: t.name, report: report, error: report.stoppedEarly)
            } catch {
                return Outcome(target: t.name, report: nil, error: SyncEngine.describe(error))
            }
        }
    }
}
