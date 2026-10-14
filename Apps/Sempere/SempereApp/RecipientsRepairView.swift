import Sempere
import SwiftUI

/// Choose Devices to Keep (the recipients alert, format.md §2.1 "Repair"):
/// tick the keys the vault stays encrypted to; the others are removed, the
/// vault secret rotates and every note is re-encrypted. The same repair as
/// `sempere vault recipients repair --keep`. The rules are
/// `RecipientsRepairChoice`; the work is `AppModel.repairRecipients(keeping:)`.
struct RecipientsRepairView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let choice: RecipientsRepairChoice

    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(choice.candidates) { candidate in
                        Toggle(isOn: binding(candidate)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.label.isEmpty ? String(localized: "Unnamed device", comment: "Repair: a key without a label") : candidate.label)
                                Text(RecipientsProblem.abbreviate(candidate.key))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                if candidate.isHeld {
                                    Text("This device's key: always kept").font(.caption).foregroundStyle(.green)
                                } else if candidate.isUnconfirmed {
                                    Text("Never confirmed by this device").font(.caption).foregroundStyle(.red)
                                } else if candidate.isRemoved {
                                    Text("Taken off the list without the vault's key").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .disabled(candidate.isHeld)
                    }
                } header: {
                    Text("Devices to keep")
                } footer: {
                    Text("Only the devices you keep can open the vault after the repair. Keep a device marked as never confirmed only if you know it is yours.")
                }
                if let problem = choice.problem(with: selected) {
                    Section { Text(problem.description).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Choose Devices to Keep")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repair…") { confirming = true }
                        .disabled(choice.problem(with: selected) != nil)
                }
            }
        }
        .frame(minWidth: SheetSizing.minWidth(460, isPhone: Platform.isPhone), minHeight: 360)
        .onAppear { selected = choice.initial }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .overlay {
            if working {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Repairing the device list and re-encrypting every note…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("Repair the device list?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Repair", role: .destructive) { Task { await repair() } }
        } message: {
            Text(choice.summary(selected))
        }
        .alert("Sempere", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func binding(_ candidate: RecipientsRepairChoice.Candidate) -> Binding<Bool> {
        Binding(get: { selected.contains(candidate.key) },
                set: { on in if on { selected.insert(candidate.key) } else { selected.remove(candidate.key) } })
    }

    private func repair() async {
        working = true
        defer { working = false }
        do {
            try await model.repairRecipients(keeping: selected, expectedVault: choice.vault)
            dismiss()
        } catch is CancellationError {
        } catch {
            failure = "\(error)"
        }
    }
}
