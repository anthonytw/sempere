import AppIntents

/// Siri and Shortcuts phrases for quick voice notes (docs/quick-capture.md
/// "Siri phrases"). The same intents back the widgets, the Control Center
/// control and the Action button.
///
/// Every phrase names the app (`.applicationName`): Apple requires it, and a
/// generic "record a voice note" goes to Apple's own app. Each English phrase
/// has one Spanish phrase in `AppShortcuts.xcstrings` (`LocalizationCatalogTests`
/// checks both), so the Spanish variants (imperative, infinitive, "en"/"con"
/// Sempere, "dictar") each come with an English phrase of their own. Start and
/// stop phrases never share a wording.
struct VoiceNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartVoiceNoteIntent(),
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
        AppShortcut(intent: StopVoiceNoteIntent(),
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
