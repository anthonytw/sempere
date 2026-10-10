import SwiftUI
import UIKit

/// The home-screen icons the user can pick in Settings. The first is the
/// primary icon (`AppIcon`); the rest are alternate icon sets listed in the
/// target's `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. iOS remembers the
/// choice itself, per device, so nothing is stored in the vault or defaults.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case keyholeNib, cemeteryDoor, shadowS, inkWind

    var id: String { rawValue }

    /// The name `setAlternateIconName` takes (an asset-catalog app-icon set); nil for the primary icon.
    var alternateName: String? {
        switch self {
        case .keyholeNib: nil
        case .cemeteryDoor: "CemeteryDoor"
        case .shadowS: "ShadowS"
        case .inkWind: "InkWind"
        }
    }

    /// The alternate names the code uses, for the test that checks they exist.
    static var alternateNames: [String] { allCases.compactMap(\.alternateName) }

    var title: LocalizedStringKey {
        switch self {
        case .keyholeNib: "Keyhole Nib"
        case .cemeteryDoor: "Cemetery Door"
        case .shadowS: "Shadow S"
        case .inkWind: "Ink Wind"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .keyholeNib: "The key to every page."
        case .cemeteryDoor: "For the notes that choose you."
        case .shadowS: "Written on the wind."
        case .inkWind: "Every story leaves a trail."
        }
    }

    /// A small image set of the icon (an app-icon set cannot be loaded as an image).
    var previewName: String {
        switch self {
        case .keyholeNib: "IconPreviewKeyholeNib"
        case .cemeteryDoor: "IconPreviewCemeteryDoor"
        case .shadowS: "IconPreviewShadowS"
        case .inkWind: "IconPreviewInkWind"
        }
    }

    /// The choice for the name iOS reports (`alternateIconName`); the primary icon when unknown.
    init(alternateName: String?) {
        self = Self.allCases.first { $0.alternateName == alternateName } ?? .keyholeNib
    }
}

/// Settings → App Icon: a grid of the icons with the current one checked.
/// Hidden where iOS offers no alternate icons (Mac Catalyst, some contexts).
struct AppIconSettingsSection: View {
    @AppModelEnvironment private var model
    @State private var current = AppIconChoice(alternateName: UIApplication.shared.alternateIconName)
    @State private var failed = false

    /// Shown only where iOS can switch icons, and never on a Mac (the Mac app uses the
    /// default icon). `Platform.isMac`, not `#if targetEnvironment(macCatalyst)`: the
    /// simulator CI then compiles and tests the Mac path too (CLAUDE.md).
    static var isSupported: Bool {
        isSupported(isMac: Platform.isMac, supportsAlternateIcons: UIApplication.shared.supportsAlternateIcons)
    }

    static func isSupported(isMac: Bool, supportsAlternateIcons: Bool) -> Bool {
        !isMac && supportsAlternateIcons
    }

    var body: some View {
        if Self.isSupported {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button { select(choice) } label: { tile(choice) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(choice == current ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
                .syncedSetting("appearance.icon")
            } header: {
                Text("App Icon")
            }
            .alert("Couldn’t change the icon.", isPresented: $failed) {}
        }
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        VStack(spacing: 6) {
            Image(choice.previewName)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(choice == current ? Color.accentColor : Color.secondary.opacity(0.25),
                                      lineWidth: choice == current ? 3 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if choice == current {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title3)
                            .offset(x: 6, y: 6)
                    }
                }
            Text(choice.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            Text(choice.caption).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func select(_ choice: AppIconChoice) {
        guard choice != current else { return }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            Task { @MainActor in
                if error == nil { current = choice; model.settingsChanged() } else { failed = true }
            }
        }
    }
}
