import Sempere
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Backups (docs/io.md "Backups"): the folder, Back Up Now,
/// Verify Backup, the last backup, the reminder and Restore from Backup.
/// The work is `AppModel+Backup`, on the same core as `sempere backup`.
///
/// Restore from Backup… sets `restoring`; the owner of the `Form` presents
/// `RestoreBackupView` from the form, not from this section. A modifier on a
/// `Section` applies to each of its rows: attached here, every row presented
/// the sheet at once, and on Mac Catalyst 27 they dismissed it again within a
/// second (`restoring` back to false), so it never showed.
struct BackupSettingsSection: View {
    @AppModelEnvironment private var model
    @Binding var restoring: Bool
    @State private var record = BackupRecord()
    @State private var picking = false
    @State private var message: String?
    @State private var problems: [String] = []
    /// A failure shown as an alert (a line in the footer was easy to miss).
    @State private var failure: BackupFailure?
    @State private var notificationsOff = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Section {
            Button(record.bookmark == nil ? LocalizedStringKey("Choose Backup Folder…") : LocalizedStringKey("Change Backup Folder…")) {
                picking = true
            }
                .disabled(busy || model.vault == nil)
                // On the button, not the section: a section's modifier is on each of its rows,
                // and several rows presenting at once can close it again on Mac Catalyst 27.
                // A folder picker with New Folder (`FolderPicker`).
                .folderPicker(isPresented: $picking) { result in
                    do {
                        try model.chooseBackupFolder(try result.get())
                        problems = []
                        message = nil
                    } catch {
                        failure = BackupFailure(kind: .folder, message: "\(error)")
                    }
                    reload()
                }
                .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                       presenting: failure) { _ in
                    Button("OK", role: .cancel) { failure = nil }
                } message: { failure in
                    Text(failure.message)
                }
            if let path = record.displayPath {
                LabeledContent("Folder", value: path)
                if let progress = model.backupProgress {
                    HStack {
                        ProgressView()
                        Text(progress.headline).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        if case .copying = progress.stage { Button("Stop") { model.cancelBackup() } }
                    }
                } else {
                    Button("Back Up Now") { run { try await backUp() } }
                    Button("Verify Backup") { run { try await verify() } }
                }
                LabeledContent("Last Backup") {
                    Text(lastBackupText)
                        .foregroundStyle(BackupReminder.isOverdue(record, now: Date()) ? Color.red : Color.secondary)
                }
                if let size = BackupText.contents(notes: record.lastNotes, files: record.lastFiles, bytes: record.lastBytes) {
                    LabeledContent("Contents", value: size)
                }
                if let verified = record.lastVerified, let healthy = record.lastVerifyHealthy {
                    let when = verified.formatted(.relative(presentation: .named))
                    LabeledContent("Last Check") {
                        (healthy ? Text("Healthy, \(when)", comment: "Settings ▸ Backups ▸ Last Check; %@ is how long ago")
                                 : Text("Problems found, \(when)", comment: "Settings ▸ Backups ▸ Last Check; %@ is how long ago"))
                            .foregroundStyle(healthy ? Color.secondary : Color.red)
                    }
                }
                if !problems.isEmpty {
                    BackupProblemList(lines: problems)
                }
                Picker("Remind Me", selection: Binding(get: { record.reminderDays }, set: { setReminder($0) })) {
                    ForEach(BackupReminder.choices, id: \.self) { Text(BackupReminder.label($0)).tag($0) }
                }
                .syncedSetting("backup.reminderDays")
                Button("Forget Backup Folder", role: .destructive) {
                    model.forgetBackupFolder()
                    problems = []
                    reload()
                }
                .disabled(busy)
            }
            Button("Restore from Backup…") { restoring = true }
                .disabled(busy)
        } header: {
            Text("Backups")
        } footer: {
            Text(message ?? footer)
        }
        .onAppear(perform: reload)
        .onChange(of: model.vaultURL) { reload() }
    }

    private var busy: Bool { model.backupProgress != nil }

    private var lastBackupText: String {
        guard let date = record.lastBackup else {
            return String(localized: "Never", comment: "Settings ▸ Backups ▸ Last Backup: there has been none")
        }
        return date.formatted(.relative(presentation: .named))
    }

    private var footer: String {
        var s = String(localized: "A backup is a copy of the vault's encrypted files, kept up to date: each run copies only what is new. Choose a folder on another drive or another cloud service. Nothing is decrypted: a backup is useless without your key, so save it with Device Keys ▸ Save Key… (with its paper recovery kit) and keep it somewhere safe as well.",
                       comment: "Settings ▸ Backups footer")
        if notificationsOff {
            s += " " + String(localized: "Notifications are off for Sempere, so the reminder shows here only; allow them in the system Settings ▸ Notifications.")
        }
        return s
    }

    private func reload() {
        record = model.backupRecord() ?? BackupRecord()
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        task = Task {
            message = nil
            do { try await body() } catch is CancellationError {
                message = String(localized: "Stopped. The backup holds every file written so far; Back Up Now finishes it.")
            } catch {
                failure = BackupFailure(kind: .run, message: "\(error)")
            }
            reload()
        }
    }

    private func backUp() async throws {
        let report = try await model.backUpNow()
        message = BackupText.report(report)
    }

    private func verify() async throws {
        let report = try await model.verifyBackup()
        problems = report.problemLines
        message = BackupText.verify(report)
    }

    private func setReminder(_ days: Int) {
        record.reminderDays = days
        Task {
            notificationsOff = !(await model.setBackupReminder(days: days))
            reload()
        }
    }
}

/// A backup failure for the alert: a folder that cannot take the backup (another vault's
/// backup, a vault, the open vault), or a run or check that failed.
struct BackupFailure: Identifiable, Equatable {
    enum Kind { case folder, run }
    var kind: Kind
    var message: String
    var id: String { message }

    var title: String {
        switch kind {
        case .folder: return String(localized: "Choose Another Backup Folder", comment: "Alert title: the picked backup folder cannot be used")
        case .run: return String(localized: "Backup Failed", comment: "Alert title: Back Up Now or Verify Backup failed")
        }
    }
}

/// Verify Backup's problems: at most `BackupText.problemLimit` lines in a box that scrolls,
/// then "and N more" (a backup with thousands of missing files listed every one).
struct BackupProblemList: View {
    let lines: [String]

    var body: some View {
        let list = BackupText.problemList(lines)
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(list.shown.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.footnote.monospaced()).foregroundStyle(.red).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: BackupText.problemListHeight)
            .accessibilityIdentifier("backup.problems")
            if list.more > 0 {
                Text("…and \(list.more) more.", comment: "Verify Backup: problems not listed [not-plural]")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup.problems.more")
            }
        }
    }
}

/// Restore from Backup: choose a backup folder, see what it holds, then
/// restore it into a new vault (never over the open one) and open it.
struct RestoreBackupView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Environment(\.dismiss) private var dismiss

    private enum Location: Hashable { case onDevice, folder }

    @State private var picked: URL?
    @State private var source: URL?
    @State private var preview: RestorePreview?
    @State private var pickingFolder = false
    @State private var importerShown = false
    @State private var name = ""
    @State private var location = Location.onDevice
    @State private var folder: URL?
    @State private var working = false
    @State private var failure: String?
    @State private var outcome: RestoreOutcome?

    var body: some View {
        NavigationStack {
            Form {
                if let outcome {
                    Section {
                        Text(BackupText.restore(outcome))
                        ForEach(outcome.report.errors.prefix(20), id: \.path) { e in
                            Text(verbatim: "\(e.path): \(e.message)").font(.footnote.monospaced()).foregroundStyle(.red)
                        }
                        if let id = outcome.recentID, let entry = library.recents.first(where: { $0.id == id }) {
                            Button("Open “\(entry.name)”") {
                                dismiss()
                                Task { await model.report { try await model.open(recent: entry, library: library) } }
                            }
                        }
                    }
                } else {
                    chooser
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier("restoreBackupSheet")
            .disabled(working)
            .overlay { if working { ProgressView(model.backupProgress?.headline ?? "") } }
            .navigationTitle("Restore from Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(outcome == nil ? LocalizedStringKey("Cancel") : LocalizedStringKey("Done")) { dismiss() }
                }
                if outcome == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore") { restore() }.disabled(!canRestore)
                    }
                }
            }
        }
        .interactiveDismissDisabled(working)
        // The backup is only opened: the system's file importer. The new vault's folder is written
        // into: the folder picker with New Folder (`FolderPicker`), on a view of its own (two
        // importers on one view can hide each other).
        .fileImporter(isPresented: $importerShown, allowedContentTypes: [.folder, .sempere]) { result in
            Task { await choose(result) }
        }
        .background {
            SwiftUI.Color.clear.folderPicker(isPresented: $pickingFolder) { result in
                folder = try? result.get()
                if folder == nil { location = .onDevice }
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        Section {
            Button(picked == nil ? LocalizedStringKey("Choose Backup Folder…") : LocalizedStringKey("Choose Another Backup…")) {
                importerShown = true
            }
            if let source { LabeledContent("Backup", value: source.lastPathComponent) }
        } footer: {
            Text("Choose the backup folder (it holds backup.json), or any vault folder. Nothing is written until you tap Restore.")
        }
        if let preview {
            Section("This Backup Holds") {
                ForEach(BackupText.preview(preview)) { row in LabeledContent(row.label, value: row.value) }
            }
            Section {
                TextField("Name", text: $name).autocorrectionDisabled()
                Picker("Location", selection: $location) {
                    Text("On This Device").tag(Location.onDevice)
                    Text("Choose Folder…").tag(Location.folder)
                }
                .onChange(of: location) { _, new in if new == .folder { pickingFolder = true } }
                if location == .folder, let folder { LabeledContent("Folder", value: folder.lastPathComponent) }
            } header: {
                Text("Restore As a New Vault")
            } footer: {
                Text("The backup is copied into a new vault; the vault you have open is never changed. It opens with the same key as the vault that was backed up.")
            }
        }
    }

    private var parent: URL? { location == .folder ? folder : VaultLibrary.onDeviceFolder }

    private var canRestore: Bool {
        guard !working, preview != nil, parent != nil else { return false }
        return (try? VaultLibrary.folderName(for: name)) != nil
    }

    private func choose(_ result: Result<URL, Error>) async {
        failure = nil
        do {
            let url = try result.get()
            let found = try await model.previewRestore(from: url)
            picked = url
            source = found.source
            preview = found.preview
            if name.isEmpty { name = BackupLocation.suggestedName(forBackup: found.source) }
        } catch {
            failure = "\(error)"
        }
    }

    private func restore() {
        guard let picked, let source, let parent else { return }
        failure = nil
        working = true
        Task {
            defer { working = false }
            do {
                outcome = try await model.restoreBackup(picked: picked, source: source, into: parent, name: name,
                                                        library: library)
            } catch {
                failure = "\(error)"
            }
        }
    }
}
