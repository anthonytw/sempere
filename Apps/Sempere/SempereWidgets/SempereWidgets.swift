import AppIntents
import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Quick voice notes from outside the app (docs/quick-capture.md): a Lock
/// Screen and Home Screen widget, a Control Center control (also offered to
/// the Action button), and the Live Activity of a recording. Every button
/// runs `StartVoiceNoteIntent`, `StopVoiceNoteIntent` or
/// `VoiceNoteControlIntent` in the app's process; nothing here reads the vault.
/// What they show comes from `VoiceNoteStatus`, which the app writes into the
/// App Group container and reloads these after every change.
@main
struct SempereWidgets: WidgetBundle {
    var body: some Widget {
        VoiceNoteWidget()
        VoiceNoteControl()
        VoiceNoteLiveActivity()
    }
}

extension VoiceNoteStatus {
    /// The stored status, or `unknown` (before the first unlock, among others).
    static func current() -> VoiceNoteStatus { VoiceNoteStatusStore.shared?.read() ?? .unknown }
}

struct VoiceNoteEntry: TimelineEntry {
    let date: Date
    let status: VoiceNoteStatus
}

/// One entry, never refreshed on a schedule: the app reloads the timeline
/// when the status changes. Reads only the small status file (no Keychain,
/// no vault, no asset catalog).
struct VoiceNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceNoteEntry { VoiceNoteEntry(date: Date(), status: .unknown) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceNoteEntry) -> Void) {
        completion(VoiceNoteEntry(date: Date(), status: context.isPreview ? .unknown : .current()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceNoteEntry>) -> Void) {
        completion(Timeline(entries: [VoiceNoteEntry(date: Date(), status: .current())], policy: .never))
    }
}

/// One button: record a voice note, stop it, or open the setup.
struct VoiceNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: VoiceNoteStatus.widgetKind, provider: VoiceNoteProvider()) { entry in
            VoiceNoteWidgetView(status: entry.status)
        }
        .configurationDisplayName("Voice Note")
        .description("Record a voice note into your vault's inbox, encrypted, without unlocking it. Tap again to stop.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let status: VoiceNoteStatus

    var body: some View {
        content
            // The placeholder (shown before the device's first unlock, when nothing can
            // run or be read yet) is redacted by default: grey boxes instead of the mic.
            .unredacted()
            .containerBackground(.fill.tertiary, for: .widget)
            .accessibilityLabel(status.title)
    }

    @ViewBuilder private var content: some View {
        switch status.action {
        case .start:
            Button(intent: StartVoiceNoteIntent()) { label }.buttonStyle(.plain)
        case .stop:
            Button(intent: StopVoiceNoteIntent()) { label }.buttonStyle(.plain)
        case .open(let link):
            label.widgetURL(link.url)
        }
    }

    @ViewBuilder private var label: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: status.symbol).font(.title2).widgetAccentable()
            }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: status.symbol).font(.title3).widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.title).font(.headline).lineLimit(1)
                    secondLine.font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 8) {
                Image(systemName: status.phase == .ready ? "mic.circle.fill" : status.symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(status.phase == .recording ? Color.red : Color.accentColor)
                Text(status.title).font(.headline).multilineTextAlignment(.center)
                secondLine.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    /// The timer while recording, else the subtitle.
    @ViewBuilder private var secondLine: some View {
        if status.phase == .recording, let started = status.started {
            Text(started, style: .timer).monospacedDigit()
        } else {
            Text(status.subtitle)
        }
    }
}

/// The control's value: the stored status.
struct VoiceNoteControlProvider: ControlValueProvider {
    var previewValue: VoiceNoteStatus { .unknown }
    func currentValue() async throws -> VoiceNoteStatus { .current() }
}

/// The Control Center control (iOS 18+), also offered to the Action button:
/// records when idle, stops while recording, and opens the setup when quick
/// voice notes are off (instead of doing nothing).
struct VoiceNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VoiceNoteStatus.controlKind, provider: VoiceNoteControlProvider()) { status in
            // One template: the action is decided when tapped (`VoiceNoteControlIntent`).
            ControlWidgetButton(action: VoiceNoteControlIntent(shown: status.phase)) {
                Label(status.title, systemImage: status.symbol)
                Text(status.subtitle)
            }
        }
        .displayName("Sempere Voice Note")
        .description("Record a voice note into your vault's inbox; tap again to stop.")
    }
}

/// While a voice note records: a pulsing record dot, the elapsed time and a
/// large Stop; then, for a few seconds, where the voice note went. A tap
/// anywhere else opens the app at the recording banner.
struct VoiceNoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceNoteAttributes.self) { context in
            VoiceNoteActivityView(state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(VoiceNoteLink.recording.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let result = state.result {
                        Label(result.title, systemImage: result.symbol).font(.headline)
                    } else {
                        HStack(spacing: 6) {
                            RecordDot(active: state.isRecording)
                            Text(state.isRecording ? "Recording" : "Saving…").font(.headline)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: state).font(.title2.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.isRecording {
                        StopButton()
                    } else if let result = state.result {
                        Text(result.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                if let result = state.result {
                    Image(systemName: result.symbol).foregroundStyle(result == .failed ? Color.orange : Color.green)
                } else {
                    RecordDot(active: state.isRecording)
                }
            } compactTrailing: {
                ElapsedTime(state: state).frame(maxWidth: 52)
            } minimal: {
                if let result = state.result {
                    Image(systemName: result.symbol).foregroundStyle(result == .failed ? Color.orange : Color.green)
                } else {
                    RecordDot(active: state.isRecording)
                }
            }
            .widgetURL(VoiceNoteLink.recording.url)
            .keylineTint(.red)
        }
    }
}

/// The Lock Screen (and banner) presentation of the Live Activity.
struct VoiceNoteActivityView: View {
    let state: VoiceNoteAttributes.ContentState

    var body: some View {
        if let result = state.result {
            HStack(spacing: 12) {
                Image(systemName: result.symbol).font(.largeTitle)
                    .foregroundStyle(result == .failed ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.headline).foregroundStyle(.white)
                    Text(result.detail).font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        RecordDot(active: state.isRecording)
                        Text(state.isRecording ? "Recording voice note" : "Saving voice note…")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    }
                    ElapsedTime(state: state).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                if state.isRecording { StopButton() }
            }
        }
    }
}

/// A red dot that pulses while recording.
struct RecordDot: View {
    let active: Bool

    var body: some View {
        Image(systemName: "record.circle.fill")
            .foregroundStyle(active ? Color.red : Color.secondary)
            .symbolEffect(.pulse, options: .repeating, isActive: active)
            .accessibilityLabel(active ? "Recording" : "Saving")
    }
}

/// Running while recording; the final length once stopped.
struct ElapsedTime: View {
    let state: VoiceNoteAttributes.ContentState

    var body: some View {
        if state.isRecording {
            Text(timerInterval: state.started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            let seconds = max(0, Int((state.ended ?? state.started).timeIntervalSince(state.started)))
            Text(Duration.seconds(seconds), format: .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The large Stop: ends the recording and saves it to the inbox.
struct StopButton: View {
    var body: some View {
        Button(intent: StopVoiceNoteIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .frame(maxWidth: 140)
        .accessibilityLabel("Stop and save the voice note")
    }
}
