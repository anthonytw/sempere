import Sempere
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The welcome screen until a vault is open, then three columns: sidebar
/// (notebooks, tags), note list, and the note itself.
struct RootView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @State private var pickingVault = false
    /// The vault folder "Open Vault…" picked, until the user chose how to open it.
    @State private var pickedVault: PickedVault?
    /// A vault opened from outside that would replace the open one (S16).
    @State private var openedVaultToConfirm: AppModel.OpenedVaultConfirmation?
    @State private var creatingVault = false
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    /// Set when a failed reopen should end in the folder picker.
    @State private var pickAfterAlert = false
    /// The kept previous copy being shared (not on a Mac, where Show in Finder opens it).
    @State private var sharingLeftover: WebDAVLeftover?
    @State private var triedAutoOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = KeepScreenOn.defaultValue
    // Read by the menus' titles (Use Full Palette, Hide Pages): the router is rebuilt when they change.
    @AppStorage(ToolPalette.compactKey) private var paletteCompact = false
    @AppStorage(PageStrip.visibleKey) private var pageStripVisible = false
    @Environment(\.openWindow) private var openWindow
    @State private var ui = WindowUI()
    /// The library window's selection, restored with the scene (Mac only).
    @SceneStorage(RestorableSelection.key) private var storedSelection = ""
    /// The vault whose saved selection was applied (or found missing); until
    /// then nothing is saved, so the first selections do not overwrite it.
    @State private var restoredVault: UUID?
    /// Settings ▸ Quick Voice Notes asked for by a widget or the control (`VoiceNoteLink.settings`).
    @State private var showingVoiceSettings = false

    /// The stack column an iPhone shows (`CompactNavigation`); the other devices ignore it.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    /// The split view's columns. An iPhone leaves them to the system (a stack when
    /// compact, columns in a wide landscape) and never stores a hidden list.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { ColumnLayout.visibility(from: storedColumns, isPhone: Platform.isPhone) },
                set: { storedColumns = ColumnLayout.storing($0, over: storedColumns, isPhone: Platform.isPhone) })
    }

    /// The window: its content, then what the Mac menus and scene restoration need.
    /// Two properties, so the compiler checks two shorter modifier chains.
    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("libraryWindow")
            .environment(ui)
            .windowSheets(ui)
            .focusedSceneValue(\.commandRouter, router)
            .menuRouter(router)
            .sheet(isPresented: $ui.creatingNote) {
                NewNoteView(notebook: currentNotebook)
            }
            .sheet(item: $ui.creatingNotebook) { NewNotebookView(request: $0) }
            .onAppear {
                model.libraryWindowCount += 1
                if model.canvasWindow == nil { model.canvasWindow = ui.id }
            }
            .onDisappear {
                model.libraryWindowCount -= 1
                if model.canvasWindow == ui.id { model.canvasWindow = nil }
            }
            .onChange(of: model.phase == .unlocked && !model.isBusy) { _, ready in
                if ready { restoreSelection() }
            }
            .onChange(of: model.selectedNoteID) { saveSelection(); showListWithoutNote() }
            .onChange(of: model.listLoaded) { showListWithoutNote() }
            .onChange(of: restoredVault) { showListWithoutNote() }
            // A closed vault leaves nothing of its selection in the window's saved state.
            .onChange(of: model.phase) { _, phase in
                if SelectionStorage.shouldClear(phase: phase) { storedSelection = "" }
            }
            .onChange(of: model.sidebarSelection) { saveSelection() }
            .menuBarRequests()
    }

    private var content: some View {
        @Bindable var model = model
        return Group {
            if model.phase == .noVault {
                WelcomeView(openFolder: { pickVault() },
                            newVault: { creatingVault = true },
                            openRecent: { entry in Task { await reopen(entry) } },
                            openStored: { entry in
                                Task { await model.report { try await model.openStored(entry, library: library) } }
                            })
            } else {
                splitView
                .onAppear {
                    // The vault opens on its notebooks: nothing is selected, so a tap pushes.
                    if Platform.isPhone, compactColumn == .sidebar { model.sidebarSelection = nil }
                }
                .onChange(of: model.selectedNoteID) { followSelection() }
                .onChange(of: model.sidebarSelection) { followSelection() }
                .onChange(of: compactColumn) { _, column in
                    guard Platform.isPhone else { return }
                    Task { await model.didShowCompactColumn(column) }
                }
            }
        }
        // "Open Vault…" copies the picked vault onto this device (docs/design/device-first-sync.md §8.1).
        .fileImporter(isPresented: $pickingVault, allowedContentTypes: UTType.vaultPickerTypes) { result in
            switch result {
            case .success(let url): pickedVault = PickedVault(url: url)
            case .failure(let error): model.errorMessage = String(describing: error)
            }
        }
        // Then: copy only, or keep syncing with the folder (`OpenVaultSheet`).
        .sheet(item: $pickedVault) { OpenVaultSheet(picked: $0) }
        .openedVaultAlert($openedVaultToConfirm)
        .onOpenURL { url in
            switch VoiceNoteLink.route(url) {
            case .link(let link):
                // A widget, the control or the Live Activity (`sempere://quick-voice/…`).
                model.quickCapture.pendingLink = link
            case .widgetTap:
                // A widget tap that opened the app instead of running its intent: kept, then done here.
                model.quickCapture.widgetOpenedApp()
            case .ignore:
                break   // another `sempere:` link: not a vault
            case .file:
                Task { await open(url) }   // a vault tapped in Files, or a PDF opened with Sempere (imported as a new note)
            }
        }
        .onChange(of: model.quickCapture.pendingLink, initial: true) { _, link in
            let capture = model.quickCapture
            switch link {
            case .settings:
                capture.pendingLink = nil
                showingVoiceSettings = true
            case .recording:
                // The banner (`VoiceNoteBanner`) takes it while it shows; nothing to show: done.
                if capture.state == .idle, capture.notice == nil { capture.pendingLink = nil }
            case nil:
                break
            }
        }
        .voiceNoteBanner()
        .safeAreaInset(edge: .bottom) {
            if model.openedPDFStage == .needsVault || model.openedPDFStage == .needsUnlock {
                OpenedPDFsWaitingBar()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // iCloud may have delivered files while the app was away; no
            // polling while it is in the background.
            if phase == .active { model.enterForeground() }
            if phase == .active { model.scheduleSettingsSync() }   // another device may have changed the vault's settings
            if phase == .active, model.isCloudVault { model.startCloudSync() }
            // A recent vault iCloud had not delivered yet (after a restart) may be there now.
            if phase == .active { library.refreshRecents() }
            if phase == .active {
                // The widgets' status, queued voice notes, and recordings no seal could finish yet.
                model.quickCaptureBecameActive()
                if model.phase == .unlocked { model.startInboxAdoption() }
            }
            // A sync in flight finishes under background time; then (or when iOS
            // takes the time back) scheduled tasks continue it (`BackgroundSync`).
            if phase == .background { model.enterBackground() }
            applyIdleTimer()
        }
        .onChange(of: model.editor != nil) { applyIdleTimer() }
        .onChange(of: keepScreenOn) { applyIdleTimer() }
        .onAppear { applyIdleTimer() }
        .overlay {
            if let progress = model.cloudProgress {
                CloudProgressView(progress: progress) { model.cancelCloudDownload() }
            }
            if let status = model.webdavDownload {
                WebDAVDownloadOverlay(status: status) { model.cancelWebDAVDownload() }
            }
            if let copy = model.vaultCopy {
                VaultCopyOverlay(progress: copy)
            }
        }
        .sheet(isPresented: $creatingVault) {
            NewVaultView()
        }
        .sheet(isPresented: .constant(model.phase == .locked || keys.holdsUnlockSheet(model))) {
            UnlockView()
                .voiceNoteBanner()
                .interactiveDismissDisabled()
        }
        // After the unlock sheet, if the vault is locked: enabling needs it unlocked.
        .sheet(isPresented: Binding(get: { showingVoiceSettings && model.phase != .locked && !keys.holdsUnlockSheet(model) },
                                    set: { if !$0 { showingVoiceSettings = false } })) {
            SettingsView(scrollTo: QuickCaptureSettingsSection.anchor)
        }
        .onChange(of: model.vaultURL) { keys.discardStaleOffer(model) }
        #if DEBUG
        .task {
            if DebugLaunch.isActive {
                // `stored` keeps the stored layout (the default one after `SEMPERE_DEBUG_FRESH`).
                let columns = DebugLaunch.environment["SEMPERE_DEBUG_COLUMNS"] ?? "detailOnly"
                if columns != "stored" { storedColumns = columns }
                await DebugLaunch.run(model, library: library, keys: keys)
            }
        }
        #endif
        .alert("Sempere", isPresented: Binding(get: { model.errorMessage != nil },
                                                set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {
                if pickAfterAlert {
                    pickAfterAlert = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        pickVault()
                    }
                }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // A previous copy an interrupted "Download Again" left with files the vault lacks: kept, and shown.
        .alert("Sempere", isPresented: Binding(get: { model.webdavLeftover != nil },
                                                set: { if !$0 { model.webdavLeftover = nil } }),
               presenting: model.webdavLeftover) { leftover in
            if Platform.isMac {
                Button("Show in Finder") { UIApplication.shared.open(leftover.folder) }
            } else {
                Button("Share…") { sharingLeftover = leftover }
            }
            Button("OK", role: .cancel) {}
        } message: { leftover in
            Text(leftover.message)
        }
        .sheet(item: $sharingLeftover) { leftover in
            ShareSheet(items: [leftover.folder]) { sharingLeftover = nil }
        }
        // Design §4.3: never write to a list nobody with the key wrote.
        .alert(model.listAlert?.displayTitle ?? ListAlert.title, isPresented: Binding(get: { model.listAlert != nil },
                                                                                     set: { if !$0 { model.dismissListAlert() } })) {
            // TODO(KH5): repair (a new epoch from home, or a takeover with the recovery key).
            Button("OK", role: .cancel) { model.dismissListAlert() }
        } message: {
            Text(model.listAlert?.message ?? "")
        }
        // A recent vault waited for (the launch reopen or a tap found it waiting for iCloud) arrived.
        .onChange(of: library.states) {
            guard model.phase == .noVault, let entry = library.takeReadyPendingOpen() else { return }
            Task { await reopen(entry, pickOnFailure: false) }
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .noVault { library.cancelPendingOpen() }   // another vault opened meanwhile
        }
        .task {
            library.watchICloudAccount()
            // Reopen the last vault on launch; a failure leaves the welcome screen. A vault iCloud has
            // not delivered yet (after a restart) is listed as waiting and opens when it arrives.
            guard !triedAutoOpen, model.phase == .noVault, let last = library.recents.first else {
                await library.checkRecents()
                return
            }
            #if DEBUG
            if DebugLaunch.isActive { return }   // the launch environment names the vault
            #endif
            triedAutoOpen = true
            await reopen(last, pickOnFailure: false)
        }
    }

    /// The three columns. Only an iPhone binds the stack's column
    /// (`preferredCompactColumn`): the iPad (Slide Over, narrow Split View) and
    /// the Mac keep the split view exactly as before.
    @ViewBuilder
    private var splitView: some View {
        if Platform.isPhone {
            NavigationSplitView(columnVisibility: columns, preferredCompactColumn: $compactColumn) {
                SidebarView()
            } content: {
                NoteListView()
            } detail: {
                NoteCanvasView()
            }
        } else {
            NavigationSplitView(columnVisibility: columns) {
                SidebarView()
            } content: {
                NoteListView()
            } detail: {
                NoteCanvasView()
            }
        }
    }

    /// A selection made in code (a search hit, the demo launch) moves the iPhone's stack.
    private func followSelection() {
        guard Platform.isPhone, let next = CompactNavigation.column(
            note: model.selectedNoteID, sidebar: model.sidebarSelection, current: compactColumn) else { return }
        compactColumn = next
    }

    private var currentNotebook: String? {
        if case .notebook(let n)? = model.sidebarSelection { return n }
        return nil
    }

    /// Applies the selection saved with this scene once the vault is unlocked
    /// (Mac only; the iPad keeps starting empty).
    private func restoreSelection() {
        guard SelectionStorage.shouldRestore(isMac: Platform.isMac, vault: model.vault?.vaultId, restored: restoredVault),
              let vaultID = model.vault?.vaultId else { return }
        restoredVault = vaultID
        if let saved = RestorableSelection(stored: storedSelection) { model.restore(saved) }
    }

    /// A library window restored (or opened for a restored note window) with the note list hidden and no
    /// note to show would be an empty "No Note Selected" window: it shows the list instead (Mac; once the
    /// saved selection has been applied and the vault is listed).
    private func showListWithoutNote() {
        guard restoredVault != nil, model.phase == .unlocked, model.listLoaded, !model.isBusy, model.selectedNoteID == nil else { return }
        #if DEBUG
        if DebugLaunch.isActive { return }
        #endif
        let next = ColumnLayout.withoutNote(storedColumns)
        if next != storedColumns { storedColumns = next }
    }

    private func saveSelection() {
        guard SelectionStorage.shouldSave(isMac: Platform.isMac, unlocked: model.phase == .unlocked, vault: model.vault?.vaultId, restored: restoredVault),
              let saved = model.restorableSelection() else { return }
        storedSelection = saved.stored
    }

    // MARK: - Menu commands (Mac)

    private var router: CommandRouter {
        var context = MenuCommand.Context()
        context.window = .library
        switch model.phase {
        case .noVault: context.vault = .none
        case .locked: context.vault = .locked
        case .unlocked: context.vault = .unlocked
        }
        let note = model.selectedNote
        context.hasNote = note != nil && !model.placeholderNoteIDs.contains(note?.id ?? UUID())
        context.noteDeleted = note?.deleted ?? false
        context.hasRecents = !library.recents.isEmpty
        // Only the window whose detail pane hosts the canvas drives the editor.
        let shown = model.editor?.noteID == model.selectedNoteID && model.canvasWindow == ui.id ? model.editor : nil
        context.editingText = ui.searchPresented || ui.renameNoteID != nil || ui.tagsNoteID != nil
            || ui.saveVersionNoteID != nil
        EditorCommands.fill(&context, from: shown)
        let exportIDs = model.exportTargetIDs
        WindowCommands.fill(&context, model: model, exportIDs: exportIDs)
        context.paletteCompact = paletteCompact
        context.noteMode = ui.noteMode
        context.pageStripVisible = pageStripVisible
        context.noteListHidden = ColumnLayout.visibility(from: storedColumns) == .detailOnly
        return CommandRouter(context: context, recents: library.recents.map { RecentItem(id: $0.id, name: $0.name) },
                             exportIDs: exportIDs, windowID: ui.id,
                             perform: { command in perform(command, editor: shown, exportIDs: exportIDs) },
                             openRecent: { id in
                                 if let entry = LibraryCommands.recent(withID: id, in: library.recents) { Task { await reopen(entry) } }
                             })
    }

    private func perform(_ command: MenuCommand, editor: NoteEditor?, exportIDs: [UUID]) {
        if EditorCommands.perform(command, editor: editor, ui: ui) { return }
        if WindowCommands.perform(command, model: model, ui: ui, exportIDs: exportIDs) { return }
        let outcome = LibraryCommands.perform(command, model: model, ui: ui, recents: library.recents,
                                              storedColumns: storedColumns)
        if let columns = outcome.columns { storedColumns = columns }
        switch outcome.effect {
        case .pickVault: pickVault()
        case .createVault: creatingVault = true
        case .openNoteWindow(let value): openWindow(id: NoteWindowValue.sceneID, value: value)
        case .reopen(let last): Task { await reopen(last) }
        case nil: break
        }
    }

    private func applyIdleTimer() {
        var debug = false
        #if DEBUG
        debug = DebugLaunch.isActive
        #endif
        UIApplication.shared.isIdleTimerDisabled = KeepScreenOn.idleTimerDisabled(
            enabled: keepScreenOn, noteOpen: model.editor != nil, active: scenePhase == .active, debugLaunch: debug)
    }

    /// "Open Vault…": the folder picker (in debug builds, `SEMPERE_DEBUG_PICK_VAULT` stands in for it).
    private func pickVault() {
        #if DEBUG
        if DebugLaunch.environment["SEMPERE_DEBUG_PICK_VAULT"] != nil {
            Task {
                guard let picked = await DebugLaunch.vaultPick() else { return }
                pickedVault = PickedVault(url: picked)
            }
            return
        }
        #endif
        pickingVault = true
    }

    private func open(_ url: URL) async {
        if let confirm = await model.handleOpened(url, library: library) { openedVaultToConfirm = confirm }
    }

    /// Reopens a recent vault; on failure explains and falls back to the picker.
    private func reopen(_ entry: RecentVault, pickOnFailure: Bool = true) async {
        if let pick = await LibraryCommands.reopen(entry, pickOnFailure: pickOnFailure, model: model, library: library) {
            pickAfterAlert = pick
        }
    }
}
