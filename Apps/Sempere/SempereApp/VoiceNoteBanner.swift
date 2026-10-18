import SwiftUI

/// The in-app face of a quick voice note (docs/quick-capture.md "In the
/// app"): while one records, a red bar at the top of the window (and of the
/// sheets above it: unlock, Settings) with a pulsing dot, the elapsed time and
/// a large Stop; while it is sealed, "Saving"; then, for a few seconds, where
/// it went. Opening the app from the Live Activity (`sempere://quick-voice/recording`)
/// lands here: the bar is shown whenever there is something to say, and the
/// link makes it pulse once so it is seen.
struct VoiceNoteBanner: View {
    @AppModelEnvironment private var model
    @State private var stopping = false
    @State private var emphasis = 0

    private var capture: QuickCapture { model.quickCapture }

    var body: some View {
        Group {
            if capture.state == .recording, let started = capture.timerStart() {
                recording(started: started, paused: capture.isPaused)
            } else if capture.state == .saving {
                bar(tint: .orange) {
                    ProgressView().tint(.white)
                    Text("Saving voice note…").font(.headline)
                    Spacer(minLength: 0)
                }
            } else if let notice = capture.notice {
                bar(tint: notice.result == .failed ? .orange : .green) {
                    Image(systemName: notice.result.symbol).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title ?? notice.result.title).font(.headline)
                        Text(notice.error ?? notice.result.detail).font(.footnote).opacity(0.9)
                    }
                    Spacer(minLength: 0)
                    Button { capture.dismissNotice() } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold))
                    }
                    .accessibilityLabel("Dismiss")
                    .help("Dismiss this message")
                }
            }
        }
        .animation(.snappy, value: capture.state)
        .animation(.snappy, value: capture.notice)
        .scaleEffect(emphasis % 2 == 1 ? 1.03 : 1)
        .animation(.spring(duration: 0.25), value: emphasis)
        .onChange(of: capture.pendingLink, initial: true) { _, link in
            guard link == .recording else { return }
            capture.pendingLink = nil
            Task {
                // One pulse: "this is the recording you tapped".
                emphasis += 1
                try? await Task.sleep(for: .milliseconds(250))
                emphasis += 1
            }
        }
    }

    /// `started`: when the timer stood at zero (`QuickCapture.timerStart`); paused, it stands still.
    private func recording(started: Date, paused: Bool) -> some View {
        bar(tint: .red) {
            if paused {
                Image(systemName: "pause.circle.fill").font(.title3).accessibilityHidden(true)
            } else {
                PulsingDot()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(paused ? "Voice note paused" : "Recording voice note").font(.subheadline.weight(.semibold))
                Group {
                    if paused {
                        let seconds = max(0, Int(capture.audioLength()))
                        Text(Duration.seconds(seconds), format: .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
                    } else {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    }
                }
                .font(.title2.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 8)
            Button {
                stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
            .disabled(stopping)
            .accessibilityLabel("Stop and save the voice note")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNoteRecordingBanner")
    }

    private func bar<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func stop() {
        stopping = true
        Task {
            defer { stopping = false }
            do {
                _ = try await capture.stop()
            } catch {
                // Already stopped (the Live Activity's Stop got there first), or the
                // seal failed: `finish` put that in `notice`, which this bar shows.
            }
        }
    }
}

/// The record dot, pulsing.
private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

extension View {
    /// Shows `VoiceNoteBanner` above this view's content while a voice note
    /// records, saves or has just been saved (`VoiceNoteBannerRule`).
    func voiceNoteBanner() -> some View {
        modifier(VoiceNoteBannerPlacement())
    }
}

/// Inserts the banner only while it has something to show, so a window
/// without a voice note has no inset at all.
private struct VoiceNoteBannerPlacement: ViewModifier {
    @AppModelEnvironment private var model

    private var shows: Bool {
        let capture = model.quickCapture
        return VoiceNoteBannerRule.shows(state: capture.state, hasNotice: capture.notice != nil)
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if shows { VoiceNoteBanner() }
        }
    }
}

/// When a window shows `VoiceNoteBanner`: while a voice note records or saves, and while
/// its notice ("saved to …", a failure) is up. On a Mac too: File > Start Voice Note
/// (`VoiceNoteMenu`) records from the app, which has no Live Activity there, so the banner
/// is the only sign in the window that the microphone is on, and its Stop the nearest.
enum VoiceNoteBannerRule {
    static func shows(state: QuickCapture.State, hasNotice: Bool) -> Bool {
        state == .recording || state == .saving || hasNotice
    }
}
