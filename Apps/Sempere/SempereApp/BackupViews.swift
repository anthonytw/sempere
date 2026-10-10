import Sempere
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Backups (docs/io.md "Backups"): the folder, Back Up Now,
/// Verify Backup, the last backup, the reminder and Restore from Backup.
/// The work is `AppModel+Backup`, on the same core as `sempere backup`.
struct BackupSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var record = BackupRecord()
    @State private var picking = false
    @State private var restoring = false
    @State private var message: String?
    @State private var problems: [String] = []
    @State private var notificationsOff = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Section {
            Button(record.bookmark == nil ? LocalizedStringKey("Choose Backup Folder…") : LocalizedStringKey("Change Backup Folder…")) {
                picking = true
            }
                .disabled(busy || model.vault == nil)
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
                ForEach(problems, id: \.self) { line in
                    Text(line).font(.footnote.monospaced()).foregroundStyle(.red).lineLimit(2)
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
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                try model.chooseBackupFolder(try result.get())
                problems = []
                message = nil
            } catch {
                message = "\(error)"
            }
            reload()
        }
        .sheet(isPresented: $restoring) { RestoreBackupView() }
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
                message = "\(error)"
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
        problems = Array(report.problemLines.prefix(20))
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
    private enum Importing { case backup, folder }
    @State private var importMode = Importing.backup
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
        // One importer for both picks: two on one view can hide each other.
        // (The mode is kept apart from `isPresented`, which SwiftUI may reset
        // before it calls the completion.)
        .fileImporter(isPresented: $importerShown,
                      allowedContentTypes: importMode == .backup ? [.folder, .sempere] : [.folder]) { result in
            switch importMode {
            case .backup: Task { await choose(result) }
            case .folder:
                folder = try? result.get()
                if folder == nil { location = .onDevice }
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        Section {
            Button(picked == nil ? LocalizedStringKey("Choose Backup Folder…") : LocalizedStringKey("Choose Another Backup…")) {
                importMode = .backup
                importerShown = true
            }
            if let source { LabeledContent("Backup", value: source.lastPathComponent) }
        } footer: {
            Text("Choose the backup folder (it holds backup.json), or any vault folder. Nothing is written until you tap Restore.")
        }
        if let preview {
            Section("This Backup Holds") {
                ForEach(BackupText.preview(preview)) { row in LabeledContent(row.label, value: row.value) }
                if preview.legacy {
                    Text(AppModel.BackupAppError.legacyBackup.description).foregroundStyle(.red)
                }
            }
            Section {
                TextField("Name", text: $name).autocorrectionDisabled()
                Picker("Location", selection: $location) {
                    Text("On This Device").tag(Location.onDevice)
                    Text("Choose Folder…").tag(Location.folder)
                }
                .onChange(of: location) { _, new in if new == .folder { importMode = .folder; importerShown = true } }
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
        guard !working, let preview, !preview.legacy, parent != nil else { return false }
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
