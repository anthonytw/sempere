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

    /// A notebook row's context menu (`NotebookRowAction.notebookMenu`).
    private func menu(for path: String) -> [NotebookRowAction] {
        let actions = NotebookRowAction.notebookMenu(newInside: {
            newNotebook = NewNotebookRequest(parent: path)
        }, rename: {
            newName = path
            renaming = path
        }, move: {
            movingNotebook = MovingNotebook(path: path)
        }, export: {
            model.requestBulkExport(.notebook(path), window: ui?.id)
        }, delete: {
            deletingNotebook = path
        })
        // Delete Notebook only for an empty notebook a record keeps (format.md §14).
        return model.canDeleteNotebook(path) ? actions : actions.filter { !$0.destructive }
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
            let tree = model.notebookTree
            if !tree.isEmpty {
                Section("Notebooks") {
                    OutlineGroup(tree, children: \.childrenOrNil) { node in
                        Label(node.name, systemImage: node.children.isEmpty ? "book.closed" : "books.vertical")
                            .tag(SidebarItem.notebook(node.path))
                            .accessibilityIdentifier("sidebar-notebook-\(node.path)")
                            .sidebarDropTarget(.notebook(node.path))
                            // The drag and the context menu come from one UIKit view (`NotebookDragSource`).
                            .notebookDragSource(node.path, hasChildren: !node.children.isEmpty, menu: menu(for: node.path))
                            .swipeActions {
                                Button("Rename", systemImage: "pencil") { newName = node.path; renaming = node.path }
                            }
                    }
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
