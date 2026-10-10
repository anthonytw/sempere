import SempereRender
import SwiftUI
import UniformTypeIdentifiers

/// "Export to Folder or Zip…": several notes, a notebook or the whole vault, as PDF,
/// PDF + attachments or PNG pages, into a folder (resumable) or a zip
/// archive; progress with Stop, and per-note failures at the end
/// (docs/io.md "Bulk export").
struct BulkExportSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let request: BulkExportRequest
    @State private var run = BulkExportRun()
    @State private var options = BulkExportOptions(format: .pdf)
    @State private var asZip: Bool
    @State private var pickingFolder = false
    @State private var handOff = ExportHandOffState()

    init(request: BulkExportRequest) {
        self.request = request
        // A Mac writes into a folder; an iPad or iPhone hands a zip to the share sheet or Files.
        _asZip = State(initialValue: !Platform.isMac)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch run.state {
                case .idle:
                    settings
                case .running(let progress):
                    Section {
                        ProgressView(value: progress.fraction)
                        Text(progress.description).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        if progress.skipped > 0 || progress.failed > 0 {
                            Text("\(progress.skipped) unchanged, \(progress.failed) not exported so far")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button("Stop Export", role: .destructive) { run.cancel() }
                    } footer: {
                        if asZip {
                            Text("Stopping deletes the unfinished archive.")
                        } else {
                            Text("Notes already written stay in the folder; exporting again into it skips them.")
                        }
                    }
                case .finished(let result):
                    finished(result)
                case .failed(let message):
                    Section {
                        Label("Export failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.callout)
                    }
                    Section { Button("Try Again") { run.discard() } }
                }
            }
            .accessibilityIdentifier("bulkExportSheet")
            .navigationTitle("Export \(request.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(run.isRunning ? "Stop" : "Close") {
                        if run.isRunning { run.cancel() } else { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(run.isRunning)
        .onDisappear { run.discard() }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { picked in
            if case .success(let url) = picked {
                run.start(model: model, request: request, options: options, target: .folder(url, scoped: true))
            }
        }
        .exportHandOff($handOff)
    }

    private var noteCount: Int { model.bulkExportJobs(request.scope, options: options).count }

    @ViewBuilder
    private var settings: some View {
        Section {
            LabeledContent {
                Text("\(noteCount) notes")
            } label: {
                Text(request.title)
            }
        }
        Section("Format") {
            Picker("Format", selection: $options.format) {
                ForEach(BulkExportFormat.allCases) { Text($0.localizedTitle).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section {
            Toggle("Folders Like Your Notebooks", isOn: Binding(get: { options.layout == .notebooks },
                                                                set: { options.layout = $0 ? .notebooks : .flat }))
            if options.format != .media {
                Toggle("Paper Background and Ruling", isOn: $options.paper)
            }
            if options.format == .png {
                ResolutionPicker(dpi: $options.dpi)
            }
            Picker("Save As", selection: $asZip) {
                Text("Files in a Folder").tag(false)
                Text("Zip Archive").tag(true)
            }
        } header: {
            Text("Options")
        } footer: {
            Text(Self.shape(options, zip: asZip))
        }
        Section {
            Group {
                if asZip {
                    Button("Export", systemImage: ExportCommand.menuImage) {
                        run.start(model: model, request: request, options: options, target: .zip)
                    }
                } else {
                    Button("Choose Folder and Export…", systemImage: ExportCommand.menuImage) { pickingFolder = true }
                }
            }
            .disabled(noteCount == 0)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Label("Exports are not encrypted. Anyone who receives the files can read the notes.", systemImage: "lock.open")
                if let cli = request.cliEquivalent(options, zip: asZip) {
                    Text("Command line: \(cli)").textSelection(.enabled).font(.caption.monospaced())
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private func finished(_ result: BulkExportResult) -> some View {
        Section {
            Label("\(result.exported.count) notes exported", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            if !result.skipped.isEmpty {
                Label("\(result.skipped.count) already in the folder, unchanged (skipped)", systemImage: "arrow.uturn.forward")
            }
            if result.cancelled {
                Label("Stopped: \(result.notReached) not exported", systemImage: "stop.circle").foregroundStyle(.orange)
            }
            let attached = result.exported.reduce(0) { $0 + $1.recordingsAttached + $1.videosAttached }
            if attached > 0 { Label("\(attached) recordings and videos attached", systemImage: "paperclip") }
            if options.format == .media {
                let files = result.exported.reduce(0) { $0 + $1.files.filter { !$0.hasSuffix("/" + MediaExport.manifestName) }.count }
                Label("\(files) media files", systemImage: "paperclip")
            }
            Text(result.output.lastPathComponent).font(.callout)
        }
        if !result.failures.isEmpty {
            Section("Not exported") {
                ForEach(result.failureLines, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
        }
        if options.format == .media, !result.warningLines.isEmpty {
            Section("Left out or kept as stored") {
                ForEach(result.warningLines, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
        }
        if case .zip = destinationKind(result), !result.exported.isEmpty, !result.cancelled {
            Section {
                ExportHandOffButtons(state: $handOff, items: [result.output])
            } footer: {
                Text("The archive is deleted from the app when you close this sheet.")
            }
        }
    }

    private enum Kind { case folder, zip }
    private func destinationKind(_ result: BulkExportResult) -> Kind {
        result.output.pathExtension.lowercased() == "zip" && result.output.path.hasPrefix(BulkExportRun.stagingRoot.path)
            ? .zip : .folder
    }

    /// What the export writes, in two sentences.
    static func shape(_ options: BulkExportOptions, zip: Bool) -> String {
        var each: String
        switch options.format {
        case .pdf: each = String(localized: "One PDF per note.")
        case .pdfAttachments:
            each = String(localized: "One PDF per note, with its recordings, transcripts and videos attached and listed on a last page.")
        case .png: each = String(localized: "A folder of PNG pages per note.")
        case .media:
            each = String(localized: "A folder per note with its recordings, transcripts, videos, images and PDFs as files; notes without them are left out.")
        }
        if options.layout == .notebooks { each += " " + String(localized: "Folders follow your notebooks.") }
        let destination = zip ? String(localized: "Everything goes into one zip archive.")
            : String(localized: "Exporting again into the same folder skips notes already there unchanged (same name, size and version).")
        return each + " " + destination
    }
}

extension BulkExportFormat {
    /// The format's name in the sheet's picker (`title` is the library's English name).
    var localizedTitle: String {
        switch self {
        case .pdf: return String(localized: "PDF", comment: "Export format: PDF document")
        case .pdfAttachments: return String(localized: "PDF + attachments", comment: "Export format: PDF with recordings and videos attached")
        case .png: return String(localized: "PNG Pages", comment: "Export format: one PNG image per page")
        case .media: return String(localized: "Media", comment: "Export format: recordings, videos, images and PDFs as files")
        }
    }
}
