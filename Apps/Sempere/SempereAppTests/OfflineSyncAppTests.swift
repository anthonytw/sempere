import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// What the app says and does when a device is offline for a long time or never online (the offline audits): an
/// unplugged drive is offline, not gone (A-P2); a run cut short after progress is no failure (P4); a clock far off
/// names the clock (P14); files iCloud has not uploaded are not "synced" (P15); and the wording of the device list
/// for mostly-offline devices (P9, P10) and of removals a takeover undid (P16).
@MainActor
struct OfflineSyncAppTests {
    // MARK: A-P2: a drive that is not connected

    /// Review of #91, M2: a folder target whose bookmark no longer resolves is unavailable (offline) only when the
    /// removable volume it was on is not mounted; a folder deleted together with the folder it was in, on a disk
    /// that is there, is gone (choose it again, review of #72, G5).
    @Test func aTargetOnAnUnmountedVolumeIsOfflineNotGone() throws {
        let absent = "/Volumes/Sempere-absent-\(UUID().uuidString)"
        var target = SyncTarget.folder(URL(fileURLWithPath: absent + "/Sync/Notes.sempere"), bookmark: Data("not a bookmark".utf8),
                                       subfolder: "Notes.sempere")
        target.path = absent + "/Sync/Notes.sempere"
        do { _ = try FolderTargetAccess.open(target, bookmarks: SecurityScopedBookmarks()); Issue.record("opened") } catch let e as FolderTargetError {
            guard case .unavailable = e else { Issue.record("\(e)"); return }
        }
        let status = SyncStatus(syncing: false, problems: [SyncStatus.problem(from: FolderTargetError.unavailable("x"))],
                                unconfirmed: 2, arriving: 0, twoWay: true, lastSuccess: nil, folder: true)
        #expect(status.kind == .offline)
        #expect(!status.needsAttention)
        #expect(!status.headline.contains("Choose it again"))
        #expect(status.headline.contains("Sync Now connects it"), "an unmounted share: Sync Now mounts it")
    }

    @Test func aFolderDeletedWithItsParentIsGoneNotOffline() throws {
        let disk = try TestTemp.directory("disk")
        let parent = disk.appendingPathComponent("Sync", isDirectory: true)
        let picked = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let bookmark = try picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var target = SyncTarget.folder(picked, bookmark: bookmark)
        target.path = nil   // only the bookmark knows where it was
        try FileManager.default.removeItem(at: parent)   // the folder and the one it was in
        do { _ = try FolderTargetAccess.open(target, bookmarks: SecurityScopedBookmarks()); Issue.record("opened") } catch let e as FolderTargetError {
            guard case .missing = e else { Issue.record("\(e)"); return }
        }
    }

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


    // MARK: P14: a clock far off

    /// The app's half: the trust check's codes and the words (the classification is `SyncProblemsTests`).
    @Test func certificateDateErrorsNameTheClock() {
        #expect(PinnedServerTrust.isDateProblem(CFIndex(errSecCertificateExpired)))
        #expect(PinnedServerTrust.isDateProblem(CFIndex(errSecCertificateNotValidYet)))
        #expect(!PinnedServerTrust.isDateProblem(CFIndex(errSecNotTrusted)))
        #expect(SyncStatus.text(for: .certificateDate) == CertificateDate.reason)
        #expect(CertificateDate.reason.contains("date and time"))
        // Typed, never by words (review of #91, S6): a server message that mentions dates is not one.
        #expect(!SyncStatus.text(for: .certificate("check the date and time")).contains("this device's date"))
        // The trust check's refusal, and the system's codes, are the date problem.
        #expect(SyncStatus.problem(from: WebDAVError.untrustedCertificate(CertificateDate.refusal)) == .certificateDate)
        #expect(SyncStatus.problem(from: URLError(.serverCertificateHasBadDate)) == .certificateDate)
        #expect(SyncStatus.problem(from: URLError(.serverCertificateNotYetValid)) == .certificateDate)
        #expect(WebDAVErrorText.message(WebDAVError.untrustedCertificate(CertificateDate.refusal)).contains(CertificateDate.marker) == false)
    }

    // MARK: P15: written into iCloud Drive, not uploaded

    /// The bar's words for a provider's upload error (`ProviderUploads.State`, SempereSync; the record itself is
    /// tested in `ProviderUploadsTests`): a full iCloud storage in plain words, a problem the user sees.
    @Test func aProvidersUploadErrorIsWordedAsAProblem() throws {
        let full = ProviderUploads.State.failed(code: CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue,
                                                domain: NSCocoaErrorDomain, message: "full")
        let text = try #require(ProviderUploads.errorText(full))
        #expect(text.contains("storage may be full"))
        let other = ProviderUploads.State.failed(code: 1, domain: "provider", message: "the provider's words")
        #expect(ProviderUploads.errorText(other)?.contains("the provider's words") == true)
        #expect(ProviderUploads.errorText(.waiting) == nil)
        // The library's numbers are the system's codes.
        #expect(ProviderUploads.State.failed(code: CocoaError.Code.fileWriteOutOfSpace.rawValue, domain: NSCocoaErrorDomain,
                                             message: "").isStorageUnavailable)
        let status = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: Date(),
                                folder: true, providerPending: 1, viaICloud: true, providerError: full)
        #expect(status.headline == text)
    }

    /// The bar's words while files wait for iCloud (the session's behavior is `SyncSessionTests`): never "Synced".
    @Test func aFolderInICloudNeverSaysSyncedWhileUploadsWait() {
        let status = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: Date(),
                                folder: true, providerPending: 3, viaICloud: true)
        #expect(status.headline == "3 changes waiting for iCloud to upload")
        #expect(!status.headline.contains("Synced"))
    }

    /// The unlisted screen's "changes no target holds" counts a file a folder target holds only in iCloud Drive's
    /// local folder (not uploaded yet) as not held.
    @Test func filesWaitingForICloudAreNotHeldForTheUnlistedCount() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try ListAlertTests.trustedFixture(trust)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        model.writeStores = DeviceWriteStores.inMemoryKey(root: try TestTemp.directory("ledger"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        defer { model.close() }
        let id = try await model.createNote(title: "Offline", paper: Paper(kind: .ruled), notebook: nil)
        let vault = try #require(model.vault)
        let mine = try #require(vault.ledger).entries().map(\.path).filter { $0.contains(id.uuidString.lowercased()) }
        #expect(!mine.isEmpty)

        let drive = try TestTemp.directory("icloud")
        let folder = drive.appendingPathComponent("Notes.sempere", isDirectory: true)
        let stateDir = try TestTemp.directory("icloud-state")
        let state = stateDir.appendingPathComponent("state.json")
        _ = try FolderTargetRun.run(vaultFolder: url, folder: folder, vault: vault, stateURL: state, twoWay: true)
        let target = (state: state, directory: stateDir)
        #expect(try ProviderUploads.unsyncedPaths(vault: vault, targets: [target]).filter { mine.contains($0) }.isEmpty,
                "held by the target")
        ProviderUploads.update(folder: folder, stateDirectory: stateDir, written: mine, check: { _ in .waiting })
        #expect(Set(try ProviderUploads.unsyncedPaths(vault: vault, targets: [target])).isSuperset(of: mine),
                "written locally only: held by no target yet")
        // A truncated record (more than the limit waited) holds nothing at all.
        ProviderUploads.save(ProviderUploads.Record(paths: [], truncated: true), in: stateDir)
        #expect(Set(try ProviderUploads.unsyncedPaths(vault: vault, targets: [target]))
                == Set(try UnsyncedChanges.paths(vault: vault, stateURLs: [])))
        #expect(try ProviderUploads.unsyncedPaths(vault: vault, targets: []).count
                == (try UnsyncedChanges.paths(vault: vault, stateURLs: [])).count)
    }

    // MARK: P9, P10: wording

    @Test func theRemovalSheetIsNeutralAboutAMostlyOfflineDevice() {
        for (last, change) in [(Date(timeIntervalSinceNow: -86_400 * 9), nil), (nil, Date(timeIntervalSinceNow: -86_400)), (nil, nil)] as [(Date?, Date?)] {
            let text = RemoveDeviceSheet.staleText("iPad", lastSynced: last, sinceChange: change)
            #expect(!text.contains("will not reach"))
            #expect(text.contains("not here yet"))
        }
    }

    @Test func theHeldBackBannerDatesTheWaitNotTheLastSync() {
        let text = DeviceNotice.heldBack(since: Date(timeIntervalSince1970: 1_800_000_000)).text
        #expect(text.hasPrefix("Since "))
        #expect(!text.contains("hasn't synced since"))
    }

    // MARK: P16: removals a takeover undid (the engine's record, `UndoneRemovalsRecord`)

    @Test func removalsATakeoverUndidAreNamedWhileListed() async throws {
        let trust = MemoryEpochTrustStore()
        let (url, keyText) = try ListAlertTests.trustedFixture(trust)
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: trust)
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        defer { model.close() }
        #expect(model.deviceNotices.isEmpty, "no record of undone removals: none")
        let vault = try #require(model.vault)
        let listed = try #require(vault.manifest.devices.first { $0.id != nil })
        model.undoneRemovalsSource = { _ in
            [UndoneRemoval(id: listed.id ?? "", name: "Lost iPhone"), UndoneRemoval(id: "ffffffff", name: "Already gone")]
        }
        #expect(model.undoneRemovals.map(\.name) == ["Lost iPhone"], "only devices still on the list")
        #expect(model.deviceNotices == [.removalsUndone(names: ["Lost iPhone"], home: vault.isHome)])
        let notice = DeviceNotice.removalsUndone(names: ["Lost iPhone"], home: true)
        #expect(notice.text.contains("Lost iPhone"))
        #expect(DeviceNotice.removalsUndone(names: ["Lost iPhone"], home: false).text.contains("ask the device that manages devices"))
    }
}
