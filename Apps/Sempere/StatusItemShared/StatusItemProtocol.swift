import Foundation

/// How the Mac menu-bar item (`SempereStatusItem`, an AppKit bundle) and the Catalyst app talk
/// (docs/mac.md "Menu-bar item"). Both live in one process, so they only post notifications on
/// `NotificationCenter.default` whose `userInfo` holds property-list values: neither can link the
/// other's types (the app is UIKit, the bundle AppKit). This file is compiled into both targets.
/// The app sends the state and the already localized titles, so the bundle has no strings;
/// the bundle sends back which entry was chosen.
enum StatusItemProtocol {
    /// App to bundle: the item's state (`State.userInfo`).
    static let updateName = Notification.Name("io.github.anthonytw.sempere.statusItem.update")
    /// Bundle to app: an entry was chosen (`userInfo["action"]`, an `Action` raw value).
    static let actionName = Notification.Name("io.github.anthonytw.sempere.statusItem.action")
    /// Bundle to app: the bundle is loaded and wants the current state.
    static let readyName = Notification.Name("io.github.anthonytw.sempere.statusItem.ready")
    /// App to bundle: bring the app to the front (a window is about to be shown).
    static let activateName = Notification.Name("io.github.anthonytw.sempere.statusItem.activate")

    /// The bundle's file name in the app's `PlugIns` folder.
    static let bundleName = "SempereStatusItem.bundle"

    /// The longest title taken from a notification (it is only ever the app's own, but whatever
    /// is posted on the default center is not trusted to be short).
    static let maxTitleLength = 80

    enum Action: String, CaseIterable, Sendable {
        /// Quick Voice Note: start, or stop while recording. Needs no window and no unlocked vault.
        case voiceNote
        /// New Note: bring the app forward and create a note (unlocking first).
        case newNote
        /// Open Sempere: bring the app forward.
        case openApp
    }

    static func userInfo(for action: Action) -> [String: Any] { ["action": action.rawValue] }

    /// The action in a posted `userInfo`, or nil for anything else.
    static func action(from userInfo: [AnyHashable: Any]?) -> Action? {
        (userInfo?["action"] as? String).flatMap(Action.init(rawValue:))
    }

    /// What the item shows.
    struct State: Equatable, Sendable {
        /// Whether the item is in the menu bar at all (Settings → Show in Menu Bar).
        var visible = false
        /// A voice note is being recorded: the item is tinted and its entry stops it.
        var recording = false
        /// A voice note is starting or being saved: its entry is off for the moment.
        var busy = false
        var voiceTitle = ""
        var newNoteTitle = ""
        var openTitle = ""
        var toolTip = ""

        init(visible: Bool = false, recording: Bool = false, busy: Bool = false, voiceTitle: String = "",
             newNoteTitle: String = "", openTitle: String = "", toolTip: String = "") {
            self.visible = visible
            self.recording = recording
            self.busy = busy
            self.voiceTitle = voiceTitle
            self.newNoteTitle = newNoteTitle
            self.openTitle = openTitle
            self.toolTip = toolTip
        }

        /// Reads a posted `userInfo`; a missing or mistyped value is the default, a long title is cut.
        init(userInfo: [AnyHashable: Any]?) {
            func text(_ key: String) -> String {
                String(((userInfo?[key] as? String) ?? "").prefix(StatusItemProtocol.maxTitleLength))
            }
            self.init(visible: userInfo?["visible"] as? Bool ?? false, recording: userInfo?["recording"] as? Bool ?? false,
                      busy: userInfo?["busy"] as? Bool ?? false, voiceTitle: text("voiceTitle"),
                      newNoteTitle: text("newNoteTitle"), openTitle: text("openTitle"), toolTip: text("toolTip"))
        }

        var userInfo: [String: Any] {
            ["visible": visible, "recording": recording, "busy": busy, "voiceTitle": voiceTitle,
             "newNoteTitle": newNoteTitle, "openTitle": openTitle, "toolTip": toolTip]
        }
    }
}
