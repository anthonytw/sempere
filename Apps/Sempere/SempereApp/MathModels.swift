import Foundation
import Sempere
import SempereAppCore
import SempereRender

extension MathModels {
    /// The model store of this app: models in Application Support, the `URLSession` fetcher, Core ML to read
    /// with, and the app's words for failures.
    static let shared = MathModels(localFolder: debugFolder, session: URLSessionModelFetcher(),
                                   defaults: UserDefaults.standard, describe: { AppModel.describe($0) }, loader: coreMLLoader)

    /// `SEMPERE_DEBUG_MATH_MODEL` (DEBUG builds): a converted model folder to
    /// use without a catalog entry (`~/` is the app's data container).
    nonisolated static var debugFolder: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["SEMPERE_DEBUG_MATH_MODEL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst(1) : path, isDirectory: true)
        #else
        return nil
        #endif
    }

    /// Core ML reads the chosen model (compiled once, into the choice's cache).
    nonisolated static let coreMLLoader: Loader = { choice in
        #if canImport(CoreML)
        switch choice {
        case .folder(let folder, let manifest):
            return try CoreMLMathRecognizer(folder: folder, manifest: manifest)
        case .installed(let model, let compiled):
            return try CoreMLMathRecognizer(folder: model.folder, manifest: model.manifest, compiledCache: compiled)
        }
        #else
        throw MathModels.Failure.unsupported
        #endif
    }

    /// "That model cannot be added: why" for Settings.
    static func importFailureText(_ why: String) -> String {
        String(localized: "That model cannot be added: \(why)",
               comment: "Settings ▸ Handwritten Math: Add Model from Files failed; the reason follows (English)")
    }
}

extension MathModels.Failure: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .noModel: return String(localized: "No handwriting model is installed. Download one in Settings.",
                                     comment: "Convert to Math without a model")
        case .unsupported: return String(localized: "This device cannot run the handwriting model.",
                                         comment: "Convert to Math: Core ML unavailable")
        }
    }
}

/// Fetches one URL to a local file (the app's only network use, and only
/// when the user asks for a model; tests use a fake).
/// The app's fetcher: `URLSession` is the platform part (`MathModelDownload` in SempereAppCore does the checking).
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
        do {
            return try await download(url, maxBytes: maxBytes)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }
    }

    private func download(_ url: URL, maxBytes: Int64) async throws -> URL {
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
