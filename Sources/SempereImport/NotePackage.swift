import Foundation
import Sempere

/// The files of one package (an importer's `.note`, say): a zip (the usual form) or
/// an unzipped package directory. Paths are `/`-separated and relative to the
/// package root.
public struct NotePackage {
    /// Every file path in the package.
    public let paths: [String]
    private let reader: (String, UInt64) throws -> Data
    private let failures = Failures()

    /// Most bytes all reads of an unzipped package directory may return
    /// together, repeated reads included (a zip has its own
    /// `ZipArchive.readBudget`): twice the attachments one note may hold.
    public static let directoryReadBudget: UInt64 = 4 << 30

    /// Paths whose read failed, with the error: asked again, they fail at
    /// once instead of reading (and inflating) the same bytes again
    /// (security review S18). Shared by copies of the package.
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [String: any Error] = [:]
        subscript(path: String) -> (any Error)? {
            get { lock.lock(); defer { lock.unlock() }; return errors[path] }
            set { lock.lock(); defer { lock.unlock() }; errors[path] = newValue }
        }
    }

    /// The running total behind `directoryReadBudget`.
    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var left: UInt64
        init(_ total: UInt64) { left = total }
        var remaining: UInt64 { lock.lock(); defer { lock.unlock() }; return left }
        func take(_ n: UInt64) { lock.lock(); defer { lock.unlock() }; left -= min(n, left) }
    }

    /// Wraps a package already opened as a zip.
    public init(zip: ZipArchive) {
        let files = zip.entries.filter { !$0.isDirectory }
        paths = files.map(\.path)
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        reader = { path, maxSize in
            guard let e = byPath[path] else { throw ImportError.package("no \(path) in package") }
            return try zip.read(e, maxSize: maxSize)
        }
    }

    /// Reads a package from `.note` file bytes (a zip).
    ///
    /// - Throws: `ImportError.zip` when the bytes are not a zip.
    public init(data: Data) throws {
        self.init(zip: try ZipArchive(data: data))
    }

    /// Reads an unzipped package directory.
    ///
    /// - Throws: `ImportError.io` when the directory cannot be listed.
    public init(directory: URL) throws {
        let base = directory.standardizedFileURL.pathComponents
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ImportError.io("cannot list \(directory.path)")
        }
        var found: [String] = []
        for case let f as URL in walker {
            // Regular files only: no symlinks (a shared package must not pull
            // in files from elsewhere), devices or FIFOs.
            let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            found.append(f.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/"))
        }
        paths = found.sorted()
        let budget = Budget(Self.directoryReadBudget)
        reader = { path, maxSize in
            let left = budget.remaining
            let url = directory.appendingPathComponent(path)
            let data: Data
            do { data = try Self.readFile(url, maxSize: min(maxSize, left)) } catch {
                if left < maxSize { throw ImportError.io("\(url.path): over the \(Self.directoryReadBudget >> 20) MiB read from this package in all") }
                throw error
            }
            budget.take(UInt64(data.count))
            return data
        }
    }

    /// The bytes of `path`, at most `maxSize` of them. A path whose read
    /// failed before fails again without being read.
    public func read(_ path: String, maxSize: UInt64 = ZipArchive.defaultMaxEntrySize) throws -> Data {
        if let e = failures[path] { throw e }
        do { return try reader(path, maxSize) } catch {
            // A smaller `maxSize` may refuse what a larger one accepts: only
            // failures at the default size are remembered.
            if maxSize >= ZipArchive.defaultMaxEntrySize { failures[path] = error }
            throw error
        }
    }

    /// Reads a whole file, refusing one larger than `maxSize` before
    /// allocating for it (a file in a shared folder can be any size).
    static func readFile(_ url: URL, maxSize: UInt64) throws -> Data {
        do {
            let h = try BoundedRead.openRegularFile(url)
            defer { try? h.close() }
            let data = try h.read(upToCount: Int(min(maxSize, UInt64(Int.max - 1))) + 1) ?? Data()
            guard UInt64(data.count) <= maxSize else {
                throw ImportError.io("\(url.path) is larger than the \(maxSize)-byte limit")
            }
            return data
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// True when the package holds `path`.
    public func contains(_ path: String) -> Bool { paths.contains(path) }
}
