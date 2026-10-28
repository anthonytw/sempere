import Foundation
import UniformTypeIdentifiers

/// A note dragged out of the app to the Finder (or any app that takes files)
/// as a PDF, or as Markdown or HTML when Settings ▸ General ▸ Drag to Finder
/// says so (`DragExportFormat`; Mac, docs/mac.md "Drag a note out as PDF").
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

    /// The name the dropped file gets, without its extension (the system adds `.pdf`, `.md`, `.html`).
    static func suggestedName(title: String) -> String {
        let name = ExportFileName.pdf(title: title)
        return String(name.dropLast(".pdf".count))
    }

    /// Registers the note's file in `format` (the setting's, by default) on
    /// `provider`: rendered when a drop asks for it, from `prepare`, on a
    /// background task. Every step goes to the `drag` log (`DragLog`).
    static func register(on provider: NSItemProvider, title: String, format: DragExportFormat = .load(),
                         prepare: Task<PreparedExport, any Error>, tag: String = "") {
        provider.suggestedName = suggestedName(title: title)
        let type = fileType(for: format).identifier
        DragLog.step("register \(tag) type=\(type) format=\(format.rawValue) visibility=all fileOptions=[]")
        DragLog.privateValue("register \(tag) suggestedName=", provider.suggestedName ?? "nil")
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
            DragLog.step("requested \(tag) type=\(type) \(DragLog.thread)")
            let started = Date()
            return load(prepare, format: format, tag: tag) { url, error in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if let url {
                    DragLog.step("completion \(tag) after=\(ms)ms \(DragLog.describe(file: url)) coordinated=false")
                    DragLog.privateValue("completion \(tag) name=", url.lastPathComponent)
                } else {
                    DragLog.failure("completion \(tag) after=\(ms)ms no file", error: error)
                }
                completion(url, false, error)
                // The system copies the file inside `completion`: it should still be there afterwards.
                if let url { DragLog.step("handed back \(tag) \(DragLog.describe(file: url))") }
            }
        }
    }

    /// `NoteDragDebug.control` (a hidden default, bug 7): registers, instead of the note, a small text file written
    /// when the drag begins, with no preparation, so a drop that never asks for the note can be told from
    /// a Finder that takes no file from this drag at all.
    static func registerControl(on provider: NSItemProvider, folder: URL, tag: String) {
        let dir = folder.appendingPathComponent("control-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("Sempere drag control.txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("Sempere drag control \(Date())\n".utf8).write(to: url)
        } catch {
            DragLog.failure("control \(tag) could not write", error: error)
            return
        }
        provider.suggestedName = "Sempere drag control"
        DragLog.step("register control \(tag) type=\(UTType.plainText.identifier) \(DragLog.describe(file: url))")
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            DragLog.step("requested control \(tag) \(DragLog.thread)")
            completion(url, false, nil)
            DragLog.step("handed back control \(tag) \(DragLog.describe(file: url))")
            return nil
        }
    }

    /// DEBUG trace of a drag out (`SEMPERE_DEBUG_DROPS`), appended to `tmp/drag-trace.txt` (UI tests).
    /// `DragLog` writes every step here as well as to the unified log.
    nonisolated static func dragTrace(_ line: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SEMPERE_DEBUG_DROPS"] != nil else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drag-trace.txt")
        let data = Data("\(Date().timeIntervalSince1970) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
        #endif
    }

    /// The type a drag offers `format`'s file as: the system's type for its extension.
    static func fileType(for format: DragExportFormat) -> UTType {
        switch format {
        case .pdf: return .pdf
        case .html: return .html
        case .markdown: return UTType(filenameExtension: format.fileExtension, conformingTo: .plainText) ?? .plainText
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
    /// and writes the file (`format`) on a background task and hands its URL (or the
    /// error) to `completion`, on that task. Never needs the main thread.
    /// `prepare` is main-actor work: if the system holds the main thread for
    /// the file before it ends, it never could, so the request fails with
    /// `DragError.timedOut` after `timeout` instead of freezing the app.
    @discardableResult
    static func load(_ prepare: Task<PreparedExport, any Error>, format: DragExportFormat = .pdf,
                     timeout: Duration = prepareTimeout, tag: String = "",
                     completion: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task.detached(priority: .userInitiated) {
            do {
                let waited = Date()
                let prepared = try await firstOf(prepare, timeout: timeout)
                DragLog.step("prepared \(tag) waited=\(Int(Date().timeIntervalSince(waited) * 1000))ms")
                try Task.checkCancellation()
                let writing = Date()
                let url = try prepared.write(format: format)
                DragLog.step("wrote \(tag) in=\(Int(Date().timeIntervalSince(writing) * 1000))ms \(DragLog.describe(file: url))")
                completion(url, nil)
            } catch {
                DragLog.failure("load \(tag) failed", error: error)
                completion(nil, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = {
            DragLog.step("canceled \(tag) by the destination")
            prepare.cancel()
        }
        return progress
    }

    /// `prepare`'s value, or `DragError.timedOut` after `timeout` (then
    /// `prepare` is canceled). Nothing structured awaits `prepare`: a task
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
