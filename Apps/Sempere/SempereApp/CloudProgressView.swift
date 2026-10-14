import SwiftUI

/// "Downloading from iCloud… n/m files", with a way out.
struct CloudProgressView: View {
    let progress: CloudProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.fractionCompleted)
                .frame(width: 240)
            Text(progress.description)
                .font(.callout)
                .monospacedDigit()
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
