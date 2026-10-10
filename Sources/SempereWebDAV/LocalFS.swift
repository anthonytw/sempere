import Foundation
import Sempere

/// Atomic local writes: a half-written file never appears under its final name.
/// They follow the vault's own write contract (`FileIO`): temporary names
/// every listing ignores, `fsync` of the file and of its directory, and the
/// rename fallback where the file system has no hard links.
enum LocalFS {
    /// Writes `data` to a temporary file next to `url`, flushes it, and moves it
    /// into place. With `replacing` false an existing file is never touched
    /// (`FileIO.placeNew`) and the result is false.
    @discardableResult
    static func write(_ data: Data, to url: URL, replacing: Bool) throws -> Bool {
        let dir = url.deletingLastPathComponent()
        return try vault {
            try FileIO.createDirectory(dir)
            let tmp = FileIO.tempURL(in: dir)
            try FileIO.writeNewFile(tmp) { try $0(data) }
            if replacing {
                try FileIO.place(tmp, at: url)
                return true
            }
            return try placeNew(flushed: tmp, at: url)
        }
    }

    /// Flushes `tmp` and moves it to `url` without ever replacing an
    /// existing file (`FileIO.placeNew`: false then), then removes `tmp`. A
    /// file is never seen half-written under its final name.
    static func placeNew(_ tmp: URL, at url: URL) throws -> Bool {
        do {
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()
            try h.close()
        } catch {
            throw WebDAVError.io("flush \(tmp.path): \(error.localizedDescription)")
        }
        return try vault { try placeNew(flushed: tmp, at: url) }
    }

    private static func placeNew(flushed tmp: URL, at url: URL) throws -> Bool {
        do { try FileIO.placeNew(tmp, at: url) } catch VaultError.alreadyExists { return false }
        return true
    }

    /// Runs a `FileIO` step, reporting its `VaultError` as `WebDAVError.io`
    /// with the same sentence.
    private static func vault<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as VaultError { throw WebDAVError.io("\(e)") }
    }

    /// Size of a regular file; nil when missing or not a regular file.
    static func regularFileSize(_ url: URL) -> Int? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return (a[.size] as? NSNumber)?.intValue
    }

    /// The first `count` bytes of a file (fewer if it is shorter).
    static func prefix(of url: URL, count: Int) throws -> Data {
        do {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            return try h.read(upToCount: count) ?? Data()
        } catch {
            throw WebDAVError.io("read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Removes a file and flushes its directory (`FileIO.remove`).
    static func remove(_ url: URL) throws {
        try vault { try FileIO.remove(url) }
    }

    static func entries(_ dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        do { return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() } catch {
            throw WebDAVError.io("list \(dir.path): \(error.localizedDescription)")
        }
    }
}
