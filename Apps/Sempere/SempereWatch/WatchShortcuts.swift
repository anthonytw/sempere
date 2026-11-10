import AppIntents

/// Siri and the Action button on the watch (docs/design/1.1-watch.md §3.5): the same phrases as the iPhone's shortcuts
/// (`VoiceNoteShortcuts`), whose catalog entries (`AppShortcuts.xcstrings`) serve both.
struct WatchVoiceNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordWatchVoiceNoteIntent(),
                    phrases: ["Record a \(.applicationName) voice note",
                              "New \(.applicationName) voice note",
                              "Start a \(.applicationName) voice note",
                              "\(.applicationName) voice note",
                              "Record in \(.applicationName)",
                              "Record with \(.applicationName)",
                              "Record voice in \(.applicationName)",
                              "Record a voice note in \(.applicationName)",
                              "Record a voice note with \(.applicationName)",
                              "Take a voice note in \(.applicationName)",
                              "Voice note in \(.applicationName)",
                              "Start recording in \(.applicationName)",
                              "Dictate in \(.applicationName)",
                              "Dictate a note in \(.applicationName)"],
                    shortTitle: "Voice Note", systemImageName: "mic.fill")
        AppShortcut(intent: StopWatchVoiceNoteIntent(),
                    phrases: ["Stop the \(.applicationName) voice note",
                              "Stop the voice note in \(.applicationName)",
                              "Stop recording in \(.applicationName)",
                              "Stop dictating in \(.applicationName)",
                              "Finish the \(.applicationName) voice note",
                              "End the \(.applicationName) voice note",
                              "Stop \(.applicationName) recording"],
                    shortTitle: "Stop Voice Note", systemImageName: "stop.fill")
    }
}
