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

/// The full report of the last import: what was imported, what was left out and the importer's warnings (the
/// same lines `sempere import <id> -v` prints).
struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let details: ImportDetails

    var body: some View {
        NavigationStack {
            List {
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
