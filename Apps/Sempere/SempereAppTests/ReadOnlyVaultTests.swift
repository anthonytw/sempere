import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Vaults of a newer format version in the app (format.md §7.3): the fixture
/// `newer.sempere` (`sempere/2`, newer revisions) opens read-only, lists and
/// opens its notes as far as this version understands them, and nothing the
/// user or the app does writes a file.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct ReadOnlyVaultTests {
    static let mixed = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let body2 = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    /// A private copy of the newer fixture and the text of its key.
    static func newerVault() throws -> (vault: URL, keyText: String) {
        let bundle = Bundle(for: ReadOnlyBundleToken.self)
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Fixtures missing from test bundle"])
        }
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("newer.sempere"), to: vault)
        return (vault, try String(contentsOf: fixtures.appendingPathComponent("sample.key"), encoding: .utf8))
    }

    @Test func opensReadOnlyAndShowsWhatItUnderstands() async throws {
        let (url, keyText) = try Self.newerVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(model.phase == .unlocked)
        #expect(model.isVaultReadOnly)
        #expect(model.readOnlyReasons.vaultFormat == "sempere/2")
        #expect(model.readOnlyBanner?.contains("sempere/2") == true)
        let mixed = try #require(model.notes.first { $0.id == Self.mixed })
        #expect(mixed.title == "Newer fixture, edited by v2")
        #expect(mixed.newer?.skippedOpCount == 3)

        model.selectedNoteID = Self.mixed
        try await model.openEditor(for: Self.mixed)
        let editor = try #require(model.editor)
        #expect(editor.isReadOnly)
        #expect(editor.readOnlyReason?.contains("newer version") == true)
        #expect(editor.pages.first?.strokes.count == 2)

        // A note whose newer revision cannot be read at all opens too.
        model.selectedNoteID = Self.body2
        try await model.openEditor(for: Self.body2)
        #expect(model.editor?.isReadOnly == true)
        #expect(model.editor?.pages.first?.strokes.count == 1)
    }

    @Test func refusesEveryWrite() async throws {
        let (url, keyText) = try Self.newerVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        model.automaticThinning = true
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        let before = try TS.fileSnapshot(of: url)

        await #expect(throws: VaultError.self) {
            _ = try await model.createNote(title: "x", paper: .ruled, notebook: nil)
        }
        await #expect(throws: VaultError.self) { try await model.renameNote(Self.mixed, to: "x") }
        await #expect(throws: VaultError.self) { try await model.addTag("x", to: Self.mixed) }
        await #expect(throws: VaultError.self) { try await model.deleteNote(Self.mixed) }
        await #expect(throws: VaultError.self) { _ = try await model.saveVersion(of: Self.mixed, name: "v") }
        await #expect(throws: VaultError.self) { _ = try await model.thinVault(days: 1, dryRun: false) }
        #expect(await model.adoptInbox() == 0)
        model.thinIfDue(now: .distantFuture)

        // The editor never autosaves or recognizes.
        model.selectedNoteID = Self.mixed
        try await model.openEditor(for: Self.mixed)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke()))
        _ = editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.flush()
        #expect(editor.deltasWritten == 0)
        model.close()
        await editor.flush()

        #expect(try TS.fileSnapshot(of: url) == before, "nothing in the vault changed")
    }

    /// The banner's reasons are the app's own localized strings, not the CLI's English
    /// (`ReadOnlyReasons.descriptions`), which left an English clause inside the Spanish banner.
    @Test func bannerReasonsAreTheAppsLocalizedStrings() {
        let format = "sempere/2", current = SempereFormat.identifier, features = "a, b", count = 2
        let reasons = ReadOnlyReasons(vaultFormat: format, unknownFeatures: ["a", "b"], newerNotes: [UUID(), UUID()])
        let details = AppModel.readOnlyDetails(reasons)
        // The same catalog keys as the app's (interpolated, not literal), so this holds in any language.
        #expect(details == [
            String(localized: "the vault uses format \(format), newer than this version's \(current)"),
            String(localized: "the vault uses format extensions this version does not know: \(features)"),
            String(localized: "\(count) notes hold revisions written by a newer version"),
        ])
        #expect(!details.contains { $0.isEmpty })
        #expect(AppModel.readOnlyText(reasons).contains("a, b"))
        #expect(AppModel.readOnlyDetails(ReadOnlyReasons()).isEmpty)
    }

}

private final class ReadOnlyBundleToken {}
