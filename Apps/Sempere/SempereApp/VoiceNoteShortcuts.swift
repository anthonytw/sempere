import AppIntents

/// Siri and Shortcuts phrases for quick voice notes (docs/quick-capture.md).
/// The same intents back the widgets, the Control Center control and the
/// Action button.
struct VoiceNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartVoiceNoteIntent(),
                    phrases: ["Record a \(.applicationName) voice note",
                              "New \(.applicationName) voice note",
                              "Start a \(.applicationName) voice note"],
                    shortTitle: "Voice Note", systemImageName: "mic.fill")
        AppShortcut(intent: StopVoiceNoteIntent(),
                    phrases: ["Stop the \(.applicationName) voice note"],
                    shortTitle: "Stop Voice Note", systemImageName: "stop.fill")
    }
}
