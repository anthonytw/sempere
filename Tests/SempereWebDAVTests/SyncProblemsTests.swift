import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Sempere
import SempereSync
import SempereWebDAV
import Testing

/// The one classification of sync problems the app's bar and the CLI read (thin-app duplicate 4): a thrown error
/// (`WebDAVSyncProblem.from(error:)`), a finished run (`SyncRunAssessment`), the connection check
/// (`WebDAVConnection.probe`) and the run bounds (`SyncBounds`). Values only; the app's words are tested in the app.
struct SyncProblemsTests {
    /// A folder target's own failures come first: a folder that went away is not found (choose it again), one on a
    /// volume or share that is not there now is offline (it syncs when it is back), never a full disk.
    @Test func aFolderTargetsFailuresAreClassifiedBeforeAServers() {
        #expect(WebDAVSyncProblem.from(error: FolderTargetError.missing("x")) == .notFound)
        #expect(WebDAVSyncProblem.from(error: FolderTargetError.unavailable("x")) == .offline)
        #expect(WebDAVSyncProblem.from(error: FolderRemoteError.unreachable("x")) == .offline)
        #expect(WebDAVSyncProblem.from(error: WebDAVError.offline("x")) == .offline)
        #expect(WebDAVSyncProblem.from(error: WebDAVError.http(method: "PROPFIND", path: "", status: 401)) == .unauthorized)
        #expect(WebDAVSyncProblem.from(error: WebDAVError.http(method: "PROPFIND", path: "", status: 404)) == .notFound)
        #expect(WebDAVSyncProblem.from(error: SyncError.vaultMismatch(local: "a", remote: "b")) == .otherVault)
    }

    /// Offline audit P14, review of #91 S6: a certificate refused for its dates is its own value, recognized by type
    /// (the `URLError` codes, the app's trust check's marker), never by a message's words. Its code stays
    /// "certificate" (`sempere webdav check --json`).
    @Test func aCertificateRefusedForItsDatesIsTyped() {
        for code in [-1201, -1204] {
            #expect(WebDAVSyncProblem.from(error: NSError(domain: NSURLErrorDomain, code: code)) == .certificateDate)
        }
        #expect(WebDAVSyncProblem.from(error: NSError(domain: NSURLErrorDomain, code: -1202)) != .certificateDate)
        let refusal = WebDAVError.untrustedCertificate(CertificateDate.marker + "words")
        #expect(WebDAVSyncProblem.from(error: refusal) == .certificateDate)
        #expect(WebDAVSyncProblem.from(error: WebDAVError.untrustedCertificate("check the date and time"))
                == .certificate("check the date and time"), "a message that mentions dates is not one")
        #expect(WebDAVSyncProblem.certificateDate.code == "certificate")
        #expect(WebDAVSyncProblem.certificateDate.isCertificate && WebDAVSyncProblem.certificate("x").isCertificate)
        #expect(!WebDAVSyncProblem.offline.isCertificate)
        #expect(!WebDAVErrorText.message(refusal).contains(CertificateDate.marker))
        #expect(CertificateDate.displayed(CertificateDate.marker + "words") == "words")
    }

    @Test func aFailureIsOneLineWithoutControlCharacters() {
        let message = WebDAVErrorText.message(WebDAVError.transport("first\nsecond\u{1B}[2J"))
        #expect(!message.contains("\n") && !message.contains("\u{1B}"))
        #expect(message.hasPrefix("network error: first second"))
    }

    /// The app's Test Connection and `sempere webdav check` read one answer: the problem and its message.
    @Test func theConnectionCheckClassifiesItsFailure() {
        guard case .failed(let problem, let message) = WebDAVConnection.probe({
            try WebDAVClient(baseURL: URL(string: "https://dav.example.org/v/")!, credentials: nil,
                             transport: StubTransport(error: .http(method: "PROPFIND", path: "", status: 401)))
        }) else { Issue.record("reachable"); return }
        #expect(problem == .unauthorized)
        #expect(message.contains("HTTP 401"))
        guard case .failed(let refused, _) = WebDAVConnection.probe({ throw WebDAVError.insecureURL("plain http") }) else {
            Issue.record("reachable"); return
        }
        guard case .failed = refused else { Issue.record("\(refused)"); return }   // a URL the client refuses fails the check
        guard case .failed(let target, _) = WebDAVConnection.probeTarget({
            try WebDAVClient(baseURL: URL(string: "https://dav.example.org/v/")!, credentials: nil,
                             transport: StubTransport(error: .offline("down")))
        }, vaultId: UUID()) else { Issue.record("checked"); return }
        #expect(target == .offline)
    }

    /// A stop of the run (`stopReason`) after progress, as the engine reports it.
    static func cut(_ reason: SyncReport.StopReason, progress: Bool) -> SyncReport {
        var r = SyncReport()
        r.stoppedEarly = "stopped"
        r.stopReason = reason
        r.errors = [.init(path: "notes", message: "stopped", kind: reason.isProgressStop ? .stopped : nil)]   // as the engine marks it
        if progress { r.uploaded = ["notes/a/1.delta.age"] }
        return r
    }

    /// Offline audit P4: a run cut short after progress is no problem but no last success either; a server bound
    /// stays a failure (review of #91, M1); an upload-only run does not report the device list it kept.
    @Test func aRunsAssessment() {
        let clean = SyncRunAssessment(report: SyncReport(), twoWay: true)
        #expect(clean.isSuccess && clean.problems.isEmpty && !clean.cutShort)
        for reason in [SyncReport.StopReason.cancelled, .timeLimit, .connectionLost] {
            let a = SyncRunAssessment(report: Self.cut(reason, progress: true), twoWay: true)
            #expect(a.cutShort && a.problems.isEmpty && !a.isSuccess, "\(reason)")
            #expect(!SyncRunAssessment(report: Self.cut(reason, progress: false), twoWay: true).cutShort)
        }
        let bound = SyncRunAssessment(report: Self.cut(.bound, progress: true), twoWay: true)
        #expect(!bound.cutShort && !bound.problems.isEmpty)
        var kept = Self.cut(.cancelled, progress: true)
        kept.errors.append(.init(path: "notes/b", message: "refused"))
        #expect(SyncRunAssessment.progressedCutShort(kept)?.errors.map(\.path) == ["notes/b"], "real errors stay")

        var manifest = SyncReport()
        manifest.conflicts = [.init(path: Vault.manifestName, remoteCopy: nil, detail: "both")]
        #expect(SyncRunAssessment(report: manifest, twoWay: true).problems == [.serverChangedManifest])
        #expect(SyncRunAssessment(report: manifest, twoWay: false).isSuccess, "upload-only: it arrives at the unlock")
    }

    /// The CLI's `--max-*` flags and the app's background bound fill a run's options the same way.
    @Test func boundsAreCheckedAndFilledIn() throws {
        var options = SyncOptions()
        try SyncBounds.checked(maxBlobMiB: 2, maxNotes: 3, maxEntries: 4, maxDownloadMiB: 5, maxMinutes: 6).apply(to: &options)
        #expect(options.maxBlobBytes == 2 << 20)
        #expect(options.limits == SyncLimits(maxNotes: 3, maxEntries: 4, maxDownloadBytes: 5 << 20, maxDuration: 360))
        var bounded = SyncOptions()
        SyncBounds(maxDuration: 7.5).apply(to: &bounded)
        #expect(bounded.limits == SyncLimits(maxDuration: 7.5), "only the bound given changes")
        #expect(bounded.maxBlobBytes == SyncOptions.defaultMaxBlobBytes)
        #expect(throws: SyncBounds.OutOfRange(field: .maxMinutes, value: 0)) { try SyncBounds.checked(maxMinutes: 0) }
        #expect(throws: SyncBounds.OutOfRange(field: .maxBlobMiB, value: (1 << 20) + 1)) {
            try SyncBounds.checked(maxBlobMiB: (1 << 20) + 1, maxNotes: 0)
        }
        #expect(SyncBounds.Field.maxNotes.range == 1...100_000_000)
    }
}
