import Sempere
import SempereRender
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Handwritten Math (docs/attachments.md §14 G1 part 2): the
/// "Convert to Math" switch (off by default) and the models it can use, each
/// downloaded only on request, with its size shown first.
struct MathRecognitionSettingsSection: View {
    @AppStorage(MathRecognitionPreference.key) private var enabled = MathRecognitionPreference.defaultValue
    private let models = MathModels.shared
    @State private var addingModel = false

    var body: some View {
        Section {
            Toggle("Convert Handwriting to Math", isOn: $enabled)
                .syncedSetting("math.recognize")
            if enabled {
                if models.catalog.isEmpty && models.added.isEmpty {
                    Text("No handwriting model is offered for this version of Sempere yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(models.catalog, id: \.id) { entry in
                    ModelRow(entry: entry, models: models)
                }
                ForEach(models.added) { model in
                    AddedModelRow(model: model, models: models)
                }
                if models.importing {
                    ProgressView("Checking the model…")
                } else {
                    Button("Add Model from Files…") { addingModel = true }
                    Text("Pick a model folder, or a zip of one, from Files. It is checked against its manifest and kept on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let why = models.importFailure {
                    Text(verbatim: why).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Handwritten Math (Experimental)")
        } footer: {
            Text("Insert ▸ Equation from Handwriting reads the ink you circle as LaTeX, with a model that runs on this device: no ink leaves it. A model is downloaded only when you ask, checked against its published fingerprint and kept on this device.")
        }
        .onAppear { models.refresh() }
        .fileImporter(isPresented: $addingModel, allowedContentTypes: [.folder, .zip]) { result in
            if case .success(let url) = result { models.importModel(from: url) }
        }
    }

    /// A model added from Files: which one reads, and removing it.
    private struct AddedModelRow: View {
        let model: InstalledMathModel
        let models: MathModels

        var body: some View {
            let inUse = (models.selectedID ?? models.added.first?.id) == model.id
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: model.name)
                Text(verbatim: "\(model.manifest.licence) · \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if inUse {
                    Text("In Use").foregroundStyle(.secondary)
                } else {
                    Button("Use This Model") { models.select(model.id) }
                }
                Button("Remove Model", role: .destructive) { models.remove(model) }
            }
        }
    }

    private struct ModelRow: View {
        let entry: MathModelCatalogEntry
        let models: MathModels

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.name)
                Text(verbatim: entry.licence).font(.caption).foregroundStyle(.secondary)
                switch models.status[entry.id] ?? .notInstalled {
                case .notInstalled:
                    Button("Download (\(ByteCountFormatter.string(fromByteCount: entry.downloadBytes, countStyle: .file)))") {
                        models.download(entry)
                    }
                case .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Button("Cancel Download") { models.cancelDownload(entry) }
                case .installed:
                    Text("Installed").foregroundStyle(.secondary)
                    Button("Remove Model", role: .destructive) { models.remove(entry) }
                case .failed(let why):
                    Text(verbatim: why).font(.caption).foregroundStyle(.red)
                    Button("Try Again") { models.download(entry) }
                }
            }
        }
    }
}
