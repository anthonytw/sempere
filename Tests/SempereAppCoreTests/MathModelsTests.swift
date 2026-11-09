import Foundation
import Sempere
import SempereRender
import TempDirSupport
import Testing
@testable import SempereAppCore

/// The device's handwritten-math models (`MathModels`): the recognizer override, a download checked file by
/// file, models added from Files, chosen and removed. The model itself is a fake recognizer and the network a
/// folder (`FolderFetcher`); the URLSession fetcher and Core ML are the app's (`MathModelFetchTests`).
@MainActor
struct MathModelsTests {
    struct FakeRecognizer: MathRecognizing {
        let imageSpec = MathImageSpec(width: 128, height: 32)
        func recognize(_ image: MathInkImage) throws -> MathRecognition {
            MathRecognition(candidates: [MathCandidate(latex: "x^{2}", score: -0.1)], engine: "fake", seconds: 0)
        }
    }

    /// Serves files from a folder by the URL's path below `base`.
    struct FolderFetcher: MathModelFetching {
        let folder: URL
        let base: String
        func fetch(_ url: URL, maxBytes: Int64) async throws -> URL {
            let source = folder.appendingPathComponent(String(url.absoluteString.dropFirst(base.count)))
            let copy = TestTemp.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        }
    }

    /// Never answers until cancelled, as a cancelled URLSession task ends.
    struct HangingFetcher: MathModelFetching {
        func fetch(_ url: URL, maxBytes: Int64) async throws -> URL {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    func newRoot() -> URL { TestTemp.root.appendingPathComponent("models-\(UUID().uuidString)") }

    func models(root: URL, catalog: [MathModelCatalogEntry] = [], session: MathModelFetching = HangingFetcher(),
                defaults: MemoryKeyValueStore = MemoryKeyValueStore(),
                loader: @escaping MathModels.Loader = { _ in throw MathModels.Failure.unsupported }) -> MathModels {
        MathModels(root: root, catalog: catalog, session: session, defaults: defaults, describe: { "\($0)" }, loader: loader)
    }

    /// A model folder with placeholder files (the store checks files, not Core ML) and its catalog entry.
    func fakeModel(id: String = "fake", corrupt: Bool = false) throws -> (URL, MathModelCatalogEntry) {
        let folder = TestTemp.root.appendingPathComponent("model-\(UUID().uuidString)")
        let files = ["encoder.mlpackage/Manifest.json": "e", "decoder.mlpackage/Manifest.json": "d",
                     "tokenizer.json": #"["<s>", "</s>", "x"]"#]
        var listed: [MathModelManifest.File] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            listed.append(.init(path: path, sha256: FileDigest.sha256(Data(text.utf8)), size: Int64(text.utf8.count)))
        }
        let manifest = MathModelManifest(id: id, name: id.capitalized, licence: "MIT", source: "test", files: listed,
                                         image: MathImageSpec(width: 64, height: 32),
                                         vocabulary: .init(file: "tokenizer.json", joining: .words),
                                         decoder: .init(start: 0, end: 1, pad: 1, maxLength: 8, vocabularySize: 3),
                                         coreml: .init(encoder: "encoder.mlpackage", decoder: "decoder.mlpackage"))
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: folder.appendingPathComponent("manifest.json"))
        if corrupt { try Data("y".utf8).write(to: folder.appendingPathComponent("tokenizer.json")) }
        let entry = MathModelCatalogEntry(id: id, name: id.capitalized, manifestURL: "https://example.org/m/manifest.json",
                                          manifestSHA256: FileDigest.sha256(data), downloadBytes: manifest.totalBytes,
                                          licence: "MIT")
        return (folder, entry)
    }

    @Test func theSettingIsOffUntilTurnedOn() {
        let d = MemoryKeyValueStore()
        #expect(!MathRecognitionPreference.isEnabled(d))
        d.set(true, forKey: MathRecognitionPreference.key)
        #expect(MathRecognitionPreference.isEnabled(d))
    }

    @Test func theRecognizerOverrideReadsAndNothingInstalledSaysSo() async throws {
        let m = models(root: newRoot())
        #expect(!m.isAvailable)
        await #expect(throws: MathModels.Failure.self) { _ = try await m.recognizer() }
        m.recognizerOverride = FakeRecognizer()
        #expect(m.isAvailable)
        let recognizer = try await m.recognizer()
        let stroke = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                            points: (0..<5).map { StrokePoint(x: Double($0) * 10, y: 5, w: 2, h: 2) })
        #expect(try recognizer.recognize(strokes: [stroke])?.best?.latex == "x^{2}")
    }

    @Test func theInstalledModelIsLoadedByTheAppsLoaderOnce() async throws {
        let (folder, _) = try fakeModel()
        let root = newRoot()
        let defaults = MemoryKeyValueStore()
        let calls = Calls()
        let m = models(root: root, defaults: defaults, loader: { choice in
            calls.add()
            guard case .installed(let model, let cache) = choice else { throw MathModels.Failure.unsupported }
            #expect(model.id == "fake")
            #expect(cache.path.hasSuffix(".compiled/\(model.manifestSHA256)"))
            return FakeRecognizer()
        })
        m.importModel(from: folder)
        #expect(await waitUntil { m.added.count == 1 })
        _ = try await m.recognizer()
        _ = try await m.recognizer()
        #expect(calls.count == 1, "loaded (and compiled) once")
        m.select("fake")
        _ = try await m.recognizer()
        #expect(calls.count == 2, "choosing a model loads it afresh")
    }

    @Test func aDownloadIsCheckedAndInstalled() async throws {
        let (folder, entry) = try fakeModel()
        let root = newRoot()
        let m = models(root: root, catalog: [entry], session: FolderFetcher(folder: folder, base: "https://example.org/m/"))
        #expect(m.status["fake"] == .notInstalled)
        m.download(entry)
        #expect(await waitUntil { m.status["fake"] == .installed })
        #expect(MathModelStore.installed(entry, root: root) != nil)
        #expect(m.isAvailable)
        m.remove(entry)
        #expect(m.status["fake"] == .notInstalled)
        #expect(MathModelStore.installed(entry, root: root) == nil)
    }

    @Test func aFileThatDoesNotMatchStopsTheDownload() async throws {
        let (folder, entry) = try fakeModel(corrupt: true)
        let root = newRoot()
        let m = models(root: root, catalog: [entry], session: FolderFetcher(folder: folder, base: "https://example.org/m/"))
        m.download(entry)
        #expect(await waitUntil {
            if case .failed = m.status["fake"] { return true }
            return false
        })
        #expect(MathModelStore.installed(entry, root: root) == nil)
        // Nothing half-installed is left behind.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(!left.contains("fake"))
        #expect(!left.contains { $0.hasPrefix(".staging") })
    }

    @Test func aCancelledDownloadIsNotAFailure() async throws {
        let (_, entry) = try fakeModel()
        let m = models(root: newRoot(), catalog: [entry])
        m.download(entry)
        #expect(await waitUntil { if case .downloading = m.status["fake"] { return true } else { return false } })
        m.cancelDownload(entry)
        #expect(await waitUntil { m.status["fake"] == .notInstalled })
    }

    @Test func aModelAddedFromFilesIsInstalledChosenAndRemoved() async throws {
        let (folder, _) = try fakeModel()
        let (other, _) = try fakeModel(id: "second")
        let root = newRoot()
        let defaults = MemoryKeyValueStore()
        let m = models(root: root, defaults: defaults)
        #expect(!m.isAvailable)
        m.importModel(from: folder)
        #expect(await waitUntil { m.added.count == 1 })
        #expect(m.isAvailable)
        #expect(m.selectedID == "fake", "the first model added is used")
        #expect(defaults.string(forKey: MathRecognitionPreference.modelKey) == "fake")
        m.importModel(from: other)
        #expect(await waitUntil { m.added.count == 2 })
        #expect(m.selectedID == "fake", "adding another does not change the choice")
        let second = try #require(m.added.first { $0.id == "second" })
        m.select("second")
        #expect(m.selectedID == "second")
        m.remove(second)
        #expect(m.added.map(\.id) == ["fake"])
        // The model in use was removed: the choice goes back to the first installed, which reading uses.
        #expect(m.selectedID == nil)
        #expect(defaults.string(forKey: MathRecognitionPreference.modelKey) == nil)
        #expect(MathModelStore.installedModels(root: root).map(\.id) == ["fake"])
        // A fresh instance sees the same.
        #expect(models(root: root, defaults: defaults).added.map(\.id) == ["fake"])
    }

    @Test func aModelThatDoesNotMatchItsManifestIsNotAdded() async throws {
        let (folder, _) = try fakeModel(corrupt: true)
        let m = models(root: newRoot())
        m.importModel(from: folder)
        #expect(await waitUntil { m.importFailure != nil && !m.importing })
        #expect(m.added.isEmpty)
        #expect(!m.isAvailable)
    }

    @Test func theChosenModelIsReadWithAndTheFirstWhenNoneIsChosen() throws {
        let (folder, _) = try fakeModel()
        let (other, _) = try fakeModel(id: "second")
        let root = newRoot()
        _ = try MathModelImport.install(from: folder, root: root)
        _ = try MathModelImport.install(from: other, root: root)
        func chosen(_ preferred: String?) throws -> String? {
            guard case .installed(let model, _) = try MathModels.choose(root: root, catalog: [], local: nil, preferred: preferred) else { return nil }
            return model.id
        }
        #expect(try chosen("second") == "second")
        #expect(try chosen("gone") == "fake", "a choice that is not installed falls back to the first")
        #expect(try chosen(nil) == "fake")
        #expect(throws: MathModels.Failure.self) {
            _ = try MathModels.choose(root: newRoot(), catalog: [], local: nil, preferred: nil)
        }
    }
}
