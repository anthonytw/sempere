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
    @State private var forgettingKey = false
    @State private var showingSettings = false
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

    /// Notebook rows for `nodes` (and everything inside them): an outline, or on an iPhone every
    /// notebook indented with no folding. `inbox` marks the Inbox's own row.
    @ViewBuilder
    private func notebookRows(_ nodes: [NotebookNode], inbox: String? = nil) -> some View {
        if Platform.isPhone {
            // An outline row's tap only folds it on an iPhone's stack and never selects it,
            // so a notebook holding sub-notebooks could not open its own notes. The phone
            // lists every notebook, indented, with no folding: a tap always opens one.
            ForEach(PhoneNotebookRows.rows(nodes)) { row in
                notebookRow(row.node, inbox: row.node.path == inbox)
                    .padding(.leading, CGFloat(row.depth) * 20)
            }
        } else {
            OutlineGroup(nodes, children: \.childrenOrNil) { node in
                notebookRow(node, inbox: node.path == inbox)
            }
        }
    }

    private func notebookRow(_ node: NotebookNode, inbox: Bool) -> some View {
        notebookLabel(node, inbox: inbox)
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
        .toolbar {
            ToolbarItem {
                Button("Close Vault", systemImage: "xmark.circle") { model.close() }
                    .help("Close the vault (⇧⌘W)")
            }
            ToolbarItem {
                Button("New Notebook", systemImage: "folder.badge.plus") {
                    newNotebook = NewNotebookRequest(parent: model.selectedNotebook)
                }
                .help("New notebook (⌃⌘N)")
                .disabled(model.phase != .unlocked || model.isVaultReadOnly)
                .accessibilityIdentifier("sidebar-new-notebook")
            }
            ToolbarItem {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .help("Settings for this device")
            }
            ToolbarItem {
                Menu("Vault Key", systemImage: "key") {
                    if let storage = keys.storage(for: model) {
                        if storage == .iCloudKeychain {
                            Text("Saved in iCloud Keychain")
                        } else {
                            Text("Saved on \(RememberedKeys.deviceName)")
                        }
                        Button("Forget Key for This Vault…", systemImage: "key.slash", role: .destructive) {
                            forgettingKey = true
                        }
                    } else {
                        Text("The key is not saved. Unlock with a passphrase or pasted key to save it.")
                    }
                }
                .help("This vault's key on this device: forget it or keep it in iCloud Keychain")
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
        .confirmationDialog("Forget this vault's key?", isPresented: $forgettingKey, titleVisibility: .visible) {
            Button("Forget Key", role: .destructive) {
                Task { await model.report { try await keys.forget(model) } }
            }
        } message: {
            if keys.storage(for: model) == .iCloudKeychain {
                Text("The key is removed from iCloud Keychain on all your devices. Keep another copy (key file or passphrase) to open the vault again.")
            } else {
                Text("The key is removed from \(RememberedKeys.deviceName). Keep another copy (key file or passphrase) to open the vault again.")
            }
        }
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

/// The sidebar's notebook rows on an iPhone: the whole tree flattened in order with each row's depth.
enum PhoneNotebookRows {
    struct Row: Identifiable {
        let node: NotebookNode
        let depth: Int
        var id: String { node.path }
    }

    static func rows(_ tree: [NotebookNode], depth: Int = 0) -> [Row] {
        tree.flatMap { [Row(node: $0, depth: depth)] + rows($0.children, depth: depth + 1) }
    }
}
