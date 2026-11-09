import Foundation
import Sempere
@testable import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

extension AppModelSuites {
    /// What the app says and does when a device is offline for a long time or never online (the offline audits): an
    /// unplugged drive is offline, not gone (A-P2); a run cut short after progress is no failure (P4); a clock far off
    /// names the clock (P14); files iCloud has not uploaded are not "synced" (P15); and the wording of the device list
    /// for mostly-offline devices (P9, P10) and of removals a takeover undid (P16).
    @MainActor
    struct OfflineSyncAppTests {

        // MARK: P4: a run cut short after progress

        /// The engine's own stops, from real runs (so a change in how it classifies them fails here): a copy that lacks the
        /// notes pulls them from a folder, stopped by a cancel, by the time bound (`maxDuration` 0) and by a server bound
        /// (`maxEntries` 1). A stop thrown before the run could report is classified as the engine does
        /// (`SyncReport.StopReason(_:limits:)`).
        static func engineStops() throws -> (cancel: SyncReport, time: SyncReport, entries: SyncReport) {
            let (vault, keyURL) = try AppModelTests.fixtureVault()
            let keys = try DeviceKeys.parse(try String(contentsOf: keyURL, encoding: .utf8))
            let v = try Vault.open(at: vault, identities: [keys.nativeIdentity], signing: keys.signing)
            let folder = try TestTemp.directory("stop").appendingPathComponent("Notes.sempere", isDirectory: true)
            _ = try FolderTargetRun.run(vaultFolder: vault, folder: folder, vault: v,
                                        stateURL: try TestTemp.directory("stop-a").appendingPathComponent("state.json"), twoWay: true)
            func stop(_ configure: (inout SyncOptions) -> Void) throws -> SyncReport {
                // Another device's copy without the notes: its run downloads them.
                let copy = try TestTemp.directory("stop-copy").appendingPathComponent("Copy.sempere", isDirectory: true)
                try FileManager.default.copyItem(at: vault, to: copy)
                try FileManager.default.removeItem(at: copy.appendingPathComponent("notes"))
                let c = try Vault.open(at: copy, identities: [keys.nativeIdentity], signing: keys.signing)
                var options = SyncOptions(deviceLabel: "test")
                configure(&options)
                do {
                    let report = try FolderTargetRun.run(vaultFolder: copy, folder: folder, vault: c,
                                                         stateURL: try TestTemp.directory("stop-b").appendingPathComponent("state.json"),
                                                         twoWay: true, options: options)
                    _ = try #require(report.stoppedEarly, "the run was not stopped: \(report.errors) down=\(report.downloaded.count)")
                    return report
                } catch {
                    var r = SyncReport()
                    r.stoppedEarly = SyncEngine.describe(error)
                    r.stopReason = SyncReport.StopReason(error, limits: options.limits)
                    r.errors = [.init(path: "notes", message: SyncEngine.describe(error),
                                      kind: r.stopReason?.isProgressStop == true ? .stopped : nil)]
                    return r
                }
            }
            return (try stop { $0.isCancelled = { true } },
                    try stop { $0.limits.maxDuration = 0 },
                    try stop { $0.limits.maxEntries = 1 })
        }

        /// `stop` as if it had moved files first (or not).
        nonisolated static func cutReport(_ stop: SyncReport, progress: Bool) -> SyncReport {
            var r = stop
            r.uploaded = progress ? ["notes/a/1.delta.age", "notes/a/2.delta.age"] : []
            r.downloaded = []
            r.deleted = []
            return r
        }

        @Test func aCutRunThatMadeProgressIsNotAFailure() async throws {
            let stops = try Self.engineStops()
            #expect(stops.cancel.stopReason == .cancelled)
            #expect(stops.time.stopReason == .timeLimit, "the engine classifies its time bound")
            #expect(stops.entries.stopReason == .bound)
            for stop in [stops.cancel, stops.time] {
                #expect(SyncSession.progressedCutShort(Self.cutReport(stop, progress: true))?.lastingErrors.isEmpty == true)
                #expect(SyncSession.progressedCutShort(Self.cutReport(stop, progress: false)) == nil, "no progress: still a failure")
            }
            var other = Self.cutReport(stops.cancel, progress: true)
            other.errors.append(.init(path: "notes/b", message: "refused"))
            #expect(SyncSession.progressedCutShort(other)?.errors.map(\.path) == ["notes/b"], "real errors stay")

            let report = Self.cutReport(stops.cancel, progress: true)
            let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                      run: { _ in report }, countUnconfirmed: { 0 })
            session.vaultUnlocked()
            _ = await session.syncNow()
            #expect(session.problems.isEmpty)
            #expect(!session.needsAttention)
            #expect(session.status.kind == .continuing)
            #expect(session.schedule.failures == 0, "no backoff")
            #expect(session.lastSuccess == nil, "only a complete run is a last sync")
            session.stop()
        }

        /// Review of #91, M1: a server bound (here `maxEntries`) that stops a run after it moved files is a failure: shown
        /// and backed off, never a silent run every 30 s.
        @Test func aServerBoundStopIsAFailureThatBacksOff() async throws {
            let stops = try Self.engineStops()
            let report = Self.cutReport(stops.entries, progress: true)
            #expect(SyncSession.progressedCutShort(report) == nil)
            #expect(!report.outcome.success, "the engine's outcome agrees")
            let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                      run: { _ in report }, countUnconfirmed: { 0 })
            session.vaultUnlocked()
            _ = await session.syncNow()
            #expect(session.needsAttention)
            #expect(session.status.kind != .continuing)
            #expect(session.schedule.failures == 1)
            #expect(session.schedule.retryDelay > 0)
            session.stop()
        }
    }
}
