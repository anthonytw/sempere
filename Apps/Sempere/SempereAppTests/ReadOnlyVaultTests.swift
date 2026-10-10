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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("newer.sempere"), to: vault)
        return (vault, try String(contentsOf: fixtures.appendingPathComponent("sample.key"), encoding: .utf8))
    }

    /// Every regular file under `url` with its bytes.
    static func files(_ url: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            guard (try f.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            out[String(f.path.dropFirst(url.path.count))] = try Data(contentsOf: f)
        }
        return out
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
        let before = try Self.files(url)

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

        // The editor never autosaves or recognises.
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

        #expect(try Self.files(url) == before, "nothing in the vault changed")
    }

    /// A newer revision that arrives while its note is open (another device,
    /// format.md §7.3): the merge shows what it understands and the editor
    /// becomes read-only instead of failing its next autosave.
    @Test func aNewerRevisionArrivingInAnOpenNoteMakesItReadOnly() async throws {
        let (url, keyText) = try Self.newerVault()
        // A version-1 manifest and only the mixed note: its newer delta is the only newer content.
        let manifestURL = url.appendingPathComponent("vault.json")
        var manifest = try VaultManifest.decode(Data(contentsOf: manifestURL))
        manifest.format = "sempere/1"
        manifest.features = []
        manifest.markersTag = nil   // a version-1 vault from before version markers
        try manifest.encoded().write(to: manifestURL)
        for other in ["44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555"] {
            try FileManager.default.removeItem(at: url.appendingPathComponent("notes/\(other)"))
        }
        let noteDir = url.appendingPathComponent("notes/\(Self.mixed.uuidString.lowercased())")
        let newerFile = try #require(try FileManager.default.contentsOfDirectory(atPath: noteDir.path)
            .first { $0.contains("-0e0e0e0e-") })
        let aside = url.deletingLastPathComponent().appendingPathComponent(newerFile)
        try FileManager.default.moveItem(at: noteDir.appendingPathComponent(newerFile), to: aside)

        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        try await model.unlock(identityText: keyText)
        #expect(!model.isVaultReadOnly)
        model.selectedNoteID = Self.mixed
        try await model.openEditor(for: Self.mixed)
        let editor = try #require(model.editor)
        #expect(!editor.isReadOnly)

        try FileManager.default.moveItem(at: aside, to: noteDir.appendingPathComponent(newerFile))
        _ = try await model.mergeRemoteRevisions(into: editor)
        #expect(editor.isReadOnly)
        #expect(editor.readOnlyReason?.contains("newer version") == true)
        #expect(editor.pages.first?.strokes.count == 2)
        let before = try Self.files(url)
        await editor.flush()
        #expect(editor.deltasWritten == 0)
        #expect(try Self.files(url) == before)
    }
}

private final class ReadOnlyBundleToken {}
