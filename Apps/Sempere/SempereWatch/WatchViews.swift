import SempereCapture
import SwiftUI

// The one screen (docs/design/1.1-watch.md §3.7): Not set up, Ready (a large Record), Recording (the time, a large Stop, a
// red dot), Saved (two seconds), Unsent notes: N (with "Send now"), Can't record (the reason). No lists, no settings but
// Reset. Every state has an accessibility identifier for the simulator UI tests.

struct WatchContentView: View {
    @Bindable var model: WatchModel
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                switch model.screen {
                case .notSetUp: notSetUp
                case .ready: ready
                case .recording: recording
                case .saving: saving
                case .saved(let note): saved(note)
                case .cannotRecord(let why): cannotRecord(why)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .containerBackground(.black.gradient, for: .navigation)
        .confirmationDialog("Reset Quick Voice Notes?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This watch forgets the vault. Saved notes are still sent.")
        }
    }

    // MARK: States

    private var notSetUp: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward").font(.title2).accessibilityHidden(true)
            Text("Set up Quick Voice Notes in Sempere on your iPhone")
                .font(.footnote).multilineTextAlignment(.center)
                .accessibilityIdentifier("watch.notSetUp")
            unsentLine
            resetButton
        }
    }

    private var ready: some View {
        VStack(spacing: 8) {
            Button { Task { await model.record() } } label: {
                Label("Record", systemImage: "mic.fill").font(.headline).frame(maxWidth: .infinity)
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("watch.record")
            if let name = model.vaultName {
                Text("Saving to \(name)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("watch.vault")
            }
            unsentLine
            resetButton
        }
    }

    private var recording: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10).accessibilityHidden(true)
                if model.paused {
                    Text(Duration.seconds(Int(model.elapsed)), format: .time(pattern: .minuteSecond)).monospacedDigit()
                } else if let start = model.timerStart {
                    Text(start, style: .timer).monospacedDigit()
                } else {
                    Text(Duration.seconds(Int(model.elapsed)), format: .time(pattern: .minuteSecond)).monospacedDigit()
                }
            }
            .font(.title3)
            .accessibilityIdentifier("watch.elapsed")
            Button { Task { await model.stop() } } label: {
                Label("Stop", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("watch.stop")
        }
    }

    private var saving: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Encrypting…").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("watch.saving")
        }
    }

    private func saved(_ note: WatchSavedNote) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green).accessibilityHidden(true)
            Text("Saved").font(.headline).accessibilityIdentifier("watch.saved")
            if note.recovered {
                Text("Interrupted voice note saved").font(.footnote).multilineTextAlignment(.center)
                    .accessibilityIdentifier("watch.recovered")
            } else if note.reachedLimit {
                Text("This note reached the 60 minute limit.").font(.footnote).multilineTextAlignment(.center)
                    .accessibilityIdentifier("watch.limit")
            }
            unsentLine
        }
    }

    private func cannotRecord(_ why: WatchCannotRecord) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Can't record").font(.headline).accessibilityIdentifier("watch.cannotRecord")
            Text(why.text).font(.footnote).multilineTextAlignment(.center).accessibilityIdentifier("watch.reason")
            Button("OK") { model.dismissProblem() }.accessibilityIdentifier("watch.dismiss")
        }
    }

    // MARK: Pieces

    /// "Unsent notes: N", with "Send now" that retries.
    @ViewBuilder private var unsentLine: some View {
        if model.unsent > 0 {
            VStack(spacing: 4) {
                Text("Unsent notes: \(model.unsent)").font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("watch.unsent")
                Button("Send now") { model.sendNow() }.font(.footnote).accessibilityIdentifier("watch.sendNow")
            }
        }
    }

    private var resetButton: some View {
        Button("Reset") { confirmReset = true }
            .font(.footnote).buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.top, 6)
            .accessibilityIdentifier("watch.reset")
    }
}

extension WatchCannotRecord {
    /// The reason, in words.
    var text: String {
        switch self {
        case .microphoneDenied: return String(localized: "Allow the microphone for Sempere in Settings ▸ Privacy & Security ▸ Microphone on your watch.", comment: "Watch: why it cannot record")
        case .outboxFull: return String(localized: "Open Sempere on your iPhone to send saved notes.")
        case .lowStorage: return String(localized: "This watch is almost out of storage.")
        case .failed(let why): return String(localized: "The watch could not record: \(why)", comment: "Watch: why it cannot record; the system's text follows")
        }
    }
}
