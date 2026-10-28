import Foundation
import Sempere
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
        do { _ = try FolderTargetAccess.open(target); Issue.record("opened") } catch let e as FolderTargetError {
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
        do { _ = try FolderTargetAccess.open(target); Issue.record("opened") } catch let e as FolderTargetError {
            guard case .missing = e else { Issue.record("\(e)"); return }
        }
    }

    @Test func removableRootsAreVolumesAndLiveFiles() throws {
        #expect(FolderReach.removableRoot(of: "/Volumes/USB/Sync/Notes") == "/Volumes/USB")
        #expect(FolderReach.removableRoot(of: "/Volumes/USB") == "/Volumes/USB")
        let ios = "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB/Sync"
        #expect(FolderReach.removableRoot(of: ios) == "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB")
        #expect(FolderReach.removableRoot(of: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Sync") == nil)
        #expect(FolderReach.isOnAbsentDrive("/Volumes/Sempere-not-there-\(UUID().uuidString)/Sync"))
        let here = try TestTemp.directory("present")
        #expect(!FolderReach.isOnAbsentDrive(here.appendingPathComponent("gone/deeper").path), "not a removable volume: gone")
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

    /// Review of #90, N1: the path monitor's return reaches the engine, so a provider's late file is not counted as
    /// stalled for the time the device had no network (offline audit P5).
    @Test func theNetworksReturnReachesTheRun() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Date?] = []
            func add(_ d: Date?) { lock.lock(); values.append(d); lock.unlock() }
            var all: [Date?] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let seen = Seen()
        let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                  run: { request in
                                      var o = SyncOptions()
                                      request.apply(to: &o)
                                      seen.add(o.networkReturned)
                                      return SyncReport()
                                  }, countUnconfirmed: { 0 })
        let back = Date(timeIntervalSince1970: 1_900_000_000)
        session.now = { back }
        session.vaultUnlocked()
        _ = await session.syncNow()
        session.networkChanged(reachable: false)
        session.networkChanged(reachable: true)
        _ = await session.syncNow()
        #expect(seen.all.first == .some(nil), "never away: nothing to leave out")
        #expect(seen.all.last == .some(back))
        session.stop()
    }

    // MARK: P14: a clock far off

    @Test func certificateDateErrorsNameTheClock() {
        #expect(PinnedServerTrust.isDateProblem(CFIndex(errSecCertificateExpired)))
        #expect(PinnedServerTrust.isDateProblem(CFIndex(errSecCertificateNotValidYet)))
        #expect(!PinnedServerTrust.isDateProblem(CFIndex(errSecNotTrusted)))
        #expect(SyncStatus.text(for: .certificate(CertificateDate.refusal)) == CertificateDate.reason)
        #expect(CertificateDate.reason.contains("date and time"))
        // Typed, never by words (review of #91, S6): a server message that mentions dates is not one.
        #expect(!SyncStatus.text(for: .certificate("check the date and time")).contains("this device's date"))
        #expect(SyncStatus.problem(from: URLError(.serverCertificateHasBadDate)) == .certificate(CertificateDate.refusal))
        #expect(SyncStatus.problem(from: URLError(.serverCertificateNotYetValid)) == .certificate(CertificateDate.refusal))
        #expect(WebDAVErrorText.message(WebDAVError.untrustedCertificate(CertificateDate.refusal)).contains(CertificateDate.marker) == false)
    }

    // MARK: P15: written into iCloud Drive, not uploaded

    @Test func filesTheProviderHasNotUploadedAreCountedAndDropOnceUploaded() throws {
        let dir = try TestTemp.directory("provider-state")
        let folder = try TestTemp.directory("provider-folder")
        let uploaded = Set(["notes/a/1.delta.age"])
        let check: ProviderUploads.Check = { url in
            let path = url.path
            if path.hasSuffix("local.age") { return nil }   // not a provider's file
            return uploaded.contains { path.hasSuffix($0) } ? .uploaded : .waiting
        }
        let n = ProviderUploads.update(folder: folder, stateDirectory: dir, written: [
            "notes/a/1.delta.age", "notes/a/2.delta.age", "inbox/c.capture.age", "local.age"], check: check)
        #expect(n.count == 2 && !n.truncated && n.error == nil)
        #expect(Set(ProviderUploads.pending(in: dir)) == ["notes/a/2.delta.age", "inbox/c.capture.age"])
        // A later run asks again: everything is up now, and the file goes.
        #expect(ProviderUploads.update(folder: folder, stateDirectory: dir, written: [], check: { _ in .uploaded }).count == 0)
        #expect(!FileManager.default.fileExists(atPath: ProviderUploads.url(in: dir).path))
    }

    /// Review of #91, S3: past the limit the record says truncated; a run that never recorded what it wrote (it
    /// threw, or the app was killed) makes the next look at the whole folder; an upload error is a visible problem.
    @Test func providerUploadsSurviveOverflowInterruptionAndErrors() throws {
        let dir = try TestTemp.directory("provider-state")
        let folder = try TestTemp.directory("provider-folder")
        let many = (0...ProviderUploads.limit).map { "notes/n/\($0).delta.age" }
        let waiting: ProviderUploads.Check = { _ in .waiting }
        let big = ProviderUploads.update(folder: folder, stateDirectory: dir, written: many, check: waiting)
        #expect(big.count == ProviderUploads.limit && big.truncated)
        _ = ProviderUploads.update(folder: folder, stateDirectory: dir, written: [], check: { _ in .uploaded })

        // A run marked in flight that never recorded its report: the next run rescans the folder.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes/x"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("notes/x/1.delta.age"))
        #expect(!ProviderUploads.begin(stateDirectory: dir), "nothing interrupted yet")
        // (the run throws here: no update)
        #expect(ProviderUploads.begin(stateDirectory: dir), "the last run never recorded its files")
        let rescanned = ProviderUploads.update(folder: folder, stateDirectory: dir, written: [], rescan: true, check: waiting)
        #expect(ProviderUploads.pending(in: dir) == ["notes/x/1.delta.age"], "\(rescanned)")
        // A rescan that stops at its cap says so: the record is then truncated, never taken as complete.
        try Data([2]).write(to: folder.appendingPathComponent("notes/x/2.delta.age"))
        #expect(ProviderUploads.files(below: folder, cap: 1).capped)
        #expect(!ProviderUploads.files(below: folder, cap: 5).capped)
        #expect(ProviderUploads.files(below: folder, cap: 5).paths.count == 2)

        // iCloud refusing to upload (its storage full): a problem the user sees.
        let full = ProviderUploads.State.failed(code: CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue,
                                                domain: NSCocoaErrorDomain, message: "full")
        let failing = ProviderUploads.update(folder: folder, stateDirectory: dir, written: ["notes/x/1.delta.age"], check: { _ in full })
        #expect(failing.error == full)
        let text = try #require(ProviderUploads.errorText(failing.error))
        #expect(text.contains("storage may be full"))
        let status = SyncStatus(syncing: false, problems: [], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: Date(),
                                folder: true, providerPending: 1, viaICloud: true, providerError: text)
        #expect(status.needsAttention)
        #expect(status.headline == text)
        #expect(!status.lastSuccessIsSync)
    }

    @Test func aFolderInICloudNeverSaysSyncedWhileUploadsWait() async throws {
        let session = SyncSession(locationID: UUID(), vaultID: UUID(), name: "V", lastSuccess: nil,
                                  run: { _ in SyncReport() }, countUnconfirmed: { 0 })
        session.kind = .folder
        session.uploadsViaICloud = true
        session.providerSummary = { ProviderUploads.Summary(count: 3) }
        session.vaultUnlocked()
        _ = await session.syncNow()
        #expect(session.status.kind == .waitingForProvider(3))
        #expect(session.headline == "3 changes waiting for iCloud to upload")
        #expect(!session.headline.contains("Synced"))
        #expect(!session.status.lastSuccessIsSync, "the bar shows the run as written to the folder")
        #expect(!session.needsAttention, "waiting is not a problem")
        session.providerSummary = { ProviderUploads.Summary() }
        _ = await session.syncNow()
        #expect(session.status.kind == .synced)
        session.stop()
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
