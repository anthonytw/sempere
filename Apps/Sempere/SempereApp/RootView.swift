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
    @State private var creatingVault = false
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    /// Set when a failed reopen should end in the folder picker.
    @State private var pickAfterAlert = false
    @State private var triedAutoOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = KeepScreenOn.defaultValue
    @AppStorage(ToolPalette.visibleKey) private var paletteVisible = true
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
    /// Choose Devices to Keep from the recipients alert (format.md §2.1 "Repair").
    @State private var repairChoice: RecipientsRepairChoice?

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
            .onChange(of: model.selectedNoteID) { saveSelection() }
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
                WelcomeView(openFolder: { pickingVault = true },
                            newVault: { creatingVault = true },
                            openRecent: { entry in Task { await reopen(entry) } },
                            openURL: { url in Task { await open(url) } })
            } else if model.phase == .migrating {
                // A legacy vault: nothing but its migration (format.md §3.3.2).
                MigrationView()
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
        .fileImporter(isPresented: $pickingVault, allowedContentTypes: UTType.vaultPickerTypes) { result in
            Task {
                await model.report {
                    try await model.open(picked: try result.get(), library: library)
                }
            }
        }
        .onOpenURL { url in
            switch VoiceNoteLink.route(url) {
            case .link(let link):
                // A widget, the control or the Live Activity (`sempere://quick-voice/…`).
                model.quickCapture.pendingLink = link
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
            if phase == .active {
                // Live Activities may have been switched in Settings ▸ Sempere meanwhile.
                model.quickCapture.publishStatus()
                // Voice notes queued while the vault folder was out of reach, then adopted if it is unlocked.
                model.quickCapture.flushStoredQueue()
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
            if let name = model.webdavDownloading {
                WebDAVDownloadOverlay(name: name)
            }
        }
        .sheet(isPresented: $creatingVault) {
            NewVaultView()
        }
        .sheet(item: $repairChoice) { choice in
            RecipientsRepairView(choice: choice)
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
                        pickingVault = true
                    }
                }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // format.md §2.1: never write to a list nobody with the key wrote.
        .alert(model.recipientsAlert?.displayTitle ?? RecipientsAlert.title, isPresented: Binding(get: { model.recipientsAlert != nil },
                                                           set: { if !$0 { model.dismissRecipientsAlert() } })) {
            if model.recipientsAlert?.canRemove == true {
                Button("Remove", role: .destructive) {
                    Task { await model.report { try await model.repairRecipients() } }
                }
            }
            if model.recipientsAlert?.canConfirm == true {
                Button("Trust This List") {
                    Task { await model.report { try await model.confirmRecipientsList() } }
                }
            }
            if model.recipientsAlert?.canChoose == true {
                Button("Choose Devices to Keep…") {
                    // Taken now (the alert's dismissal clears it); shown once the alert is gone.
                    let choice = model.recipientsRepairChoice()
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        repairChoice = choice
                    }
                }
            }
            Button("Cancel", role: .cancel) { model.dismissRecipientsAlert() }
        } message: {
            Text(model.recipientsAlert?.message ?? "")
        }
        .alert("Device List Protected", isPresented: Binding(get: { model.recipientsNotice != nil && model.recipientsAlert == nil },
                                                             set: { if !$0 { model.recipientsNotice = nil } })) {
            Button("OK", role: .cancel) { model.recipientsNotice = nil }
        } message: {
            Text(model.recipientsNotice ?? "")
        }
        .task {
            // Reopen the last vault on launch; a failure leaves the welcome screen.
            guard !triedAutoOpen, model.phase == .noVault, let last = library.recents.first else { return }
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
        case .migrating: context.vault = .migrating
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
        context.pageStripVisible = pageStripVisible
        context.noteListHidden = ColumnLayout.visibility(from: storedColumns) == .detailOnly
        return CommandRouter(context: context, recents: library.recents.map { RecentItem(id: $0.id, name: $0.name) },
                             paletteVisible: paletteVisible, exportIDs: exportIDs, windowID: ui.id,
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
        case .pickVault: pickingVault = true
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

    private func open(_ url: URL) async {
        await model.handleOpened(url, library: library)
    }

    /// Reopens a recent vault; on failure explains and falls back to the picker.
    private func reopen(_ entry: RecentVault, pickOnFailure: Bool = true) async {
        if let pick = await LibraryCommands.reopen(entry, pickOnFailure: pickOnFailure, model: model, library: library) {
            pickAfterAlert = pick
        }
    }
}
