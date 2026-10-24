import Sempere
import SwiftUI

/// Removing a device (on home: key-hierarchy design §5.2, §5.5): what the removal cannot do and the stale
/// warning, "Lost or stolen" (then the devices it approved while it managed devices go too, and a kit it
/// replaced is pointed out), then Remove: every target synced first (at most 10 seconds each), and a new key.
struct RemoveDeviceSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let device: DeviceRow
    /// Told what the change did (the list's alert).
    let done: (String) -> Void
    @State private var review: RemovalReviewItem?
    @State private var lost = false
    @State private var alsoApproved = true
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
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) { remove() }
                        .help("Remove the device and give the vault a new key")
                        .disabled(review == nil || working)
                        .accessibilityIdentifier("removeDevice.confirm")
                }
            }
            .disabled(working)
            .overlay {
                if working {
                    ProgressView("Syncing, then changing the vault's key…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .task {
                do { review = try await model.removalReview([device.id]).first } catch { failure = "\(error)" }
            }
        }
        .accessibilityIdentifier("removeDeviceSheet")
    }

    @ViewBuilder private func content(_ r: RemovalReviewItem) -> some View {
        Section {
            if r.stale {
                Label {
                    if let last = r.lastSynced {
                        Text("“\(device.name)” last synced \(last, format: .relative(presentation: .named)). Changes it made since then will not reach this vault. It will be told it was removed, and can export them.",
                             comment: "Removal warning; the values are a device name and a relative date")
                    } else {
                        Text("“\(device.name)” has no recorded sync. Changes it made will not reach this vault. It will be told it was removed, and can export them.",
                             comment: "Removal warning; the value is a device name")
                    }
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
        Section {
            Toggle("Lost or Stolen", isOn: $lost)
                .onChange(of: lost) { _, on in if on { alsoApproved = true } }
            if lost, !r.approved.isEmpty {
                Toggle(isOn: $alsoApproved) {
                    let names = r.approved.map { DeviceName.display($0.name) }.formatted(.list(type: .and))
                    Text("Also remove the devices “\(device.name)” added: \(names)", comment: "Removal sheet; the values are device names")
                }
            }
            if lost, r.replacedKit {
                Label("“\(device.name)” replaced the recovery kit while it managed devices. Replace the kit again after this.",
                      systemImage: "key.viewfinder")
                    .foregroundStyle(.orange)
            }
        } footer: {
            if !r.approved.isEmpty || r.replacedKit {
                Text("“\(device.name)” managed devices for a while. If someone else has it, they could have added their own devices then.",
                     comment: "Removal sheet footer; the value is a device name")
            }
        }
    }

    /// "It can still reach your storage. Change the password of <WebDAV target>, or sign it out of iCloud…"
    private var storageAdvice: String {
        let servers = model.openVaultTargets.filter { $0.kind == .webdav }.map(\.name)
        if servers.isEmpty {
            return String(localized: "It can still reach your storage. Sign it out of iCloud (or of the service that holds your sync folder) if you no longer control it.",
                          comment: "Removal sheet: storage advice without a WebDAV target")
        }
        let list = servers.formatted(.list(type: .and))
        return String(localized: "It can still reach your storage. Change the password of \(list), or sign it out of iCloud, if you no longer control it.",
                      comment: "Removal sheet: storage advice; the value names WebDAV servers")
    }

    private func remove() {
        guard let review else { return }
        var ids = [device.id]
        if lost, alsoApproved { ids += review.approved.compactMap(\.id).filter { $0 != device.id } }
        let suggestKit = lost && review.replacedKit
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
                failure = "\(error)"
            }
        }
    }
}
