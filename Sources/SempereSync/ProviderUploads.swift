import Foundation
import Sempere

/// Files a folder target's runs wrote into a provider's folder (iCloud Drive, another provider that uploads) that the
/// provider has not uploaded yet (offline audit P15). A run into such a folder only writes local files: offline, the
/// target is not "synced" until the provider uploads them, so the bar says how many wait (or why the provider cannot
/// upload them), and the unlisted screen does not count them as held by the target.
///
/// Kept per target next to its sync state (`provider-uploads.json`; the app writes it): each run adds the paths it wrote and
/// drops those the provider reports uploaded, so the count survives a relaunch while offline. A run is marked in
/// flight before it starts (`begin`): when the next run finds the mark (the run threw or the app was killed before
/// its report was recorded), it looks at every file of the folder once (`rescan`), so nothing written then is lost.
/// Past `limit` paths the record says it is truncated, and the target then counts as holding nothing.
public enum ProviderUploads {
    public static let fileName = "provider-uploads.json"
    /// At most this many paths are kept (a first upload of a large vault while offline): past it, `truncated`.
    public static let limit = 20_000

    /// What the provider says about one file.
    public enum State: Equatable, Sendable {
        case uploaded
        case waiting
        /// The provider reported an upload error (`ubiquitousItemUploadingError`): its code and message.
        case failed(code: Int, domain: String, message: String)

        /// The provider says, in so many words, that its storage is full: `CocoaError.fileWriteOutOfSpace` (640),
        /// `.ubiquitousFileNotUploadedDueToQuota` (4354) or `NSFileProviderError.insufficientQuota` (-1003). Only then may
        /// the app say the storage is full. Every other error is uncertain: iCloud reports
        /// `.ubiquitousFileUbiquityServerNotAvailable` (4355) while it is merely slow or out of reach, and calling that "may
        /// be full" was a false alarm (TestFlight 1.3.0 (112), owner 2026-11-20).
        public var isStorageFull: Bool {
            guard case .failed(let code, let domain, _) = self else { return false }
            switch domain {
            case NSCocoaErrorDomain: return code == 640 || code == 4354
            case ProviderUploads.fileProviderErrorDomain: return code == -1003
            default: return false
            }
        }
    }

    /// `NSFileProviderErrorDomain` (FileProvider is not on Linux; the string is the system's).
    public static let fileProviderErrorDomain = "NSFileProviderErrorDomain"

    /// How long an upload error must last before it is a problem the app shows.
    public static let problemAfter: TimeInterval = 10 * 60
    /// How many looks in a row (a run's count, the looks between runs) must see an upload error before it is a problem.
    public static let problemSightings = 3

    /// Whether an upload error the provider reports has lasted long enough to be a problem (owner 2026-11-20: "I don't
    /// need it unless something is definitely wrong"). Providers report errors for a while that clear by themselves (iCloud
    /// says its server is not available while it catches up), so one look proves nothing: an error is a problem only once
    /// every look for at least `problemAfter`, and at least `problemSightings` looks, saw one. A look that sees none, or
    /// one made while the device has no network path (a provider cannot upload then, and that is no fault), starts over.
    /// A full storage is held to the same rule: nothing is lost meanwhile (the changes are on this device), and a single
    /// answer of any kind is not "definitely wrong" yet.
    public struct Persistence: Equatable, Sendable {
        /// When the looks in a row that saw an error began.
        public private(set) var since: Date?
        /// How many looks in a row saw one.
        public private(set) var sightings = 0
        /// The error the last look saw.
        public private(set) var latest: State?

        public init() {}

        /// One look's answer: `error` is the provider's (a `.failed` state; nil or any other state: none).
        public mutating func observe(_ error: State?, at now: Date, networkDown: Bool = false) {
            guard let error, case .failed = error, !networkDown else {
                self = Persistence()
                return
            }
            if since == nil { since = now }
            sightings += 1
            latest = error
        }

        /// An error the provider still reports, whether or not it is a problem yet.
        public var isActive: Bool { latest != nil }

        /// The error to show as a problem at `now`: the latest, once it lasted; nil before.
        public func problem(at now: Date) -> State? {
            guard let latest, let since, sightings >= ProviderUploads.problemSightings,
                  now.timeIntervalSince(since) >= ProviderUploads.problemAfter else { return nil }
            return latest
        }
    }

    /// The provider's state of the file at `url`: nil when it is not a provider's (a local folder, a drive) or is
    /// gone, which drops it.
    public typealias Check = @Sendable (URL) -> State?

    /// The system's answer (`ubiquitousItemIsUploaded`, `isUploading`, `ubiquitousItemUploadingError`), read fresh.
    public static let system: Check = { url in
        #if canImport(Darwin)
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                         .ubiquitousItemUploadingErrorKey, .contentModificationDateKey]
        guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return nil }
        return state(isUploaded: values.ubiquitousItemIsUploaded, isUploading: values.ubiquitousItemIsUploading,
                     error: values.ubiquitousItemUploadingError, modified: values.contentModificationDate)
        #else
        return nil   // no provider uploads here
        #endif
    }

    /// How long a file with no upload answer is taken as one the provider has not taken in yet.
    public static let settleTime: TimeInterval = 300

    /// The state of a provider's file from what the provider says of it. A file with no answer is waiting only while
    /// it is fresh (`modified` within `settleTime` of `now`): one just written, before the provider took it in
    /// (TestFlight 1.1.0 (69)). An old file with no answer is uploaded, as it always was: a File Provider that never
    /// gives `ubiquitousItemIsUploaded` (a third-party one that marks its items ubiquitous) must not leave every file
    /// waiting for good. Time is the more robust bound than a path test: it needs no list of providers, so it holds
    /// for any provider, and a wrong guess ends in minutes instead of never.
    public static func state(isUploaded: Bool?, isUploading: Bool?, error: NSError?, modified: Date? = nil,
                             now: Date = Date()) -> State {
        if let error { return .failed(code: error.code, domain: error.domain, message: error.localizedDescription) }
        if isUploading == true { return .waiting }
        if let isUploaded { return isUploaded ? .uploaded : .waiting }
        guard let modified else { return .uploaded }
        return now.timeIntervalSince(modified) < settleTime ? .waiting : .uploaded
    }

    /// One target's record.
    public struct Record: Codable, Equatable, Sendable {
        public var paths: [String] = []
        /// More than `limit` paths waited: the list is not all of them.
        public var truncated = false
        /// A run started and has not recorded what it wrote yet (`begin`, cleared by `update`).
        public var inFlight = false
        /// The last run met an upload error (a full iCloud storage): code, domain and message.
        public var errorCode: Int?
        public var errorDomain: String?
        public var error: String?

        public init(paths: [String] = [], truncated: Bool = false, inFlight: Bool = false, errorCode: Int? = nil,
                    errorDomain: String? = nil, error: String? = nil) {
            self.paths = paths
            self.truncated = truncated
            self.inFlight = inFlight
            self.errorCode = errorCode
            self.errorDomain = errorDomain
            self.error = error
        }

        public var isEmpty: Bool { paths.isEmpty && !truncated && !inFlight && error == nil }
    }

    /// What the bar shows.
    public struct Summary: Equatable, Sendable {
        public var count = 0
        public var truncated = false
        public var error: State?

        public init(count: Int = 0, truncated: Bool = false, error: State? = nil) {
            self.count = count
            self.truncated = truncated
            self.error = error
        }
    }

    public static func url(in stateDirectory: URL) -> URL { stateDirectory.appendingPathComponent(fileName) }

    public static func record(in stateDirectory: URL) -> Record {
        guard let data = try? BoundedRead.contents(of: url(in: stateDirectory), maxBytes: 8 << 20),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
        return record
    }

    /// The paths waiting, as last recorded.
    public static func pending(in stateDirectory: URL) -> [String] { record(in: stateDirectory).paths }

    public static func summary(in stateDirectory: URL) -> Summary {
        let r = record(in: stateDirectory)
        let error = r.error.map { State.failed(code: r.errorCode ?? 0, domain: r.errorDomain ?? "", message: $0) }
        return Summary(count: r.paths.count, truncated: r.truncated, error: error)
    }

    public static func save(_ record: Record, in stateDirectory: URL) {
        let file = url(in: stateDirectory)
        if record.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Before a run into the folder: marks it in flight. Returns true when the previous run's mark is still there
    /// (it never recorded what it wrote): `update` then rescans the folder.
    @discardableResult
    public static func begin(stateDirectory: URL) -> Bool {
        exclusive(stateDirectory) {
            var r = record(in: stateDirectory)
            let interrupted = r.inFlight
            r.inFlight = true
            save(r, in: stateDirectory)
            return interrupted
        }
    }

    /// One lock per state directory: `begin`, `update` and `recheck` read, change and write the record whole, and the
    /// app's look between runs (`recheck`) may overlap a run's `update`; without it either could write over what the
    /// other just recorded (a run's new paths lost, its in-flight mark cleared).
    private static let locks = Locks()

    private final class Locks: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: NSLock] = [:]
        func lock(for directory: URL) -> NSLock {
            lock.lock()
            defer { lock.unlock() }
            let key = directory.standardizedFileURL.path
            if let l = byPath[key] { return l }
            let l = NSLock()
            byPath[key] = l
            return l
        }
    }

    private static func exclusive<T>(_ stateDirectory: URL, _ body: () -> T) -> T {
        let lock = locks.lock(for: stateDirectory)
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Between runs: asks the provider again about the paths recorded as waiting, writes nothing new to the list and
    /// leaves a run's in-flight mark as it found it (a run may be under way). Returns what still waits.
    @discardableResult
    public static func recheck(folder: URL, stateDirectory: URL, check: Check, now: Date = Date()) -> Summary {
        exclusive(stateDirectory) {
            reconcile(folder: folder, stateDirectory: stateDirectory, written: [], rescan: false, keepInFlight: true,
                      check: check, now: now)
        }
    }

    /// After a run into `folder`: the paths it wrote (`written`) join those waiting (with every file of the folder
    /// when `rescan`, after an interrupted run), and each is asked again; returns what still waits. Off the main
    /// actor (a resource lookup per file).
    @discardableResult
    public static func update(folder: URL, stateDirectory: URL, written: [String], rescan: Bool = false, check: Check, now: Date = Date()) -> Summary {
        exclusive(stateDirectory) {
            reconcile(folder: folder, stateDirectory: stateDirectory, written: written, rescan: rescan, keepInFlight: false,
                      check: check, now: now)
        }
    }

    private static func reconcile(folder: URL, stateDirectory: URL, written: [String], rescan: Bool, keepInFlight: Bool,
                                  check: Check, now: Date) -> Summary {
        let previous = record(in: stateDirectory)
        var candidates = previous.paths + written
        // A rescan only for a provider's folder: a drive's or a local folder's files are never waiting.
        var capped = false
        if rescan || previous.truncated, check(folder) != nil {
            let found = files(below: folder)
            candidates += found.paths
            capped = found.capped
        }
        let inProvider = check(folder) != nil
        var seen = Set<String>()
        var out = Record()
        // A rescan that stopped at its cap did not look at every file: the record is incomplete (review of #91).
        out.truncated = capped
        out.inFlight = keepInFlight && previous.inFlight
        for path in candidates where seen.insert(path).inserted {
            let answer = answer(for: folder.appendingPathComponent(path), inProvider: inProvider, check: check, now: now)
            switch answer {
            case .waiting?:
                if out.paths.count >= limit { out.truncated = true } else { out.paths.append(path) }
            case .failed(let code, let domain, let message)?:
                if out.paths.count >= limit { out.truncated = true } else { out.paths.append(path) }
                if out.error == nil { (out.errorCode, out.errorDomain, out.error) = (code, domain, message) }
            case .uploaded?, nil:
                break
            }
        }
        save(out, in: stateDirectory)
        return summary(in: stateDirectory)
    }

    /// The provider's answer for `file`; a file just written into a provider's folder, before the provider has taken it in,
    /// may answer nothing (not yet ubiquitous): it waits, rather than counting as uploaded (owner 2026-11-19, an iPad delete
    /// read "synced" before iCloud had uploaded it). Only while fresh, as `state(...)`.
    private static func answer(for file: URL, inProvider: Bool, check: Check, now: Date) -> State? {
        let answer = check(file)
        if answer == nil, inProvider, let modified = modified(file), now.timeIntervalSince(modified) < settleTime { return .waiting }
        return answer
    }

    /// What of `paths` (vault paths under `folder`) the provider has not uploaded, asked once and kept nowhere: the CLI's
    /// look after a run (`sempere sync folder`). Empty for a folder that is no provider's.
    public static func waiting(folder: URL, paths: [String], check: Check = system, now: Date = Date()) -> Summary {
        guard check(folder) != nil else { return Summary() }
        var summary = Summary()
        for path in Set(paths).sorted() {
            switch answer(for: folder.appendingPathComponent(path), inProvider: true, check: check, now: now) {
            case .waiting?: summary.count += 1
            case .failed(let code, let domain, let message)?:
                summary.count += 1
                if summary.error == nil { summary.error = .failed(code: code, domain: domain, message: message) }
            case .uploaded?, nil: break
            }
        }
        return summary
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Every regular file below `folder`, as a vault path, bounded by twice `limit`: `capped` when it stopped there
    /// with files left unlisted.
    public static func files(below folder: URL, cap: Int = 2 * limit) -> (paths: [String], capped: Bool) {
        let base = folder.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles]) else { return ([], false) }
        var out: [String] = []
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            if out.count >= cap { return (out, true) }
            out.append(String(path.dropFirst(base.count + 1)))
        }
        return (out, false)
    }

    /// This device's own files that no target holds, with the files a provider target holds only locally (not
    /// uploaded yet) counted as not held (offline audit P15). A target whose record is truncated or in flight (its
    /// list may be incomplete) holds nothing. `targets`: each target's sync-state file and its folder of state.
    public static func unsyncedPaths(vault: Vault, targets: [(state: URL, directory: URL)]) throws -> [String] {
        let records = targets.map { (target: $0, record: record(in: $0.directory)) }
        let plain = records.filter { $0.record.paths.isEmpty && !$0.record.truncated && !$0.record.inFlight }.map(\.target.state)
        var unsynced = Set(try UnsyncedChanges.paths(vault: vault, stateURLs: plain))
        for provider in records where !provider.record.paths.isEmpty && !provider.record.truncated && !provider.record.inFlight {
            // Held by this target (it holds them and the plain ones do not), and uploaded: held for good.
            let notHeld = Set(try UnsyncedChanges.paths(vault: vault, stateURLs: plain + [provider.target.state]))
            let held = unsynced.subtracting(notHeld)
            unsynced.subtract(held.subtracting(provider.record.paths))
        }
        return unsynced.sorted()
    }
}
