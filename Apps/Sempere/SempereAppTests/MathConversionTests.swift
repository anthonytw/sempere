import Foundation
import PencilKit
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// "Convert to Math" (docs/attachments.md §14 G1 part 2): the lasso's pick,
/// the one delta that replaces ink with a typeset equation (or adds it
/// beside), undo and redo through the ledger, and the model store's
/// download (a fake fetcher; the model itself is a fake recogniser).
@MainActor
@Suite(.serialized)
struct MathConversionTests {
    struct FakeRecognizer: MathRecognizing {
        let imageSpec = MathImageSpec(width: 128, height: 32)
        func recognize(_ image: MathInkImage) throws -> MathRecognition {
            MathRecognition(candidates: [MathCandidate(latex: "x^{2}", score: -0.1), MathCandidate(latex: "x^{z}", score: -0.9)],
                            engine: "fake", seconds: 0)
        }
    }

    static let everywhere = [CGPoint(x: -10_000, y: -10_000), CGPoint(x: 10_000, y: -10_000),
                             CGPoint(x: 10_000, y: 100_000), CGPoint(x: -10_000, y: 100_000)]

    func request(_ editor: NoteEditor, page: UUID, undo: UndoManager? = nil) throws -> MathConversionRequest {
        let strokes = editor.mathSelection(pageID: page, loop: Self.everywhere)
        #expect(!strokes.isEmpty)
        return MathConversionRequest(page: page, strokeIDs: strokes.map(\.id), strokes: strokes, undoManager: undo)
    }

    @Test func theLassoPicksTheInkInsideAndSaysWhenItPicksNothing() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let live = editor.liveStrokes(of: page).filter { $0.ink.tool != .marker }
        #expect(Set(editor.mathSelection(pageID: page, loop: Self.everywhere).map(\.id)) == Set(live.map(\.id)))
        editor.beginMathLasso()
        #expect(editor.mathLassoActive)
        // A loop around nothing: the lasso stays, with a message.
        editor.mathLassoFinished(pageID: page, loop: [CGPoint(x: -50, y: -50), CGPoint(x: -40, y: -50), CGPoint(x: -40, y: -40)],
                                 undoManager: nil)
        #expect(editor.mathLassoActive)
        #expect(editor.mathLassoMessage != nil)
        #expect(editor.mathConversion == nil)
        // Around the ink: the sheet's request, the lasso off.
        editor.mathLassoFinished(pageID: page, loop: Self.everywhere, undoManager: nil)
        #expect(!editor.mathLassoActive)
        #expect(editor.mathConversion?.strokeIDs.count == live.count)
        editor.endMathLasso()
    }

    @Test func replaceWritesTheRenderThenOneDeltaAndUndoBringsTheInkBack() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let before = editor.liveStrokes(of: page)
        let undo = AttachmentEditorTests.undoManager()
        let request = try request(editor, page: page, undo: undo)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        let content = try NoteOps.math("x^{2}")
        let (item, ink) = try await editor.convertInk(request, to: content, placement: .replace)
        let actions = ItemActions(editor: editor, undoManager: undo)
        editor.conversionActions = actions
        AttachmentEditorTests.grouped(undo) { actions.converted(item, ink: ink, on: page) }
        await editor.flush()
        let written = try NoteEditorTests.myDeltas(vault, clock)
        #expect(written.count == deltas + 1, "one delta")
        let ops = try #require(written.last)
        let removed = Set(request.strokeIDs.map { Op.removeStroke(page: page, strokeId: $0) })
        #expect(Set(ops.filter { if case .removeStroke = $0 { return true } else { return false } }) == removed)
        #expect(ops.contains { if case .addItem(_, let added) = $0 { return added.id == item.id } else { return false } })
        #expect(ink?.strokes.count == request.strokeIDs.count)
        // The render is in the note, typeset by SwiftMath; the ink is gone.
        let render = try #require(item.math?.render)
        #expect(item.math?.engine == MathTypesetter.engine)
        _ = try vault.readBlob(note: AppModelTests.lecture, render, maxBytes: 1 << 20)
        let state = try vault.reconstruct(noteId: AppModelTests.lecture)
        let stored = try #require(state.pages.first { $0.id == page })
        #expect(Set(stored.strokes.map(\.id)).isDisjoint(with: request.strokeIDs))
        #expect(stored.strokes.count == before.count - request.strokeIDs.count)
        #expect(stored.items.contains { $0.id == item.id })

        // Undo: the item goes and the ink comes back (new ids, parent = the converted strokes), one delta.
        undo.undo()
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 2)
        let undone = try #require(try vault.reconstruct(noteId: AppModelTests.lecture).pages.first { $0.id == page })
        #expect(!undone.items.contains { $0.id == item.id })
        #expect(undone.strokes.count == before.count)
        let back = undone.strokes.filter { request.strokeIDs.contains($0.parent ?? UUID()) }
        #expect(back.count == request.strokeIDs.count)

        // Redo: converted again, one delta.
        #expect(undo.canRedo)
        undo.redo()
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 3)
        let redone = try #require(try vault.reconstruct(noteId: AppModelTests.lecture).pages.first { $0.id == page })
        #expect(redone.strokes.count == before.count - request.strokeIDs.count)
        #expect(redone.items.contains { $0.kind == .math && $0.parent == item.id })
    }

    @Test func besideKeepsTheInk() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let before = editor.liveStrokes(of: page).map(\.id)
        let request = try request(editor, page: page)
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        let (item, ink) = try await editor.convertInk(request, to: try NoteOps.math("a+b"), placement: .beside)
        await editor.flush()
        #expect(ink == nil)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas + 1)
        #expect(editor.liveStrokes(of: page).map(\.id) == before)
        #expect(editor.item(item.id, on: page) != nil)
    }

    @Test func inkErasedMeanwhileStopsTheConversionBeforeAnythingIsWritten() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let request = try request(editor, page: page)
        // Everything erased on the canvas before Convert.
        editor.drawingDidChange(pageID: page, drawing: PKDrawing(), tool: PKEraserTool(.vector))
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock).count
        await #expect(throws: AttachmentOpsError.self) {
            _ = try await editor.convertInk(request, to: try NoteOps.math("x"), placement: .replace)
        }
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == deltas)
    }

    @Test func theRecognizerOverrideReadsAndCandidatesComeBack() async throws {
        let models = MathModels(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                catalog: [], localFolder: nil)
        #expect(!models.isAvailable)
        await #expect(throws: (any Error).self) { _ = try await models.recognizer() }
        models.recognizerOverride = FakeRecognizer()
        #expect(models.isAvailable)
        let recognizer = try await models.recognizer()
        let stroke = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                            points: (0..<5).map { StrokePoint(x: Double($0) * 10, y: 5, w: 2, h: 2) })
        #expect(try recognizer.recognize(strokes: [stroke])?.best?.latex == "x^{2}")
    }

    // MARK: Downloads

    /// Serves files from a folder by the URL's last path components.
    struct FolderFetcher: MathModelFetching {
        let folder: URL
        let base: String
        func fetch(_ url: URL, maxBytes: Int64) async throws -> URL {
            let path = String(url.absoluteString.dropFirst(base.count))
            let source = folder.appendingPathComponent(path)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        }
    }

    /// A model folder with placeholder files (the store checks files, not Core ML) and its catalogue entry.
    func fakeModel(corrupt: Bool = false) throws -> (URL, MathModelCatalogEntry) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        let files = ["encoder.mlpackage/Manifest.json": "e", "decoder.mlpackage/Manifest.json": "d",
                     "tokenizer.json": #"["<s>", "</s>", "x"]"#]
        var listed: [MathModelManifest.File] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            listed.append(.init(path: path, sha256: FileDigest.sha256(Data(text.utf8)), size: Int64(text.utf8.count)))
        }
        let manifest = MathModelManifest(id: "fake", name: "Fake", licence: "MIT", source: "test", files: listed,
                                         image: MathImageSpec(width: 64, height: 32),
                                         vocabulary: .init(file: "tokenizer.json", joining: .words),
                                         decoder: .init(start: 0, end: 1, pad: 1, maxLength: 8, vocabularySize: 3),
                                         coreml: .init(encoder: "encoder.mlpackage", decoder: "decoder.mlpackage"))
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: folder.appendingPathComponent("manifest.json"))
        if corrupt { try Data("y".utf8).write(to: folder.appendingPathComponent("tokenizer.json")) }
        let entry = MathModelCatalogEntry(id: "fake", name: "Fake", manifestURL: "https://example.org/m/manifest.json",
                                          manifestSHA256: FileDigest.sha256(data), downloadBytes: manifest.totalBytes,
                                          licence: "MIT")
        return (folder, entry)
    }

    @Test func aDownloadIsCheckedAndInstalled() async throws {
        let (folder, entry) = try fakeModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let models = MathModels(root: root, catalog: [entry], localFolder: nil,
                                session: FolderFetcher(folder: folder, base: "https://example.org/m/"))
        #expect(models.status["fake"] == .notInstalled)
        models.download(entry)
        #expect(await TS.waitUntil { models.status["fake"] == .installed })
        #expect(MathModelStore.installed(entry, root: root) != nil)
        #expect(models.isAvailable)
        models.remove(entry)
        #expect(models.status["fake"] == .notInstalled)
        #expect(MathModelStore.installed(entry, root: root) == nil)
    }

    @Test func aFileThatDoesNotMatchStopsTheDownload() async throws {
        let (folder, entry) = try fakeModel(corrupt: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let models = MathModels(root: root, catalog: [entry], localFolder: nil,
                                session: FolderFetcher(folder: folder, base: "https://example.org/m/"))
        models.download(entry)
        #expect(await TS.waitUntil {
            if case .failed = models.status["fake"] { return true }
            return false
        })
        #expect(MathModelStore.installed(entry, root: root) == nil)
        // Nothing half-installed is left behind.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(!left.contains("fake"))
        #expect(!left.contains { $0.hasPrefix(".staging") })
    }

    @Test func aModelAddedFromFilesIsInstalledChosenAndRemoved() async throws {
        let (folder, _) = try fakeModel()
        let (other, _) = try fakeModel()
        // A second model with another id.
        var manifest = try JSONDecoder().decode(MathModelManifest.self, from: Data(contentsOf: other.appendingPathComponent("manifest.json")))
        manifest.id = "second"
        manifest.name = "Second"
        try JSONEncoder().encode(manifest).write(to: other.appendingPathComponent("manifest.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let suite = "math-models-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = MathModels(root: root, catalog: [], localFolder: nil, defaults: defaults)
        #expect(!models.isAvailable)
        models.importModel(from: folder)
        #expect(await TS.waitUntil { models.added.count == 1 })
        #expect(models.isAvailable)
        #expect(models.selectedID == "fake", "the first model added is used")
        #expect(defaults.string(forKey: MathRecognitionPreference.modelKey) == "fake")
        models.importModel(from: other)
        #expect(await TS.waitUntil { models.added.count == 2 })
        #expect(models.selectedID == "fake", "adding another does not change the choice")
        let second = try #require(models.added.first { $0.id == "second" })
        models.select("second")
        #expect(models.selectedID == "second")
        models.remove(second)
        #expect(models.added.map(\.id) == ["fake"])
        // The model in use was removed: the choice goes back to the first installed, which reading uses.
        #expect(models.selectedID == nil)
        #expect(defaults.string(forKey: MathRecognitionPreference.modelKey) == nil)
        #expect(MathModelStore.installedModels(root: root).map(\.id) == ["fake"])
        // A fresh instance sees the same.
        #expect(MathModels(root: root, catalog: [], localFolder: nil, defaults: defaults).added.map(\.id) == ["fake"])
    }

    @Test func aModelThatDoesNotMatchItsManifestIsNotAdded() async throws {
        let (folder, _) = try fakeModel(corrupt: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let suite = "math-models-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = MathModels(root: root, catalog: [], localFolder: nil, defaults: defaults)
        models.importModel(from: folder)
        #expect(await TS.waitUntil { models.importFailure != nil && !models.importing })
        #expect(models.added.isEmpty)
        #expect(!models.isAvailable)
    }
}
