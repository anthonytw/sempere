import Foundation
import Observation
import Sempere
import SempereRender

/// Why an export run (`ExportJob`, `BulkExportRun`) ended without a result; worded by the app.
public enum ExportRunFailure: Equatable, Sendable {
    /// The run threw: the error's own sentence.
    case error(String)
    /// Nothing was exported, and this is the first note's failure line.
    case noteFailed(String)
    /// A media export of notes without recordings, videos, images or PDFs.
    case noMedia
    /// Nothing was exported, for no reason the run knows.
    case nothingExported
    /// A bulk export whose scope holds no notes.
    case noNotes
    /// A bulk export into a folder inside the vault (exported notes are not encrypted).
    case folderInsideVault
}

/// One export run for the export sheet: runs `AppModel.exportNotes` in a task
/// the sheet can cancel, and owns the scratch folder the files are written to
/// (deleted by `discard`, and any left behind by `purgeStale` at launch).
@MainActor
@Observable
public final class ExportJob {
    public enum State: Equatable {
        case idle
        case running(ExportProgress)
        case finished(Outcome)
        case failed(ExportRunFailure)
    }

    /// What a finished export produced.
    public struct Outcome: Equatable {
        public var items: [URL]
        public var failures: [String]
        public var exported: Int
        /// Recordings embedded ("PDF + attachments").
        public var recordingsAttached = 0
        /// Recordings of the exported notes left out.
        public var recordingsOmitted = 0
        /// Video clips embedded ("PDF + attachments").
        public var videosAttached = 0
        /// Media export: files written (media and transcripts).
        public var mediaFiles = 0
        /// Media export: notes without recordings, videos, images or PDFs.
        public var withoutMedia = 0
        /// Media export: files left out (not downloaded, unreadable transcript)
        /// or written with their metadata, one line each.
        public var warnings: [String] = []

        init(items: [URL], failures: [String], exported: Int, recordingsAttached: Int = 0,
                    recordingsOmitted: Int = 0, videosAttached: Int = 0, mediaFiles: Int = 0, withoutMedia: Int = 0,
                    warnings: [String] = []) {
            self.items = items
            self.failures = failures
            self.exported = exported
            self.recordingsAttached = recordingsAttached
            self.recordingsOmitted = recordingsOmitted
            self.videosAttached = videosAttached
            self.mediaFiles = mediaFiles
            self.withoutMedia = withoutMedia
            self.warnings = warnings
        }
    }

    public init() {}

    public private(set) var state = State.idle
    private var task: Task<Void, Never>?
    private var scratch: URL?

    public var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Where exports are staged (under the temporary directory, never in the vault).
    nonisolated static var scratchRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereExports", isDirectory: true)
    }

    /// Deletes every staged export: they are plaintext copies of notes. Call
    /// when the app starts, when no export can be running.
    nonisolated public static func purgeStale() {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    /// Starts exporting `ids`. Does nothing while a run is in flight.
    ///
    /// The run owns its scratch folder: unless its result is handed to this
    /// job (still current, not canceled), the run deletes the folder itself
    /// when it ends. A note being rendered when the sheet goes away finishes
    /// writing after `discard`, so deleting the folder only in `discard`
    /// would leave plaintext behind.
    public func start<Host>(model: AppModelCore<Host>, ids: [UUID], options: ShareOptions) {
        guard !isRunning else { return }
        discard()
        let dir = Self.scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        scratch = dir
        state = .running(ExportProgress(phase: .reading, done: 0, total: ids.count))
        task = Task { [weak self] in
            var next: State?
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                #if os(iOS)
                // Plaintext copies of notes: readable only while the device is unlocked.
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
                #endif
                let result = try await model.exportNotes(ids, options: options, into: dir) { progress in
                    self?.advance(to: progress)
                }
                next = .finished(Outcome(items: result.items, failures: result.failures, exported: result.exported,
                                         recordingsAttached: result.recordingsAttached,
                                         recordingsOmitted: result.recordingsOmitted,
                                         videosAttached: result.videosAttached, mediaFiles: result.mediaFiles,
                                         withoutMedia: result.withoutMedia,
                                         warnings: options.format == .media ? result.warnings : []))
            } catch is CancellationError {
            } catch {
                next = .failed(.error(model.services.describeError(error)))
            }
            guard let self, self.scratch == dir, !Task.isCancelled, let next else {
                try? FileManager.default.removeItem(at: dir)
                self?.cancelled(dir)
                return
            }
            if case .failed = next { try? FileManager.default.removeItem(at: dir) }
            self.finish(next)
        }
    }

    /// Stops a running export and removes what it wrote.
    public func cancel() {
        task?.cancel()
    }

    /// Cancels, forgets the result and deletes the staged files. Call when the sheet goes away.
    public func discard() {
        task?.cancel()
        task = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        state = .idle
    }

    private func advance(to progress: ExportProgress) {
        // Progress callbacks hop to the main actor one by one and may arrive out of order.
        guard case .running(let old) = state else { return }
        if progress.fraction >= old.fraction { state = .running(progress) }
    }

    private func finish(_ next: State) {
        guard isRunning else { return }
        task = nil
        if case .finished(let outcome) = next, outcome.items.isEmpty {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            let why: ExportRunFailure = outcome.failures.first.map { .noteFailed($0) }
                ?? (outcome.withoutMedia > 0 ? .noMedia : .nothingExported)
            state = .failed(why)
        } else {
            state = next
        }
    }

    /// The run that staged into `dir` ended without a result to show.
    private func cancelled(_ dir: URL) {
        guard scratch == dir else { return }   // a later run owns the job now
        task = nil
        scratch = nil
        state = .idle
    }
}
