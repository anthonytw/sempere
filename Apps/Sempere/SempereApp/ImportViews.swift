import SempereImport
import SwiftUI

/// What the file picker returned for "Import from …", waiting for the options sheet.
struct ImportPick: Identifiable, Equatable {
    let id = UUID()
    /// The importer's id (`VaultImporter.id`).
    var importer: String
    var urls: [URL]
    /// The sidebar's notebook when the files were picked (nil: the importer's own rule).
    var notebook: String?
}

/// The names the app shows for the options an importer offers (docs/localization.md): the ones the importers use
/// today are localized here; an option the app does not know shows the importer's English title.
enum ImportOptionText {
    static func title(for spec: ImporterOptionSpec, importer: String) -> String {
        switch spec.id {
        case "attachments": return String(localized: "Attachments")
        case "keepImageMetadata": return String(localized: "Keep Photo Metadata", comment: "Toggle in the import options: keep camera and location data in photos")
        case "folderTags":
            return String(localized: "Tag Notes with Their \(importer) Folders", comment: "Toggle in the import options (the app's name)")
        default: return spec.appTitle ?? spec.id
        }
    }

    /// Options that mean nothing when the importer's attachments are off.
    static func needsAttachments(_ id: String) -> Bool { id == "keepImageMetadata" }

    static let attachmentsFooter = String(
        localized: "Attachments are PDF pages, images, typed text and recordings; off imports the ink, any recognized handwriting and the note's details only. Camera and location data in photos is removed unless you keep it. PDF page text makes the pages searchable.",
        comment: "Footer of the import options")
}

/// The options of an import (the importer's CLI flags, `ImportOptions`), asked after the files are picked and
/// before anything is written.
struct ImportOptionsSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let pick: ImportPick
    @State private var options = ImportOptions()

    private var importer: (any VaultImporter)? { AppImporters.registry.importer(id: pick.importer) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(pick.urls.count) files or folders chosen", comment: "Import options: what was picked")
                        .foregroundStyle(.secondary)
                }
                if let importer {
                    Section {
                        ForEach(importer.options.filter { $0.appTitle != nil }, id: \.id) { spec in
                            Toggle(ImportOptionText.title(for: spec, importer: importer.displayName), isOn: flag(spec))
                                .disabled(ImportOptionText.needsAttachments(spec.id) && !attachmentsOn(importer))
                        }
                        if importer.usesPDFText {
                            Toggle("PDF Page Text", isOn: $options.pdfText).disabled(!attachmentsOn(importer))
                        }
                    } footer: {
                        Text(ImportOptionText.attachmentsFooter)
                    }
                    if importer.supportsRecognizeAfter {
                        Section {
                            Toggle("Read Handwriting That \(importer.displayName) Did Not Index", isOn: $options.recognizeMissing)
                        } footer: {
                            Text("Reads the handwriting of pages the source app never recognized, on this device, right after the import.")
                        }
                    }
                }
            }
            .accessibilityIdentifier("importOptions")
            .navigationTitle(importer.map { String(localized: "Import from \($0.displayName)") } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        guard let importer else { return }
                        let urls = pick.urls, notebook = pick.notebook, chosen = options
                        Task { await model.report { try await model.importFromApp(importer, urls: urls, notebook: notebook, options: chosen) } }
                        dismiss()
                    }
                    .disabled(importer == nil)
                }
            }
        }
    }

    private func attachmentsOn(_ importer: any VaultImporter) -> Bool {
        guard let spec = importer.options.first(where: { $0.id == "attachments" }) else { return true }
        return options.values.bool("attachments", default: defaultOn(spec))
    }

    private func defaultOn(_ spec: ImporterOptionSpec) -> Bool {
        if case .flag(let on) = spec.kind { return on }
        return false
    }

    /// A switch for a flag option: on is the flag's value, whatever spelling the CLI has for turning it off.
    private func flag(_ spec: ImporterOptionSpec) -> Binding<Bool> {
        Binding(get: { options.values.bool(spec.id, default: defaultOn(spec)) },
                set: { options.values.values[spec.id] = .bool($0) })
    }
}

/// The running import over the window: what it is doing, a bar and the count of notes, the file being read
/// or written, and Cancel when the importer can stop between notes (`AppModel.cancelImport`).
struct ImportProgressOverlay: View {
    @AppModelEnvironment private var model
    /// The importer's name ("Notability").
    let source: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Importing from \(source)…", comment: "Progress while notes are imported from another app (its name)")
                .font(.headline)
            if let p = model.importProgress, p.phase != .finding, p.total > 0 {
                ProgressView(value: p.fraction)
                    .frame(width: 260)
                    .accessibilityIdentifier("importProgressBar")
                Text(Self.phaseLine(p)).font(.subheadline).monospacedDigit()
                    .accessibilityIdentifier("importProgressCount")
                if let current = p.current {
                    Text(verbatim: current).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260)
                }
            } else {
                ProgressView()
                Text("Finding notes…", comment: "Import progress: listing the chosen files").font(.subheadline)
            }
            if model.importCancellation != nil {
                Button("Cancel", role: .cancel) { model.cancelImport() }
                    .accessibilityIdentifier("importCancel")
                    .disabled(model.importCancellation?.isCancelled == true)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        // A container: the identifier would otherwise replace its children's (the count's, Cancel's).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importProgress")
    }

    /// "Reading 120 of 1,531 notes", "Importing 7 of 1,531 notes".
    static func phaseLine(_ p: ImporterProgress) -> String {
        switch p.phase {
        case .finding:
            return String(localized: "Finding notes…", comment: "Import progress: listing the chosen files")
        case .reading:
            return String(localized: "Reading note \(p.done) of \(p.total)", comment: "Import progress: every file is read before anything is written")
        case .writing:
            return String(localized: "Importing note \(p.done) of \(p.total)", comment: "Import progress: notes being written to the vault")
        }
    }
}

/// The full report of the last import: what was imported, what was left out and the importer's warnings (the
/// same lines `sempere import <id> -v` prints), and Save Report… / Share… for the whole report as a text file.
struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let details: ImportDetails
    @State private var handOff = ExportHandOffState()
    @State private var file: URL?

    var body: some View {
        NavigationStack {
            List {
                if let file {
                    Section {
                        ExportHandOffButtons(state: $handOff, items: [file])
                    } footer: {
                        Text("The report lists every file of the import with what happened to it.", comment: "Import report: under Share… and Save…")
                    }
                }
                if !details.imported.isEmpty {
                    Section("Imported") { rows(details.imported) }
                }
                if !details.notImported.isEmpty {
                    Section {
                        rows(details.notImported)
                    } header: {
                        Text("Not Imported")
                    } footer: {
                        Text("Counts of what the source app stores that Sempere does not convert (yet). Everything else of those notes was imported.")
                    }
                }
                if !details.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(Array(details.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(verbatim: warning).font(.footnote).textSelection(.enabled)
                        }
                        if details.moreWarnings > 0 {
                            Text("…and \(details.moreWarnings) more warnings.", comment: "After the first warnings of an import report")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("importReport")
            .exportHandOff($handOff)
            .task {
                guard file == nil, !details.text.isEmpty else { return }
                file = try? ImportReportText.write(details.text)
            }
            .onDisappear {
                if let file { ImportReportText.discard(file) }
            }
            .navigationTitle("Import Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func rows(_ rows: [ImportDetails.Row]) -> some View {
        ForEach(rows) { row in
            LabeledContent {
                Text(row.count, format: .number).monospacedDigit()
            } label: {
                Text(verbatim: row.label)
            }
        }
    }
}
