import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Counts fetches and hands out given content (thread-safe).
final class FakeBlobStore: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data] = [:]
    private var fetched: [String] = []
    /// Fetches wait for this gate when set.
    var gate: Gate?
    var failWith: (any Error)?

    func put(_ data: Data, type: String = "image/png") -> BlobRef {
        let ref = BlobRef(content: data, type: type)
        lock.withLock { contents[ref.sha256] = data }
        return ref
    }

    var fetchLog: [String] { lock.withLock { fetched } }

    var fetch: BlobCache.Fetch {
        { [self] _, ref, destination in
            if let gate { await gate.pass() }
            lock.withLock { fetched.append(ref.sha256) }
            if let failWith { throw failWith }
            let data = lock.withLock { contents[ref.sha256] }
            try BlobCache.writeFile(destination) { write in
                guard let data else { throw BlobError.missing(ref.sha256) }
                try write(data)
            }
        }
    }
}

/// `BlobCache`: verified files fetched once, pinned while used, least
/// recently used ones dropped beyond the limits, all deleted by `clear`;
/// `CachedBlobSource` checks content against the reference.
struct BlobCacheTests {
    static func root() -> URL {
        TestTemp.root.appendingPathComponent("blobcache-" + UUID().uuidString, isDirectory: true)
    }

    let note = UUID()

    @Test func fetchesOnceAndServesTheFile() async throws {
        let store = FakeBlobStore()
        let ref = store.put(Data("hello".utf8))
        let cache = BlobCache(root: Self.root(), fetch: store.fetch)
        let a = try await cache.acquire(note: note, ref: ref)
        let b = try await cache.acquire(note: note, ref: ref)
        #expect(a == b)
        #expect(try Data(contentsOf: a) == Data("hello".utf8))
        #expect(store.fetchLog.count == 1)
        let mode = (try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // Per note: the same content in another note is fetched through that note.
        _ = try await cache.acquire(note: UUID(), ref: ref)
        #expect(store.fetchLog.count == 2)
    }

    /// Recordings and transcripts: their plaintext stays only while in use.
    /// A `discard` release deletes the file once its last use ends; images
    /// and PDFs (plain release) stay cached.
    @Test func aDiscardReleaseDeletesTheFileOnceUnused() async throws {
        let store = FakeBlobStore()
        let audio = store.put(Data(repeating: 1, count: 100), type: "audio/mp4")
        let image = store.put(Data(repeating: 2, count: 100))
        let cache = BlobCache(root: Self.root(), fetch: store.fetch)
        let a = try await cache.acquire(note: note, ref: audio)
        _ = try await cache.acquire(note: note, ref: audio)   // played and transcribed at once
        await cache.release(note: note, ref: audio, discard: true)
        #expect(FileManager.default.fileExists(atPath: a.path), "still in use")
        await cache.release(note: note, ref: audio, discard: true)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(await !cache.contains(note: note, ref: audio))
        let i = try await cache.acquire(note: note, ref: image)
        await cache.release(note: note, ref: image)
        #expect(FileManager.default.fileExists(atPath: i.path))
        // Asked for again, the audio is fetched again (verified), not served from a deleted path.
        let again = try await cache.acquire(note: note, ref: audio)
        #expect(try Data(contentsOf: again) == Data(repeating: 1, count: 100))
        #expect(store.fetchLog.filter { $0 == audio.sha256 }.count == 2)
    }

    @Test func concurrentRequestsShareOneFetch() async throws {
        let store = FakeBlobStore()
        let ref = store.put(Data(repeating: 7, count: 1000))
        let gate = Gate()
        await gate.close()
        store.gate = gate
        let cache = BlobCache(root: Self.root(), fetch: store.fetch)
        let note = self.note
        async let first = cache.acquire(note: note, ref: ref)
        async let second = cache.acquire(note: note, ref: ref)
        #expect(await TS.waitUntilAsync { await gate.arrivals >= 1 })
        await gate.open()
        let (x, y) = try await (first, second)
        #expect(x == y)
        #expect(await cache.fetchCount == 1)
    }

    @Test func failedOrWrongSizedFetchesLeaveNothing() async throws {
        let store = FakeBlobStore()
        let root = Self.root()
        let cache = BlobCache(root: root, fetch: store.fetch)
        let missing = BlobRef(content: Data("absent".utf8), type: "image/png")
        await #expect(throws: BlobError.self) { try await cache.acquire(note: note, ref: missing) }
        let ref = store.put(Data("12345".utf8))
        let lying = BlobRef(sha256: ref.sha256, size: 99, type: ref.type)
        await #expect(throws: BlobCache.CacheError.sizeMismatch) { try await cache.acquire(note: note, ref: lying) }
        await #expect(throws: BlobCache.CacheError.invalidReference) {
            try await cache.acquire(note: note, ref: BlobRef(sha256: "xyz", size: 1, type: "image/png"))
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(left.isEmpty, "\(left)")
        #expect(await cache.count == 0)
    }

    @Test func leastRecentlyUsedUnpinnedFilesGo() async throws {
        let store = FakeBlobStore()
        let refs = (0..<4).map { store.put(Data(repeating: UInt8($0), count: 100)) }
        let cache = BlobCache(root: Self.root(), maxBytes: 250, fetch: store.fetch)
        let first = try await cache.acquire(note: note, ref: refs[0])   // stays pinned
        for ref in refs[1...] {
            _ = try await cache.acquire(note: note, ref: ref)
            await cache.release(note: note, ref: ref)
        }
        #expect(await cache.totalBytes <= 250)
        #expect(await cache.contains(note: note, ref: refs[0]), "in use: kept")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(!(await cache.contains(note: note, ref: refs[1])), "least recently used: dropped")
        #expect(await cache.contains(note: note, ref: refs[3]))
        await cache.release(note: note, ref: refs[0])
        _ = try await cache.acquire(note: note, ref: refs[1])
        #expect(!(await cache.contains(note: note, ref: refs[0])), "released and oldest: dropped")
    }

    @Test func clearDeletesEverythingAndDropsLateFetches() async throws {
        let store = FakeBlobStore()
        let a = store.put(Data("a".utf8)), b = store.put(Data("b".utf8))
        let root = Self.root()
        let cache = BlobCache(root: root, fetch: store.fetch)
        let file = try await cache.acquire(note: note, ref: a)
        let gate = Gate()
        await gate.close()
        store.gate = gate
        let note = self.note
        let late = Task { try await cache.acquire(note: note, ref: b) }
        #expect(await TS.waitUntilAsync { await gate.arrivals >= 1 })
        await cache.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await gate.open()
        await #expect(throws: (any Error).self) { try await late.value }
        #expect(await cache.count == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path) ||
                ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }

    /// A cleared cache fetches nothing more: a view that still holds it must
    /// not decrypt with the old vault into a folder nothing deletes.
    @Test func aClearedCacheFetchesNothingMore() async throws {
        let store = FakeBlobStore()
        let a = store.put(Data("a".utf8))
        let root = Self.root()
        let cache = BlobCache(root: root, fetch: store.fetch)
        await cache.clear()
        let note = self.note
        await #expect(throws: BlobCache.CacheError.cleared) { _ = try await cache.acquire(note: note, ref: a) }
        #expect(store.fetchLog.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path), "no folder recreated")
    }

    @Test func cachedSourceChecksContent() throws {
        let data = Data("content".utf8)
        let ref = BlobRef(content: data, type: "image/png")
        let file = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        let source = CachedBlobSource(files: [ref.sha256: file])
        #expect(try source.data(for: ref, maxBytes: 100) == data)
        #expect(throws: BlobError.contentTooLarge(limit: 3)) { try source.data(for: ref, maxBytes: 3) }
        try Data("tampered".utf8).write(to: file)
        #expect(throws: BlobError.referenceMismatch) { try source.data(for: ref, maxBytes: 100) }
        #expect(throws: BlobError.missing(String(repeating: "0", count: 64))) {
            try source.data(for: BlobRef(sha256: String(repeating: "0", count: 64), size: 1, type: "x"), maxBytes: 10)
        }
        #expect(try source.withFile(for: ref) { $0 } == file)
    }
}

extension TS {
    /// Polls an async `condition` every 10 ms until it holds or `timeout` passes.
    static func waitUntilAsync(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
