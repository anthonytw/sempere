import Sempere
import SwiftUI

/// Re-encrypt Everything, the progress (on home; key-hierarchy design §7.2 "Progress"): this device's files under the
/// new key, each sync target's confirmation, and Continue, which runs one step (`AppModel.advanceReencryption`: the
/// pass, the runs, each target confirmed, and the finish once every one is). A step that cannot finish (a target out
/// of reach, another device's files still to arrive) leaves it for the next Continue; nothing is lost by closing the
/// sheet, the list's row opens it again.
struct ReencryptProgressSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var progress: ReencryptProgress?
    @State private var status: ReencryptStatus?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                overview
                if let progress, !progress.targets.isEmpty { targets(progress) }
                if let progress, !progress.problems.isEmpty { problems(progress) }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Re-encryption")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .help("Close; the re-encryption goes on with the next Continue")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if status?.pending == true {
                        Button("Continue") { advance() }
                            .help("Re-encrypt this device's files, sync and check every target")
                            .accessibilityIdentifier("reencrypt.continue")
                    }
                }
            }
            .disabled(working)
            .interactiveDismissDisabled(working)
            .overlay {
                if working {
                    ProgressView(String(localized: "Re-encrypting…"))
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .task { await refresh() }
        }
        .accessibilityIdentifier("reencryptProgressSheet")
    }

    @ViewBuilder private var overview: some View {
        Section {
            if let status {
                if status.pending {
                    ProgressView(value: Double(status.total - status.remaining), total: Double(max(status.total, 1))) {
                        Text("\(status.total - status.remaining) of \(status.total) files on this device under the new key",
                             comment: "Re-encryption progress: files done of all")
                    }
                    if !status.journalHere {
                        Text("The re-encryption's journal has not arrived on this device yet.").foregroundStyle(.secondary)
                    }
                    if status.unaccepted > 0 {
                        Text("\(status.unaccepted) files under an earlier key do not check and are kept aside (Repair).",
                             comment: "Re-encryption: unaccepted files")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label("Everything is re-encrypted.", systemImage: "checkmark.seal").foregroundStyle(.green)
                }
            } else if failure == nil {
                ProgressView()
            }
        } footer: {
            Text("Every target the vault syncs with is checked; once each holds only files under the new key, the re-encryption finishes and the old keys open nothing there. Other devices follow when they sync.")
        }
    }

    @ViewBuilder private func targets(_ p: ReencryptProgress) -> some View {
        Section {
            ForEach(p.targets) { line in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: line.name).font(.headline)
                        Spacer()
                        if !line.reached {
                            Label("Not reached", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                        } else if line.confirmed {
                            Label("Confirmed", systemImage: "checkmark.circle").foregroundStyle(.green)
                        } else {
                            Label("Waiting", systemImage: "hourglass").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    if line.reached {
                        ProgressView(value: line.fraction)
                        Text("\(line.current) of \(line.files) files under the new key", comment: "Re-encryption: a target's files done of all")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Sync Targets")
        }
    }

    @ViewBuilder private func problems(_ p: ReencryptProgress) -> some View {
        Section {
            ForEach(p.problems, id: \.self) { Text(verbatim: $0).font(.caption.monospaced()) }
        } header: {
            Text("Not done yet")
        } footer: {
            Text("These files are retried at the next Continue.")
        }
    }

    private func refresh() async {
        do {
            status = try await model.reencryptStatus()
        } catch {
            failure = DeviceChangeText.message(error)
        }
    }

    private func advance() {
        failure = nil
        working = true
        Task {
            defer { working = false }
            do {
                let p = try await model.advanceReencryption()
                progress = p
                status = p.status
            } catch is CancellationError {
            } catch {
                failure = DeviceChangeText.message(error)
                await refresh()
            }
        }
    }
}
