import Foundation
import UniformTypeIdentifiers

/// A note dragged out of the app to the Finder (or any app that takes files)
/// as a PDF (Mac, docs/mac.md "Drag a note out as PDF").
///
/// On a Mac the drop becomes a file promise, and the system may ask for the
/// file while the main thread waits for it. So the main-actor part (saving
/// the note's pending ink, the iCloud download: `AppModel.prepareExport`)
/// starts when the drag begins, and the file request only waits for it and
/// renders off the main actor: it never needs the main thread itself.
enum NoteFileDrag {
    /// Starts preparing `noteID` for export (the drag began).
    @MainActor
    static func prepare(_ noteID: UUID, model: AppModel) -> Task<PreparedExport, any Error> {
        Task { try await model.prepareExport(noteID: noteID) }
    }

    /// The name the dropped file gets, without its extension (the system adds `.pdf`).
    static func suggestedName(title: String) -> String {
        let name = ExportFileName.pdf(title: title)
        return String(name.dropLast(".pdf".count))
    }

    /// Registers the note's PDF on `provider`: rendered when a drop asks for
    /// it, from `prepare`, on a background task.
    static func register(on provider: NSItemProvider, title: String, prepare: Task<PreparedExport, any Error>) {
        provider.suggestedName = suggestedName(title: title)
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            load(prepare) { completion($0, false, $1) }
        }
    }

    /// The drop's file request gave up on the preparation (`load`).
    enum DragError: Error, LocalizedError {
        case timedOut
        var errorDescription: String? {
            String(localized: "The note took too long to get ready to export. Try dragging it again.",
                   comment: "Error when a note dragged out of the app as a PDF could not be prepared in time")
        }
    }

    /// How long a file request waits for the preparation.
    static let prepareTimeout: Duration = .seconds(20)

    /// What a drop's request for the file runs: waits for `prepare`, renders
    /// and writes the PDF on a background task and hands its URL (or the
    /// error) to `completion`, on that task. Never needs the main thread.
    /// `prepare` is main-actor work: if the system holds the main thread for
    /// the file before it ends, it never could, so the request fails with
    /// `DragError.timedOut` after `timeout` instead of freezing the app.
    @discardableResult
    static func load(_ prepare: Task<PreparedExport, any Error>, timeout: Duration = prepareTimeout,
                     completion: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task.detached(priority: .userInitiated) {
            do {
                let prepared = try await firstOf(prepare, timeout: timeout)
                try Task.checkCancellation()
                completion(try prepared.write(), nil)
            } catch {
                completion(nil, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { prepare.cancel() }
        return progress
    }

    /// `prepare`'s value, or `DragError.timedOut` after `timeout` (then
    /// `prepare` is cancelled). Nothing structured awaits `prepare`: a task
    /// group would, at its end, wait for a child still awaiting `prepare.value`,
    /// and main-actor work that cannot run ends only once the main thread is
    /// free, which is never while the system holds it for this very file.
    static func firstOf(_ prepare: Task<PreparedExport, any Error>,
                        timeout: Duration) async throws -> PreparedExport {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreparedExport, any Error>) in
            let once = Once()
            let timer = Task.detached {
                try? await Task.sleep(for: timeout)
                guard once.claim() else { return }
                prepare.cancel()
                continuation.resume(throwing: DragError.timedOut)
            }
            Task.detached {
                let result = await prepare.result
                guard once.claim() else { return }
                timer.cancel()
                continuation.resume(with: result)
            }
        }
    }

    /// Lets only the first of the two racers resume the continuation.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
