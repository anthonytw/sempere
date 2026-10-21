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
                // With the note open, these are in the editor's toolbar (`NoteToolbar`: one order on every
                // device); here only while it is not (opening, downloading, could not open: its history is
                // still there to restore from).
                if !showsEditor(note) {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Rename…", systemImage: "pencil") { startRename(note) }
                            .help("Rename the note")
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        ExportMenu(ids: [note.id])
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Version History…", systemImage: "clock.arrow.circlepath") { ui.historyNoteID = note.id }
                            .help("Browse earlier versions of the note and restore one")
                    }
                }
            }
            if !Platform.isPhone {   // the stack's back button is the way to the list
                ToolbarItem(placement: .topBarLeading) {
                    let full = ColumnLayout.visibility(from: storedColumns) == .detailOnly
                    Button(LocalizedStringKey(full ? "Show Note List" : "Hide Note List"),
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

    /// Whether the detail pane shows `note`'s editor (whose toolbar then has the note's actions).
    private func showsEditor(_ note: NoteSummary) -> Bool {
        !model.windowClaims.contains(note.id) && model.canvasWindow == ui.id && model.editor?.noteID == note.id
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
    /// Selection mode for placed items (images, text boxes, PDF pages), or the
    /// text tool (a tap edits a text box or starts a new one, once:
    /// `TextBoxEditorController`, `CanvasModes`), or drawing.
    @State private var modes = CanvasModes()
    @AppStorage(ToolPalette.compactKey) private var paletteCompact = false
    @AppStorage(ObjectEraserSize.defaultsKey) private var eraserRadius = ObjectEraserSize.defaultRadius
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = KeepScreenOn.defaultValue
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
                              paletteVisible: canvasPaletteVisible,
                              input: modeInput,
                              generation: editor.canvasGeneration,
                              itemSource: model.itemLayerSource, itemCommands: itemCommands,
                              selectingItems: canvasSelectingItems, onSelectingItemsEnded: selectingItemsEnded,
                              onPencilAnnotate: pencilTouched,
                              addingText: modes.addingText, onAddingTextEnded: { modes.textToolEnded($0) },
                              onDrop: editor.isReadOnly ? nil : { providers, page, point in
                                  EditorInsert.add(providers, to: editor, page: page, at: point, model: model, ui: ui, state: insert)
                              })
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if let page = editor.currentPage {
                PageCanvasView(editor: editor, pageID: page.id, paper: editor.displayedPaper(of: page), pageSize: editor.pageSize,
                               paletteVisible: canvasPaletteVisible,
                               input: modeInput,
                               generation: editor.canvasGeneration,
                               itemSource: model.itemLayerSource, itemCommands: itemCommands,
                               selectingItems: canvasSelectingItems, onSelectingItemsEnded: selectingItemsEnded,
                               onPencilAnnotate: pencilTouched,
                               addingText: modes.addingText, onAddingTextEnded: { modes.textToolEnded($0) },
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
        // Sempere's drawing palette (`DrawingPaletteView`), on every device, while annotating.
        .overlay(alignment: .bottom) {
            if showsPalette {
                DrawingPaletteView(editor: editor,
                                   compact: PhoneReading.paletteCompact(isPhone: Platform.isPhone, stored: paletteCompact))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        // The Apple Pencil's double-tap and squeeze (Settings ▸ Apple Pencil), while annotating.
        .background(PencilGestureHost(enabled: showsPalette))
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
        // An editor opened again after another device's key change says so from its first frame.
        .onAppear { if editor.remoteUpdates > 0 { remoteNoticeFor = editor.remoteUpdates } }
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
        // Every note opens in reading mode (on every device), the next one too; a view rebuilt for the same
        // editor (a column layout change) keeps the mode.
        .onAppear { startModeIfNewEditor() }
        .onChange(of: ObjectIdentifier(editor)) { startModeIfNewEditor() }
        .onChange(of: editor.noteID) {
            ui.noteMode = Self.openingMode
            ui.noteModeEditor = ObjectIdentifier(editor)
            modes.reset()
            showingTranscript = nil
            remoteNoticeFor = 0
        }
        // The text tool is one of Annotate's: leaving Annotate puts it down.
        .onChange(of: ui.noteMode) { _, mode in
            if mode != .annotating, modes.addingText { modes.reset() }
        }
        // Tools > Annotate, Hand and Text (Mac menu, keyboard): the toolbar buttons of the same name.
        .onChange(of: ui.toolRequest) { _, request in
            guard let request else { return }
            ui.toolRequest = nil
            guard showsModeButtons else { return }
            switch request {
            case .annotate: ui.noteMode = ui.noteMode.tapping(.annotate)
            case .hand: ui.noteMode = ui.noteMode.tapping(.hand)
            case .draw: ui.noteMode = ui.noteMode.toolPicked()
            case .text: toggleTextTool()
            }
        }
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
        .toolbar { noteToolbar }
    }

    /// The mode a note opens in: reading (`NoteMode.initial`), or a debug launch's (`SEMPERE_DEBUG_NOTE_MODE`).
    static var openingMode: NoteMode {
        #if DEBUG
        if let mode = NoteMode.debugInitial(DebugLaunch.environment["SEMPERE_DEBUG_NOTE_MODE"]) { return mode }
        #endif
        return .initial
    }

    /// A note just opened in this window (a new editor): reading mode.
    private func startModeIfNewEditor() {
        let id = ObjectIdentifier(editor)
        guard ui.noteModeEditor != id else { return }
        ui.noteModeEditor = id
        ui.noteMode = Self.openingMode
        modes.reset()
    }

    /// What the mode lets the canvas do on this device.
    private var modeInput: NoteModeInput { .of(ui.noteMode, on: .current) }

    /// The palette: Annotate only, and hidden under a notice or the tour.
    private var canvasPaletteVisible: Bool {
        modeInput.showsPalette && ui.expectations == nil
    }

    /// The drawing palette is on screen: annotating an editable note with a page.
    private var showsPalette: Bool {
        canvasPaletteVisible && !editor.isReadOnly && editor.currentPage != nil
    }

    /// Selection mode for the canvas: the Hand (not while the text tool is armed).
    private var canvasSelectingItems: Bool {
        modeInput.selectingItems && !modes.addingText
    }

    /// The canvas ended selection mode: a tool was picked (the Mac's Tools menu). Picking a tool is drawing.
    private func selectingItemsEnded() {
        if ui.noteMode == .hand { ui.noteMode = ui.noteMode.toolPicked() }
    }

    /// A Pencil started drawing while reading or in Hand mode (an iPad): annotating, with that stroke.
    private func pencilTouched() {
        ui.noteMode = ui.noteMode.pencilTouched()
    }

    /// Arms or puts down the text tool; arming it from reading or Hand switches to Annotate (it is one of
    /// Annotate's tools).
    private func toggleTextTool() {
        guard !editor.isReadOnly, editor.currentPage != nil else { return }
        if ui.noteMode != .annotating {
            ui.noteMode = ui.noteMode.toolPicked()
            modes.addingText = true
        } else {
            modes.addingText.toggle()
        }
    }

    /// What the toolbar is built from (`NoteToolbar`).
    private var toolbarState: NoteToolbar.State {
        NoteToolbar.State(device: .current, mode: ui.noteMode, readOnly: editor.isReadOnly,
                          hasPage: editor.currentPage != nil, pageCount: editor.pages.count, pageless: editor.isPageless,
                          hasRecordings: !editor.recordings.isEmpty, pageEntries: !pageEntries.isEmpty,
                          noteWindow: model.windowEditors[editor.noteID] === editor)
    }

    /// The note: its summary in the list (title, tags, favorite, deleted).
    private var note: NoteSummary? { model.notesByID[editor.noteID] }

    /// One of the top bar's two mode buttons: lit in its own mode; a tap on the lit one goes back to reading,
    /// on the other one switches straight to that mode (`NoteMode.tapping`). The iPad's pencil keeps the
    /// compact palette in its menu (press and hold); an iPhone's palette is always the compact one, and a
    /// Mac's is chosen in the Tools menu (Use Compact Palette) or Settings.
    @ViewBuilder
    private func modeButton(_ button: NoteMode.Button) -> some View {
        let on = ui.noteMode.lights(button)
        let binding = Binding(get: { ui.noteMode.lights(button) }, set: { _ in ui.noteMode = ui.noteMode.tapping(button) })
        switch button {
        case .annotate where !Platform.isPhone && !Platform.isMac:
            Menu {
                Toggle("Compact Palette", systemImage: "rectangle.compress.vertical", isOn: $paletteCompact)
            } label: {
                Label("Annotate", systemImage: on ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            } primaryAction: {
                ui.noteMode = ui.noteMode.tapping(.annotate)
            }
            .accessibilityIdentifier("annotateButton")
            .accessibilityValue(Text(verbatim: on ? "1" : "0"))
            .accessibilityAddTraits(on ? .isSelected : [])
            .help("Annotate: draw on the page with the tool palette; press and hold for the compact palette")
        case .annotate:
            Toggle("Annotate", systemImage: on ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", isOn: binding)
                .toggleStyle(.button)
                .accessibilityIdentifier("annotateButton")
                .help(Platform.isMac ? "Annotate: draw on the page with the mouse and the tool palette"
                                     : "Annotate: draw on the page with a finger")
        case .hand:
            Toggle("Hand", systemImage: on ? "hand.point.up.left.fill" : "hand.point.up.left", isOn: binding)
                .toggleStyle(.button)
                .accessibilityIdentifier("handButton")
                .help(Platform.isMac ? "Hand: click an item to select it, drag to move or resize it; nothing draws"
                                     : "Hand: scroll with one finger, tap an item to select it, hold for its menu, drag to move it")
        }
    }

    /// Whether the mode buttons are offered (`NoteToolbar`: an editable note with a page).
    private var showsModeButtons: Bool {
        NoteToolbar.isAvailable(.annotate, in: toolbarState)
    }

    /// The note view's toolbar on every device (`NoteToolbar`): the top bar's items, then the overflow
    /// menu's, in one order; the iPhone's page navigation in the bottom bar.
    @ToolbarContentBuilder
    private var noteToolbar: some ToolbarContent {
        let state = toolbarState
        ForEach(NoteToolbar.items(.bar, in: state), id: \.self) { item in
            ToolbarItem(placement: .primaryAction) { toolbarView(item) }
        }
        ForEach(NoteToolbar.items(.overflow, in: state), id: \.self) { item in
            ToolbarItem(placement: .secondaryAction) { toolbarView(item) }
        }
        if NoteToolbar.items(.bottomBar, in: state).contains(.pageNavigation) {
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

    /// One toolbar item (`NoteToolbar.Item`), wherever it is placed.
    @ViewBuilder
    private func toolbarView(_ item: NoteToolbar.Item) -> some View {
        switch item {
        case .annotate: modeButton(.annotate)
        case .hand: modeButton(.hand)
        case .drawingTools: macToolsMenu
        case .text: textToolToggle
        case .eraserSize: eraserSizeMenu
        case .insert: insertMenu
        case .recordings: recordingsMenu
        case .favorite: favoriteButton
        case .tags:
            Button("Tags", systemImage: note?.tags.isEmpty == false ? "tag.fill" : "tag") { ui.tagsNoteID = editor.noteID }
                .help("Edit the note's tags")
        case .pageNavigation:
            HStack {
                Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
                    .disabled(editor.pageIndex == 0)
                    .help("Previous page (⌘[)")
                // Never squeezed: a narrow window's toolbar truncated "1 / 1" (PseudoLanguageLayoutTests).
                pageCounter.fixedSize()
                Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
                    .disabled(editor.pageIndex + 1 >= editor.pages.count)
                    .help("Next page (⌘])")
            }
            .fixedSize()
        case .addPage:
            // Tap: a page after this one. Press and hold: the other page actions.
            Menu {
                pageActionButtons
            } label: {
                Label("Add Page", systemImage: "doc.badge.plus")
            } primaryAction: {
                editor.addPageAfterCurrent()
            }
            .help("Add a page after this one; press and hold to duplicate, delete or add at the end")
        case .thumbnails:
            Button(LocalizedStringKey(stripVisible ? "Hide Pages" : "Show Pages"), systemImage: "sidebar.right") {
                stripVisible.toggle()
            }
            .help("Page thumbnails: tap to go to a page, drag to reorder")
        case .pages:
            Menu("Pages", systemImage: "doc.on.doc") { pageButtons }
                .help("Go to another page, add, duplicate or delete one, show the thumbnails, or switch the layout")
        case .paper:
            Button("Paper…", systemImage: "square.grid.3x3") { ui.choosingPaper = true }
                .disabled(editor.currentPage == nil)
                .help("Choose the paper (ruling, color) of this page or all pages")
        case .allRecordings:
            Button("All Recordings…", systemImage: "list.bullet") { ui.showingRecordings = true }
                .accessibilityIdentifier("allRecordings")
                .help("List this note's recordings: play, transcribe, rename or delete them")
        case .rename:
            Button("Rename…", systemImage: "pencil") { ui.renameNoteID = editor.noteID }
                .help("Rename the note")
        case .export:
            ExportMenu(ids: [editor.noteID])
        case .saveVersion:
            Button("Save Version…", systemImage: "bookmark") { ui.saveVersionNoteID = editor.noteID }
                .disabled(note?.deleted ?? false)
                .help("Save this version of the note under a name; saved versions are never thinned")
        case .versionHistory:
            Button("Version History…", systemImage: "clock.arrow.circlepath") { ui.historyNoteID = editor.noteID }
                .help("Browse earlier versions of the note and restore one")
        case .keepScreenOn:
            Toggle("Keep Screen On", systemImage: "sun.max", isOn: $keepScreenOn)
                .help("Keep the screen awake while this note is open")
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

    private var recordingsMenu: some View {
        RecordingsMenu(editor: editor, showingTranscript: $showingTranscript, renaming: $renamingRecording)
    }

    private var insertMenu: some View {
        InsertMenu(editor: editor, state: insert, onAddText: {
            if ui.noteMode != .annotating { ui.noteMode = ui.noteMode.toolPicked() }
            modes.addingText = true
        }) { providers in
            EditorInsert.add(providers, to: editor, page: editor.currentPage?.id, at: nil, model: model, ui: ui, state: insert)
        }
    }

    private var textToolToggle: some View {
        Toggle("Text", systemImage: "character.textbox", isOn: $modes.addingText)
            .toggleStyle(.button)
            .help("Type text: tap the page for a new text box, or a text box to edit it")
    }

    private var pageCounter: some View {
        Text(verbatim: editor.pages.isEmpty ? "–" : "\(editor.pageIndex + 1) / \(editor.pages.count)")
            .monospacedDigit()
    }

    /// What the Pages menu offers besides turning pages (`PageMenu`, every device).
    private var pageEntries: [PageMenu.Entry] {
        PageMenu.entries(readOnly: editor.isReadOnly, pageless: editor.isPageless,
                         pageCount: editor.pages.count, hasDeletedPages: !editor.deletedPages.isEmpty)
    }

    /// Add Page's menu (iPad and Mac, press and hold): the page actions besides the thumbnails and the layout.
    @ViewBuilder
    // help-lint: titled
    private var pageActionButtons: some View {
        ForEach(pageEntries.filter { $0 != .thumbnails && $0 != .layout }, id: \.self) { entry in
            pageButton(entry)
        }
    }

    /// The Pages menu (the overflow menu's, every device; titles shown).
    @ViewBuilder
    // help-lint: titled
    private var pageButtons: some View {
        if editor.pages.count > 1 {
            Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
                .disabled(editor.pageIndex == 0)
            Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
                .disabled(editor.pageIndex + 1 >= editor.pages.count)
        }
        ForEach(pageEntries, id: \.self) { entry in
            pageButton(entry)
        }
        Text(editor.pages.isEmpty ? "No pages" : "Page \(editor.pageIndex + 1) of \(editor.pages.count)")
    }

    /// Marks this note as a favorite or not (Favorites in the sidebar).
    private var favoriteButton: some View {
        let on = model.notesByID[editor.noteID]?.favorite ?? false
        return Button(LocalizedStringKey(on ? "Remove from Favorites" : "Add to Favorites"),
                      systemImage: on ? "star.fill" : "star") {
            Task { await model.report { try await model.setFavorite(!on, for: editor.noteID) } }
        }
        .disabled(model.isVaultReadOnly)
        .help(LocalizedStringKey(on ? "Remove this note from Favorites" : "Add this note to Favorites"))
    }

    @ViewBuilder
    // help-lint: titled
    private func pageButton(_ entry: PageMenu.Entry) -> some View {
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

    /// The Mac's tool menu beside Annotate: the Tools menu's tools (`MenuCommand.toolPen` …, ⌥⌘1–5) and
    /// the ruler, through the same tool state as the palette (`DrawingToolbox`). It came before the
    /// palette (PencilKit's never shows in a Mac Catalyst app, TestFlight 1.0.0 (6)) and stays for the
    /// pointer and the keyboard's sake.
    private var macToolsMenu: some View {
        Menu {
            ForEach(ToolChoice.allCases, id: \.self) { tool in
                Button(tool.command.title) { editor.canvasTarget?.select(tool: tool) }
            }
            Divider()
            Button(MenuCommand.toggleRuler.title) { editor.canvasTarget?.toggleRuler() }
        } label: {
            Label("Drawing Tools", systemImage: "paintbrush.pointed")
        }
        .help("Pick the pen, marker, pencil, eraser or lasso (also in the Tools menu)")
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

