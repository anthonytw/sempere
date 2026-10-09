import Foundation
import Observation
import Sempere
import SempereRender

/// The "Convert to Math" setting (per device, off by default): the Insert
/// menu's "Equation from Handwriting" appears only when it is on and a
/// model is installed (docs/attachments.md §14 G1 part 2).
enum MathRecognitionPreference {
    static let key = "Sempere.mathRecognition"
    static let defaultValue = false
    /// The id of the installed model to read with (nothing: the first installed).
    static let modelKey = "Sempere.mathModelID"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Handwritten-math models on this device: which can be had
/// (`MathModelCatalog`, plus a local folder in DEBUG scripted runs), which
/// is installed (`MathModelStore`, Application Support/Sempere/MathModels,
/// excluded from backups), downloading one (every file checked against the
/// manifest the catalogue pins before anything is used) and the loaded
/// recogniser. Device-wide: models are not vault data.
@MainActor
@Observable
final class MathModels {
    static let shared = MathModels()

    enum Status: Equatable {
        case notInstalled
        case downloading(done: Int64, total: Int64)
        case installed
        case failed(String)
    }

    /// Where models are kept.
    let root: URL
    /// The models offered, best first.
    let catalog: [MathModelCatalogEntry]
    private(set) var status: [String: Status] = [:]
    /// Every model in the store that is not a catalogue download: the ones added from Files
    /// (`importModel`), shown in Settings to choose from or remove.
    private(set) var added: [InstalledMathModel] = []
    /// The id of the model used for reading (`MathRecognitionPreference.modelKey`); nil: the first installed.
    private(set) var selectedID: String?
    /// "Add Model from Files" in progress, and why the last one failed.
    private(set) var importing = false
    private(set) var importFailure: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// Tests: used instead of loading a model.
    @ObservationIgnored var recognizerOverride: (any MathRecognizing)?
    /// A model folder used as is (DEBUG `SEMPERE_DEBUG_MATH_MODEL`; checked like a download).
    @ObservationIgnored private let localFolder: URL?
    @ObservationIgnored private var loaded: (id: String, recognizer: any MathRecognizing)?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let session: MathModelFetching

    init(root: URL = MathModels.defaultRoot, catalog: [MathModelCatalogEntry] = MathModelCatalog.entries,
         localFolder: URL? = MathModels.debugFolder, session: MathModelFetching = URLSessionModelFetcher(),
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedID = defaults.string(forKey: MathRecognitionPreference.modelKey)
        self.root = root
        self.catalog = catalog
        self.localFolder = localFolder
        self.session = session
        refresh()
    }

    nonisolated static var defaultRoot: URL { AppSupport.folder("MathModels") }

    /// `SEMPERE_DEBUG_MATH_MODEL` (DEBUG builds): a converted model folder to
    /// use without a catalogue entry (`~/` is the app's data container).
    nonisolated static var debugFolder: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["SEMPERE_DEBUG_MATH_MODEL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst(1) : path, isDirectory: true)
        #else
        return nil
        #endif
    }

    /// Whether a model can read ink now (installed, or the test override).
    var isAvailable: Bool {
        recognizerOverride != nil || localFolder != nil || status.values.contains(.installed) || !added.isEmpty
    }

    /// Looks at what is installed.
    func refresh() {
        for entry in catalog where downloads[entry.id] == nil {
            status[entry.id] = MathModelStore.installed(entry, root: root) == nil ? .notInstalled : .installed
        }
        let catalogIDs = Set(catalog.map(\.id))
        added = MathModelStore.installedModels(root: root).filter { !catalogIDs.contains($0.id) }
    }

    /// Adds the model in `url` (a folder or a zip picked in Files): checked against its manifest,
    /// copied into the store and, if it is the only one, used. Reads the files off the main actor.
    func importModel(from url: URL) {
        guard !importing else { return }
        importing = true
        importFailure = nil
        let root = self.root
        Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
                self.importFailure = String(localized: "That model cannot be added: \(String(describing: error))",
                                            comment: "Settings ▸ Handwritten Math: Add Model from Files failed; the reason follows (English)")
            }
        }
    }

    /// Uses model `id` for reading from now on.
    func select(_ id: String) {
        selectedID = id
        defaults.set(id, forKey: MathRecognitionPreference.modelKey)
        loaded = nil
    }

    /// Deletes a model added from Files.
    func remove(_ model: InstalledMathModel) {
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
    func download(_ entry: MathModelCatalogEntry) {
        guard downloads[entry.id] == nil else { return }
        status[entry.id] = .downloading(done: 0, total: entry.downloadBytes)
        let root = self.root, session = self.session
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
            } catch let e as URLError where e.code == .cancelled {
                result = .notInstalled
            } catch {
                result = .failed(String(describing: error))
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

    func cancelDownload(_ entry: MathModelCatalogEntry) {
        downloads[entry.id]?.cancel()
    }

    /// Deletes the installed copy of `entry`.
    func remove(_ entry: MathModelCatalogEntry) {
        if loaded?.id == entry.id { loaded = nil }
        try? MathModelStore.remove(id: entry.id, root: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".compiled/\(entry.manifestSHA256)"))
        refresh()
    }

    /// The recogniser of the first installed model, loaded (and compiled,
    /// once) off the main actor.
    func recognizer() async throws -> any MathRecognizing {
        if let recognizerOverride { return recognizerOverride }
        if let loaded { return loaded.recognizer }
        let root = self.root, catalog = self.catalog, local = localFolder, preferred = selectedID
        let made: (String, any MathRecognizing) = try await Task.detached(priority: .userInitiated) {
            try Self.load(root: root, catalog: catalog, local: local, preferred: preferred)
        }.value
        loaded = made
        return made.1
    }

    enum Failure: Error, CustomStringConvertible {
        case noModel
        case unsupported
        var description: String {
            switch self {
            case .noModel: return String(localized: "No handwriting model is installed. Download one in Settings.",
                                         comment: "Convert to Math without a model")
            case .unsupported: return String(localized: "This device cannot run the handwriting model.",
                                             comment: "Convert to Math: Core ML unavailable")
            }
        }
    }

    nonisolated private static func load(root: URL, catalog: [MathModelCatalogEntry],
                                         local: URL?, preferred: String?) throws -> (String, any MathRecognizing) {
        #if canImport(CoreML)
        if let local {
            let m = try MathModelStore.manifest(in: local)
            try MathModelStore.verify(m, in: local)
            return (m.id, try CoreMLMathRecognizer(folder: local, manifest: m))
        }
        // Catalogue models must still match the catalogue's pin; models added from Files are checked
        // when added (the store's marker holds the manifest hash) and their sizes again here.
        var candidates: [InstalledMathModel] = []
        for entry in catalog {
            guard let (folder, m) = MathModelStore.installed(entry, root: root) else { continue }
            candidates.append(InstalledMathModel(manifest: m, manifestSHA256: entry.manifestSHA256, folder: folder))
        }
        let catalogIDs = Set(catalog.map(\.id))
        candidates += MathModelStore.installedModels(root: root).filter { !catalogIDs.contains($0.id) }
        guard let model = candidates.first(where: { $0.id == preferred }) ?? candidates.first else { throw Failure.noModel }
        let compiled = root.appendingPathComponent(".compiled", isDirectory: true).appendingPathComponent(model.manifestSHA256)
        return (model.id, try CoreMLMathRecognizer(folder: model.folder, manifest: model.manifest, compiledCache: compiled))
        #else
        throw Failure.unsupported
        #endif
    }
}

/// Fetches one URL to a local file (the app's only network use, and only
/// when the user asks for a model; tests use a fake).
protocol MathModelFetching: Sendable {
    /// Downloads `url` to a new temporary file and returns it; refuses more than `maxBytes`.
    func fetch(_ url: URL, maxBytes: Int64) async throws -> URL
}

struct URLSessionModelFetcher: MathModelFetching {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Tests pass a session whose configuration has a stub `URLProtocol`.
    var session: URLSession = .shared

    /// Streams the body to a temporary file and stops once it passes
    /// `maxBytes` (a server may send more than the manifest says; nothing
    /// past the limit reaches the disk).
    func fetch(_ url: URL, maxBytes: Int64) async throws -> URL {
        guard url.scheme == "https" else { throw Failure(description: "not an HTTPS URL") }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            throw Failure(description: "the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let tooLarge = Failure(description: "the file is larger than expected")
        guard response.expectedContentLength <= maxBytes else {
            bytes.task.cancel()
            throw tooLarge
        }
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("math-model-\(UUID().uuidString)")
        guard fm.createFile(atPath: file.path, contents: nil) else {
            bytes.task.cancel()
            throw Failure(description: "cannot create \(file.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var size: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            for try await byte in bytes {
                size += 1
                guard size <= maxBytes else {
                    bytes.task.cancel()
                    throw tooLarge
                }
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
        } catch {
            try? fm.removeItem(at: file)
            throw error
        }
        return file
    }
}

/// One model download, off the main actor: into a staging folder under the
/// store, checked file by file, then installed (`MathModelStore.install`).
enum MathModelDownload {
    static func run(_ entry: MathModelCatalogEntry, root: URL, session: MathModelFetching,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var backupFree = root
        try? backupFree.setResourceValues(values)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        guard let manifestURL = URL(string: entry.manifestURL), manifestURL.scheme == "https" else {
            throw MathModelManifest.Failure.malformed("the catalogue's manifest URL is not HTTPS")
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
