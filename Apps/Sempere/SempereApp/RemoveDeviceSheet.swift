import Sempere
import SwiftUI

/// Removing a device (on home: key-hierarchy design §5.2, §5.5): the stale warning and what the removal cannot do;
/// the devices it approved while it managed devices, listed and checked so they go too (the owner's default,
/// review of #87); "Lost or Stolen", which points out a kit it made; then Remove: every target synced first (at
/// most 10 seconds each, skippable), and a new key.
struct RemoveDeviceSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let device: DeviceRow
    /// Told what the change did (the list's alert).
    let done: (String) -> Void
    @State private var review: RemovalReviewItem?
    @State private var lost = false
    /// The approved devices to remove too, by id (all of them, checked, to start with).
    @State private var alsoRemove: Set<String> = []
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let review {
                    content(review)
                } else if failure == nil {
                    ProgressView()
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Remove “\(device.name)”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(working)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) { remove() }
                        .help("Remove the device and give the vault a new key")
                        .disabled(review == nil || working)
                        .accessibilityIdentifier("removeDevice.confirm")
                }
            }
            .disabled(working)
            .interactiveDismissDisabled(working)
            .overlay { if working { DeviceChangeSyncOverlay() } }
            .task {
                do {
                    let r = try await model.removalReview([device.id]).first
                    review = r
                    alsoRemove = Set(r?.approved.compactMap(\.id) ?? [])
                } catch { failure = DeviceChangeText.message(error) }
            }
        }
        .accessibilityIdentifier("removeDeviceSheet")
    }

    @ViewBuilder private func content(_ r: RemovalReviewItem) -> some View {
        Section {
            if r.stale {
                Label {
                    Text(Self.staleText(device.name, r))
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
            }
            Label {
                Text(storageAdvice)
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
            }
        } footer: {
            Text("The vault gets a new key. Notes from before stay readable to the removed device; nothing written after reaches it.")
        }
        if !r.approved.isEmpty {
            Section {
                ForEach(r.approved, id: \.fingerprint) { e in
                    let id = e.id ?? ""
                    Toggle(DeviceName.display(e.name), isOn: Binding(get: { alsoRemove.contains(id) },
                                                                     set: { if $0 { alsoRemove.insert(id) } else { alsoRemove.remove(id) } }))
                }
            } header: {
                Text("Also remove the devices “\(device.name)” added", comment: "Removal sheet; the value is a device name")
            } footer: {
                Text("“\(device.name)” managed devices for a while and added these. If someone else has it, they could have added their own devices then. Uncheck the ones you hold.",
                     comment: "Removal sheet footer; the value is a device name")
            }
        }
        Section {
            Toggle("Lost or Stolen", isOn: $lost)
            if lost, r.replacedKit {
                Label("“\(device.name)” made the current recovery kit while it managed devices. Replace the kit after this.",
                      systemImage: "key.viewfinder")
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "<name> last synced 3 days ago…", "…hasn't synced since a device change…", "…has no recorded sync…".
    static func staleText(_ name: String, _ r: RemovalReviewItem) -> String {
        if let last = r.lastSynced {
            return String(localized: "“\(name)” last synced \(last.formatted(.relative(presentation: .named))). Changes it made since then will not reach this vault. It will be told it was removed, and can export them.",
                          comment: "Removal warning; the values are a device name and a relative date")
        }
        if let change = r.notSyncedSinceChange {
            return String(localized: "“\(name)” hasn't synced since a device change \(change.formatted(.relative(presentation: .named))). Changes it made since then will not reach this vault. It will be told it was removed, and can export them.",
                          comment: "Removal warning; the values are a device name and a relative date")
        }
        return String(localized: "“\(name)” has no recorded sync. Changes it made will not reach this vault. It will be told it was removed, and can export them.",
                      comment: "Removal warning; the value is a device name")
    }

    /// What the removal cannot take away: the vault's storage, named by the targets it has (review of #87).
    private var storageAdvice: String {
        let targets = model.openVaultTargets
        return Self.storageAdvice(servers: targets.filter { $0.kind == .webdav }.map(\.name), hasFolder: targets.contains { $0.kind == .folder })
    }

    static func storageAdvice(servers: [String], hasFolder: Bool) -> String {
        let list = servers.formatted(.list(type: .and))
        switch (servers.isEmpty, hasFolder) {
        case (false, true):
            return String(localized: "It can still reach your storage. If you no longer control it, change the password of \(list) and sign it out of iCloud or the service that holds your sync folder.",
                          comment: "Removal sheet: storage advice; the value names WebDAV servers")
        case (false, false):
            return String(localized: "It can still reach \(list). If you no longer control it, change that password.",
                          comment: "Removal sheet: storage advice; the value names WebDAV servers")
        case (true, true):
            return String(localized: "It can still reach your sync folder. If you no longer control it, sign it out of iCloud or the service that holds the folder.",
                          comment: "Removal sheet: storage advice for a folder target")
        case (true, false):
            return String(localized: "This vault has no sync targets, so the removed device keeps only what it had.",
                          comment: "Removal sheet: storage advice without targets")
        }
    }

    /// The ids a removal removes: the device, and the approved devices still checked (never the device itself).
    static func ids(removing device: String, approved: Set<String>) -> [String] {
        [device] + approved.filter { $0 != device }.sorted()
    }

    private func remove() {
        guard let review else { return }
        let ids = Self.ids(removing: device.id, approved: alsoRemove.intersection(Set(review.approved.compactMap(\.id))))
        let suggestKit = review.replacedKit
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let outcome = try await model.removeDevices(ids)
                var action = String(localized: "“\(device.name)” was removed. The vault has a new key.", comment: "After a removal; the value is a device name")
                if suggestKit {
                    action += "\n\n" + String(localized: "Replace the recovery kit now: the removed device made the current one.")
                }
                done(DeviceChangeText.done(outcome, action: action))
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }
}
