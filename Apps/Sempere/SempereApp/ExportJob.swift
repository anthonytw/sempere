import Foundation
import Observation
import Sempere
import SempereRender

/// One export run for the export sheet: runs `AppModel.exportNotes` in a task
/// the sheet can cancel, and owns the scratch folder the files are written to
/// (deleted by `discard`, and any left behind by `purgeStale` at launch).
@MainActor
@Observable
final class ExportJob {
    enum State: Equatable {
        case idle
        case running(ExportProgress)
        case finished(Outcome)
        case failed(String)
    }

    /// What a finished export produced.
    struct Outcome: Equatable {
        var items: [URL]
        var failures: [String]
        var exported: Int
        /// Recordings embedded ("PDF + attachments").
        var recordingsAttached = 0
        /// Recordings of the exported notes left out.
        var recordingsOmitted = 0
        /// Video clips embedded ("PDF + attachments").
        var videosAttached = 0
        /// Media export: files written (media and transcripts).
        var mediaFiles = 0
        /// Media export: notes without recordings, videos, images or PDFs.
        var withoutMedia = 0
        /// Media export: files left out (not downloaded, unreadable transcript)
        /// or written with their metadata, one line each.
        var warnings: [String] = []
    }

    private(set) var state = State.idle
    private var task: Task<Void, Never>?
    private var scratch: URL?

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Where exports are staged (under the temporary directory, never in the vault).
    nonisolated static var scratchRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereExports", isDirectory: true)
    }

    /// Deletes every staged export: they are plaintext copies of notes. Call
    /// when the app starts, when no export can be running.
    nonisolated static func purgeStale() {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    /// Starts exporting `ids`. Does nothing while a run is in flight.
    ///
    /// The run owns its scratch folder: unless its result is handed to this
    /// job (still current, not cancelled), the run deletes the folder itself
    /// when it ends. A note being rendered when the sheet goes away finishes
    /// writing after `discard`, so deleting the folder only in `discard`
    /// would leave plaintext behind.
    func start(model: AppModel, ids: [UUID], options: ShareOptions) {
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
                next = .failed("\(error)")
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
    func cancel() {
        task?.cancel()
    }

    /// Cancels, forgets the result and deletes the staged files. Call when the sheet goes away.
    func discard() {
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
            let why = outcome.failures.first ?? (outcome.withoutMedia > 0
                ? String(localized: "The notes have no recordings, videos, images or PDFs.")
                : String(localized: "There was nothing to export."))
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
