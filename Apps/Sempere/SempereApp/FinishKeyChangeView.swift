import Sempere
import SwiftUI

/// The only screen of a vault whose last key change was interrupted
/// (format.md §3.3.1): its notes stay closed until the change is finished
/// (`AppModel+KeyChangeResume`).
struct FinishKeyChangeView: View {
    @AppModelEnvironment private var model

    var body: some View {
        NavigationStack {
            Form {
                if let resume = model.keyChangeResume {
                    content(resume)
                }
            }
            .navigationTitle(model.vaultName ?? String(localized: "Vault", comment: "Name shown for a vault that has none"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close Vault") { model.close() }
                        .disabled(model.keyChangeResume?.isRunning ?? false)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func content(_ resume: KeyChangeResume) -> some View {
        Section {
            Text("A change of this vault's keys was interrupted. Finish it to open your notes.")
        }
        Section {
            switch resume.step {
            case .ready:
                EmptyView()
            case .running(let text):
                HStack {
                    ProgressView()
                    Text(text)
                }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red)
            }
            Button(buttonTitle(resume)) { start() }
                .disabled(resume.isRunning)
        }
    }

    private func buttonTitle(_ resume: KeyChangeResume) -> String {
        if case .failed = resume.step { return String(localized: "Try Again", comment: "Button: try again after a failure") }
        return String(localized: "Finish", comment: "Button: finish an interrupted change of the vault's keys")
    }

    private func start() {
        // A failure is shown on this screen (`step`); starting again resumes.
        Task { try? await model.finishKeyChange() }
    }
}
