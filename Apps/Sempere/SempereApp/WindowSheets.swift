import Sempere
import SwiftUI
import UniformTypeIdentifiers
import SempereImport

/// The rename alert and the tag sheet that menu commands (and the toolbars)
/// open through `WindowUI`, for the window they are attached to.
struct WindowSheets: ViewModifier {
    @AppModelEnvironment private var model
    let ui: WindowUI
    @State private var title = ""
    @State private var versionName = ""
    @State private var pdfPassword = ""

    // Two halves: as one chain the body is past what the type checker solves in time.
    func body(content: Content) -> some View {
        noteDialogs(importsAndPrompts(content))
    }

    private func importsAndPrompts(_ content: Content) -> some View {
        @Bindable var ui = ui
        return content
            // Each importer on a view of its own: two `fileImporter`s on one view do not both work.
            .background {
                SwiftUI.Color.clear.fileImporter(isPresented: $ui.importingPDF, allowedContentTypes: [.pdf]) { result in
                    guard case .success(let url) = result else { return }
                    let notebook = model.sidebarNotebook
                    Task {
                        if case .needsPassword(let request) = await model.importPDF(picked: url, to: .newNote(notebook: notebook)) {
                            ui.pdfPassword = request
                        }
                    }
                }
            }
            .background {
                SwiftUI.Color.clear.fileImporter(isPresented: $ui.importingFromApp,
                                                 allowedContentTypes: AppImporters.primary.map { AppModel.importTypes(for: $0) } ?? [],
                                                 allowsMultipleSelection: true) { result in
                    guard case .success(let urls) = result, !urls.isEmpty, let importer = AppImporters.primary else { return }
                    // The options come next (`ImportOptionsSheet`); nothing is read before they are chosen.
                    ui.importPick = ImportPick(importer: importer.id, urls: urls, notebook: model.sidebarNotebook)
                }
            }
            .sheet(item: $ui.importPick) { pick in
                ImportOptionsSheet(pick: pick)
            }
            .sheet(isPresented: Binding(get: { ui.importReport != nil }, set: { if !$0 { ui.importReport = nil } })) {
                if let details = ui.importReport { ImportReportView(details: details) }
            }
            .overlay {
                if model.isImporting {
                    ProgressView(String(localized: "Importing from \(AppImporters.primary?.displayName ?? "")…",
                                        comment: "Progress while notes are imported from another app (its name)"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(model.importSummary?.title ?? "", isPresented: Binding(get: { model.importSummary != nil && isFront },
                                                                          set: { if !$0 { model.importSummary = nil } })) {
                if let details = model.importSummary?.details, !details.isEmpty {
                    Button("Show Report") {
                        ui.importReport = details
                        model.importSummary = nil
                    }
                }
                Button("OK", role: .cancel) { model.importSummary = nil }
            } message: {
                Text(model.importSummary?.message ?? "")
            }
            // PDFs opened from the Finder or the share sheet (`AppModel+OpenedFiles`).
            .sheet(isPresented: Binding(get: { isFront && [OpenedFile.Stage.ready, .readOnly].contains(model.openedPDFStage) },
                                        set: { _ in })) {
                OpenedPDFsView(ui: ui)
            }
    }

    private func noteDialogs(_ content: some View) -> some View {
        @Bindable var ui = ui
        return content
            .onChange(of: ui.renameNoteID) { _, id in
                if let id, let note = model.notes.first(where: { $0.id == id }) { title = note.title }
            }
            .alert("Rename Note", isPresented: Binding(get: { ui.renameNoteID != nil },
                                                       set: { if !$0 { ui.renameNoteID = nil } })) {
                TextField("Title", text: $title)
                Button("Rename") {
                    if let id = ui.renameNoteID {
                        let text = title
                        Task { await model.report { try await model.renameNote(id, to: text) } }
                    }
                    ui.renameNoteID = nil
                }
                Button("Cancel", role: .cancel) { ui.renameNoteID = nil }
            }
            .onChange(of: ui.saveVersionNoteID) { _, id in if id != nil { versionName = "" } }
            .alert("Save Version", isPresented: Binding(get: { ui.saveVersionNoteID != nil },
                                                        set: { if !$0 { ui.saveVersionNoteID = nil } })) {
                TextField("Name (optional)", text: $versionName)
                Button("Save") {
                    if let id = ui.saveVersionNoteID {
                        let name = versionName
                        Task { await model.report { try await model.saveVersion(of: id, name: name) } }
                    }
                    ui.saveVersionNoteID = nil
                }
                Button("Cancel", role: .cancel) { ui.saveVersionNoteID = nil }
            } message: {
                Text("Saved versions are listed first in Version History and are never removed when old autosaves are thinned.")
            }
            .onChange(of: ui.pdfPassword?.id) { _, _ in pdfPassword = "" }
            .alert(ui.pdfPassword?.wrongPassword == true ? "Wrong Password" : "PDF Password",
                   isPresented: Binding(get: { ui.pdfPassword != nil }, set: { _ in })) {
                SecureField("Password", text: $pdfPassword)
                Button("Open") {
                    guard let request = ui.pdfPassword else { return }
                    let password = pdfPassword
                    ui.pdfPassword = nil
                    Task {
                        if case .needsPassword(let again) = await model.continuePDFImport(request, password: password) {
                            ui.pdfPassword = again
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    if let request = ui.pdfPassword { model.cancelPDFImport(request) }
                    ui.pdfPassword = nil
                }
            } message: {
                Text(ui.pdfPassword?.wrongPassword == true
                     ? "That password does not open this PDF. Try again."
                     : "This PDF is protected. Enter its password to add it; it is stored without the password, encrypted with the vault's key.")
            }
            .sheet(isPresented: Binding(get: { ui.tagsNoteID != nil }, set: { if !$0 { ui.tagsNoteID = nil } })) {
                if let id = ui.tagsNoteID { TagEditorView(noteID: id) }
            }
            // Version History: the toolbar's button, Note > Version History… and the note window's.
            .sheet(isPresented: Binding(get: { ui.historyNoteID != nil }, set: { if !$0 { ui.historyNoteID = nil } })) {
                if let id = ui.historyNoteID { HistoryView(noteID: id) }
            }
            // The export sheet opens in the window that asked for it (a Mac may have several).
            .sheet(item: Binding(get: { ExportRequest.shown(model.exportRequest, in: ui.id, canvasWindow: model.canvasWindow) },
                                 set: { if $0 == nil, ExportRequest.shown(model.exportRequest, in: ui.id,
                                                                            canvasWindow: model.canvasWindow) != nil {
                                     model.exportRequest = nil
                                 } })) { request in
                ExportSheet(request: request)
            }
            .sheet(item: Binding(get: { BulkExportRequest.shown(model.bulkExportRequest, in: ui.id, canvasWindow: model.canvasWindow) },
                                 set: { if $0 == nil, BulkExportRequest.shown(model.bulkExportRequest, in: ui.id,
                                                                                canvasWindow: model.canvasWindow) != nil {
                                     model.bulkExportRequest = nil
                                 } })) { request in
                BulkExportSheet(request: request)
            }
    }
}

extension WindowSheets {
    /// The window that shows app-wide prompts (the opened-PDF sheet, the
    /// import result): the library window with the canvas, else any.
    private var isFront: Bool { OpenedFile.shows(in: ui.id, canvasWindow: model.canvasWindow) }
}

/// The PDFs opened from outside the app: "Import as new notes into <vault>",
/// with the notebook to file them in. Another vault: close this one and open
/// that one; the PDFs wait (the welcome screen says so).
struct OpenedPDFsView: View {
    @AppModelEnvironment private var model
    let ui: WindowUI
    @State private var notebook = ""
    @State private var importing = false

    private var vaultName: String {
        model.vaultURL.map { VaultLibrary.displayName(of: $0) } ?? "the open vault"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        ForEach(model.openedPDFs) { pdf in
                            Label(pdf.name, systemImage: "doc.richtext")
                        }
                    } footer: {
                        if model.openedPDFs.count == 1 {
                            Text("Becomes a new note in “\(vaultName)”, one page per PDF page, to write on. The PDF is stored encrypted in the vault.")
                        } else {
                            Text("Each PDF becomes a new note in “\(vaultName)”, one page per PDF page, to write on. The PDFs are stored encrypted in the vault.")
                        }
                    }
                    if model.openedPDFStage == .readOnly {
                        Section {
                            Label("This vault is read-only: it was written by a newer version of Sempere.", systemImage: "lock")
                        }
                    } else {
                        Section {
                            NotebookField(title: "Notebook (blank: top level)", text: $notebook, notebooks: model.notebooks, reveal: proxy)
                        }
                    }
                    Section {
                        Button("Choose Another Vault…", systemImage: "archivebox") { model.close() }
                            .help("Close this vault; the PDFs wait until you open and unlock another one")
                    }
                }
            }
            .navigationTitle(String(localized: "Import \(model.openedPDFs.count) PDFs", comment: "Title of the sheet for PDFs opened with Sempere"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.discardOpenedPDFs() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { runImport() }
                        .disabled(importing || model.openedPDFStage != .ready)
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { notebook = model.sidebarNotebook ?? "" }
    }

    private func runImport() {
        importing = true
        let target = notebook
        Task {
            let locked = await model.importOpenedPDFs(notebook: target)
            importing = false
            // One password prompt at a time: the others are dropped and named.
            if let first = locked.first { ui.pdfPassword = first }
            let rest = locked.dropFirst()
            for request in rest { model.cancelPDFImport(request) }
            if !rest.isEmpty {
                let names = rest.map { $0.file.lastPathComponent }.formatted(.list(type: .and))
                model.errorMessage = String(localized: "Protected PDFs not imported (open them again to enter their passwords): \(names)",
                                            comment: "The value lists file names")
            }
        }
    }
}

/// Under the welcome screen or the locked vault: PDFs opened with Sempere
/// wait for a vault to be opened and unlocked.
struct OpenedPDFsWaitingBar: View {
    @AppModelEnvironment private var model

    var body: some View {
        let count = model.openedPDFs.count
        let text = model.openedPDFStage == .needsVault
            ? String(localized: "Open a vault to import \(count) PDFs as new notes.", comment: "Bar under the welcome screen")
            : String(localized: "Unlock the vault to import \(count) PDFs as new notes.", comment: "Bar under the locked vault")
        HStack {
            Label(text, systemImage: "doc.richtext")
                .font(.callout)
            Spacer()
            Button("Discard") { model.discardOpenedPDFs() }
                .help("Forget the PDFs waiting to be imported")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension View {
    func windowSheets(_ ui: WindowUI) -> some View {
        modifier(WindowSheets(ui: ui)).modifier(ExpectationsSheets(ui: ui))
    }
}
