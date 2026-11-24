import Foundation

// MARK: - Errors and status of the CloudKit transport (docs/design/1.4-cloudkit.md §4)

/// What `CloudRecordRemote` throws. Conforms to `TransientRemoteError`, so the engine keeps partial downloads,
/// counts a lost link (`LinkBreaker`) and words the failure as it does for every transport.
public enum CloudRecordError: Error, Sendable, Equatable {
    /// The store failed (the code says how; see `CloudStatus.classify`).
    case store(CloudStoreError)
    /// No file at that path (or a tombstone).
    case notFound(String)
    /// The collection a write goes into does not exist.
    case missingParent(String)
    /// A path component the transport cannot represent.
    case invalidPath(String)
    /// A read past its bound, or a record whose size says it is over it.
    case tooLarge(path: String, limit: Int)
    /// A record that fails its own checks (hash, size, parts): a hostile or broken server. Never transient.
    case corrupt(path: String, reason: String)
    /// The record, or the zone (`path` nil), has a layout newer than this build knows: read-only (design §12,
    /// owner decision 3). Never transient; the status asks for an update.
    case newerSchema(path: String?)
    /// The zone is missing on a target that synced before, or the user deleted it: never recreated by itself.
    case zoneGone(userDeleted: Bool)
    /// The server asked for a wait longer than the request may take: the run ends and the next one is due at `until`.
    case throttled(until: Date)
    /// No run until the account changes.
    case account(CloudAccount.Status)
    /// The device is signed in to another Apple Account than the target was made with.
    case otherAccount
    /// A request the transport does not implement for this shape (a split file moved, say).
    case unsupported(String)
    /// The zone lists more records than the run's bound.
    case tooManyRecords(Int)
}

extension CloudRecordError: TransientRemoteError {
    public var isTransient: Bool {
        switch self {
        case .store(let e):
            switch e.code {
            case .networkUnavailable, .networkFailure, .serverResponseLost, .serviceUnavailable, .requestRateLimited, .zoneBusy,
                 .assetFileNotFound, .assetNotAvailable, .quotaExceeded, .changeTokenExpired, .limitExceeded, .serverRecordChanged, .batchRequestFailed:
                return true
            default:
                return false
            }
        case .throttled: return true
        case .account(let s): return s == .temporarilyUnavailable || s == .couldNotDetermine
        default: return false
        }
    }

    /// The network: no connection, a cut one, an answer lost.
    public var isUnreachable: Bool {
        if case .store(let e) = self {
            return e.code == .networkUnavailable || e.code == .networkFailure || e.code == .serverResponseLost
        }
        return false
    }

    /// Only `networkUnavailable` means the request never left.
    public var sentNothing: Bool {
        if case .store(let e) = self { return e.code == .networkUnavailable }
        return false
    }
}

extension CloudRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .store(let e): return e.errorDescription
        case .notFound(let p): return "\(SyncReport.printable(p)): not found"
        case .missingParent(let p): return "\(SyncReport.printable(p)): the parent collection does not exist"
        case .invalidPath(let p): return "\(SyncReport.printable(p)): not a usable path"
        case .tooLarge(let p, let limit): return "\(SyncReport.printable(p)): over \(limit) bytes; not read"
        case .corrupt(let p, let why): return "\(SyncReport.printable(p)): the iCloud record is not valid (\(why))"
        case .newerSchema(let p):
            return (p.map { "\(SyncReport.printable($0)): " } ?? "") + "written by a newer Sempere than this one; update Sempere to sync it"
        case .zoneGone(let userDeleted):
            return userDeleted ? "this vault's data was deleted in iCloud settings; nothing here was deleted"
                : "this vault's iCloud data is gone; nothing here was deleted"
        case .throttled(let until): return "iCloud asked to wait until \(until)"
        case .account(let s): return "the iCloud account is not available (\(s.rawValue))"
        case .otherAccount: return "this device is signed in to a different Apple Account"
        case .unsupported(let m): return "not supported over iCloud: \(m)"
        case .tooManyRecords(let n): return "the iCloud zone lists more than \(n) records; not mirrored"
        }
    }
}

// MARK: - Status (design §4's table)

/// A problem the bar shows: only what definitely needs the user (the 1.3 quiet-status rule). The words are the
/// design's, in English; the app localizes them (phase C3).
public enum CloudProblem: Sendable, Hashable {
    case storageFull
    case zoneGone
    case zoneDeletedByUser
    case signedOut
    case restricted
    case otherAccount
    case updateNeeded
    /// No run succeeded for 24 hours while the network was up (`since`: the last success, if any).
    case notAccepted(since: Date?)

    /// The line the status bar shows (design §4).
    public var message: String {
        switch self {
        case .storageFull: return "iCloud storage is full. Free up space or upgrade iCloud+, then Sync Now."
        case .zoneGone: return "This vault's iCloud data is gone. Nothing here was deleted."
        case .zoneDeletedByUser: return "This vault's data was deleted in iCloud settings. Nothing here was deleted."
        case .signedOut: return "Sign in to iCloud in Settings to sync this vault."
        case .restricted: return "iCloud is restricted on this device (Screen Time or device management)."
        case .otherAccount:
            return "This device is signed in to a different Apple Account. Syncing with iCloud is paused; nothing was deleted."
        case .updateNeeded: return "Update Sempere to keep syncing with iCloud."
        case .notAccepted(let since):
            return since.map { "iCloud has not accepted changes since \($0)." } ?? "iCloud has not accepted changes."
        }
    }
}

/// What one failure means for the status.
public enum CloudStatus: Sendable, Equatable {
    /// Nothing to show.
    case ok
    /// Offline, as for WebDAV (not an error).
    case offline
    /// Healing by itself: listed in Vault Details, never in the bar.
    case quiet
    /// The server asked for a wait; the session takes `until` as its next run time, never as a failure.
    case throttled(until: Date)
    case problem(CloudProblem)

    /// The status one failed run shows, by design §4. `now` dates a throttle that gave only seconds.
    public static func classify(_ error: Error, now: Date = Date()) -> CloudStatus {
        if let e = error as? CloudRecordError {
            switch e {
            case .store(let s): return classify(s)
            case .throttled(let until): return .throttled(until: until)
            case .zoneGone(let userDeleted): return .problem(userDeleted ? .zoneDeletedByUser : .zoneGone)
            case .newerSchema: return .problem(.updateNeeded)
            case .otherAccount: return .problem(.otherAccount)
            case .account(let s):
                switch s {
                case .noAccount: return .problem(.signedOut)
                case .restricted, .managedAccountRestricted: return .problem(.restricted)
                case .temporarilyUnavailable, .couldNotDetermine, .available: return .quiet
                }
            case .notFound, .missingParent, .invalidPath, .tooLarge, .corrupt, .unsupported, .tooManyRecords: return .quiet
            }
        }
        if let e = error as? CloudStoreError { return classify(e, now: now) }
        return .quiet
    }

    /// The status of one store failure.
    public static func classify(_ e: CloudStoreError, now: Date = Date()) -> CloudStatus {
        switch e.code {
        case .networkUnavailable: return .offline
        case .networkFailure, .serverResponseLost, .serviceUnavailable, .zoneBusy, .assetFileNotFound, .assetNotAvailable,
             .changeTokenExpired, .limitExceeded, .serverRecordChanged, .unknownItem, .batchRequestFailed:
            return .quiet
        case .requestRateLimited:
            return e.retryAfterSeconds.map { .throttled(until: now.addingTimeInterval($0)) } ?? .quiet
        case .quotaExceeded: return .problem(.storageFull)
        case .zoneNotFound: return .problem(.zoneGone)
        case .userDeletedZone: return .problem(.zoneDeletedByUser)
        case .notAuthenticated: return .problem(.signedOut)
        case .incompatibleVersion: return .problem(.updateNeeded)
        case .accountChanged: return .problem(.otherAccount)
        case .badContainer, .missingEntitlement, .permissionFailure, .invalidArguments, .internalError, .serverRejectedRequest:
            return .quiet
        }
    }
}

/// Tracks a CloudKit target's runs for the status: a definite problem shows at once; a quiet failure that never
/// clears shows as `notAccepted` after 24 hours with the network up (design §4, the stall rule).
public struct CloudStatusTracker: Sendable {
    /// How long failures with the network up may last before they are a problem.
    public static let stallInterval: TimeInterval = 24 * 3600

    public private(set) var lastSuccess: Date?
    private var firstFailure: Date?
    private var problem: CloudProblem?
    private var offline = false

    public init(lastSuccess: Date? = nil) { self.lastSuccess = lastSuccess }

    /// A run finished with no failure.
    public mutating func succeeded(at now: Date) {
        lastSuccess = now
        firstFailure = nil
        problem = nil
        offline = false
    }

    /// A run failed with `error`. `networkUp`: the path monitor said the network was available for it.
    public mutating func failed(_ error: Error, networkUp: Bool, at now: Date) {
        switch CloudStatus.classify(error, now: now) {
        case .offline:
            offline = true
        case .throttled, .ok:
            break
        case .problem(let p):
            problem = p
        case .quiet:
            problem = nil
            if networkUp, firstFailure == nil { firstFailure = now }
        }
        if case .store(let e)? = error as? CloudRecordError, e.code == .networkFailure || e.code == .serverResponseLost {
            // Unreachable but not "offline": quiet, and the link may not be at fault (the stall rule still counts it).
            if networkUp, firstFailure == nil { firstFailure = now }
        }
    }

    /// What the bar shows now.
    public func status(at now: Date) -> CloudStatus {
        if let problem { return .problem(problem) }
        if let firstFailure, now.timeIntervalSince(firstFailure) >= Self.stallInterval {
            return .problem(.notAccepted(since: lastSuccess))
        }
        return offline ? .offline : .ok
    }
}
