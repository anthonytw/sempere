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
    /// The window's UI state: "Export Notes…" opens its sheet in this window.
    @Environment(WindowUI.self) private var ui: WindowUI?
    @State private var forgettingKey = false
    @State private var showingSettings = false
    @State private var renaming: String?
    /// The notebook a "Move Notebook To…" sheet is open for.
    @State private var movingNotebook: MovingNotebook?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Label("All Notes", systemImage: "note.text").tag(SidebarItem.allNotes)
                .sidebarDropTarget(.allNotes)
                .contextMenu {
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
            Label("Favorites", systemImage: "star").tag(SidebarItem.favorites)
            let tree = model.notebookTree
            if !tree.isEmpty {
                Section("Notebooks") {
                    OutlineGroup(tree, children: \.childrenOrNil) { node in
                        Label(node.name, systemImage: node.children.isEmpty ? "book.closed" : "books.vertical")
                            .tag(SidebarItem.notebook(node.path))
                            .accessibilityIdentifier("sidebar-notebook-\(node.path)")
                            .sidebarDropTarget(.notebook(node.path))
                            // The drag and the context menu come from one UIKit view (`NotebookDragSource`).
                            .notebookDragSource(node.path, menu: NotebookRowAction.notebookMenu(rename: {
                                newName = node.path
                                renaming = node.path
                            }, move: {
                                movingNotebook = MovingNotebook(path: node.path)
                            }, export: {
                                model.requestBulkExport(.notebook(node.path), window: ui?.id)
                            }))
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
            TextField("Path", text: $newName)
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
