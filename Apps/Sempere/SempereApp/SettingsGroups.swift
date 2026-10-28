import SwiftUI

/// The groups of the Settings panel, each a page (`SettingsGroupPage`): a list
/// to drill into on iPad and iPhone, the sidebar of the Settings window on the Mac.
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Appearance, App Language, App Icon, Keep Screen On, Show in Menu Bar (Drag to Finder is hidden in v1).
    case general
    /// Editor, New Notes, Handwriting Recognition, Math, Photos.
    case writing
    /// Recording, Transcription, Quick Voice Notes, transcript search.
    case audio
    /// Sync Settings, Device Keys.
    case sync
    /// Backups, Version History (and Thin Now), Storage.
    case backups
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .writing: return String(localized: "Writing", comment: "Settings group: editor, new notes, recognition, photos")
        case .audio: return String(localized: "Audio & Transcription", comment: "Settings group")
        case .sync: return String(localized: "Sync & Devices", comment: "Settings group: settings sync and device keys")
        case .backups: return String(localized: "Backups & History", comment: "Settings group: backups, version history, storage")
        case .about: return String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .writing: return "pencil.tip"
        case .audio: return "waveform"
        case .sync: return "arrow.triangle.2.circlepath"
        case .backups: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    /// The group's row in the list (UI tests).
    var accessibilityID: String { "settingsGroup.\(rawValue)" }
    /// The group's page (UI tests).
    var pageAccessibilityID: String { "settingsPage.\(rawValue)" }

    /// Sections other screens open Settings at (`SettingsView(scrollTo:)`), by group.
    @MainActor static let anchors: [String: SettingsGroup] = [
        QuickCaptureSettingsSection.anchor: .audio,
    ]

    /// The group whose page holds the section `anchor`; nil for none or an unknown one.
    @MainActor static func containing(anchor: String?) -> SettingsGroup? {
        anchor.flatMap { anchors[$0] }
    }
}

// MARK: - Appearance

/// Settings ▸ General ▸ Appearance: the app's theme as three pictures, as the
/// system's own Appearance setting shows them, and how note pages are shown.
struct AppearanceSettingsSection: View {
    @AppStorage(AppTheme.key) private var theme = AppTheme.defaultValue
    @AppStorage(NotePagesAppearance.key) private var notePages = NotePagesAppearance.defaultValue

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AppTheme.allCases) { choice in
                    ThemeChoice(theme: choice, selected: choice == theme) { theme = choice }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            .syncedSetting("appearance.theme")
            // The name above the choices, which get the row's whole width (they are long in some languages).
            VStack(alignment: .leading, spacing: 8) {
                Text("Note Pages")
                // Segments while their names fit, else a menu (long translations).
                ViewThatFits(in: .horizontal) {
                    notePagesPicker.pickerStyle(.segmented).fixedSize()
                    notePagesPicker.pickerStyle(.menu)
                }
            }
            .syncedSetting("appearance.notePages")
        } header: {
            Text("Appearance")
        } footer: {
            Text("Dark note pages show the paper dark and ink, text and equations with their lightness inverted, keeping their colors; pictures, PDFs and videos are shown as they are. Notes are stored and exported as on light paper.")
        }
    }

    private var notePagesPicker: some View {
        Picker("Note Pages", selection: $notePages) {
            ForEach(NotePagesAppearance.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .accessibilityIdentifier("notePages")
    }
}

/// One theme as a small picture of a window, its name and a checkmark.
private struct ThemeChoice: View {
    let theme: AppTheme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                preview
                    .frame(width: 64, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                                          lineWidth: selected ? 3 : 1)
                    }
                Text(theme.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("appTheme.\(theme.rawValue)")
        .help(theme.title)
    }

    @ViewBuilder private var preview: some View {
        switch theme {
        case .light: ThemePreview(dark: false)
        case .dark: ThemePreview(dark: true)
        case .system:
            // Light on the left, dark on the right, as the system draws "Automatic".
            ZStack {
                ThemePreview(dark: false)
                ThemePreview(dark: true).mask(alignment: .trailing) {
                    Rectangle().frame(width: 32)
                }
            }
        }
    }
}

/// A sketch of a screen in one style: a bar and a few lines of text.
private struct ThemePreview: View {
    let dark: Bool

    var body: some View {
        let background = dark ? Color(white: 0.11) : Color(white: 0.98)
        let bar = dark ? Color(white: 0.22) : Color(white: 0.88)
        let ink = dark ? Color(white: 0.85) : Color(white: 0.2)
        ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 6) {
                bar.frame(height: 14)
                ForEach([44.0, 36, 40, 26], id: \.self) { width in
                    Capsule().fill(ink.opacity(0.75)).frame(width: width, height: 4).padding(.leading, 8)
                }
            }
        }
    }
}

// MARK: - Drag to Finder (hidden in v1)

/// Settings ▸ General ▸ Drag to Finder (Mac): the file a note dragged out of the
/// note list becomes (`DragExportFormat`, `NoteFileDrag`).
///
/// Hidden in v1: the Finder never accepts the drop (docs/mac.md "Debugging a drag
/// out"), so nothing may promise a file. The setting and its sync (`drag.format`)
/// stay. To restore: set `DragExportFormat.showsInSettings` to true, give the
/// literals below `String(localized:)` again and re-add their catalog entries
/// (English keys, Spanish translations) in Localizable.xcstrings.
struct DragToFinderSettingsSection: View {
    @AppStorage(DragExportFormat.key) private var format = DragExportFormat.defaultValue

    var body: some View {
        if Platform.isMac && DragExportFormat.showsInSettings {
            Section {
                Picker(selection: $format) {   // l10n:ignore (hidden in v1)
                    ForEach(DragExportFormat.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text(verbatim: "Exports As")   // l10n:ignore
                }
                .accessibilityIdentifier("dragFormat")
                .syncedSetting("drag.format")
            } header: {
                Text(verbatim: "Drag to Finder")   // l10n:ignore
            } footer: {
                Text(verbatim: "A note dragged from the note list to the Finder or another app becomes a file in this format, made from the note as it is now. The file is not encrypted.")   // l10n:ignore
            }
        }
    }
}
