import Sempere
import SwiftUI

/// Settings ▸ Sync & Devices ▸ Devices, and the Mac's key window (key-hierarchy design §6.4): every device with
/// its kind, "This Device", "Manages devices", who added it and when, and its last sync; the recovery kit; the
/// history of device changes; Repair. On the device that manages devices: Rename, Make Home and Remove per
/// device, and Replace Recovery Kit.
struct DevicesView: View {
    @AppModelEnvironment private var model
    @State private var snapshot: DeviceListSnapshot?
    @State private var failure: String?
    @State private var renaming: DeviceRow?
    @State private var newName = ""
    @State private var removing: DeviceRow?
    @State private var makingHome: DeviceRow?
    @State private var replacingKit = false
    @State private var addingCopy = false
    @State private var addingDevice = false
    @State private var takingOver = false
    @State private var reencrypting = false
    @State private var reencryptProgress = false
    @State private var reencryptStarted = false
    @State private var reencryptStatus: ReencryptStatus?
    @State private var working = false
    @State private var outcome: String?

    var body: some View {
        Form {
            if model.phase != .unlocked {
                Text("Unlock a vault to see its devices.").foregroundStyle(.secondary)
            } else if model.isRecoveryOpen {
                Text("Unlocked with the recovery key: this device is not one of the vault's devices.")
                    .foregroundStyle(.secondary)
            } else if let snapshot {
                devices(snapshot)
                recoveryKit(snapshot)
                Section {
                    NavigationLink {
                        SetAsideRepairView()
                    } label: {
                        Label("Repair", systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("devices.repair")
                } footer: {
                    Text("Files from before a device change, and device lists a sync could not check.")
                }
                history(snapshot)
            } else {
                ProgressView()
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Devices")
        .accessibilityIdentifier("devicesView")
        .disabled(working)
        .overlay { if working { DeviceChangeSyncOverlay() } }
        .task(id: model.keyEpoch) { await reload() }
        .alert("Rename Device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                guard let device = renaming, !DeviceName.clean(newName).isEmpty else { return }
                let name = newName
                renaming = nil
                run { try await model.renameDevice(device.id, to: name) }
            }
            .disabled(DeviceName.clean(newName).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Names are stored unencrypted in the vault, so the storage can read them (it cannot change them).")
        }
        .confirmationDialog(makingHome.map { String(localized: "Make “\($0.name)” manage devices?", comment: "Make Home confirmation; the value is a device name") } ?? "",
                            isPresented: Binding(get: { makingHome != nil }, set: { if !$0 { makingHome = nil } }),
                            titleVisibility: .visible, presenting: makingHome) { device in
            Button("Make Home") {
                makingHome = nil
                run {
                    let done = try await model.makeHome(device.id)
                    outcome = DeviceChangeText.done(done, action: String(localized: "“\(device.name)” manages devices now.",
                                                                         comment: "After Make Home; the value is a device name"))
                }
            }
            Button("Cancel", role: .cancel) { makingHome = nil }
        } message: { device in
            Text("From then on only “\(device.name)” can add, rename and remove devices or replace the recovery kit. The vault gets a new key.")
        }
        .sheet(item: $removing) { device in
            RemoveDeviceSheet(device: device) { message in
                outcome = message
                Task { await reload() }
            }
        }
        .sheet(isPresented: $addingDevice) {
            AddDeviceSheet { message in
                outcome = message
                Task { await reload() }
            }
        }
        .sheet(isPresented: $takingOver) {
            NavigationStack { TakeoverView { takingOver = false; Task { await reload() } } }
        }
        .sheet(isPresented: $addingCopy) {
            AddPassphraseCopySheet { message in
                outcome = message
                Task { await reload() }
            }
        }
        .sheet(isPresented: $replacingKit) {
            ReplaceKitSheet { message in
                outcome = message
                Task { await reload() }
            }
        }
        .sheet(isPresented: $reencrypting, onDismiss: {
            // Straight on to the progress once the start's sheet is gone: the start is only steps 1–4 (design §7.1).
            if reencryptStarted { reencryptStarted = false; reencryptProgress = true }
            Task { await reload() }
        }) {
            ReplaceKitSheet(mode: .reencrypt) { _ in reencryptStarted = true }
        }
        .sheet(isPresented: $reencryptProgress, onDismiss: { Task { await reload() } }) {
            ReencryptProgressSheet()
        }
        .alert("Devices", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outcome ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder private func devices(_ s: DeviceListSnapshot) -> some View {
        Section {
            ForEach(s.devices) { device in
                HStack {
                    DeviceRowView(device: device)
                    if s.thisIsHome {
                        // Visible, not only on touch and hold (build 12: "Any way to change names?").
                        Menu {
                            actions(device)
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Actions for “\(device.name)”",
                                comment: "Devices: the value is a device name"))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .help(device.isHome ? String(localized: "Rename this device")
                                            : String(localized: "Rename, make home or remove this device"))
                        .accessibilityIdentifier("devices.actions.\(device.id)")
                    }
                }
                    .contextMenu { if s.thisIsHome { actions(device) } }
                    .swipeActions(edge: .trailing) {
                        if s.thisIsHome && !device.isHome {
                            Button("Remove", systemImage: "minus.circle", role: .destructive) { removing = device }
                        }
                    }
            }
            if s.thisIsHome {
                Button("Add Device…", systemImage: "plus.circle") { addingDevice = true }
                    .accessibilityIdentifier("devices.add")
            }
        } header: {
            Text("Devices")
        } footer: {
            if s.thisIsHome {
                if s.joinRequests > 0 {
                    Text("This device manages devices. \(s.joinRequests) devices asked to join.",
                         comment: "Devices footer on home; the value is a count of join requests")
                } else {
                    Text("This device manages devices: it adds, renames and removes them. Use a device's ⋯ button to rename it, this one included.")
                }
            } else if let home = s.homeName {
                Text("“\(home)” manages devices: add, rename and remove devices there. If it is lost, take over with the recovery kit (on a computer: sempere devices takeover).",
                     comment: "Devices footer; the value is the home device's name")
            }
        }
    }

    // help-lint: titled
    @ViewBuilder private func actions(_ device: DeviceRow) -> some View {
        Button("Rename…", systemImage: "pencil") {
            newName = device.name
            renaming = device
        }
        if !device.isHome {
            Button("Make Home…", systemImage: "house") { makingHome = device }
            Button("Remove…", systemImage: "minus.circle", role: .destructive) { removing = device }
        }
    }

    @ViewBuilder private func recoveryKit(_ s: DeviceListSnapshot) -> some View {
        Section {
            if let added = s.recoveryAdded {
                LabeledContent("Recovery Kit", value: added.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Passphrase Copy", value: s.passphraseCopy ? String(localized: "In the vault", comment: "Passphrase copy state")
                                                                      : String(localized: "None", comment: "Passphrase copy state"))
            if let status = reencryptStatus, status.pending {
                Button {
                    reencryptProgress = true
                } label: {
                    LabeledContent {
                        Text("\(status.total - status.remaining) of \(status.total)", comment: "Re-encryption row: files done of all")
                    } label: {
                        Label("Re-encryption in progress", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!s.thisIsHome)
                .accessibilityIdentifier("devices.reencryptPending")
            }
            if s.thisIsHome {
                if !s.passphraseCopy {
                    Button("Add Passphrase Copy…", systemImage: "key.horizontal") { addingCopy = true }
                        .accessibilityIdentifier("devices.addPassphraseCopy")
                }
                Button("Replace Recovery Kit…", systemImage: "key.viewfinder") { replacingKit = true }
                    .accessibilityIdentifier("devices.replaceKit")
                    .disabled(reencryptStatus?.pending == true)
                if reencryptStatus?.pending != true {
                    Button("Re-encrypt Everything…", systemImage: "lock.rotation") { reencrypting = true }
                        .accessibilityIdentifier("devices.reencrypt")
                }
            } else {
                Button("Take Over with Recovery Kit…", systemImage: "key.viewfinder") { takingOver = true }
                    .accessibilityIdentifier("devices.takeover")
            }
        } header: {
            Text("Recovery Kit")
        } footer: {
            Text("The kit was printed once; no device keeps the recovery key, so it cannot be printed again. Replacing it makes the old kit useless for every later change. Re-encrypting everything also makes it, and removed devices' keys, open nothing written before. A passphrase copy is the recovery key under a passphrase, kept in the vault: add it from the printed kit here, or when you replace the kit. A copy cannot be changed in place; replace the kit to give it a new passphrase.")
        }
    }

    @ViewBuilder private func history(_ s: DeviceListSnapshot) -> some View {
        Section {
            ForEach(s.history, id: \.epochId) { event in
                HistoryEventRow(event: event)
            }
            if s.dropped > 0 {
                Text("\(s.dropped) changes this device had followed were undone by a takeover.",
                     comment: "Device history: epochs a takeover dropped")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("History")
        }
    }

    // MARK: - Actions

    private func reload() async {
        guard model.phase == .unlocked, !model.isRecoveryOpen else { return }
        do {
            snapshot = try await model.loadDeviceList()
            reencryptStatus = try? await model.reencryptStatus()
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await action()
                await reload()
            } catch is CancellationError {
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }
}

/// One device of the list.
struct DeviceRowView: View {
    let device: DeviceRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: device.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: device.name).font(.headline)
                    if device.isThisDevice {
                        Text("This Device").font(.caption).foregroundStyle(.green)
                    }
                }
                if device.isHome {
                    Label("Manages devices", systemImage: "house.fill").font(.caption).foregroundStyle(.blue)
                }
                added.font(.caption).foregroundStyle(.secondary)
                Group {
                    if let last = device.lastSynced {
                        Text("Last synced \(last, format: .relative(presentation: .named))", comment: "Device row; the value is a relative date")
                    } else {
                        Text("No sync recorded")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(verbatim: device.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device.\(device.id)")
    }

    @ViewBuilder private var added: some View {
        let date = device.added.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "?"
        switch device.addedBy {
        case .creation:
            Text("Created the vault on \(date)", comment: "Device row; the value is a date")
        case .recoveryKit:
            Text("Added on \(date) **with the recovery kit**", comment: "Device row; a takeover's new home; the value is a date")
        case .device(let name):
            Text("Added on \(date) by \(name)", comment: "Device row; the values are a date and a device name")
        case .formerDevice(let id):
            Text("Added on \(date) by a removed device (\(id))", comment: "Device row; the values are a date and a device id")
        }
    }
}

/// One device change of the history.
struct HistoryEventRow: View {
    let event: DeviceHistoryEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: symbol).foregroundStyle(event.reason == .takeover ? .orange : .secondary)
                    .accessibilityHidden(true)
                Text(DeviceChangeText.history(event)).font(event.reason == .takeover ? .body.bold() : .body)
            }
            if let date = event.date {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch event.reason {
        case .create: return "sparkles"
        case .remove: return "minus.circle"
        case .handoff: return "house"
        case .takeover: return "exclamationmark.shield"
        case .recovery, .reencrypt: return "key"
        }
    }
}

/// The words of device changes, shared by the list, the sheets and tests.
enum DeviceChangeText {
    /// A device as the history names it.
    static func name(_ ref: DeviceRef) -> String {
        ref.name.map(DeviceName.display) ?? String(localized: "a removed device (\(ref.id))", comment: "History: a device no list here names; the value is its id")
    }

    /// One history line: "Old Mac removed by iPad", "iPad took over with the recovery kit".
    static func history(_ e: DeviceHistoryEvent) -> String {
        let by = name(e.author)
        switch e.reason {
        case .create:
            return String(localized: "Vault created on \(by)", comment: "History; the value is a device name")
        case .remove:
            let gone = e.removed.map(name).formatted(.list(type: .and))
            return String(localized: "\(gone) removed by \(by)", comment: "History; the values are device names")
        case .handoff:
            let home = e.newHome.map(name) ?? "?"
            return String(localized: "\(by) made \(home) manage devices", comment: "History: a handoff; the values are device names")
        case .takeover:
            return withRemoved(String(localized: "\(by) took over with the recovery kit", comment: "History; the value is a device name"), e)
        case .recovery:
            return withRemoved(String(localized: "Recovery kit replaced by \(by)", comment: "History; the value is a device name"), e)
        case .reencrypt:
            return String(localized: "Everything re-encrypted by \(by)", comment: "History; the value is a device name")
        }
    }

    /// `line`, then the devices `e` removed (a takeover or a kit replacement can remove some too).
    static func withRemoved(_ line: String, _ e: DeviceHistoryEvent) -> String {
        guard !e.removed.isEmpty else { return line }
        let gone = e.removed.map(name).formatted(.list(type: .and))
        return line + " " + String(localized: "(removed: \(gone))", comment: "History: after a takeover or kit replacement; the value lists devices")
    }

    /// An error of a device change or Repair, in the app's words: the package's reasons are English, so they come
    /// after a localized sentence for the cases a user can act on.
    static func message(_ error: any Error) -> String {
        switch error {
        case VaultError.notHome:
            return String(localized: "Only the device that manages devices can do this.")
        case VaultError.partialCopy:
            return String(localized: "This vault is still downloading to this device. Try again once it is complete.")
        case VaultError.removedFromVault:
            return String(localized: "This device is not on the vault's device list any more.")
        case VaultError.untrustedList:
            return String(localized: "This vault's device list does not check on this device, so nothing is changed.")
        case VaultError.epochChangeRefused(let why):
            return String(localized: "The change was refused: \(why)", comment: "The value is the reason (English)")
        case let e as VaultFileLock.LockError:
            return String(localized: "Another sync is writing to this vault. Try again in a moment. (\(String(describing: e)))",
                          comment: "The value is the error (English)")
        case let e as KeyProblem:
            return e.message
        case let e as DeviceJoinError:
            return e.description
        case is CancellationError:
            return String(localized: "Canceled.")
        default:
            return String(localized: "That did not work: \(String(describing: error))", comment: "The value is the error (English)")
        }
    }

    /// What a finished change says: `action`, then the targets the run before it could not reach.
    static func done(_ outcome: DeviceChangeOutcome, action: String) -> String {
        var lines = [action]
        for t in outcome.unreachable {
            let since = t.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) }
                ?? String(localized: "its last sync", comment: "Unreachable target: since when, if unknown")
            lines.append(String(localized: "\(t.name) was not reachable: changes there since \(since) from other devices will be caught up by them.",
                                comment: "After a device change; the values are a sync target and a date"))
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Over a device-change sheet while the change runs: "Syncing with the vault's targets…" with Cancel (design §5.2
/// step 2: the bounded run before the change, cancellable; the targets skipped count as not reached), then
/// "Changing the vault's key…".
struct DeviceChangeSyncOverlay: View {
    @AppModelEnvironment private var model

    var body: some View {
        if model.isSyncingBeforeChange || model.isChangingKeys {
            VStack(spacing: 12) {
                ProgressView(model.isSyncingBeforeChange ? String(localized: "Syncing with the vault's targets…")
                                                         : String(localized: "Changing the vault's key…"))
                if model.isSyncingBeforeChange {
                    Button("Skip the Rest") { model.cancelDeviceChangeSync() }
                        .help("Stop syncing and make the change now; the targets not reached are named afterwards")
                        .accessibilityIdentifier("deviceChange.skipSync")
                }
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
    }
}
