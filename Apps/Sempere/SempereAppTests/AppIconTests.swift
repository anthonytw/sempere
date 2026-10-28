import Foundation
import UIKit
import Testing
@testable import SempereApp

/// Every alternate app icon the Settings picker can set must exist: as an app-icon set in
/// the asset catalog and in the target's alternate-icon build setting (otherwise
/// `setAlternateIconName` fails at run time with no hint at build time).
struct AppIconTests {
    private var appDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func everyAlternateNameHasAnIconSet() throws {
        let catalog = appDir.appendingPathComponent("SempereApp/Assets.xcassets")
        for name in AppIconChoice.alternateNames {
            let set = catalog.appendingPathComponent("\(name).appiconset")
            let contents = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
            let json = try #require(try JSONSerialization.jsonObject(with: contents) as? [String: Any])
            let images = try #require(json["images"] as? [[String: Any]])
            for image in images {
                let file = try #require(image["filename"] as? String)
                #expect(FileManager.default.fileExists(atPath: set.appendingPathComponent(file).path), "\(name): \(file)")
            }
        }
        #expect(FileManager.default.fileExists(atPath: catalog.appendingPathComponent("AppIcon.appiconset").path))
    }

    @Test func everyAlternateNameIsInTheBuildSettings() throws {
        let project = try String(contentsOf: appDir.appendingPathComponent("Sempere.xcodeproj/project.pbxproj"), encoding: .utf8)
        let lines = project.split(separator: "\n").filter { $0.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES") }
        #expect(lines.count == 2, "Debug and Release of the app target")
        for line in lines {
            let listed = Set(line.split(whereSeparator: { " \";".contains($0) }).dropFirst(2).map(String.init))
            #expect(listed == Set(AppIconChoice.alternateNames))
        }
    }

    @Test func everyChoiceHasAPreviewImage() {
        for choice in AppIconChoice.allCases {
            #expect(UIImage(named: choice.previewName) != nil, "\(choice.previewName)")
        }
    }

    @Test func builtAppDeclaresTheAlternateIcons() throws {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        guard let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any] else { return } // Catalyst bundles carry none
        #expect(Set(alternates.keys) == Set(AppIconChoice.alternateNames))
    }

    /// The picker is hidden on a Mac (Catalyst, or the iPad app on a Mac) and wherever iOS
    /// offers no alternate icons; on this runner it follows the same rule.
    @MainActor @Test func pickerIsHiddenOnTheMacAndWithoutAlternateIcons() {
        #expect(!AppIconSettingsSection.isSupported(isMac: true, supportsAlternateIcons: true))
        #expect(!AppIconSettingsSection.isSupported(isMac: false, supportsAlternateIcons: false))
        #expect(AppIconSettingsSection.isSupported(isMac: false, supportsAlternateIcons: true))
        #expect(AppIconSettingsSection.isSupported == (!Platform.isMac && UIApplication.shared.supportsAlternateIcons))
        if Platform.isMac { #expect(!AppIconSettingsSection.isSupported) }
    }

    @Test func choiceFromReportedName() {
        #expect(AppIconChoice(alternateName: nil) == .keyholeNib)
        #expect(AppIconChoice(alternateName: "InkWind") == .inkWind)
        #expect(AppIconChoice(alternateName: "Gone") == .keyholeNib)
    }
}
