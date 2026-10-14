import Sempere
import SwiftUI

/// Version history of one note: its restore points (time, device), a
/// read-only preview of the note as of one, and "Restore this version".
struct HistoryView: View {
    let noteID: UUID
    /// A restore point to show once the history is read (Settings → Storage
    /// links to the one where an attachment was last used); ignored when it
    /// is gone or cannot be previewed.
    var revealing: String? = nil
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var data: HistoryData?
    @State private var failure: String?
    @State private var path: [RevisionName] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let data {
                    list(data)
                } else if let failure {
                    ContentUnavailableView {
                        Label("Could Not Load History", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Reading history…")
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: RevisionName.self) { name in
                if let data, let entry = data.entries.first(where: { $0.id == name }) {
                    HistoryPreviewView(data: data, entry: entry) { await load() ; path = [] }
                }
            }
        }
        .task { await load() }
    }

    private func list(_ data: HistoryData) -> some View {
        List {
            if data.entries.isEmpty {
                Text("This note has no history yet.").foregroundStyle(.secondary)
            }
            // Checkpoints at the top level; the autosaves of each editing
            // session collapsed under one row (format.md §5.8.2).
            ForEach(data.groups) { group in
                switch group.kind {
                case .checkpoint:
                    link(group.newest)
                case .session:
                    DisclosureGroup {
                        ForEach(group.entries) { entry in link(entry) }
                    } label: {
                        SessionRow(group: group)
                    }
                }
            }
            if let notice = data.compactionNotice {
                Section { } footer: { Text(notice) }
            }
        }
    }

    @ViewBuilder
    private func link(_ entry: HistoryEntry) -> some View {
        if entry.isAvailable {
            NavigationLink(value: entry.id) { HistoryRow(entry: entry) }
        } else {
            HistoryRow(entry: entry).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        failure = nil
        do {
            data = try await model.loadHistory(for: noteID)
            if let revealing, path.isEmpty,
               let entry = data?.entries.first(where: { $0.id.filename == revealing }), entry.isAvailable {
                path = [entry.id]
            }
        } catch is CancellationError {
        } catch {
            failure = "\(error)"
        }
    }
}

/// One editing session, collapsed: its time range, device and saves.
private struct SessionRow: View {
    let group: HistoryGroupRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.timeRange)
                if group.containsLatest { Text("Current").font(.caption.bold()).foregroundStyle(.tint) }
            }
            Text(group.summary).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Editing session, \(group.timeRange), \(group.summary)")
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = entry.checkpointTitle {
                Label(title, systemImage: "bookmark.fill").font(.headline)
            }
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                if entry.isLatest { Text("Current").font(.caption.bold()).foregroundStyle(.tint) }
            }
            Text("\(entry.deviceLabel) · \(entry.kindLabel) · \(entry.point.app)")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = entry.unavailableReason {
                Label(reason, systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The note as of one restore point, read-only, with the restore button.
private struct HistoryPreviewView: View {
    let data: HistoryData
    let entry: HistoryEntry
    /// Called after a restore, to refresh the list.
    let restored: () async -> Void
    @AppModelEnvironment private var model
    @State private var preview: NoteEditor?
    @State private var failure: String?
    @State private var confirming = false
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        VStack(spacing: 0) {
            if let preview, let page = preview.currentPage {
                PageCanvasView(editor: preview, pageID: page.id, paper: preview.displayedPaper(of: page),
                               pageSize: preview.pageSize, paletteVisible: false, itemSource: model.itemLayerSource)
                    .id(page.id)
            } else if let failure {
                ContentUnavailableView("Cannot Show This Version", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if preview != nil {
                ContentUnavailableView("No Pages", systemImage: "doc",
                                       description: Text("The note had no pages at this point."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let preview, preview.pages.count > 1 {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Previous Page", systemImage: "chevron.up") { preview.selectPage(preview.pageIndex - 1) }
                        .disabled(preview.pageIndex == 0)
                        .help("Previous page of this version")
                    Text("\(preview.pageIndex + 1) / \(preview.pages.count)").monospacedDigit()
                    Button("Next Page", systemImage: "chevron.down") { preview.selectPage(preview.pageIndex + 1) }
                        .disabled(preview.pageIndex + 1 >= preview.pages.count)
                        .help("Next page of this version")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Restore This Version") { confirming = true }
                    .disabled(preview == nil || working || entry.isLatest)
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Restore This Version") { Task { await restore() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let when = entry.date.formatted(date: .abbreviated, time: .shortened)
            Text("The note is set back to how it was on \(when). Newer changes stay in the history, so you can undo this by restoring a newer version.")
        }
        .alert("Version History", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK") {}
        } message: {
            Text(outcome ?? "")
        }
        .task {
            do { preview = try await model.historyPreview(data, at: entry.id) } catch is CancellationError {} catch {
                failure = "\(error)"
            }
        }
    }

    private func restore() async {
        working = true
        defer { working = false }
        do {
            let summary = try await model.restoreVersion(of: data.noteID, to: entry.id)
            outcome = summary == nil
                ? String(localized: "The note already matches this version.")
                : String(localized: "The note was restored.")
            await restored()
        } catch is CancellationError {
        } catch {
            let detail = "\(error)"
            outcome = String(localized: "Could not restore: \(detail)")
        }
    }
}
