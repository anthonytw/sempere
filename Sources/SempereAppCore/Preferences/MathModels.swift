import Foundation
import Observation
import Sempere
import SempereRender

/// The "Convert to Math" setting (per device, off by default): the Insert
/// menu's "Equation from Handwriting" appears only when it is on and a
/// model is installed (docs/attachments.md §14 G1 part 2).
public enum MathRecognitionPreference {
    public static let key = "Sempere.mathRecognition"
    public static let defaultValue = false
    /// The id of the installed model to read with (nothing: the first installed).
    public static let modelKey = "Sempere.mathModelID"

    public static func isEnabled(_ defaults: any KeyValueStore) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Fetches one URL to a local file (the app's only network use, and only
/// when the user asks for a model; the app supplies the real fetcher, tests use a fake).
/// A fetch that is cancelled throws `CancellationError`.
public protocol MathModelFetching: Sendable {
    /// Downloads `url` to a new temporary file and returns it; refuses more than `maxBytes`.
    func fetch(_ url: URL, maxBytes: Int64) async throws -> URL
}

/// What the recognizer is loaded from: the platform (Core ML in the app) turns it into a `MathRecognizing`.
public enum MathModelChoice: Sendable {
    /// A model folder used as is (DEBUG `SEMPERE_DEBUG_MATH_MODEL`), already checked against its manifest.
    case folder(URL, MathModelManifest)
    /// An installed model; `compiledCache` is where its compiled form is kept.
    case installed(InstalledMathModel, compiledCache: URL)
}

/// Handwritten-math models on this device: which can be had
/// (`MathModelCatalog`, plus a local folder in DEBUG scripted runs), which
/// is installed (`MathModelStore`, Application Support/Sempere/MathModels,
/// excluded from backups), downloading one (every file checked against the
/// manifest the catalog pins before anything is used) and the loaded
/// recognizer. Device-wide: models are not vault data. The words (failure texts) and the Core ML
/// loading are the app's: `describe` words an error, `load` makes the recognizer.
@MainActor
@Observable
public final class MathModels {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case downloading(done: Int64, total: Int64)
        case installed
        case failed(String)
    }

    /// Makes the recognizer for a chosen model (off the main actor); throws `Failure.unsupported` where none can run.
    public typealias Loader = @Sendable (MathModelChoice) throws -> (any MathRecognizing)

    /// Where models are kept.
    public let root: URL
    /// The models offered, best first.
    public let catalog: [MathModelCatalogEntry]
    public private(set) var status: [String: Status] = [:]
    /// Every model in the store that is not a catalog download: the ones added from Files
    /// (`importModel`), shown in Settings to choose from or remove.
    public private(set) var added: [InstalledMathModel] = []
    /// The id of the model used for reading (`MathRecognitionPreference.modelKey`); nil: the first installed.
    public private(set) var selectedID: String?
    /// "Add Model from Files" in progress, and why the last one failed (the error as `describe` words it).
    public private(set) var importing = false
    public private(set) var importFailure: String?
    @ObservationIgnored private let defaults: any KeyValueStore
    /// Tests: used instead of loading a model.
    @ObservationIgnored public var recognizerOverride: (any MathRecognizing)?
    /// A model folder used as is (DEBUG `SEMPERE_DEBUG_MATH_MODEL`; checked like a download).
    @ObservationIgnored private let localFolder: URL?
    @ObservationIgnored private var loaded: (id: String, recognizer: any MathRecognizing)?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let session: MathModelFetching
    @ObservationIgnored private let describe: @Sendable (any Error) -> String
    @ObservationIgnored private let loader: Loader

    public init(root: URL = MathModels.defaultRoot, catalog: [MathModelCatalogEntry] = MathModelCatalog.entries,
                localFolder: URL? = nil, session: MathModelFetching, defaults: any KeyValueStore,
                describe: @escaping @Sendable (any Error) -> String = { "\($0)" },
                loader: @escaping Loader = { _ in throw Failure.unsupported }) {
        self.defaults = defaults
        self.selectedID = defaults.string(forKey: MathRecognitionPreference.modelKey)
        self.root = root
        self.catalog = catalog
        self.localFolder = localFolder
        self.session = session
        self.describe = describe
        self.loader = loader
        refresh()
    }

    public nonisolated static var defaultRoot: URL { AppSupport.folder("MathModels") }

    /// Whether a model can read ink now (installed, or the test override).
    public var isAvailable: Bool {
        recognizerOverride != nil || localFolder != nil || status.values.contains(.installed) || !added.isEmpty
    }

    /// Looks at what is installed.
    public func refresh() {
        for entry in catalog where downloads[entry.id] == nil {
            status[entry.id] = MathModelStore.installed(entry, root: root) == nil ? .notInstalled : .installed
        }
        let catalogIDs = Set(catalog.map(\.id))
        added = MathModelStore.installedModels(root: root).filter { !catalogIDs.contains($0.id) }
    }

    /// Adds the model in `url` (a folder or a zip picked in Files): checked against its manifest,
    /// copied into the store and, if it is the only one, used. Reads the files off the main actor.
    /// `access` brackets the read (the app's security-scoped resource access).
    public func importModel(from url: URL, access: @escaping @Sendable (URL) -> (() -> Void) = { _ in {} }) {
        guard !importing else { return }
        importing = true
        importFailure = nil
        let root = self.root
        Task { [weak self] in
            let stop = access(url)
            defer { stop() }
            let outcome: Result<InstalledMathModel, Error> = await Task.detached(priority: .userInitiated) {
                Result { try MathModelImport.install(from: url, root: root) }
            }.value
            guard let self else { return }
            self.importing = false
            switch outcome {
            case .success(let model):
                if self.loaded?.id == model.id { self.loaded = nil }
                try? FileManager.default.removeItem(at: root.appendingPathComponent(".compiled/\(model.manifestSHA256)"))
                self.refresh()
                if self.selectedID == nil || self.added.count == 1 { self.select(model.id) }
            case .failure(let error):
                self.importFailure = self.describe(error)
            }
        }
    }

    /// Uses model `id` for reading from now on.
    public func select(_ id: String) {
        selectedID = id
        defaults.set(id, forKey: MathRecognitionPreference.modelKey)
        loaded = nil
    }

    /// Deletes a model added from Files.
    public func remove(_ model: InstalledMathModel) {
        if loaded?.id == model.id { loaded = nil }
        if selectedID == model.id {
            // Back to "the first installed", which is what reading falls back to (and Settings shows in use).
            selectedID = nil
            defaults.removeObject(forKey: MathRecognitionPreference.modelKey)
        }
        try? MathModelStore.remove(id: model.id, root: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".compiled/\(model.manifestSHA256)"))
        refresh()
    }

    /// Downloads `entry` into the store: its manifest (which must hash to the
    /// entry's), then every file (each must match the manifest), then installs.
    public func download(_ entry: MathModelCatalogEntry) {
        guard downloads[entry.id] == nil else { return }
        status[entry.id] = .downloading(done: 0, total: entry.downloadBytes)
        let root = self.root, session = self.session, describe = self.describe
        let progress: @Sendable (Int64) -> Void = { [weak self] done in
            let models = self
            Task { @MainActor in models?.progressed(entry, done: done) }
        }
        downloads[entry.id] = Task { [weak self] in
            let result: Status
            do {
                try await MathModelDownload.run(entry, root: root, session: session, progress: progress)
                result = .installed
            } catch is CancellationError {
                result = .notInstalled
            } catch {
                result = .failed(describe(error))
            }
            guard let self else { return }
            self.downloads[entry.id] = nil
            self.status[entry.id] = result
        }
    }

    private func progressed(_ entry: MathModelCatalogEntry, done: Int64) {
        if case .downloading = status[entry.id] {
            status[entry.id] = .downloading(done: done, total: entry.downloadBytes)
        }
    }

    public func cancelDownload(_ entry: MathModelCatalogEntry) {
        downloads[entry.id]?.cancel()
    }

    /// Deletes the installed copy of `entry`.
    public func remove(_ entry: MathModelCatalogEntry) {
        if loaded?.id == entry.id { loaded = nil }
        try? MathModelStore.remove(id: entry.id, root: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".compiled/\(entry.manifestSHA256)"))
        refresh()
    }

    /// The recognizer of the chosen model (the first installed when none is chosen), loaded (and compiled,
    /// once) off the main actor.
    public func recognizer() async throws -> any MathRecognizing {
        if let recognizerOverride { return recognizerOverride }
        if let loaded { return loaded.recognizer }
        let root = self.root, catalog = self.catalog, local = localFolder, preferred = selectedID, loader = self.loader
        let made: (String, any MathRecognizing) = try await Task.detached(priority: .userInitiated) {
            let choice = try Self.choose(root: root, catalog: catalog, local: local, preferred: preferred)
            let id: String
            switch choice {
            case .folder(_, let manifest): id = manifest.id
            case .installed(let model, _): id = model.id
            }
            return (id, try loader(choice))
        }.value
        loaded = made
        return made.1
    }

    public enum Failure: Error {
        /// Nothing is installed to read with.
        case noModel
        /// This device cannot run the model (no Core ML).
        case unsupported
    }

    /// The model reading uses: the local folder (checked like a download), else the chosen installed model,
    /// else the first installed one. Catalog models must still match the catalog's pin; models added from Files
    /// are checked when added (the store's marker holds the manifest hash) and their sizes again here.
    nonisolated static func choose(root: URL, catalog: [MathModelCatalogEntry], local: URL?,
                                   preferred: String?) throws -> MathModelChoice {
        if let local {
            let m = try MathModelStore.manifest(in: local)
            try MathModelStore.verify(m, in: local)
            return .folder(local, m)
        }
        var candidates: [InstalledMathModel] = []
        for entry in catalog {
            guard let (folder, m) = MathModelStore.installed(entry, root: root) else { continue }
            candidates.append(InstalledMathModel(manifest: m, manifestSHA256: entry.manifestSHA256, folder: folder))
        }
        let catalogIDs = Set(catalog.map(\.id))
        candidates += MathModelStore.installedModels(root: root).filter { !catalogIDs.contains($0.id) }
        guard let model = candidates.first(where: { $0.id == preferred }) ?? candidates.first else { throw Failure.noModel }
        let compiled = root.appendingPathComponent(".compiled", isDirectory: true).appendingPathComponent(model.manifestSHA256)
        return .installed(model, compiledCache: compiled)
    }
}

/// One model download, off the main actor: into a staging folder under the
/// store, checked file by file, then installed (`MathModelStore.install`).
public enum MathModelDownload {
    public static func run(_ entry: MathModelCatalogEntry, root: URL, session: MathModelFetching,
                           progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Models are not backed up (they can be downloaded again).
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var backupFree = root
        try? backupFree.setResourceValues(values)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        guard let manifestURL = URL(string: entry.manifestURL), manifestURL.scheme == "https" else {
            throw MathModelManifest.Failure.malformed("the catalog's manifest URL is not HTTPS")
        }
        let manifestFile = try await session.fetch(manifestURL, maxBytes: Int64(MathModelManifest.maxBytes))
        try fm.moveItem(at: manifestFile, to: staging.appendingPathComponent("manifest.json"))
        let manifest = try MathModelStore.manifest(in: staging, expectedSHA256: entry.manifestSHA256)
        var done: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard let url = entry.fileURL(file.path) else { throw MathModelManifest.Failure.malformed("bad path \(file.path)") }
            let fetched = try await session.fetch(url, maxBytes: file.size)
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: fetched, to: target)
            // Checked as it lands, so a wrong file stops the download early.
            let (hex, size) = try FileDigest.sha256(of: target, maxBytes: file.size)
            guard hex == file.sha256, size == file.size else { throw MathModelManifest.Failure.mismatch(file.path) }
            done += file.size
            progress(done)
        }
        try Task.checkCancellation()
        try MathModelStore.install(from: staging, manifestSHA256: entry.manifestSHA256, root: root)
    }
}
