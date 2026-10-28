import Foundation

/// File > Start Voice Note / Stop Voice Note on a Mac (docs/quick-capture.md
/// "Surfaces"): the same recorder as Siri, Shortcuts and the widgets
/// (`QuickCapture.start()` / `stop()`), so a voice note is sealed into the
/// vault's inbox without the vault being unlocked. The decisions are plain
/// values so tests can pin them.
enum VoiceNoteMenu {
    /// What choosing the menu item does.
    enum Action: Equatable, Sendable {
        /// Quick voice notes are not set up: show Settings ▸ Quick Voice Notes.
        case openSetup
        case start
        case stop
        /// Starting or saving: nothing (the item is disabled then).
        case none
    }

    /// The recorder's state as the menu sees it.
    static func phase(_ state: QuickCapture.State) -> MenuCommand.Context.VoiceNote {
        switch state {
        case .idle: return .idle
        case .recording: return .recording
        case .starting, .saving: return .busy
        }
    }

    /// The Mac menu opens the Settings window itself (`AppCommands`) rather than the
    /// model's `pendingLink`, which only the library window answers (with a sheet).
    static func opensSettingsWindow(setUp: Bool, state: QuickCapture.State) -> Bool {
        action(setUp: setUp, state: state) == .openSetup
    }

    /// What the menu item does for a recorder in `state`, set up or not.
    static func action(setUp: Bool, state: QuickCapture.State) -> Action {
        switch state {
        case .recording: return .stop
        case .starting, .saving: return .none
        case .idle: return setUp ? .start : .openSetup
        }
    }
}

extension AppModel {
    /// File > Start Voice Note / Stop Voice Note. A failure (no microphone
    /// permission, a missing profile) is shown as any other error.
    func toggleVoiceNote() async {
        let capture = quickCapture
        switch VoiceNoteMenu.action(setUp: capture.isSetUp, state: capture.state) {
        case .openSetup:
            capture.pendingLink = .settings
        case .start:
            await report { try await capture.start() }
        case .stop:
            await report { _ = try await capture.stop() }
        case .none:
            break
        }
    }
}
