import Sempere
import SempereAppCore
import SwiftUI

/// "Make a Copy…": a new vault of the person's own with this vault's notes as they are now (issue #12,
/// docs/design/1.2-make-a-copy.md; `sempere store copy` makes the same copy). Name, whether to take the notes in
/// Recently Deleted, the new vault's recovery key as New Vault makes it (a new key, the kit, an optional passphrase
/// copy), a progress bar with Cancel, and the result: the key to save, what could not be copied, and "Open the Copy".
struct MakeCopySheet: View {
    let request: MakeCopyRequest
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var includeDeleted = false
    @State private var stopOnProblem = false
    @State private var wrap = false
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var revealed = false
    @State private var failure: String?
    @State private var made: MadeCopy?
    @State private var opening = false

    private var sourceName: String { model.vaultURL.map { VaultLibrary.displayName(of: $0) } ?? "" }

    var body: some View {
        NavigationStack {
            Group {
                if let made {
                    KeyReceipt(created: made.created) { MakeCopyReport(report: made.report) }
                } else {
                    form
                }
            }
            .accessibilityIdentifier("makeCopySheet")
            .navigationTitle(made == nil
                             ? String(localized: "Make a Copy", comment: "Title of the Make a Copy sheet")
                             : String(localized: "Copy Made", comment: "Title of the Make a Copy sheet once the copy exists"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if made == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.isMakingCopy ? "Cancel Copy" : "Cancel") {
                            if model.isMakingCopy { model.cancelMakeCopy() } else { dismiss() }
                        }
                        .help("Stop making the copy, or close this window")
                        .accessibilityIdentifier("makeCopy.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Make Copy") { start() }
                            .disabled(!canStart)
                            .help("Make the copy")
                            .accessibilityIdentifier("makeCopy.start")
                    }
                } else if let made {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .help("Close: the recovery key is saved or its kit printed")
                            .accessibilityIdentifier("makeCopy.done")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open the Copy") { open(made) }
                            .disabled(opening)
                            .help("Close this vault and open the copy")
                            .accessibilityIdentifier("makeCopy.open")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isMakingCopy || made != nil)
        .task {
            if name.isEmpty { name = Self.defaultName(source: sourceName) }
        }
        .holdsOnboarding()
    }

    // MARK: - The form

    private var form: some View {
        Form {
            Section {
                TextField("Notes", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("makeCopy.name")
            } header: {
                Text("Name")
            } footer: {
                Text("A new vault of your own with these notes as they are now: its own recovery key, and none of this vault's history, devices or sync targets. “\(sourceName)” is not changed.")
            }
            let notices = model.makeCopyNotices
            if !notices.isEmpty {
                Section {
                    ForEach(notices, id: \.self) { notice in
                        Label(Self.words(notice), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }
                .accessibilityIdentifier("makeCopy.notices")
            }
            Section {
                Toggle("Include notes in Recently Deleted", isOn: $includeDeleted)
                    .accessibilityIdentifier("makeCopy.includeDeleted")
                Toggle("Stop on the first problem", isOn: $stopOnProblem)
                    .accessibilityIdentifier("makeCopy.strict")
            } footer: {
                Text("A note that cannot be read is left out and listed afterwards. With Stop on the first problem, no copy is made at all.")
            }
            Section {
                Toggle("Also store the recovery key under a passphrase", isOn: $wrap)
                    .accessibilityIdentifier("makeCopy.storeKey")
                if wrap {
                    PassphrasePairField(placeholder: String(localized: "Passphrase", comment: "Placeholder of the new passphrase field"),
                                        confirmationPlaceholder: String(localized: "Repeat passphrase",
                                                                        comment: "Placeholder of the passphrase confirmation"),
                                        passphrase: $passphrase, confirmation: $confirmation, revealed: $revealed,
                                        identifier: "makeCopy.passphrase", confirmationIdentifier: "makeCopy.confirmation",
                                        account: name.trimmingCharacters(in: .whitespaces))
                    PassphraseMismatchView(passphrase: passphrase, confirmation: confirmation)
                    Button(String(localized: "Suggest a Passphrase", comment: "New Vault: fill in seven random words"),
                           systemImage: "dice") {
                        let suggested = GeneratedPassphrase.make()
                        passphrase = suggested
                        confirmation = suggested
                        revealed = true
                    }
                    .help(String(localized: "Fill in seven random words as the passphrase"))
                }
            } header: {
                Text("Recovery Key")
            } footer: {
                Text(wrap ? StoredKeyPassphrase.footnote
                          : String(localized: "The copy gets its own recovery key, shown once when it is made: save it or print its kit. This device becomes the copy's home.",
                                   comment: "Footer of the Make a Copy recovery key section"))
            }
            if model.isMakingCopy {
                Section {
                    ProgressView(value: model.makeCopyProgress?.fraction ?? 0)
                    if let p = model.makeCopyProgress, p.total > 0 {
                        Text(Self.progressText(p)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("makeCopy.progress")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
                    .accessibilityIdentifier("makeCopy.failure")
            }
        }
        .disabled(model.isMakingCopy)
    }

    private var canStart: Bool {
        guard !model.isMakingCopy, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !wrap || (!passphrase.isEmpty && passphrase == confirmation)
    }

    // MARK: - Making the copy

    private func start() {
        failure = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let deleted = includeDeleted, strict = stopOnProblem
        let draft = NewVaultRequest(name: trimmed, keySource: .generate, passphrase: wrap ? passphrase : nil,
                                    deviceName: ThisDevice.name, deviceKind: ThisDevice.kind)
        Task {
            var request = draft
            do {
                // This device's keys for the new vault, stored before it exists and deleted again if it is not made
                // (as New Vault does, review of #88, S4).
                let device = try keys.store.generate()
                request.device = device
                try await keys.saveCreatedVaultKeys(device, vaultID: request.vaultId, vaultName: trimmed)
                do {
                    made = try await model.makeCopy(request, includeDeleted: deleted, strict: strict, library: library)
                } catch {
                    try? await keys.store.delete(for: request.vaultId)
                    throw error
                }
            } catch CopyError.cancelled {
                failure = nil   // the person stopped it: nothing was made
            } catch is CancellationError {
                dismiss()   // the vault closed meanwhile
            } catch {
                failure = AppModel.describe(error)
            }
        }
    }

    private func open(_ made: MadeCopy) {
        opening = true
        Task {
            defer { opening = false }
            do {
                try await model.openMadeCopy(made, library: library)
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                model.alert = .error(error)
            }
        }
    }

    // MARK: - Words

    /// "<name> Copy".
    static func defaultName(source: String) -> String {
        String(localized: "\(source) Copy", comment: "Default name of a copy of a vault; the value is the vault's name")
    }

    /// "Copying note 3 of 120".
    static func progressText(_ p: CopyProgress) -> String {
        String(localized: "Copying note \(min(p.done + 1, p.total)) of \(p.total)", comment: "Make a Copy progress: note number, notes in all")
    }

    /// What a notice before the copy says.
    static func words(_ notice: MakeCopyNotice) -> String {
        switch notice {
        case .newerContent:
            return String(localized: "This vault holds content written by a newer version of Sempere. What this version does not understand is not in the copy, and you can change the copy here.",
                          comment: "Make a Copy notice: the vault is of a newer format")
        case .unconfirmedList:
            return String(localized: "This device could not confirm this vault's device list. The copy is a vault of its own and starts its own list.",
                          comment: "Make a Copy notice: the vault's device list does not check here")
        case .removedDevice:
            return String(localized: "This device was removed from this vault, so notes written after that cannot be read and are left out of the copy.",
                          comment: "Make a Copy notice: this device is no longer on the vault's list")
        case .recoveryKey:
            return String(localized: "This vault is open with its recovery key, which cannot change it. The copy is a vault you can change.",
                          comment: "Make a Copy notice: the vault is open with the recovery key")
        }
    }

    /// The report's lines as the result shows them (what was copied, what was not).
    static func lines(_ report: CopyReport) -> [String] {
        var out = [String(localized: "\(report.notes) notes copied", comment: "Make a Copy result: a number of notes")]
        if report.deletedSkipped > 0 {
            out.append(String(localized: "\(report.deletedSkipped) notes in Recently Deleted left out",
                              comment: "Make a Copy result: a number of deleted notes not copied"))
        }
        if !report.failed.isEmpty {
            out.append(String(localized: "\(report.failed.count) notes could not be copied and are not in the copy",
                              comment: "Make a Copy result: a number of notes that failed"))
        }
        if !report.newer.isEmpty {
            out.append(String(localized: "\(report.newer.count) notes might be missing something a newer version wrote",
                              comment: "Make a Copy result: a number of notes that held content of a newer version"))
        }
        return out
    }
}

extension CopyError {
    /// What the sheet says for a copy that stopped (the library's errors carry no user-facing text).
    var text: String {
        switch self {
        case .cancelled:
            return String(localized: "The copy was canceled. Nothing was made.", comment: "Make a Copy: the person stopped it")
        case .partialSource:
            return String(localized: "Some notes of this vault are still downloading. Download them first, then make the copy.",
                          comment: "Make a Copy: the vault is only partly on this device")
        case .unreadableSource:
            return String(localized: "This vault is locked, so it cannot be copied.", comment: "Make a Copy: the vault is locked")
        case .stopped(let note, let reason):
            let id = String(note.uuidString.lowercased().prefix(8))
            return String(localized: "Note \(id) could not be copied, so no copy was made: \(reason)",
                          comment: "Make a Copy with Stop on the first problem: the note's id prefix and the reason")
        }
    }
}

/// The result's section: the copy's counts, and never a copy with problems shown as complete.
private struct MakeCopyReport: View {
    let report: CopyReport

    var body: some View {
        Section {
            let lines = MakeCopySheet.lines(report)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Label(line, systemImage: index == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
            }
            // The names of the notes that failed are ids and the library's reasons, never note text.
            ForEach(report.failed.prefix(5), id: \.note) { failed in
                Text(verbatim: "\(failed.note.prefix(8)): \(failed.reason)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("makeCopy.report")
    }
}
