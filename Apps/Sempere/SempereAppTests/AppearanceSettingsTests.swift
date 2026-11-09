import CoreGraphics
import Foundation
import Sempere
import SempereAppCore
import SempereRender
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SempereApp

/// Settings in groups, the app theme, Note Pages and the drag format (Settings ▸ General).
@MainActor
@Suite(.serialized)
struct AppearanceSettingsTests {
    func scratch() -> UserDefaults {
        let name = "sempere-appearance-tests"
        let d = TestDefaults.suite(name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Groups

    @Test func theGroupsAreTheApprovedOnesInOrder() {
        #expect(SettingsGroup.allCases == [.general, .writing, .audio, .sync, .backups, .about])
        for group in SettingsGroup.allCases {
            #expect(!group.title.isEmpty)
            #expect(UIImage(systemName: group.systemImage) != nil, "\(group.systemImage) is a symbol")
        }
        #expect(Set(SettingsGroup.allCases.map(\.accessibilityID)).count == SettingsGroup.allCases.count)
    }

    /// "Open Settings at Quick Voice Notes" (`sempere://quick-voice/settings`) opens the group that holds it.
    @Test func aDeepLinkOpensTheGroupOfItsSection() {
        #expect(SettingsGroup.containing(anchor: QuickCaptureSettingsSection.anchor) == .audio)
        #expect(SettingsGroup.containing(anchor: nil) == nil)
        #expect(SettingsGroup.containing(anchor: "nowhere") == nil)
    }

    // MARK: - Theme and Note Pages

    @Test func theThemeMapsToTheWindowStyle() {
        #expect(AppTheme.system.userInterfaceStyle == .unspecified)
        #expect(AppTheme.light.userInterfaceStyle == .light)
        #expect(AppTheme.dark.userInterfaceStyle == .dark)
        #expect(!AppTheme.allCases.contains { $0.title.isEmpty } && !NotePagesAppearance.allCases.contains { $0.title.isEmpty })
    }

    /// Every new setting syncs through the bridge, read and written back.
    @Test func theNewSettingsSyncThroughTheBridge() {
        let d = scratch()
        SettingsSyncBridge.apply(["appearance.theme": .string("dark"), "appearance.notePages": .string("matchApp"),
                                  "drag.format": .string("html")], defaults: d)
        #expect(AppTheme.load(from: d) == .dark)
        #expect(NotePagesAppearance.load(from: d) == .matchApp)
        #expect(DragExportFormat.load(from: d) == .html)
        let mac = SettingsSyncBridge.values(for: .mac, defaults: d, extras: .init())
        #expect(mac["appearance.theme"] == .string("dark"))
        #expect(mac["appearance.notePages"] == .string("matchApp"))
        #expect(mac["drag.format"] == .string("html"))
        #expect(SettingsSyncBridge.values(for: .ipad, defaults: d, extras: .init())["drag.format"] == nil, "Mac only")
    }

    // MARK: - Color inversion

    // The colour arithmetic (`PageColorInversion`) is tested in SempereAppCoreTests (`PageColorInversionTests`).

    @Test func anImagesPixelsAreInvertedAndTransparencyKept() throws {
        // Black, opaque red, half-transparent blue, transparent.
        let pixels: [UInt8] = [0, 0, 0, 255, 204, 26, 26, 255, 13, 26, 89, 128, 0, 0, 0, 0]
        let image = try #require(Self.image(pixels, width: 4))
        let out = try #require(PageColorInversion.invertedImage(image))
        let read = try #require(Self.pixels(of: out))
        #expect(read[3] == 255 && read[0] > 220, "black became light")
        let red = PageColorInversion.hsl(r: Double(read[4]) / 255, g: Double(read[5]) / 255, b: Double(read[6]) / 255)
        #expect(red.h < 0.02 || red.h > 0.98, "red stays red")
        #expect(read[11] == 128, "alpha kept")
        #expect(read[12...15] == [0, 0, 0, 0], "transparent stays transparent")
    }

    static func image(_ rgba: [UInt8], width: Int) -> CGImage? {
        var bytes = rgba
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    static func pixels(of image: CGImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? out : nil
    }

    // MARK: - Paper

    @Test func darkPaperIsDarkAndLightPaperAsStored() throws {
        let view = PaperView()
        view.configure(paper: .ruled, size: CGSize(width: 612, height: 792))
        let stored = Paint(Paper.ruled.background)
        #expect(view.shownBackground == stored, "light: the stored color")
        view.setDark(true)
        let dark = try #require(view.shownBackground)
        #expect(dark != stored)
        #expect(max(dark.r, dark.g, dark.b) < 0x40, "dark paper is dark")
        view.setDark(false)
        #expect(view.shownBackground == stored)
    }

    // MARK: - Drag format

    @Test func dragFormatDefaultsToPDF() {
        let d = scratch()
        #expect(DragExportFormat.load(from: d) == .pdf)
        DragExportFormat.save(.markdown, to: d)
        #expect(DragExportFormat.load(from: d) == .markdown)
        #expect(NoteFileDrag.fileType(for: .pdf) == .pdf)
        #expect(NoteFileDrag.fileType(for: .html) == .html)
        #expect(NoteFileDrag.fileType(for: .markdown).preferredFilenameExtension == "md")
        #expect(DragExportFormat.allCases.map(\.fileExtension) == ["pdf", "md", "html"])
    }

    /// A note dragged out as Markdown or HTML is that file, named after the note's title.
    @Test(arguments: [DragExportFormat.markdown, .html])
    func aDraggedNoteIsWrittenInTheChosenFormat(_ format: DragExportFormat) async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        defer { model.close() }   // and the export folder is emptied
        let prepared = try await model.prepareExport(noteID: NoteWindowTests.lecture)
        let url = try await Task.detached { try prepared.write(format: format) }.value
        #expect(url.lastPathComponent == "Fixture lecture.\(format.fileExtension)")
        let text = try String(contentsOf: url, encoding: .utf8)
        if format == .html {
            #expect(text.contains("<html") || text.contains("<!DOCTYPE"), "an HTML page")
        } else {
            #expect(text.contains("Fixture lecture"), "Markdown with the note's title")
        }
        let provider = NSItemProvider()
        NoteFileDrag.register(on: provider, title: "Fixture lecture", format: format,
                              prepare: NoteFileDrag.prepare(NoteWindowTests.lecture, model: model))
        #expect(provider.registeredTypeIdentifiers == [NoteFileDrag.fileType(for: format).identifier])
    }
}
