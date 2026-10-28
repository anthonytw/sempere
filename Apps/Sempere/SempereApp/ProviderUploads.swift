import Foundation
import Sempere
import SempereSync

/// Files a folder target's runs wrote into a provider's folder (iCloud Drive, another provider that uploads) that the
/// provider has not uploaded yet (offline audit P15). A run into such a folder only writes local files: offline, the
/// target is not "synced" until the provider uploads them, so the bar says how many wait (or why the provider cannot
/// upload them), and the unlisted screen does not count them as held by the target.
///
/// Kept per target next to its sync state (`provider-uploads.json`; app only): each run adds the paths it wrote and
/// drops those the provider reports uploaded, so the count survives a relaunch while offline. A run is marked in
/// flight before it starts (`begin`): when the next run finds the mark (the run threw or the app was killed before
/// its report was recorded), it looks at every file of the folder once (`rescan`), so nothing written then is lost.
/// Past `limit` paths the record says it is truncated, and the target then counts as holding nothing.
enum ProviderUploads {
    static let fileName = "provider-uploads.json"
    /// At most this many paths are kept (a first upload of a large vault while offline): past it, `truncated`.
    static let limit = 20_000

    /// What the provider says about one file.
    enum State: Equatable, Sendable {
        case uploaded
        case waiting
        /// The provider reported an upload error (`ubiquitousItemUploadingError`): its code and message.
        case failed(code: Int, domain: String, message: String)
    }

    /// The provider's state of the file at `url`: nil when it is not a provider's (a local folder, a drive) or is
    /// gone, which drops it.
    typealias Check = @Sendable (URL) -> State?

    /// The system's answer (`ubiquitousItemIsUploaded`, `isUploading`, `ubiquitousItemUploadingError`), read fresh.
    static let system: Check = { url in
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                         .ubiquitousItemUploadingErrorKey]
        guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return nil }
        if let error = values.ubiquitousItemUploadingError {
            return .failed(code: error.code, domain: error.domain, message: error.localizedDescription)
        }
        if values.ubiquitousItemIsUploading == true { return .waiting }
        return values.ubiquitousItemIsUploaded == false ? .waiting : .uploaded
    }

    /// One target's record.
    struct Record: Codable, Equatable, Sendable {
        var paths: [String] = []
        /// More than `limit` paths waited: the list is not all of them.
        var truncated = false
        /// A run started and has not recorded what it wrote yet (`begin`, cleared by `update`).
        var inFlight = false
        /// The last run met an upload error (a full iCloud storage): code, domain and message.
        var errorCode: Int?
        var errorDomain: String?
        var error: String?

        var isEmpty: Bool { paths.isEmpty && !truncated && !inFlight && error == nil }
    }

    /// What the bar shows.
    struct Summary: Equatable, Sendable {
        var count = 0
        var truncated = false
        var error: State?
    }

    static func url(in stateDirectory: URL) -> URL { stateDirectory.appendingPathComponent(fileName) }

    static func record(in stateDirectory: URL) -> Record {
        guard let data = try? BoundedRead.contents(of: url(in: stateDirectory), maxBytes: 8 << 20),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
        return record
    }

    /// The paths waiting, as last recorded.
    static func pending(in stateDirectory: URL) -> [String] { record(in: stateDirectory).paths }

    static func summary(in stateDirectory: URL) -> Summary {
        let r = record(in: stateDirectory)
        let error = r.error.map { State.failed(code: r.errorCode ?? 0, domain: r.errorDomain ?? "", message: $0) }
        return Summary(count: r.paths.count, truncated: r.truncated, error: error)
    }

    static func save(_ record: Record, in stateDirectory: URL) {
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
    static func begin(stateDirectory: URL) -> Bool {
        var r = record(in: stateDirectory)
        let interrupted = r.inFlight
        r.inFlight = true
        save(r, in: stateDirectory)
        return interrupted
    }

    /// After a run into `folder`: the paths it wrote (`written`) join those waiting (with every file of the folder
    /// when `rescan`, after an interrupted run), and each is asked again; returns what still waits. Off the main
    /// actor (a resource lookup per file).
    @discardableResult
    static func update(folder: URL, stateDirectory: URL, written: [String], rescan: Bool = false, check: Check) -> Summary {
        let previous = record(in: stateDirectory)
        var candidates = previous.paths + written
        // A rescan only for a provider's folder: a drive's or a local folder's files are never waiting.
        var capped = false
        if rescan || previous.truncated, check(folder) != nil {
            let found = files(below: folder)
            candidates += found.paths
            capped = found.capped
        }
        var seen = Set<String>()
        var out = Record()
        // A rescan that stopped at its cap did not look at every file: the record is incomplete (review of #91).
        out.truncated = capped
        for path in candidates where seen.insert(path).inserted {
            switch check(folder.appendingPathComponent(path)) {
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

    /// Every regular file below `folder`, as a vault path, bounded by twice `limit`: `capped` when it stopped there
    /// with files left unlisted.
    static func files(below folder: URL, cap: Int = 2 * limit) -> (paths: [String], capped: Bool) {
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
    static func unsyncedPaths(vault: Vault, targets: [(state: URL, directory: URL)]) throws -> [String] {
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

    /// The upload error as the bar says it: a full iCloud storage (or iCloud unavailable) in plain words.
    static func errorText(_ state: State?) -> String? {
        guard case .failed(let code, let domain, let message)? = state else { return nil }
        let full = domain == NSCocoaErrorDomain
            && (code == CocoaError.Code.fileWriteOutOfSpace.rawValue || code == CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable.rawValue)
        if full {
            return String(localized: "iCloud is not uploading this folder's files: its storage may be full, or iCloud is not available. Check iCloud storage in Settings.",
                          comment: "Sync status: a folder target in iCloud Drive whose uploads fail")
        }
        return String(localized: "The folder's provider could not upload some files: \(message)",
                      comment: "Sync status; the value is the provider's error message")
    }
}
