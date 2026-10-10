import Sempere
import SwiftUI

/// The selected note: one page at a time on the canvas, with page controls.
/// Opens a `NoteEditor` through the model when the selection changes and
/// saves when the app goes to the background.
struct NoteCanvasView: View {
    @AppModelEnvironment private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    @Environment(WindowUI.self) private var ui
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = KeepScreenOn.defaultValue

    var body: some View {
        Group {
            if let note = model.selectedNote {
                if model.windowClaims.contains(note.id) {
                    ContentUnavailableView("Open in Its Own Window", systemImage: "macwindow",
                                           description: Text("This note is shown in a window of its own."))
                } else if model.canvasWindow != ui.id {
                    // Another library window shows the canvas: one canvas per editor.
                    ContentUnavailableView {
                        Label("Shown in Another Window", systemImage: "macwindow.on.rectangle")
                    } actions: {
                        Button("Show Here") { model.canvasWindow = ui.id }
                    }
                } else if let editor = model.editor, editor.noteID == note.id {
                    EditorView(editor: editor)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("noteEditor")
                        .navigationTitle(NoteTitle.display(note.title))
                } else if let failure = model.editorFailure, failure.id == note.id {
                    ContentUnavailableView {
                        Label("Could Not Open Note", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Try Again") { Task { await model.showSelectedNote() } }
                    }
                } else if let download = model.noteDownload, download.id == note.id {
                    VStack(spacing: 10) {
                        ProgressView(value: download.progress.fractionCompleted).frame(width: 240)
                        Text("Downloading this note from iCloud: \(download.progress.downloaded) of \(String(localized: "\(download.progress.total) files"))")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if model.pendingNoteIDs.contains(note.id) {
                    ProgressView("Downloading this note from iCloud…")
                } else {
                    ProgressView("Opening…")
                }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
            }
        }
        .toolbar {
            if let note = model.selectedNote {
                // The title itself: tap it, or press and hold it, to rename the note.
                ToolbarItem(placement: .principal) {
                    Button {
                        startRename(note)
                    } label: {
                        HStack(spacing: 4) {
                            Text(NoteTitle.display(note.title)).font(.headline).lineLimit(1)
                            Image(systemName: "pencil").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in startRename(note) })
                    .accessibilityLabel("Note title: \(NoteTitle.display(note.title))")
                    .accessibilityHint("Renames the note")
                    .help("Rename the note (or press and hold)")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Rename…", systemImage: "pencil") { startRename(note) }
                        .help("Rename the note")
                }
                ToolbarItem(placement: .secondaryAction) {
                    ExportMenu(ids: [note.id])
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Save Version…", systemImage: "bookmark") { ui.saveVersionNoteID = note.id }
                        .disabled(note.deleted)
                        .help("Save this version of the note under a name; saved versions are never thinned")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Version History…", systemImage: "clock.arrow.circlepath") { ui.historyNoteID = note.id }
                        .help("Browse earlier versions of the note and restore one")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Toggle("Keep Screen On", systemImage: "sun.max", isOn: $keepScreenOn)
                        .help("Keep the screen awake while this note is open")
                }
                ToolbarItem(placement: Platform.isPhone ? .secondaryAction : .primaryAction) {
                    Button("Tags", systemImage: note.tags.isEmpty ? "tag" : "tag.fill") { ui.tagsNoteID = note.id }
                        .help("Edit the note's tags")
                }
            }
            if !Platform.isPhone {   // the stack's back button is the way to the list
                ToolbarItem(placement: .topBarLeading) {
                    let full = ColumnLayout.visibility(from: storedColumns) == .detailOnly
                    Button(LocalizedStringKey(full ? "Show Notes" : "Hide Notes"),
                           systemImage: full ? "list.bullet" : "arrow.up.left.and.arrow.down.right") {
                        withAnimation { storedColumns = ColumnLayout.toggled(storedColumns) }
                    }
                    .disabled(!full && model.selectedNote == nil)
                    .help(LocalizedStringKey(full ? "Show the note list" : "Hide the note list for a full-width canvas"))
                }
            }
        }
        .task(id: ShowKey(note: model.phase == .unlocked ? model.selectedNoteID : nil,
                          claimed: model.selectedNoteID.map { model.windowClaims.contains($0) } ?? false,
                          epoch: model.keyEpoch)) {
            await model.showSelectedNote()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let editor = model.editor {
                Task { await editor.flush() }
            }
        }
    }

    /// What the detail pane has to show: another note, a window taking or
    /// giving a note back, or a key change (every editor was closed).
    private struct ShowKey: Hashable {
        var note: UUID?
        var claimed: Bool
        var epoch: Int
    }

    /// Opens the rename alert (`AppModel.renameNote`, one `setMeta(.title)` delta).
    private func startRename(_ note: NoteSummary) {
        guard ui.renameNoteID == nil else { return }
        ui.renameNoteID = note.id
    }
}

/// The canvas of one note with its toolbar: the library window's detail pane
/// and the note windows (`NoteWindowView`) both show it.
struct EditorView: View {
    let editor: NoteEditor
    @Environment(WindowUI.self) private var ui
    @AppModelEnvironment private var model
    /// Selection mode for placed items (images, text boxes, PDF pages).
    @State private var selectingItems = false
    /// The text tool: a tap edits a text box or starts a new one (`TextBoxEditorController`).
    @State private var addingText = false
    /// PencilKit's palette floats above sheets; it hides while a notice or the tour is up.
    @AppStorage(ToolPalette.visibleKey) private var paletteVisible = true
    @AppStorage(ToolPalette.compactKey) private var paletteCompact = false
    @AppStorage(ObjectEraserSize.defaultsKey) private var eraserRadius = ObjectEraserSize.defaultRadius
    /// iPhone only: finger annotation is off until the pencil button turns it on.
    @State private var annotating = false
    @AppStorage(PageStrip.visibleKey) private var stripVisible = false
    /// Deleted pages the undo banner has already been shown for.
    @State private var undoBannerFor = 0
    /// Photos, camera, PDF pages and crop (`EditorInsert`).
    @State private var insert = InsertState()
    /// The recording whose transcript is shown (`TranscriptView`).
    @State private var showingTranscript: Recording?
    /// The recording being renamed.
    @State private var renamingRecording: Recording?
    /// `editor.remoteUpdates` the "Updated from another device" notice is shown for (0: none).
    @State private var remoteNoticeFor = 0

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            if let reason = editor.readOnlyReason {
                Banner(text: reason, systemImage: "lock", tint: .secondary)
            }
            if let error = editor.saveError {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            RecordingBar(editor: editor, showingTranscript: $showingTranscript)
            if let cursor = editor.searchCursor {
                SearchMatchBar(position: cursor.position, count: cursor.count,
                               previous: { editor.stepSearchMatch(-1) }, next: { editor.stepSearchMatch(1) },
                               done: { editor.clearSearchHighlight() })
            }
            if undoBannerFor > 0, undoBannerFor == editor.deletedPages.count {
                HStack {
                    Label("Page deleted.", systemImage: "trash").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { editor.undoDeletePage() }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                .task(id: undoBannerFor) {
                    try? await Task.sleep(for: .seconds(6))
                    undoBannerFor = 0
                }
            }
            if !editor.isPageless, !editor.pages.isEmpty {
                // Paged: every page in one scroll (lazy canvases), the current page follows it.
                PageStackView(editor: editor, pageIDs: editor.pages.map(\.id), pageSize: editor.pageSize,
                              pageJump: editor.pageJump,
                              paletteVisible: paletteVisible && ui.expectations == nil,
                              paletteCompact: PhoneReading.paletteCompact(isPhone: Platform.isPhone, stored: paletteCompact),
                              drawingSuspended: PhoneReading.drawingSuspended(isPhone: Platform.isPhone, annotating: annotating),
                              generation: editor.canvasGeneration,
                              itemSource: model.itemLayerSource, itemCommands: itemCommands,
                              selectingItems: selectingItems, onSelectingItemsEnded: { selectingItems = false },
                              addingText: addingText, onAddingTextEnded: { addingText = false },
                              onDrop: editor.isReadOnly ? nil : { providers, page, point in
                                  EditorInsert.add(providers, to: editor, page: page, at: point, model: model, ui: ui, state: insert)
                              })
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if let page = editor.currentPage {
                PageCanvasView(editor: editor, pageID: page.id, paper: editor.displayedPaper(of: page), pageSize: editor.pageSize,
                               paletteVisible: paletteVisible && ui.expectations == nil,
                               paletteCompact: PhoneReading.paletteCompact(isPhone: Platform.isPhone, stored: paletteCompact),
                               drawingSuspended: PhoneReading.drawingSuspended(isPhone: Platform.isPhone, annotating: annotating),
                               generation: editor.canvasGeneration,
                               itemSource: model.itemLayerSource, itemCommands: itemCommands,
                               selectingItems: selectingItems, onSelectingItemsEnded: { selectingItems = false },
                               addingText: addingText, onAddingTextEnded: { addingText = false },
                               onDrop: editor.isReadOnly ? nil : { providers, page, point in
                                   EditorInsert.add(providers, to: editor, page: page, at: point, model: model, ui: ui, state: insert)
                               })
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc")
                } description: {
                    Text("This note has no pages yet.")
                } actions: {
                    if !editor.isReadOnly {
                        Button("Add Page") { editor.addPage() }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if remoteNoticeFor > 0, remoteNoticeFor == editor.remoteUpdates {
                RemoteUpdateNotice()
                    .padding(.top, 8)
                    .transition(.opacity)
                    .task(id: remoteNoticeFor) {
                        try? await Task.sleep(for: RemoteUpdateNotice.duration)
                        withAnimation { remoteNoticeFor = 0 }
                    }
            }
        }
        .onChange(of: editor.remoteUpdates) { _, new in
            withAnimation { remoteNoticeFor = new }
        }
        .inspector(isPresented: Binding(get: { stripVisible && !editor.isPageless }, set: { stripVisible = $0 })) {
            // On a phone the inspector is a sheet: picking a page closes it.
            PageStripView(editor: editor, onPicked: { if Platform.isPhone { stripVisible = false } })
                .inspectorColumnWidth(min: 150, ideal: 180, max: 260)
        }
        .modifier(EditorInsert(editor: editor, state: insert, ui: ui))
        // File > Insert Photo… and Insert PDF Pages… (Mac menu): the Insert menu's pickers.
        .onChange(of: ui.insertRequest) { _, request in
            guard let request else { return }
            ui.insertRequest = nil
            insert.open(request, pageless: editor.isPageless)
        }
        .onChange(of: editor.deletedPages.count) { old, new in
            undoBannerFor = new > old ? new : 0
        }
        #if DEBUG
        .task {
            // App Store screenshots: show the paper picker over the note (DemoLaunch).
            if DebugLaunch.environment["SEMPERE_DEMO_PAPER_PICKER"] != nil {
                try? await Task.sleep(for: .seconds(2))
                ui.choosingPaper = true
            }
        }
        #endif
        .sheet(isPresented: $ui.choosingPaper) {
            if let page = editor.currentPage {
                PaperPickerView(paper: editor.displayedPaper(of: page),
                                purpose: .page(number: editor.pageIndex + 1, count: editor.pages.count),
                                onPreview: { editor.showPaperPreview($0) },
                                onChoose: { paper, choice in editor.setPaper(paper, allPages: choice == .allPages) })
            }
        }
        .onChange(of: editor.noteID) {
            annotating = PhoneReading.annotatingAfterNoteChange()
            selectingItems = false
            addingText = false
            showingTranscript = nil
            remoteNoticeFor = 0
        }
        // Tools > Text and Select (Mac menu): the toolbar toggles of the same name.
        .onChange(of: ui.toolRequest) { _, request in
            guard let request else { return }
            ui.toolRequest = nil
            switch request {
            case .text: if !editor.isReadOnly, editor.currentPage != nil { addingText.toggle() }
            case .select: if showsItemSelection { selectingItems.toggle() }
            }
        }
        .onChange(of: selectingItems) { if selectingItems { addingText = false } }
        .onChange(of: addingText) { if addingText { selectingItems = false } }
        .sheet(item: $showingTranscript) { TranscriptView(editor: editor, recording: $0) }
        // The note's recordings, on or off its pages (Recordings…, Note > Recordings… on the Mac).
        .sheet(isPresented: $ui.showingRecordings) {
            RecordingsListView(editor: editor) { r in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))   // after the list's sheet is gone
                    showingTranscript = r
                }
            }
        }
        .sheet(item: $renamingRecording) { RenameRecordingSheet(editor: editor, recording: $0) }
        .toolbar {
            if Platform.isPhone { phoneToolbar } else { fullToolbar }
        }
    }

    private var phoneItems: PhoneToolbar.Items {
        PhoneToolbar.items(readOnly: editor.isReadOnly, annotating: annotating, pageCount: editor.pages.count,
                           hasPage: editor.currentPage != nil, pageEntries: !phonePageEntries.isEmpty)
    }

    /// The iPhone's toolbar: one pencil button for light annotation, page
    /// controls in the bottom bar (in a menu while annotating, so the bar does
    /// not sit on the palette), the rest in the overflow menu (`PhoneToolbar`).
    @ToolbarContentBuilder
    private var phoneToolbar: some ToolbarContent {
        if phoneItems.writes {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Annotate", systemImage: annotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                       isOn: $annotating)
                    .toggleStyle(.button)
                    .help("Draw on the page with a finger")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Paper…", systemImage: "square.grid.3x3") { ui.choosingPaper = true }
                    .disabled(editor.currentPage == nil)
                    .help("Choose the paper (ruling, colour) of this page or all pages")
            }
            ToolbarItem(placement: .secondaryAction) { favoriteButton }
            ToolbarItem(placement: .secondaryAction) { insertMenu }
            ToolbarItem(placement: .secondaryAction) { recordingsMenu }
            ToolbarItem(placement: .secondaryAction) { recordingsListButton }
            if phoneItems.writingTools {
                ToolbarItem(placement: .secondaryAction) { textToolToggle }
                ToolbarItem(placement: .secondaryAction) { eraserSizeMenu }
                if phoneItems.selectToggle {
                    ToolbarItem(placement: .secondaryAction) { itemSelectionToggle }
                }
            }
        }
        // The page actions (layout, add, duplicate, delete, undo, PDF at this page, thumbnails)
        // are in this menu whether or not the pencil is on; while annotating it also turns pages,
        // since the bottom bar gives way to the palette then.
        if phoneItems.pagesMenu {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Pages", systemImage: "doc.on.doc") { pageButtons }
                    .help("Go to another page, add, duplicate or delete one, or show the thumbnails")
            }
        }
        if phoneItems.pageBar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous Page", systemImage: "chevron.left") { editor.selectPage(editor.pageIndex - 1) }
                    .disabled(editor.pageIndex == 0)
                    .help("Previous page")
                Spacer()
                pageCounter
                Spacer()
                Button("Next Page", systemImage: "chevron.right") { editor.selectPage(editor.pageIndex + 1) }
                    .disabled(editor.pageIndex + 1 >= editor.pages.count)
                    .help("Next page")
            }
        }
    }

    /// The model's item commands, with Crop opening this editor's crop sheet.
    private var itemCommands: ItemCommands {
        var commands = model.itemCommands
        let state = insert, note = editor.noteID
        commands.crop = { item, page, actions in
            state.cropping = CropRequest(item: item, page: page, note: note, actions: actions)
        }
        commands.replace = { item, page, actions, source, done in
            state.replacing = ReplaceRequest(item: item, page: page, actions: actions, done: done)
            switch source {
            case .photos: state.pickingReplacementPhoto = true
            case .files:
                state.fileImport = .image
                state.pickingFile = true
            }
        }
        let editor = self.editor
        commands.play = { item, page in
            state.playing = VideoPlayRequest(item: item, page: page, editor: editor)
        }
        commands.editMath = { item, page, actions in
            state.editingMath = MathRequest(editor: editor, page: page, item: item, actions: actions, visible: nil)
        }
        // A recording's card on the page (format.md §8.2.9): its button plays or pauses it.
        let model = self.model
        commands.toggleRecording = { id in model.toggleRecording(id, in: editor) }
        let transcript = $showingTranscript
        commands.showTranscript = { id in transcript.wrappedValue = editor.recording(id) }
        return commands
    }

    private var recordingsListButton: some View {
        Button("Recordings…", systemImage: "waveform") { ui.showingRecordings = true }
            .help("List this note's recordings")
    }

    private var recordingsMenu: some View {
        RecordingsMenu(editor: editor, showingTranscript: $showingTranscript, renaming: $renamingRecording)
    }

    private var insertMenu: some View {
        InsertMenu(editor: editor, state: insert, onAddText: { addingText = true }) { providers in
            EditorInsert.add(providers, to: editor, page: editor.currentPage?.id, at: nil, model: model, ui: ui, state: insert)
        }
    }

    /// Whether the Select toggle is offered: whenever the note can be edited
    /// (always in the same place: a toggle that comes and goes with the
    /// current page's items cannot be found; on a paged note the current page
    /// is the one at the top of the screen, not the one with the photo).
    private var showsItemSelection: Bool {
        !editor.isReadOnly && editor.currentPage != nil
    }

    private var textToolToggle: some View {
        Toggle("Text", systemImage: "character.textbox", isOn: $addingText)
            .toggleStyle(.button)
            .help("Type text: tap the page for a new text box, or a text box to edit it")
    }

    private var itemSelectionToggle: some View {
        Toggle("Select", systemImage: "cursorarrow.rays", isOn: $selectingItems)
            .toggleStyle(.button)
            .help("Select images, text boxes, PDF pages and videos to move, resize, crop, replace or delete them. While drawing: tap one with the lasso, hold a finger on it, or right-click it")
    }

    private var pageCounter: some View {
        Text(verbatim: editor.pages.isEmpty ? "–" : "\(editor.pageIndex + 1) / \(editor.pages.count)")
            .monospacedDigit()
    }

    /// What the iPhone's Pages menu offers besides turning pages.
    private var phonePageEntries: [PhonePageMenu.Entry] {
        PhonePageMenu.entries(readOnly: editor.isReadOnly, pageless: editor.isPageless,
                              pageCount: editor.pages.count, hasDeletedPages: !editor.deletedPages.isEmpty)
    }

    /// The iPhone's Pages menu (titles shown).
    @ViewBuilder
    // help-lint: titled
    private var pageButtons: some View {
        if editor.pages.count > 1 {
            Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
                .disabled(editor.pageIndex == 0)
            Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
                .disabled(editor.pageIndex + 1 >= editor.pages.count)
        }
        ForEach(phonePageEntries, id: \.self) { entry in
            phonePageButton(entry)
        }
        Text(editor.pages.isEmpty ? "No pages" : "Page \(editor.pageIndex + 1) of \(editor.pages.count)")
    }

    /// Marks this note as a favorite or not (Favorites in the sidebar).
    private var favoriteButton: some View {
        let on = model.notes.first { $0.id == editor.noteID }?.favorite ?? false
        return Button(LocalizedStringKey(on ? "Remove from Favorites" : "Add to Favorites"),
                      systemImage: on ? "star.fill" : "star") {
            Task { await model.report { try await model.setFavorite(!on, for: editor.noteID) } }
        }
        .disabled(model.isVaultReadOnly)
        .help(LocalizedStringKey(on ? "Remove this note from Favorites" : "Add this note to Favorites"))
    }

    @ViewBuilder
    // help-lint: titled
    private func phonePageButton(_ entry: PhonePageMenu.Entry) -> some View {
        switch entry {
        case .addAfter:
            Button("Add Page After This One", systemImage: "doc.badge.plus") { editor.addPageAfterCurrent() }
        case .addAtEnd:
            Button("Add Page at End", systemImage: "arrow.down.to.line") { editor.addPage() }
        case .insertPDF:
            Button(InsertOptions.pdfPagesTitle(pageless: false, pageIndex: editor.pageIndex, pageCount: editor.pages.count),
                   systemImage: "doc.richtext") {
                insert.fileImport = .pdf
                insert.pickingFile = true
            }
        case .duplicate:
            Button("Duplicate Page", systemImage: "plus.square.on.square") {
                if let page = editor.currentPage { editor.duplicatePage(page.id) }
            }
            .disabled(editor.currentPage == nil)
        case .delete:
            Button("Delete Page", systemImage: "trash", role: .destructive) {
                if let page = editor.currentPage { editor.deletePage(page.id) }
            }
            .disabled(!editor.canDeletePage || editor.currentPage == nil)
        case .undoDelete:
            Button("Undo Delete Page", systemImage: "arrow.uturn.backward") { editor.undoDeletePage() }
        case .thumbnails:
            Button(LocalizedStringKey(stripVisible ? "Hide Pages" : "Show Pages"), systemImage: "sidebar.right") {
                stripVisible.toggle()
            }
        case .layout:
            Button(LocalizedStringKey(editor.isPageless ? "Switch to Paged Layout" : "Switch to Pageless Layout"),
                   systemImage: editor.isPageless ? "doc.on.doc" : "scroll") {
                Task { await editor.setLayout(pageless: !editor.isPageless) }
            }
        }
    }

    private var eraserSizeMenu: some View {
        // PencilKit's object eraser has no size; the app's does (ObjectEraser.swift).
        Menu {
            Picker("Object Eraser Size", selection: $eraserRadius) {
                ForEach(ObjectEraserSize.radii, id: \.self) { r in
                    Text("\(ObjectEraserSize.name(of: r)) – \(Int(r)) pt").tag(r)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Object Eraser Size", systemImage: "eraser.line.dashed")
        }
        .help("Size of the object eraser; the pixel eraser's size is in the tool palette")
    }

    /// The iPad's and the Mac's toolbar.
    @ToolbarContentBuilder
    private var fullToolbar: some ToolbarContent {
            if !editor.isReadOnly {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Paper…", systemImage: "square.grid.3x3") { ui.choosingPaper = true }
                        .disabled(editor.currentPage == nil)
                        .help("Choose the paper (ruling, colour) of this page or all pages")
                }
                ToolbarItem(placement: .secondaryAction) {
                    // Switching never deletes ink (format.md §5.4.3); it is one delta.
                    Picker(selection: Binding(
                        get: { editor.isPageless },
                        set: { pageless in Task { await editor.setLayout(pageless: pageless) } })) {
                        Label("Pages", systemImage: "doc.on.doc").tag(false)
                        Label("Pageless", systemImage: "scroll").tag(true)
                    } label: {
                        Label("Page Layout", systemImage: "rectangle.split.1x2")
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .primaryAction) {
                    // Tap: show or hide the palette. Press and hold: compact palette.
                    Menu {
                        Toggle("Compact Palette", systemImage: "rectangle.compress.vertical", isOn: $paletteCompact)
                    } label: {
                        Label(LocalizedStringKey(paletteVisible ? "Hide Tools" : "Show Tools"),
                              systemImage: paletteVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    } primaryAction: {
                        paletteVisible.toggle()
                    }
                    .help("Show or hide the tool palette; press and hold for the compact palette")
                }
            }
            ToolbarItem(placement: .primaryAction) { favoriteButton }
            if !editor.isReadOnly, editor.currentPage != nil {
                ToolbarItem(placement: .primaryAction) { textToolToggle }
            }
            if !editor.isReadOnly {
                ToolbarItem(placement: .primaryAction) { insertMenu }
            }
            if !editor.isReadOnly || !editor.recordings.isEmpty {
                ToolbarItem(placement: .primaryAction) { recordingsMenu }
            }
            // The note's menu ("…"): every recording, whether or not it is on a page.
            ToolbarItem(placement: .secondaryAction) { recordingsListButton }
            if showsItemSelection {
                ToolbarItem(placement: .primaryAction) { itemSelectionToggle }
            }
            if !editor.isReadOnly {
                ToolbarItem(placement: .primaryAction) {
                    // PencilKit's object eraser has no size; the app's does (ObjectEraser.swift).
                    Menu {
                        Picker("Object Eraser Size", selection: $eraserRadius) {
                            ForEach(ObjectEraserSize.radii, id: \.self) { r in
                                Text("\(ObjectEraserSize.name(of: r)) – \(Int(r)) pt").tag(r)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Object Eraser Size", systemImage: "eraser.line.dashed")
                    }
                    .help("Size of the object eraser; the pixel eraser's size is in the tool palette")
                }
            }
            // A pageless note is one page (an older one may have several: they can be browsed).
            if editor.pages.count > 1 || (!editor.isReadOnly && !editor.isPageless) {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
                        .disabled(editor.pageIndex == 0)
                        .help("Previous page (⌘[)")
                    Text(verbatim: editor.pages.isEmpty ? "–" : "\(editor.pageIndex + 1) / \(editor.pages.count)")
                        .monospacedDigit()
                    Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
                        .disabled(editor.pageIndex + 1 >= editor.pages.count)
                        .help("Next page (⌘])")
                    if !editor.isReadOnly && !editor.isPageless {
                        // Tap: a page after this one. Press and hold: the other page actions.
                        Menu {
                            Button("Add Page After This One", systemImage: "doc.badge.plus") { editor.addPageAfterCurrent() }
                            Button("Add Page at End", systemImage: "arrow.down.to.line") { editor.addPage() }
                            Button(InsertOptions.pdfPagesTitle(pageless: false, pageIndex: editor.pageIndex,
                                                               pageCount: editor.pages.count),
                                   systemImage: "doc.richtext") {
                                insert.fileImport = .pdf
                                insert.pickingFile = true
                            }
                            if let page = editor.currentPage {
                                Button("Duplicate Page", systemImage: "plus.square.on.square") { editor.duplicatePage(page.id) }
                                Button("Delete Page", systemImage: "trash", role: .destructive) { editor.deletePage(page.id) }
                                    .disabled(!editor.canDeletePage)
                            }
                            if !editor.deletedPages.isEmpty {
                                Button("Undo Delete Page", systemImage: "arrow.uturn.backward") { editor.undoDeletePage() }
                            }
                        } label: {
                            Label("Add Page", systemImage: "doc.badge.plus")
                        } primaryAction: {
                            editor.addPageAfterCurrent()
                        }
                        .help("Add a page after this one; press and hold to duplicate, delete or add at the end")
                    }
                    if !editor.isPageless {
                        Button(LocalizedStringKey(stripVisible ? "Hide Pages" : "Show Pages"), systemImage: "sidebar.right") {
                            stripVisible.toggle()
                        }
                        .help("Page thumbnails: tap to go to a page, drag to reorder")
                    }
                }
            }
    }
}

/// Above the canvas while a search is highlighted: "3 of 12", previous and
/// next (wrapping across the pages), and Done.
struct SearchMatchBar: View {
    let position: Int
    let count: Int
    let previous: () -> Void
    let next: () -> Void
    let done: () -> Void

    /// "3 of 12 matches", "1 match".
    static func label(position: Int, count: Int) -> String {
        count == 1 ? String(localized: "1 match", comment: "Search highlights: the only match")
            : String(localized: "\(position) of \(count) matches", comment: "Search highlights: current match of the count (never 1)")
    }

    var body: some View {
        HStack(spacing: 14) {
            Label(Self.label(position: position, count: count), systemImage: "text.magnifyingglass")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button("Previous Match", systemImage: "chevron.up", action: previous)
                .labelStyle(.iconOnly)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(count < 2)
                .help("Previous match (⇧⌘G)")
            Button("Next Match", systemImage: "chevron.down", action: next)
                .labelStyle(.iconOnly)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(count < 2)
                .help("Next match (⌘G)")
            Button("Done", action: done)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

/// "Updated from another device": a small capsule over the top of the
/// canvas for a few seconds after a merge brought another device's changes
/// (`NoteEditor.mergeRevisions`). It takes no touches.
struct RemoteUpdateNotice: View {
    static let text = String(localized: "Updated from another device", comment: "Notice over the canvas after another device's changes were merged into the open note")
    static let duration = Duration.seconds(3)

    var body: some View {
        Label(Self.text, systemImage: "arrow.triangle.2.circlepath")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityIdentifier("remoteUpdateNotice")
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: SwiftUI.Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// How a note's title is shown.
enum NoteTitle {
    static func display(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Untitled", comment: "Shown for a note without a title") : t
    }
}
