import CoreGraphics
import Foundation
import Sempere
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

    @Test func themeDefaultsToTheSystemAndRoundTrips() {
        let d = scratch()
        #expect(AppTheme.load(from: d) == .system)
        AppTheme.save(.dark, to: d)
        #expect(AppTheme.load(from: d) == .dark)
        d.set("sepia", forKey: AppTheme.key)
        #expect(AppTheme.load(from: d) == .system, "an unknown value is the default")
        #expect(AppTheme.system.userInterfaceStyle == .unspecified)
        #expect(AppTheme.light.userInterfaceStyle == .light)
        #expect(AppTheme.dark.userInterfaceStyle == .dark)
    }

    @Test func notePagesAreLightUnlessChosen() {
        let d = scratch()
        #expect(NotePagesAppearance.load(from: d) == .light)
        for appIsDark in [false, true] {
            #expect(!NotePagesAppearance.light.isDark(appIsDark: appIsDark))
            #expect(NotePagesAppearance.dark.isDark(appIsDark: appIsDark))
            #expect(NotePagesAppearance.matchApp.isDark(appIsDark: appIsDark) == appIsDark)
        }
        NotePagesAppearance.save(.matchApp, to: d)
        #expect(NotePagesAppearance.load(from: d) == .matchApp)
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

    private func lightness(_ c: (r: Double, g: Double, b: Double)) -> Double {
        PageColorInversion.hsl(r: c.r, g: c.g, b: c.b).l
    }

    @Test func blackInkShowsLightAndWhitePaperDark() {
        let black = PageColorInversion.invert(r: 0, g: 0, b: 0)
        let white = PageColorInversion.invert(r: 1, g: 1, b: 1)
        #expect(lightness(black) > 0.9)
        #expect(lightness(white) < 0.15)
        #expect(abs(black.r - black.g) < 1e-9 && abs(black.g - black.b) < 1e-9, "gray stays gray")
    }

    @Test func hueAndSaturationAreKeptAndLightnessInverted() {
        let colors: [(Double, Double, Double)] = [(0.8, 0.1, 0.1), (0.1, 0.2, 0.7), (0.0, 0.5, 0.2), (0.95, 0.85, 0.2), (0.3, 0.1, 0.4)]
        for (r, g, b) in colors {
            let before = PageColorInversion.hsl(r: r, g: g, b: b)
            let out = PageColorInversion.invert(r: r, g: g, b: b)
            let after = PageColorInversion.hsl(r: out.r, g: out.g, b: out.b)
            let hueDistance = min(abs(after.h - before.h), 1 - abs(after.h - before.h))
            #expect(hueDistance < 0.01, "hue of \((r, g, b))")
            #expect(abs(after.s - before.s) < 0.02, "saturation of \((r, g, b))")
            let expected = PageColorInversion.darkest + (1 - before.l) * (PageColorInversion.lightest - PageColorInversion.darkest)
            #expect(abs(after.l - expected) < 0.01, "lightness of \((r, g, b))")
        }
        // Darker in, lighter out.
        #expect(lightness(PageColorInversion.invert(r: 0.2, g: 0.2, b: 0.6)) > lightness(PageColorInversion.invert(r: 0.5, g: 0.5, b: 0.9)))
    }

    @Test func paintKeepsItsAlpha() {
        let p = PageColorInversion.invert(Paint(r: 0, g: 0, b: 0, alpha: 0.4))
        #expect(p.alpha == 0.4)
        #expect(p.r > 200)
    }

    /// Text, equations and recording cards are converted; pictures, PDF pages and videos never.
    @Test func picturesPDFsAndVideosAreNeverInverted() {
        #expect(PageColorInversion.converts(kind: .text))
        #expect(PageColorInversion.converts(kind: .math))
        #expect(PageColorInversion.converts(kind: .audio))
        #expect(!PageColorInversion.converts(kind: .image))
        #expect(!PageColorInversion.converts(kind: .pdfPage))
        #expect(!PageColorInversion.converts(kind: .video))
    }

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
        defer { try? FileManager.default.removeItem(at: model.exportFolder) }
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
