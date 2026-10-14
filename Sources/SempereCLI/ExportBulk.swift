import Foundation
import SempereFonts
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
        let errorText: (Error) -> String = { CLIError.from($0).message }
        for job in jobs {
            let id = job.noteId
            let short = String(id.uuidString.lowercased().prefix(8))
            do {
                let version = BulkExportPlan.version(of: try vault.revisionNames(of: id))
                if !overwrite && !zip && session.skip(job, version: version) {
                    if !output.json { output.info("Unchanged \(outURL.appendingPathComponent(job.path(options.format)).path)") }
                    continue
                }
                let loaded = try vault.loadNote(id)
                let state = try vault.reconstruct(loaded)
                let outcome = try session.export(job, state: state, version: version, blobs: vault.blobSource(note: id),
                                                 text: errorText)
                if case .failed(let why) = outcome.status {
                    printError("\(id.uuidString.lowercased()): \(why)")
                    continue
                }
                for w in Self.warnings(outcome.report, format: format) { printStderr("sempere: warning: \(short): \(w)") }
                if !zip { for f in outcome.files { output.info("Wrote \(outURL.appendingPathComponent(f).path)") } }
            } catch let e as BulkExportError {
                _ = try? session.finish(cancelled: true)
                throw CLIError.failure("\(e)")
            } catch {
                session.fail(job, error, text: errorText)
                printError("\(id.uuidString.lowercased()): \(errorText(error))")
            }
        }
        let result: BulkExportResult
        do { result = try session.finish(cancelled: false) } catch { throw CLIError.failure("\(error)") }
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
