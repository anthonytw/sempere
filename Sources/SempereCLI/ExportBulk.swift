import Foundation
import SempereFonts
import SempereImport
import SempereRender
import Sempere

/// `export --all --format pdf|png`: the shared bulk export (`BulkExportSession`),
/// one note read, rendered and written at a time, as the app's "Export Notes…".
extension ExportCommand {
    func runBulk(_ vault: Vault) throws {
        try vault.requireCompleteCopy()
        // Plan from the summaries (cached), then read each note only when its turn comes.
        let summaries = try vault.summaries(of: nil, cache: cache.cache(for: vault))
        let scope: BulkExportScope = notebook.map { .notebook($0) } ?? .vault
        let options = BulkExportOptions(format: bulkFormat, layout: layout, paper: !noPaper, dpi: dpi, breaks: breaks,
                                        keepImageMetadata: keepImageMetadata)
        // Folders start at --notebook, as the app's "Export Notebook…" does.
        let jobs = BulkExportPlan.jobs(for: scope, from: summaries, format: options.format, layout: layout,
                                       includeDeleted: deleted)
        if jobs.isEmpty { throw CLIError.failure("no notes to export") }

        let fonts = FontLibrary(bundled: SempereFonts.directory, packs: FontLibrary.defaultPackDirectories())
        if SempereFonts.directory == nil && !output.json {
            printStderr("sempere: warning: the bundled fonts were not found next to the program; text uses font packs only")
        }
        let base = RenderOptions(pdfRasterizer: try rasterizer(), shaper: DefaultTextShaper(library: fonts))
        let outURL = URL(fileURLWithPath: out)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sempere-export-\(UUID().uuidString.lowercased())", isDirectory: true)
        let destination: BulkExportSession.Destination = zip ? .zip(archive: outURL, staging: staging) : .folder(outURL)
        let session: BulkExportSession
        do {
            session = try BulkExportSession(destination: destination, options: options, jobs: jobs, renderBase: base)
        } catch {
            throw CLIError.failure("\(error)")
        }
        let errorText: @Sendable (Error) -> String = { CLIError.from($0).message }
        // Ctrl-C stops after the note being written, so no half-written `.partial` is left behind (a second
        // Ctrl-C ends the process at once; the next run sweeps what that leaves).
        let cancellation = ImporterCancellation()
        let interrupt = ImportInterrupt(cancellation)
        defer { interrupt.stop() }
        // The shared loop (`BulkExportDriver`: skip, read, render, write, one failed note not stopping the rest).
        // Its events print as the notes go; Ctrl-C ends it between notes.
        var driver = BulkExportDriver(vault: vault, session: session, jobs: jobs)
        driver.skipUnchanged = !overwrite && !zip
        driver.describeError = errorText
        driver.stopRequested = { cancellation.isCancelled }
        let format = self.format
        let output = self.output
        let json = output.json
        let out = self.out
        let zip = self.zip
        driver.onEvent = { event in
            switch event {
            case .skipped(let job):
                if !json { output.info("Unchanged \(outURL.appendingPathComponent(job.path(options.format)).path)") }
            case .failed(let job, let message):
                printError("\(job.noteId.uuidString.lowercased()): \(message)")
            case .written(let outcome):
                let id = outcome.job.noteId
                if case .failed(let why) = outcome.status {
                    printError("\(id.uuidString.lowercased()): \(why)")
                    return
                }
                let short = String(id.uuidString.lowercased().prefix(8))
                for w in Self.warnings(outcome.report, format: format) { printStderr("sempere: warning: \(short): \(w)") }
                if !zip { for f in outcome.files { output.info("Wrote \(outURL.appendingPathComponent(f).path)") } }
            }
        }
        let ready = driver
        let driven: BulkExportResult
        do {
            driven = try blockingThrowing { try await ready.run() }
        } catch {
            throw CLIError.failure("\(error)")
        }
        if driven.cancelled {
            throw CLIError.failure("interrupted: \(driven.exported.count) note(s) exported into \(out); "
                                   + "run the same command again to resume")
        }
        let result = driven
        let written = result.notes.compactMap { o -> Written? in
            let files = o.files.map { zip ? $0 : outURL.appendingPathComponent($0).path }
            switch o.status {
            case .exported:
                return Written(note: o.job.noteId.uuidString.lowercased(), files: files,
                               placeholders: o.placeholders == 0 ? nil : o.placeholders,
                               recordings: o.recordingsAttached > 0 ? o.recordingsAttached : nil,
                               videos: o.videosAttached > 0 ? o.videosAttached : nil)
            case .skipped:
                return Written(note: o.job.noteId.uuidString.lowercased(), files: files, skipped: true)
            case .failed:
                return nil
            }
        }
        if zip { output.info("Wrote \(out) (\(result.exported.count) note(s), PLAINTEXT)") }
        let skipped = result.skipped.count
        output.info("\(result.exported.count) note(s) exported, \(skipped) unchanged since the last export into \(out)"
                    + (result.failures.isEmpty ? "" : ", \(result.failures.count) failed"))
        if output.json { try output.emitJSON(written) }
        if !result.failures.isEmpty { throw CLIError.failure("\(result.failures.count) note(s) could not be exported") }
    }
}
