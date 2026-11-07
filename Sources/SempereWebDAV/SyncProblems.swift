import Foundation
import Sempere
import SempereSync

/// A server certificate refused for its dates: either it really expired, or this device's clock is far off (a device
/// back after a long time offline, a date set by hand; offline audit P14). Recognized by type (review of #91, S6): a
/// `URLError` code, or the fixed marker the app's certificate check (`PinnedServerTrust`) starts its refusal with,
/// never by the words of a message. The classification is `WebDAVSyncProblem.certificateDate`; the app words it.
public enum CertificateDate {
    /// Starts a refusal's reason that is a date problem. Unlocalized: only the app's trust check writes it, and the
    /// message shown strips it (`WebDAVErrorText.message`, `displayed`).
    public static let marker = "[sempere:certificate-date] "

    /// True when a refusal's reason is one of ours for the dates.
    public static func matches(_ message: String) -> Bool { message.hasPrefix(marker) }

    /// `URLError.serverCertificateHasBadDate` and `.serverCertificateNotYetValid`, by their codes (the same on
    /// every platform).
    static let dateCodes: Set<Int> = [-1201, -1204]

    /// True for the `URLError` codes of a certificate refused for its dates. The domain by its value
    /// (`NSURLErrorDomain`), which needs no networking module on Linux.
    public static func isDateProblem(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "NSURLErrorDomain" && dateCodes.contains(ns.code)
    }

    /// `message` without the marker, for display.
    public static func displayed(_ message: String) -> String {
        message.hasPrefix(marker) ? String(message.dropFirst(marker.count)) : message
    }
}

/// One line for a sync or WebDAV failure, without credentials (the library's messages never contain them), control
/// characters escaped and the `CertificateDate` marker left out: the detail line under a problem (the app's sheet
/// and bar, the CLI's error line). It is the error's own description, not the problem's wording.
public enum WebDAVErrorText {
    public static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let line = SyncReport.printable(text.split(whereSeparator: \.isNewline).joined(separator: " "))
        return line.replacingOccurrences(of: CertificateDate.marker, with: "")
    }
}

/// What a connection check of a WebDAV URL found (the app's Test Connection, `sempere webdav check`).
public enum WebDAVCheckOutcome: Sendable {
    case reachable(WebDAVCheckResult)
    case failed(WebDAVSyncProblem, message: String)
}

/// What checking a server folder as a new sync target found (the app's Add WebDAV Server…,
/// `sempere store target add --webdav --check`).
public enum WebDAVTargetCheckOutcome: Sendable {
    case checked(WebDAVTargetFolder)
    case failed(WebDAVSyncProblem, message: String)
}

extension WebDAVConnection {
    /// `check` with its failure classified: the problem and its one-line message. `client` is made inside, so a URL
    /// the client refuses is a failure too.
    public static func probe(_ client: () throws -> WebDAVClient) -> WebDAVCheckOutcome {
        do {
            return .reachable(try check(try client()))
        } catch {
            return .failed(WebDAVSyncProblem.from(error: error), message: WebDAVErrorText.message(error))
        }
    }

    /// `checkTargetFolder` with its failure classified, as `probe`.
    public static func probeTarget(_ client: () throws -> WebDAVClient, vaultId: UUID) -> WebDAVTargetCheckOutcome {
        do {
            return .checked(try checkTargetFolder(try client(), vaultId: vaultId))
        } catch {
            return .failed(WebDAVSyncProblem.from(error: error), message: WebDAVErrorText.message(error))
        }
    }
}

/// How a run that returned a report went, for a target's status (the app's `SyncSession`, `sempere store sync`'s
/// last success): its problems, whether it was cut short after progress, and whether it counts as a last success.
public struct SyncRunAssessment: Sendable, Equatable {
    /// What to show; empty: all is well.
    public var problems: [WebDAVSyncProblem]
    /// The run moved files and stopped early (a cancel, its time bound, a lost link): progress, not a failure; the
    /// next run continues (offline audit P4).
    public var cutShort: Bool

    /// Only a complete run without problems is a last success.
    public var isSuccess: Bool { problems.isEmpty && !cutShort }

    /// - Parameters:
    ///   - twoWay: an upload-only run keeps a device list another device changed (`keepServerChanges`): it arrives
    ///     at the next unlocked run, so it is no problem then.
    ///   - targetRoots: a folder target's path, as `WebDAVSyncProblem.from(report:targetRoots:)` takes it.
    public init(report: SyncReport, twoWay: Bool, targetRoots: [String] = []) {
        let cut = Self.progressedCutShort(report)
        cutShort = cut != nil
        problems = WebDAVSyncProblem.from(report: cut ?? report, targetRoots: targetRoots)
            .filter { twoWay || $0 != .serverChangedManifest }
    }

    /// A report of a run that stopped early after it moved files, because of a cancel (iOS taking the background time
    /// back) or its time bound, or a lost link, with those stops left out of its errors; nil for any other run (offline
    /// audit P4). The engine classifies the stop (`SyncReport.stopReason`): the other run bounds (`maxEntries`,
    /// `maxDownloadBytes`, `maxNotes`) guard against a server that lists or serves without end, so they are `.bound`
    /// and stay failures, shown and backed off (review of #91, M1).
    public static func progressedCutShort(_ report: SyncReport) -> SyncReport? {
        guard report.stoppedEarly != nil, report.stopReason?.isProgressStop == true, report.madeProgress else { return nil }
        var out = report
        out.errors.removeAll { $0.kind == .stopped || $0.kind == .network }
        return out
    }
}
