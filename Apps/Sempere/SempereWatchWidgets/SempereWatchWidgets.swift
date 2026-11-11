import AppIntents
import SempereCaptureShared
import SwiftUI
import WidgetKit

/// The watch's surfaces (docs/design/1.1-watch.md §3.5): a complication (accessory families), a Smart Stack widget and a
/// Control. Every one lands in the watch app and records there: the widgets open `sempere-watch://record`, the Control runs
/// `RecordWatchVoiceNoteIntent`, which opens the app. They read only `VoiceNoteStatus`, which the watch app writes into the
/// watch's App Group (`notSetUp`, `ready`, `recording`, `saving`); nothing here reads a note, a key or the outbox.
@main
struct SempereWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchVoiceNoteWidget()
        #if !targetEnvironment(simulator)
        // The watchOS Simulator has no Shortcuts services behind a Control's intent (linkd, VoiceShortcuts): the extension
        // process dies at "Can't create CHSIntentReference from RecordWatchVoiceNoteIntent" as soon as the system renders the
        // control, which fails every UI test of the app ("Critical process … crashed"). The control is built for every device
        // (`scripts/app.sh build-watch` compiles the device SDK too) and checked on a real watch (docs/design/1.1-watch.md, W2).
        WatchVoiceNoteControl()
        #endif
    }
}

extension VoiceNoteStatus {
    /// The stored status, or `unknown` (before the first unlock, among others).
    static func current() -> VoiceNoteStatus { VoiceNoteStatusStore.shared?.read() ?? .unknown }
}

struct WatchVoiceNoteEntry: TimelineEntry {
    let date: Date
    let status: VoiceNoteStatus
}

/// One entry; the app reloads the timeline when the status changes, and the system refreshes it every half hour as a backstop.
struct WatchVoiceNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchVoiceNoteEntry { WatchVoiceNoteEntry(date: Date(), status: .unknown) }
    func getSnapshot(in context: Context, completion: @escaping (WatchVoiceNoteEntry) -> Void) {
        completion(WatchVoiceNoteEntry(date: Date(), status: context.isPreview ? .unknown : .current()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchVoiceNoteEntry>) -> Void) {
        completion(Timeline(entries: [WatchVoiceNoteEntry(date: Date(), status: .current())],
                            policy: .after(Date().addingTimeInterval(VoiceNoteStatus.refreshInterval))))
    }
}

/// The complication and the Smart Stack widget: the accessory families (the rectangular one is the Smart Stack's).
struct WatchVoiceNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: VoiceNoteStatus.widgetKind, provider: WatchVoiceNoteProvider()) { entry in
            WatchVoiceNoteView(status: entry.status)
        }
        .configurationDisplayName("Voice Note")
        .description("Record a voice note on your watch. It is encrypted on the watch and sent to your iPhone's vault inbox.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct WatchVoiceNoteView: View {
    @Environment(\.widgetFamily) private var family
    let status: VoiceNoteStatus

    var body: some View {
        content
            // Every tap opens the app at the recording, which starts it (from a surface).
            .widgetURL(WatchLink.record)
            .unredacted()
            .containerBackground(.fill.tertiary, for: .widget)
            .accessibilityLabel(status.watchTitle)
    }

    /// The status's glyph: the nib (a custom symbol of this extension's catalog, `SempereNib.symbolset`) when ready, a
    /// system symbol otherwise.
    private var glyph: Image {
        switch status.glyph {
        case .custom(let name): Image(name)
        case .system(let name): Image(systemName: name)
        }
    }

    /// The glyph scaled to fit its slot, whatever the watch's size: at a fixed font the nib (about 0.7 of the font
    /// size tall) overflowed the corner slot and was cropped (TestFlight 1.1.0 (67)).
    private func fittedGlyph(padding: CGFloat) -> some View {
        glyph.resizable().scaledToFit().padding(padding).widgetAccentable()
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                fittedGlyph(padding: 9)
            }
        case .accessoryCorner:
            // The icon alone: no curved label beside it (owner, build 67).
            fittedGlyph(padding: 2)
        case .accessoryInline:
            Label { Text(status.watchTitle) } icon: { glyph }
        default:
            HStack(spacing: 6) {
                glyph.font(.title3).widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.watchTitle).font(.headline).lineLimit(1)
                    secondLine.font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The timer while recording, else the subtitle.
    @ViewBuilder private var secondLine: some View {
        if status.timerRuns, let started = status.started {
            Text(started, style: .timer).monospacedDigit()
        } else {
            Text(status.watchSubtitle)
        }
    }
}

/// The Control's value: the stored status.
struct WatchVoiceNoteControlProvider: ControlValueProvider {
    var previewValue: VoiceNoteStatus { .unknown }
    func currentValue() async throws -> VoiceNoteStatus { .current() }
}

/// A button that opens the watch app and records (a second press, in the app, stops).
struct WatchVoiceNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VoiceNoteStatus.controlKind, provider: WatchVoiceNoteControlProvider()) { status in
            ControlWidgetButton(action: RecordWatchVoiceNoteIntent()) {
                switch status.glyph {
                case .custom(let name): Label(status.watchTitle, image: name)
                case .system(let name): Label(status.watchTitle, systemImage: name)
                }
                Text(status.watchSubtitle)
            }
        }
        .displayName("Sempere Voice Note")
        .description("Record a voice note on your watch; tap again in the app to stop.")
    }
}
