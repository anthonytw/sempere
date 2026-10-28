import Sempere
import SwiftUI

/// Notebooks (a tree of `/`-separated paths) and tags of the open vault.
/// Selecting a notebook shows the notes in it and in its sub-notebooks.
struct SidebarView: View {
    private struct MovingNotebook: Identifiable {
        let path: String
        var id: String { path }
    }

    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    /// The window's UI state: "Export to Folder or Zip…" opens its sheet in this window.
    @Environment(WindowUI.self) private var ui: WindowUI?
    @State private var showingSettings = false
    /// Sync Targets… (`SyncTargetsSheet`): where the iPad and iPhone reach it (the Mac also has File > Sync Targets…).
    @State private var showingSyncTargets = false
    @State private var renaming: String?
    /// The notebook a "Move Notebook To…" sheet is open for.
    @State private var movingNotebook: MovingNotebook?
    @State private var newName = ""
    /// The New Notebook sheet opened from the sidebar (its button and menus).
    @State private var newNotebook: NewNotebookRequest?
    /// The empty notebook a Delete Notebook confirmation is open for.
    @State private var deletingNotebook: String?
    /// The window's undo manager: a notebook moved from a row's menu is undone there.
    @Environment(\.undoManager) private var undoManager
    /// iPhone: the notebooks whose sub-notebooks are shown (`PhoneNotebookRows`); folded by default, as the
    /// iPad's outline is.
    @State private var unfolded: Set<String> = []

    /// A notebook row's context menu (`NotebookRowAction.notebookMenu`).
    private func menu(for path: String) -> [NotebookRowAction] {
        // A nested notebook: Move to Top Level un-nests it (with everything inside), one undo step,
        // as a drop on the Notebooks header does.
        var moveToTop: (@MainActor @Sendable () -> Void)?
        if NotebookPath.components(path).count > 1 {
            moveToTop = { moveToTopLevel(path) }
        }
        let actions = NotebookRowAction.notebookMenu(newInside: {
            newNotebook = NewNotebookRequest(parent: path)
        }, rename: {
            newName = path
            renaming = path
        }, move: {
            movingNotebook = MovingNotebook(path: path)
        }, moveToTop: moveToTop, export: {
            model.requestBulkExport(.notebook(path), window: ui?.id)
        }, delete: {
            deletingNotebook = path
        })
        // Delete Notebook only for an empty notebook a record keeps (format.md §14).
        return model.canDeleteNotebook(path) ? actions : actions.filter { !$0.destructive }
    }

    private func moveToTopLevel(_ path: String) {
        let undo = UndoBox(undoManager)
        Task { await model.move(.notebook(path), to: .topLevel, undoManager: undo.manager) }
    }

    private func notebookLabel(_ node: NotebookNode, inbox: Bool = false) -> some View {
        Label(node.name, systemImage: inbox ? "tray" : node.children.isEmpty ? "book.closed" : "books.vertical")
            .accessibilityIdentifier("sidebar-notebook-\(node.path)")
    }

    /// Notebook rows for `nodes` (and everything inside them): an outline, or on an iPhone the tree
    /// drawn by `PhoneNotebookRows` (folding with a chevron of its own). `inbox` marks the Inbox's own row.
    @ViewBuilder
    private func notebookRows(_ nodes: [NotebookNode], inbox: String? = nil) -> some View {
        if Platform.isPhone {
            // An outline row's tap only folds it on an iPhone's stack and never selects it,
            // so a notebook holding sub-notebooks could not open its own notes. The phone
            // draws the tree itself: a tap on a row opens its notebook, the chevron at its end
            // folds or unfolds its sub-notebooks (`PhoneNotebookRows`).
            ForEach(PhoneNotebookRows.rows(nodes, unfolded: unfolded)) { row in
                decorated(phoneNotebookRow(row, inbox: row.node.path == inbox), row.node)
            }
        } else {
            OutlineGroup(nodes, children: \.childrenOrNil) { node in
                notebookRow(node, inbox: node.path == inbox)
            }
        }
    }

    /// An iPhone notebook row: the label, indented by depth, and for a notebook with sub-notebooks a
    /// disclosure chevron of its own at the trailing end (the drag handle leaves that end to it,
    /// `NotebookDragSourceModifier.chevronWidth`), so the row's tap still opens the notebook.
    private func phoneNotebookRow(_ row: PhoneNotebookRows.Row, inbox: Bool) -> some View {
        HStack(spacing: 0) {
            notebookLabel(row.node, inbox: inbox)
                .padding(.leading, CGFloat(row.depth) * 20)
            Spacer(minLength: 0)
            if row.hasChildren {
                let name = row.node.name
                Button {
                    withAnimation { unfolded = PhoneNotebookRows.toggled(row.node.path, in: unfolded) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.unfolded ? 90 : 0))
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(row.unfolded ? String(localized: "Fold \(name)", comment: "Sidebar on an iPhone: hide a notebook's sub-notebooks (the notebook's name)")
                                                 : String(localized: "Unfold \(name)", comment: "Sidebar on an iPhone: show a notebook's sub-notebooks (the notebook's name)"))
                .accessibilityIdentifier("sidebar-fold-\(row.node.path)")
                .help(row.unfolded ? "Hide the sub-notebooks" : "Show the sub-notebooks")
            }
        }
    }

    private func notebookRow(_ node: NotebookNode, inbox: Bool) -> some View {
        decorated(notebookLabel(node, inbox: inbox), node)
    }

    /// A notebook row's selection tag, drop target, drag source and swipe action (every platform).
    private func decorated(_ label: some View, _ node: NotebookNode) -> some View {
        label
            .tag(SidebarItem.notebook(node.path))
            .sidebarDropTarget(.notebook(node.path))
            // The drag and the context menu come from one UIKit view (`NotebookDragSource`).
            .notebookDragSource(node.path, hasChildren: !node.children.isEmpty, menu: menu(for: node.path))
            .swipeActions {
                Button("Rename", systemImage: "pencil") { newName = node.path; renaming = node.path }
            }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text").tag(SidebarItem.allNotes)
                .sidebarDropTarget(.allNotes)
                .contextMenu {
                    Button("New Notebook…", systemImage: "folder.badge.plus") { newNotebook = NewNotebookRequest() }
                    Button("Export All Notes…", systemImage: ExportCommand.menuImage) {
                        model.requestBulkExport(.vault, window: ui?.id)
                    }
                }
            // The Inbox (where quick voice notes land, to be moved on from) is listed with the
            // special lists, not among the notebooks (`SidebarSections`).
            let sections = SidebarSections(tree: model.notebookTree)
            if let inbox = sections.inbox {
                notebookRows([inbox], inbox: inbox.path)
            }
            // A smart list under All Notes: notes a recognition run on any device read
            // in the last 7 days (`meta.recognized`, synced); gone while there are none.
            let recognized = model.recentlyRecognizedNotes.count
            if recognized > 0 {
                Label("Recently Recognized", systemImage: "text.viewfinder")
                    .badge(recognized)
                    .tag(SidebarItem.recentlyRecognized)
            }
            Label {
                Text("Favorites")
            } icon: {
                Image(systemName: "star.fill").foregroundStyle(FavoriteMark.color)
            }
            .tag(SidebarItem.favorites)
            if !sections.notebooks.isEmpty {
                Section {
                    notebookRows(sections.notebooks)
                } header: {
                    // A notebook dropped on the header goes to the top level (un-nested), as on All Notes.
                    Text("Notebooks")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // The drop itself through UIKit (`UIKitDropZone`); the modifier highlights it.
                        .overlay { UIKitDropZone(model: model, target: .topLevel, undoManager: undoManager) }
                        .sidebarDropTarget(.allNotes)
                        .accessibilityIdentifier("sidebar-notebooks-header")
                        .help(String(localized: "Drop a notebook here to move it to the top level",
                                     comment: "Tooltip of the sidebar's Notebooks header"))
                }
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag").tag(SidebarItem.tag(tag))
                    }
                }
            }
            Label("Recently Deleted", systemImage: "trash").tag(SidebarItem.deleted)
        }
        .onChange(of: model.recentlyRecognizedNotes.isEmpty) { model.leaveEmptyRecognizedSection() }
        // iPhone: a notebook chosen elsewhere is listed, its parents unfolded.
        .onChange(of: model.sidebarSelection, initial: true) { _, selection in
            guard Platform.isPhone, case .notebook(let path) = selection else { return }
            unfolded = PhoneNotebookRows.revealing(path, in: unfolded)
        }
        // "Recently Recognized" also changes when a run leaves the 7-day window, which no note change reports.
        .task(id: model.recentlyRecognizedNextChange) {
            guard let next = model.recentlyRecognizedNextChange else { return }
            // A second late, so the list is past the boundary when it is read again.
            let wait = max(0, next.timeIntervalSince(model.activityNow())) + 1
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            model.recentlyRecognizedClockChanged()
        }
        #if DEBUG
        .overlay(alignment: .bottomLeading) { DropTraceLabel() }
        #endif
        .navigationTitle(model.vaultName ?? "Sempere")
        .sheet(isPresented: $showingSyncTargets) { SyncTargetsSheet() }
        .toolbar {
            ToolbarItem {
                // New Notebook and Settings live here, Close Vault always last (TestFlight 1.0.0 (6) feedback).
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("New Notebook", systemImage: "folder.badge.plus") {
                        newNotebook = NewNotebookRequest(parent: model.selectedNotebook)
                    }
                    .disabled(model.phase != .unlocked || model.isVaultReadOnly)
                    .accessibilityIdentifier("sidebar-new-notebook")
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    Button("Sync Targets…", systemImage: "arrow.triangle.2.circlepath") { showingSyncTargets = true }
                        .accessibilityIdentifier("sidebar-sync-targets")
                    Divider()
                    // Another vault (or this one's sync folder on a new device) without going back to the welcome screen.
                    Button("Open Vault…", systemImage: "folder") { ui?.openVaultRequested = true }
                        .disabled(ui == nil)
                        .accessibilityIdentifier("sidebar-open-vault")
                    Button("Close Vault", systemImage: "xmark.circle") { model.close() }
                }
                .help("New notebook, settings, sync targets, opening another vault and closing this one")
                .accessibilityIdentifier("sidebar-more")
            }
        }
        .sheet(item: $movingNotebook) { MoveNotebookView(path: $0.path) }
        .sheet(item: $newNotebook) { NewNotebookView(request: $0) }
        .confirmationDialog("Delete this notebook?", isPresented: Binding(get: { deletingNotebook != nil },
                                                                          set: { if !$0 { deletingNotebook = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Notebook", role: .destructive) {
                if let path = deletingNotebook {
                    Task { await model.report { try await model.deleteNotebook(path) } }
                }
                deletingNotebook = nil
            }
        } message: {
            Text("“\(deletingNotebook ?? "")” and the empty notebooks inside it are removed. It holds no notes.")
        }
        .task(id: model.vault?.vaultId) { await keys.refresh(model) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        #if DEBUG
        // `SEMPERE_DEMO_SETTINGS` opens Settings at launch (the pseudo-language layout check, docs/localization.md).
        .task {
            if DebugLaunch.environment["SEMPERE_DEMO_SETTINGS"] != nil {
                try? await Task.sleep(for: .seconds(3))
                showingSettings = true
            }
        }
        #endif
        .alert("Rename or Move Notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Path", text: $newName.replacingEmojiShortcodes())
                .autocorrectionDisabled()
            Button("Rename") {
                if let old = renaming {
                    Task { await model.report { try await model.renameNotebook(old, to: newName) } }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Applies to every note in “\(renaming ?? "")” and its sub-notebooks. Use / for levels, e.g. School/Math. An empty name takes the notes out of the notebook and lifts its sub-notebooks to the top.")
        }
    }
}

/// The sidebar's groups of notebooks: the Inbox (the top-level notebook quick voice notes go to by
/// default, `CaptureProfile.defaultNotebook`) is listed with All Notes and the other special
/// lists; every other notebook under "Notebooks".
struct SidebarSections {
    var inbox: NotebookNode?
    var notebooks: [NotebookNode]

    init(tree: [NotebookNode], inbox name: String = CaptureProfile.defaultNotebook) {
        let path = NotebookPath.canonical(name)
        inbox = tree.first { $0.path == path }
        notebooks = tree.filter { $0.path != path }
    }
}

/// The sidebar's notebook rows on an iPhone: the tree flattened in order with each row's depth, the
/// sub-notebooks of an unfolded notebook only (folding, as the iPad's outline does; its rows' taps only fold
/// on a phone's stack, so the phone draws the rows itself, with a chevron of their own).
enum PhoneNotebookRows {
    struct Row: Identifiable {
        let node: NotebookNode
        let depth: Int
        /// Its sub-notebooks are listed under it.
        var unfolded = true
        var id: String { node.path }
        var hasChildren: Bool { !node.children.isEmpty }
    }

    /// Every notebook (`unfolded` nil), or the top ones and the sub-notebooks of each unfolded one.
    static func rows(_ tree: [NotebookNode], unfolded: Set<String>? = nil, depth: Int = 0) -> [Row] {
        tree.flatMap { node -> [Row] in
            let open = unfolded.map { $0.contains(node.path) } ?? true
            let row = Row(node: node, depth: depth, unfolded: open)
            return [row] + (open ? rows(node.children, unfolded: unfolded, depth: depth + 1) : [])
        }
    }

    /// `path` folded if it was unfolded, else unfolded.
    static func toggled(_ path: String, in unfolded: Set<String>) -> Set<String> {
        unfolded.contains(path) ? unfolded.subtracting([path]) : unfolded.union([path])
    }

    /// `unfolded` with every notebook above `path` unfolded, so `path`'s row is listed (a notebook chosen
    /// elsewhere, e.g. a note's notebook).
    static func revealing(_ path: String, in unfolded: Set<String>) -> Set<String> {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return unfolded }
        return unfolded.union((1..<parts.count).map { parts[0..<$0].joined(separator: "/") })
    }
}
