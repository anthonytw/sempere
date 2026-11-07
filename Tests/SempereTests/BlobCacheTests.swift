import Foundation
import Sempere
import TempDirSupport
import Testing

/// Counts fetches and hands out given content (thread-safe).
fileprivate final class FakeBlobStore: @unchecked Sendable {
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
        #expect(await waitUntil { await gate.arrivals >= 1 })
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
        #expect(await waitUntil { await gate.arrivals >= 1 })
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

// MARK: - Across launches (moved from the app's AttachmentPersistenceTests)

/// TestFlight build 6: reopening a note with PDF pages was as slow as the first open. Decrypted blobs outlive a
/// note being closed and the app being quit, keyed by the vault secret, checked before use. (The model's folder per
/// vault and the Mac's no-data-protection launches are the app's `AttachmentPersistenceTests`.)
struct BlobCacheAcrossLaunchesTests {
    static func root() -> URL {
        TestTemp.root.appendingPathComponent("persist-" + UUID().uuidString, isDirectory: true)
    }

    /// The bundled sample vault, unlocked (read only).
    static func fixtureVault() throws -> Vault {
        let id = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
        return try Vault.open(at: FixtureTests.bundled("sample.sempere"), identities: [id])
    }

    let note = SampleFixture.lecture

    @Test func aNewCacheOnTheSameFolderAdoptsVerifiedFilesInsteadOfFetching() async throws {
        let key = try LocalCacheKey(vault: try Self.fixtureVault(), purpose: "blob-cache", magic: [1])
        let store = FakeBlobStore()
        let ref = store.put(Data(repeating: 9, count: 5000), type: "application/pdf")
        let root = Self.root()
        let first = BlobCache(root: root, naming: BlobCache.keyedNaming(key), fetch: store.fetch)
        let url = try await first.acquire(note: note, ref: ref)
        await first.release(note: note, ref: ref)
        #expect(await first.fetchCount == 1)
        #expect(url.pathExtension == "pdf")
        #expect(!url.lastPathComponent.contains(ref.sha256), "names say nothing without the vault secret")
        #expect(!url.lastPathComponent.contains(note.uuidString.lowercased()))

        // Next launch: same folder, a new cache. The file is hashed, then used.
        let second = BlobCache(root: root, naming: BlobCache.keyedNaming(key), fetch: store.fetch)
        #expect(await second.contains(note: note, ref: ref), "listed from the folder")
        let again = try await second.acquire(note: note, ref: ref)
        // The same file (the listing may name it through /private on macOS, where the temp folder is a symlink).
        #expect(again.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        #expect(await second.fetchCount == 0)
        #expect(await second.adoptedCount == 1)
        #expect(store.fetchLog.count == 1, "not decrypted again")
        // Once checked, later uses do not hash it again.
        _ = try await second.acquire(note: note, ref: ref)
        #expect(await second.adoptedCount == 1)
    }

    @Test func aChangedFileFromAnEarlierLaunchIsFetchedAgain() async throws {
        let store = FakeBlobStore()
        let ref = store.put(Data("original content".utf8))
        let root = Self.root()
        let first = BlobCache(root: root, fetch: store.fetch)
        let url = try await first.acquire(note: note, ref: ref)
        try Data("tampered content".utf8).write(to: url)   // same size, other bytes
        let second = BlobCache(root: root, fetch: store.fetch)
        let fresh = try await second.acquire(note: note, ref: ref)
        #expect(try Data(contentsOf: fresh) == Data("original content".utf8))
        #expect(await second.fetchCount == 1)
        #expect(await second.adoptedCount == 0)
        // Leftovers of an interrupted fetch are removed when the folder is listed.
        try Data("x".utf8).write(to: root.appendingPathComponent(".tmp-leftover"))
        let third = BlobCache(root: root, fetch: store.fetch)
        _ = await third.contains(note: note, ref: ref)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".tmp-leftover").path))
    }

    @Test func filesOfEarlierLaunchesCountTowardsTheLimitOldestFirst() async throws {
        let store = FakeBlobStore()
        let refs = (0..<3).map { store.put(Data(repeating: UInt8($0), count: 100)) }
        let root = Self.root()
        let first = BlobCache(root: root, fetch: store.fetch)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (i, ref) in refs.enumerated() {
            let file = try await first.acquire(note: note, ref: ref)
            await first.release(note: note, ref: ref)
            // Distinct modification dates, set outright: no sleeping for the file system's clock to tick.
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(Double(i) * 10)], ofItemAtPath: file.path)
        }
        let second = BlobCache(root: root, maxBytes: 250, fetch: store.fetch)
        #expect(!(await second.contains(note: note, ref: refs[0])), "the least recently used went")
        #expect(await second.contains(note: note, ref: refs[2]))
        #expect(await second.totalBytes <= 250)
    }

    /// Security review 2026-10 stage 4, S12: a transcript drawn on an audio card was released without
    /// `discard` and stayed in the cache (across launches on iOS), and a recording a killed session was
    /// playing was adopted by the next launch. Recordings, clips and transcripts now never stay.
    @Test func transcriptsAndRecordingsNeverStayInTheCache() async throws {
        let store = FakeBlobStore()
        let transcript = store.put(Data(#"{"text":"secret words"}"#.utf8), type: BlobRef.transcriptType)
        let audio = store.put(Data(repeating: 7, count: 4000), type: "audio/mp4")
        let video = store.put(Data(repeating: 8, count: 4000), type: "video/mp4")
        let image = store.put(Data(repeating: 9, count: 4000), type: "image/png")
        let root = Self.root()
        let cache = BlobCache(root: root, fetch: store.fetch)
        for ref in [transcript, audio, video] {
            let url = try await cache.acquire(note: note, ref: ref)
            #expect(FileManager.default.fileExists(atPath: url.path))
            await cache.release(note: note, ref: ref)   // no `discard`, as the audio card did
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(ref.type)")
            #expect(await !cache.contains(note: note, ref: ref))
        }
        // Other attachments are kept for later, as before.
        let kept = try await cache.acquire(note: note, ref: image)
        await cache.release(note: note, ref: image)
        #expect(FileManager.default.fileExists(atPath: kept.path))

        // Killed while a recording played and a transcript was read: the next launch deletes both.
        let playing = try await cache.acquire(note: note, ref: audio)
        let reading = try await cache.acquire(note: note, ref: transcript)
        let next = BlobCache(root: root, fetch: store.fetch)
        #expect(await !next.contains(note: note, ref: audio))
        #expect(await !next.contains(note: note, ref: transcript))
        #expect(!FileManager.default.fileExists(atPath: playing.path))
        #expect(!FileManager.default.fileExists(atPath: reading.path))
        #expect(await next.contains(note: note, ref: image), "an image is still adopted after its check")
    }

    /// Security review 2026-10 stage 4, S11: on a Mac (no data protection) decrypted attachments were deleted
    /// only once a later launch unlocked a vault and used an attachment. A quit deletes them, and a launch
    /// after a crash deletes them before any vault opens.
    @Test func withoutDataProtectionQuitAndLaunchDeleteEveryDecryptedFile() async throws {
        let blobs = Self.root()
        let fm = FileManager.default
        func plant() throws -> URL {
            let dir = blobs.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("doc.pdf")
            try Data("plaintext".utf8).write(to: file)
            return file
        }
        func regularFiles() -> [String] {
            (fm.enumerator(atPath: blobs.path)?.allObjects as? [String] ?? []).filter {
                var dir: ObjCBool = false
                return fm.fileExists(atPath: blobs.appendingPathComponent($0).path, isDirectory: &dir) && !dir.boolValue
            }
        }
        // Where files are protected at rest (iOS), both keep the cache.
        let kept = try plant()
        BlobCache.purgeAtLaunch(in: blobs, keepsAcrossLaunches: true)
        BlobCache.purgeAtQuit(in: blobs, keepsAcrossLaunches: true)
        #expect(fm.fileExists(atPath: kept.path))
        // A Mac launch: nothing of an earlier session is left in a vault's folder once it returns.
        BlobCache.purgeAtLaunch(in: blobs, keepsAcrossLaunches: false)
        #expect(!fm.fileExists(atPath: kept.path))
        #expect(await waitUntil { regularFiles().isEmpty })
        // A Mac quit: deleted at once.
        let quit = try plant()
        BlobCache.purgeAtQuit(in: blobs, keepsAcrossLaunches: false)
        #expect(!fm.fileExists(atPath: quit.path))
        #expect(!fm.fileExists(atPath: blobs.path))
    }
}

/// Holds async work at a point until the test opens it.
fileprivate actor Gate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    /// Closes the gate: later `pass()` calls wait for `open()`.
    func close() { isOpen = false }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters = []
    }

    func pass() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Polls an async `condition` every 10 ms until it holds or `timeout` passes.
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
