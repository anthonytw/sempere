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

/// One entry; the app reloads the timeline when the status changes and each
/// time it launches or becomes active, and the system refreshes it every half
/// hour as a backstop (a missed reload, a status written while the widget was not loaded). Reads only the small status file (no Keychain,
/// no vault, no asset catalog).
struct VoiceNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceNoteEntry { VoiceNoteEntry(date: Date(), status: .unknown) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceNoteEntry) -> Void) {
        completion(VoiceNoteEntry(date: Date(), status: context.isPreview ? .unknown : .current()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceNoteEntry>) -> Void) {
        completion(Timeline(entries: [VoiceNoteEntry(date: Date(), status: .current())], policy: .after(Date().addingTimeInterval(VoiceNoteStatus.refreshInterval))))
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
            // A tap that does not reach the button (or that iOS turns into opening the app) opens
            // the app with this link: the app keeps it in Recent Starts and does what the button
            // would have done. Without it such a tap opened the app with nothing at all.
            .widgetURL(VoiceNoteLink.widgetTapURL)
            // The placeholder (shown before the device's first unlock, when nothing can
            // run or be read yet) is redacted by default: gray boxes instead of the mic.
            .unredacted()
            .containerBackground(.fill.tertiary, for: .widget)
            .accessibilityLabel(status.title)
    }

    @ViewBuilder private var content: some View {
        // One intent for every phase, as the control (never `widgetURL`, which only opens
        // the app): the app decides when tapped, from its live state, whether to record,
        // stop or continue in the app, so a stale status cannot make a tap do nothing.
        //
        // The button fills the whole widget and every point of it takes the tap. A `.plain`
        // button is hit only where its label draws: on the rectangular Lock Screen widget that was
        // the glyph and the two lines of text, and a tap anywhere else in the widget fell through
        // to the widget's default action, opening the app without running the intent (TestFlight
        // 1.0.0 (6): "opens the app, records nothing", no Recent Starts entry).
        //
        // The circular Lock Screen widget (iPhone, build 6, unlocked): every tap logged "Launching with no
        // widgetURL" in WidgetRenderer and no intent ran, while the rectangular one ran it. Its label was
        // `AccessoryWidgetBackground()` under a small glyph: the system background is not the button's
        // hit area, so only the glyph was. Now the background sits behind the button, outside it, and the
        // button's label is a clear square filling the widget with the glyph on it, all of it hit-testable.
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Button(intent: status.tapIntent) {
                    ZStack {
                        Color.clear
                        Image(systemName: status.symbol).font(.title2).widgetAccentable()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            Button(intent: status.tapIntent) {
                label
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var label: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: status.symbol).font(.title2).widgetAccentable()
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

    /// The timer while recording (standing still while paused, as on the
    /// Live Activity), else the subtitle.
    @ViewBuilder private var secondLine: some View {
        if status.timerRuns, let started = status.started {
            Text(started, style: .timer).monospacedDigit()
        } else if status.phase == .recording, let started = status.started, let paused = status.paused {
            let seconds = max(0, Int(paused.timeIntervalSince(started)))
            Text(Duration.seconds(seconds), format: .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
                .monospacedDigit()
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
            VoiceNoteActivityView(state: context.state, interrupted: context.isStale && context.state.isRecording)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(VoiceNoteLink.recording.url)
        } dynamicIsland: { context in
            let state = context.state
            // The app stopped refreshing it while recording: it was force quit or crashed (`keepActivityFresh`).
            let interrupted = context.isStale && state.isRecording
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if interrupted {
                        Label("Interrupted", systemImage: "exclamationmark.triangle.fill").font(.headline)
                    } else if let result = state.result {
                        Label(result.title, systemImage: result.symbol).font(.headline)
                    } else {
                        HStack(spacing: 6) {
                            RecordDot(state: state)
                            Text(state.paused && state.isRecording ? "Paused" : state.isRecording ? "Recording" : "Saving…").font(.headline)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: state).font(.title2.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if interrupted {
                        Text("Open Sempere to save the voice note.").font(.footnote).foregroundStyle(.secondary)
                    } else if state.isRecording {
                        StopButton()
                    } else if let result = state.result {
                        Text(result.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                if let result = state.result {
                    Image(systemName: result.symbol).foregroundStyle(result == .failed ? Color.orange : Color.green)
                } else {
                    RecordDot(state: state)
                }
            } compactTrailing: {
                ElapsedTime(state: state).frame(maxWidth: 52)
            } minimal: {
                if let result = state.result {
                    Image(systemName: result.symbol).foregroundStyle(result == .failed ? Color.orange : Color.green)
                } else {
                    RecordDot(state: state)
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
    /// Stale while recording: the app was force quit or crashed, so Stop would reach nothing. A tap
    /// opens the app, which ends this activity and saves what was recorded.
    var interrupted = false

    var body: some View {
        if interrupted {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice note interrupted").font(.headline).foregroundStyle(.white)
                    Text("Open Sempere to save it.").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
        } else if let result = state.result {
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
                        RecordDot(state: state)
                        Text(state.paused && state.isRecording ? "Voice note paused"
                             : state.isRecording ? "Recording voice note" : "Saving voice note…")
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

/// A red dot that pulses while recording (still while paused, gray while saving).
struct RecordDot: View {
    let state: VoiceNoteAttributes.ContentState

    var body: some View {
        Image(systemName: "record.circle.fill")
            .foregroundStyle(state.isRecording ? Color.red : Color.secondary)
            .symbolEffect(.pulse, options: .repeating, isActive: state.timerRuns)
            .accessibilityLabel(state.timerRuns ? "Recording" : state.isRecording ? "Paused" : "Saving")
    }
}

/// Running while recording; the length so far while paused, the final length once stopped.
struct ElapsedTime: View {
    let state: VoiceNoteAttributes.ContentState

    var body: some View {
        if state.timerRuns {
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
