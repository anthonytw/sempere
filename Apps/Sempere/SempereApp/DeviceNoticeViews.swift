import Sempere
import SempereRender
import SwiftUI
import UniformTypeIdentifiers

/// The banners over the note list about this device's place in the vault (key-hierarchy design §5.5, §5.6,
/// §6.3): a takeover by another device (until dismissed), not on the newest device list (opens the unlisted
/// screen), sync held back for more than a day, a home conflict. Each opens what explains it.
struct DeviceNoticeBanners: View {
    @AppModelEnvironment private var model
    @State private var showingUnlisted = false
    @State private var showingDevices = false

    var body: some View {
        VStack(spacing: 0) {
            if let alert = model.takeoverAlert {
                HStack(alignment: .top) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TakeoverAlert.title).bold()
                            Text(alert.message)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                    Button("Dismiss") { model.dismissTakeoverAlert() }
                        .accessibilityIdentifier("takeoverAlert.dismiss")
                }
                .font(.callout)
                .bannerStyle()
                .accessibilityIdentifier("takeoverAlert")
            }
            ForEach(model.deviceNotices) { notice in
                Button {
                    if notice == .unlisted { showingUnlisted = true } else { showingDevices = true }
                } label: {
                    Label(notice.text, systemImage: notice.symbol)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show what this means")
                .bannerStyle()
                .accessibilityIdentifier("deviceNotice.\(notice.id)")
            }
        }
        .sheet(isPresented: $showingUnlisted) { UnlistedDeviceView() }
        .sheet(isPresented: $showingDevices) {
            NavigationStack {
                DevicesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingDevices = false }
                        }
                    }
            }
        }
    }
}

private extension View {
    func bannerStyle() -> some View {
        padding(.horizontal).padding(.vertical, 6).background(.bar)
    }
}

/// The unlisted screen (design §5.5): what this device can know (who made the change, when it saw it), that a
/// takeover can undo it, its own changes no other device has, and what to do with them: Export, or remove the
/// vault from this device.
struct UnlistedDeviceView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @AppEnvironmentObject private var keys: RememberedKeys
    @Environment(\.dismiss) private var dismiss
    @State private var facts: UnlistedFacts?
    @State private var confirmRemove = false
    @State private var savingFiles = false
    /// Files Save Files copied this time (the Remove warning names what it did not cover).
    @State private var saved: Int?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(explanation)
                }
                if let facts {
                    Section {
                        if facts.unsynced.isEmpty {
                            Text("Every change made on this device reached another device or a sync target.")
                        } else {
                            Text("\(facts.unsynced.count) files written on this device are on no sync target.",
                                 comment: "Unlisted screen: own changes no target holds")
                            if facts.captures > 0 {
                                Text("\(facts.captures) of them are voice notes not in a note yet: only Save Files keeps them.",
                                     comment: "Unlisted screen: inbox captures among the unsynced files")
                            }
                            Button("Save Files…", systemImage: "folder") { savingFiles = true }
                                .accessibilityIdentifier("unlisted.saveFiles")
                            if let saved {
                                Text("Saved \(saved) files.", comment: "Unlisted screen: after Save Files").foregroundStyle(.secondary)
                            }
                            Button("Export Those Notes…", systemImage: "square.and.arrow.up") {
                                dismiss()
                                model.requestBulkExport(.notes(facts.notes))
                            }
                            .disabled(facts.notes.isEmpty)
                        }
                        Button("Export All Notes…", systemImage: "square.and.arrow.up.on.square") {
                            dismiss()
                            model.requestBulkExport(.vault)
                        }
                    } header: {
                        Text("Changes on this device")
                    } footer: {
                        Text("Save Files copies them as they are, encrypted. Opening them takes the recovery kit and the vault.json file and epochs folder from another copy of the vault (with sempere or stock age). Export makes PDFs or images of the notes. The notes stay readable here.")
                    }
                    Section {
                        Button("Remove from This Device…", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    } footer: {
                        Text("Deletes this device's copy of the vault. The vault on your other devices and sync targets is not changed.")
                    }
                } else {
                    ProgressView()
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Not on the Device List")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Remove this vault from this device?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let n = facts?.unsynced.count, n > 0 {
                    if saved == n {
                        Text("You saved the \(n) files that are on no sync target. The copy here is deleted.",
                             comment: "Unlisted screen: removing after Save Files")
                    } else {
                        Text("\(n) files on this device are on no sync target and will be lost. Save Files keeps them all; Export keeps only the notes as PDFs or images.",
                             comment: "Unlisted screen: removing the copy")
                    }
                } else {
                    Text("Nothing is lost: every change here reached another device or a sync target.")
                }
            }
            .task { facts = await model.unlistedFacts() }
            .fileImporter(isPresented: $savingFiles, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result, let paths = facts?.unsynced else { return }
                Task {
                    do { saved = try await model.exportUnsyncedFiles(paths, to: folder) } catch {
                        failure = DeviceChangeText.message(error)
                    }
                }
            }
        }
        .accessibilityIdentifier("unlistedDeviceView")
    }

    private var explanation: String {
        let vault = model.vaultName ?? ""
        let by = facts?.by ?? String(localized: "another device", comment: "Unlisted screen: who removed this device, if unknown")
        let when = facts?.seen.map { $0.formatted(date: .abbreviated, time: .omitted) }
            ?? String(localized: "recently", comment: "Unlisted screen: when, if unknown")
        return String(localized: "This device is not on the newest device list of “\(vault)”. The change was made by \(by); this device saw it on \(when). If that is a mistake (for example a lost device that was managing devices), a takeover with the recovery kit undoes it, and this device rejoins by itself when the vault shows it.",
                      comment: "Unlisted screen; the values are the vault name, a device name and a date")
    }

    private func remove() {
        guard let url = model.vaultURL, let entry = model.syncStore.entry(containing: url) else {
            failure = String(localized: "This vault is not kept by the app, so there is no copy to remove.")
            return
        }
        Task {
            model.close()
            do {
                try await library.removeStored(entry)
                try? await keys.store.delete(for: entry.vaultId)
                dismiss()
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }
}

/// Repair for device changes (design §5.8, docs/design/device-first-sync.md §8.4): files set aside from before a device change
/// (each with its epoch and reason; Export, Keep, Clear Superseded, and Keep this device's own files from changes
/// a takeover dropped), and the device lists a sync met that this device did not take (forget the detached ones,
/// or every one after a warning).
struct SetAsideRepairView: View {
    @AppModelEnvironment private var model
    @State private var items: [SetAsideStatus] = []
    @State private var ownDropped: [SetAsideItem] = []
    @State private var exporting: [SetAsideItem]?
    @State private var keeping: [SetAsideItem]?
    /// Keeping this device's own files from dropped changes (their own message, review of #87 S7).
    @State private var keepingOwn: [SetAsideItem]?
    /// A file that is not superseded, about to be deleted: asked first (review of #87 S6).
    @State private var deleting: SetAsideItem?
    @State private var forgetAll = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            setAside
            sightings
        }
        .navigationTitle("Device Changes")
        .accessibilityIdentifier("setAsideRepairView")
        .disabled(working)
        .task(id: model.keyEpoch) { await reload() }
        .fileImporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      allowedContentTypes: [.folder]) { result in
            guard let picked = exporting else { return }
            exporting = nil
            if case .success(let folder) = result {
                run {
                    let n = try await model.exportSetAside(picked, to: folder)
                    message = String(localized: "Exported \(n) files.", comment: "Repair: set-aside files exported")
                }
            }
        }
        .confirmationDialog("Keep these files in the vault?", isPresented: Binding(get: { keeping != nil }, set: { if !$0 { keeping = nil } }),
                            titleVisibility: .visible, presenting: keeping) { picked in
            Button("Keep") {
                keeping = nil
                run { try await model.keepSetAside(picked) }
            }
            Button("Cancel", role: .cancel) { keeping = nil }
        } message: { _ in
            Text("They may come from a removed device. Keep only what you recognize. They are added under the vault's current key.")
        }
        .confirmationDialog("Keep these files in the vault?", isPresented: Binding(get: { keepingOwn != nil }, set: { if !$0 { keepingOwn = nil } }),
                            titleVisibility: .visible, presenting: keepingOwn) { picked in
            Button("Keep") {
                keepingOwn = nil
                run { try await model.keepSetAside(picked) }
            }
            Button("Cancel", role: .cancel) { keepingOwn = nil }
        } message: { _ in
            Text("This device wrote them, under a device change a takeover undid. They are added again under the vault's current key.")
        }
        .confirmationDialog("Delete this file from this device?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete", role: .destructive) {
                deleting = nil
                run { try await model.clearSetAside([item]) }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("The vault has no copy of it: it may be the only copy of someone's change. Export it first to keep it.")
        }
        .confirmationDialog("Forget every device list?", isPresented: $forgetAll, titleVisibility: .visible) {
            Button("Forget All", role: .destructive) {
                run { try await model.forgetSightings(anchoredToo: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some of them are changes this device checked, such as its own removal. Forgetting them lets it write and upload again until a sync meets the change again.")
        }
        .alert("Repair", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder private var setAside: some View {
        Section {
            if items.isEmpty {
                Text("No files were set aside.").foregroundStyle(.secondary)
            }
            ForEach(items, id: \.item.file) { status in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: status.item.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(Self.reason(status.item)).font(.caption).foregroundStyle(.secondary)
                    if status.superseded {
                        Label("The vault has the same content", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    }
                }
                .contextMenu {
                    Button("Export…", systemImage: "square.and.arrow.up") { exporting = [status.item] }
                    Button("Keep in Vault…", systemImage: "tray.and.arrow.down") { keeping = [status.item] }
                    Button("Delete from This Device", systemImage: "trash", role: .destructive) {
                        if status.superseded { run { try await model.clearSetAside([status.item]) } } else { deleting = status.item }
                    }
                }
            }
            if !ownDropped.isEmpty {
                Button("Keep \(ownDropped.count) Files This Device Wrote", systemImage: "tray.and.arrow.down") { keepingOwn = ownDropped }
                    .accessibilityIdentifier("repair.keepOwn")
            }
            if !items.isEmpty {
                Button("Export All…", systemImage: "square.and.arrow.up") { exporting = items.map(\.item) }
            }
            if items.contains(where: \.superseded) {
                Button("Clear Superseded", systemImage: "trash", role: .destructive) {
                    run { try await model.clearSetAside(items.filter(\.superseded).map(\.item)) }
                }
            }
        } header: {
            Text("From Before a Device Change")
        } footer: {
            Text("Files under an earlier key that no device change kept: written after a removal, by a removed device, or by a device that had not caught up. They are never read as notes and never deleted unless you do it. Touch and hold one for its actions.")
        }
    }

    @ViewBuilder private var sightings: some View {
        let rows = model.sightingRows
        Section {
            if rows.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device change \(row.epoch), seen \(row.seen, format: .relative(presentation: .named))",
                         comment: "Repair: a sighting; the values are an epoch number and a relative date")
                    Text(row.anchored ? String(localized: "Checked against this device's list: holds every sync back")
                                      : String(localized: "Not checked: holds back only the targets that show it"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: row.sources.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if rows.contains(where: { !$0.anchored }) {
                Button("Forget Unchecked Lists") {
                    run {
                        let n = try await model.forgetSightings(anchoredToo: false)
                        message = String(localized: "Forgot \(n) device lists.", comment: "Repair: sightings forgotten")
                    }
                }
            }
            if rows.contains(where: \.anchored) {
                Button("Forget All…", role: .destructive) { forgetAll = true }
            }
        } header: {
            Text("Device Lists Not Taken")
        } footer: {
            Text("Device lists a sync met that this device could not take yet. Anyone who can write to a sync target can leave an unchecked one.")
        }
    }

    static func reason(_ item: SetAsideItem) -> String {
        let epoch = item.epoch.map { String(localized: "Device change \($0): ", comment: "Repair: before the reason; the value is an epoch number") } ?? ""
        switch item.reason {
        case .notSealed: return epoch + String(localized: "written under an earlier key after that change")
        case .bytesDiffer: return epoch + String(localized: "kept by that change with other content")
        case .dropped: return epoch + String(localized: "written under a change a takeover undid")
        case .beforeReencryption: return epoch + String(localized: "from before a re-encryption that finished")
        }
    }

    private func reload() async {
        items = await model.setAsideItems()
        ownDropped = await model.ownDroppedSetAside()
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do { try await action() } catch is CancellationError {} catch { message = DeviceChangeText.message(error) }
            await reload()
        }
    }
}
