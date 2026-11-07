import Foundation
import Sempere
import TempDirSupport
import Testing

/// `DrawingCache`'s store: sealed entries named by key and bound to their note version, layouts without ink, the
/// least-recently-used trim and the folders of other vaults. (Opening notes through it is the app's
/// `DrawingCacheTests`.)
struct DrawingCacheStoreTests {
    static func tempDir() -> URL {
        TestTemp.root.appendingPathComponent("sempere-drawings-\(UUID().uuidString)")
    }

    /// The bundled sample vault, unlocked (read only).
    static func vault() throws -> Vault {
        let id = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
        return try Vault.open(at: FixtureTests.bundled("sample.sempere"), identities: [id])
    }


    @Test func entriesAreSealedNamedByKeyAndBoundToTheirVersion() throws {
        let root = Self.tempDir()
        let cache = try DrawingCache(root: root, vault: try Self.vault())
        let note = UUID(), page = UUID()
        let k1 = DrawingCache.Key(note: note, revisions: ["b", "a"])
        let k2 = DrawingCache.Key(note: note, revisions: ["a", "b", "c"])
        #expect(k1 == DrawingCache.Key(note: note, revisions: ["a", "b"]), "the revision order does not matter")
        cache.store(drawing: Data("ink".utf8), for: k1, page: page)
        #expect(cache.drawing(k1, page: page) == Data("ink".utf8))
        #expect(cache.drawing(k2, page: page) == nil, "another version misses")
        #expect(cache.drawing(k1, page: UUID()) == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(files.count == 1)
        let bytes = try Data(contentsOf: cache.directory.appendingPathComponent(files[0]))
        #expect(bytes.starts(with: DrawingCache.magic))
        #expect(bytes.range(of: Data("ink".utf8)) == nil, "encrypted")
        #expect(!files[0].contains(note.uuidString.lowercased()), "names say nothing")
        // A damaged file is a miss.
        var damaged = bytes
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: cache.directory.appendingPathComponent(files[0]))
        #expect(cache.drawing(k1, page: page) == nil)
    }

    @Test func layoutsKeepPagesWithoutInk() throws {
        let root = Self.tempDir()
        let vault = try Self.vault()
        let cache = try DrawingCache(root: root, vault: vault)
        let state = try vault.reconstruct(noteId: SampleFixture.lecture)
        let key = DrawingCache.Key(note: SampleFixture.lecture, revisions: ["x"])
        cache.store(DrawingCache.Layout(state), for: key)
        let layout = try #require(cache.layout(key))
        #expect(layout.state.pages.map(\.id) == state.pages.map(\.id))
        #expect(layout.state.pages.allSatisfy { $0.strokes.isEmpty })
        #expect(layout.strokeCounts == Dictionary(uniqueKeysWithValues: state.pages.map { ($0.id, $0.strokes.count) }))
        #expect(layout.state.meta == state.meta)
    }

    /// Least recently used files go first once the cap is passed. The cache's clock is stepped by hand
    /// (10 s per use), so the order never depends on the file system's timestamp resolution or the runner's speed.
    @Test func theCacheIsTrimmedLeastRecentlyUsedFirst() throws {
        let root = Self.tempDir()
        let tick = StepClock()
        let cache = try DrawingCache(root: root, vault: try Self.vault(), capBytes: 1 << 20, clock: { tick.next() })
        let note = UUID()
        let blob = Data(repeating: 7, count: 300 << 10)
        let pages = (0..<3).map { _ in UUID() }
        let key = DrawingCache.Key(note: note, revisions: ["r"])
        for p in pages { cache.store(drawing: blob, for: key, page: p) }
        #expect(cache.drawing(key, page: pages[0]) != nil)   // a use: now the most recent
        cache.store(drawing: blob, for: key, page: UUID())   // over the cap
        #expect(cache.totalBytes <= 1 << 20)
        #expect(cache.drawing(key, page: pages[0]) != nil, "recently used: kept")
        #expect(cache.drawing(key, page: pages[1]) == nil, "least recently used: gone")
    }

    /// Opening the cache of one vault deletes every other folder (other
    /// vaults, or this vault under an earlier secret).
    @Test func otherFoldersAreDeleted() throws {
        let root = Self.tempDir()
        let stale = root.appendingPathComponent("0123456789abcdef0123456789abcdef")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale.appendingPathComponent("x.page"))
        let cache = try DrawingCache(root: root, vault: try Self.vault())
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [cache.directory.lastPathComponent])
    }
}

/// A clock that moves 10 s on every reading.
private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func next() -> Date { lock.withLock { t += 10; return t } }
}
