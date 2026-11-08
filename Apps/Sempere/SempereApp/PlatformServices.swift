import Foundation
import os
import Sempere
import SempereAppCore
import UIKit

// The app's implementations of the platform protocols the library declares (`Sources/Sempere/Platform/`,
// docs/design/thin-app.md "Rules"). Library code, and app code as it moves into the library, takes these as
// `any KeyValueStore`, `any PerfSink`, `any FolderBookmarks`, `any FileCoordinating`, `any PlatformServices`;
// tests pass the memory versions (`MemoryKeyValueStore`, `MemoryPerfSink`, `PathBookmarks`, `UncoordinatedFiles`,
// `HeadlessPlatform`).

// MARK: - KeyValueStore

/// `UserDefaults` is the app's `KeyValueStore`: its own getters and setters are the requirements, and a change
/// is its `didChangeNotification` (posted with the defaults as the object, on the thread that changed it).
extension UserDefaults: @retroactive KeyValueStore {
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> KeyValueObservation {
        let center = NotificationCenter.default
        nonisolated(unsafe) let token = center.addObserver(forName: UserDefaults.didChangeNotification, object: self,
                                                           queue: nil) { _ in handler() }
        return KeyValueObservation { center.removeObserver(token) }
    }
}

// MARK: - PerfSink

private let perfLoggers = OSAllocatedUnfairLock<[String: Logger]>(initialState: [:])

/// The package's timing reports as the app's signposts (`Perf`; phases the app does not know are not reported),
/// and its log lines as `os.Logger` lines (subsystem `io.github.anthonytw.sempere`, public: the protocol allows
/// counts and id prefixes only).
struct AppPerfSink: PerfSink {
    func measure<T>(_ phase: String, _ detail: String, _ body: () throws -> T) rethrows -> T {
        guard let phase = Perf.Phase(rawValue: phase) else { return try body() }
        return try Perf.measure(phase, detail, body)
    }

    func event(_ phase: String, _ detail: String) {
        guard let phase = Perf.Phase(rawValue: phase) else { return }
        Perf.event(phase, detail)
    }

    func begin(_ phase: String) -> PerfInterval {
        guard let known = Perf.Phase(rawValue: phase) else { return PerfInterval(phase: phase) }
        return PerfInterval(Perf.begin(known))
    }

    func end(_ interval: PerfInterval, _ detail: String) {
        guard let mark = interval.mark as? PerfMark else { return }
        Perf.end(mark.interval, detail)
    }

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        let logger = perfLoggers.withLock { loggers in
            if let known = loggers[category] { return known }
            let made = Logger(subsystem: "io.github.anthonytw.sempere", category: category)
            loggers[category] = made
            return made
        }
        let type: OSLogType = switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
        logger.log(level: type, "\(message, privacy: .public)")
    }
}

extension PerfInterval {
    /// A signpost interval the app began itself (`Perf.begin`), for the package to end (`AppPerfSink.end`).
    init(_ interval: Perf.Interval) {
        self.init(phase: interval.phase.rawValue, mark: PerfMark(interval: interval))
    }
}

/// `Perf.Interval` handed through the package (its signpost state is used on one thread at a time).
struct PerfMark: @unchecked Sendable {
    let interval: Perf.Interval
}

// MARK: - FolderBookmarks

/// Security-scoped bookmarks. Bookmarks are made with `options: []` (no `.withSecurityScope` on iOS or Catalyst,
/// CLAUDE.md); a resolve without `mounting` passes `.withoutMounting`.
struct SecurityScopedBookmarks: FolderBookmarks {
    func bookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data, mounting: Bool) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: mounting ? [] : [.withoutMounting], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, isStale: stale)
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

// MARK: - FileCoordinating

/// `NSFileCoordinator` with no file presenter. The wait for the grant is the `reconcile.coordinate` signpost
/// (`Perf`); a refused coordination throws the coordinator's error.
struct SystemFileCoordinator: FileCoordinating {
    func coordinateReading<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try coordinate(url, write: false, body)
    }

    func coordinateWriting<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try coordinate(url, write: true, body)
    }

    private func coordinate<T>(_ url: URL, write: Bool, _ body: () throws -> T) throws -> T {
        var result: Result<T, any Error>?
        var error: NSError?
        let wait = Perf.begin(.reconcileCoordinate)
        var granted = false
        if write {
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                Perf.end(wait, "write")
                granted = true
                result = Result { try body() }
            }
        } else {
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { _ in
                Perf.end(wait, "read")
                granted = true
                result = Result { try body() }
            }
        }
        if !granted { Perf.end(wait, write ? "write refused" : "read refused") }
        if let result { return try result.get() }
        throw error ?? CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

// MARK: - PlatformServices

/// The device the app runs on: `Platform`'s flags, UIKit's idle timer and feedback generators.
struct AppPlatform: PlatformServices {
    var isMac: Bool { Platform.isMac }
    @MainActor var isPhone: Bool { Platform.isPhone }

    @MainActor func setIdleTimerDisabled(_ disabled: Bool) { UIApplication.shared.isIdleTimerDisabled = disabled }

    @MainActor func play(_ feedback: HapticFeedback) {
        guard !isMac else { return }
        switch feedback {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

extension BundleBitRepair {
    /// `clear(_:_:log:)` (the package's), logging to the app's `AppPerfSink`.
    @discardableResult
    static func clear(_ url: URL, _ role: Role) -> Bool {
        clear(url, role, log: AppPerfSink())
    }
}

extension NoteDevice {
    /// This device (`AppPlatform`): the Mac (Mac Catalyst), an iPhone, else an iPad.
    @MainActor static var current: NoteDevice { .of(AppPlatform()) }
}
