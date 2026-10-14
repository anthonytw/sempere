import Foundation
import Sempere
import Testing
@testable import SempereApp

/// iCloud placeholders for the blobs in notes' `att/` folders: each one is
/// evicted to `.<name>.icloud` and comes back when requested.
final class FakeBlobCloud: @unchecked Sendable {
    let vault: URL
    private let lock = NSLock()
    private var held: [URL: Data] = [:]
    private var requests: [String] = []
    /// Deliver a blob the moment it is requested.
    var autoDeliver = true

    init(vault: URL) { self.vault = vault }

    func attURL(_ note: UUID) -> URL { CloudScan.attachmentFolder(inVault: vault, id: note) }

    /// Every blob of the note becomes a placeholder.
    func evictBlobs(of note: UUID) throws {
        let dir = attURL(note)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".age") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            lock.withLock { held[url.standardizedFileURL] = data }
            try FileManager.default.removeItem(at: url)
            try Data().write(to: CloudPlaceholder.placeholderURL(for: url))
        }
    }

    /// The note's `att/` exists, but iCloud has not listed what is in it.
    func unlistBlobs(of note: UUID) throws {
        let dir = attURL(note)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            if !name.hasPrefix(".") { lock.withLock { held[url.standardizedFileURL] = try? Data(contentsOf: url) } }
            try FileManager.default.removeItem(at: url)
        }
    }

    func deliver(_ url: URL) {
        let key = url.standardizedFileURL
        guard let data = lock.withLock({ held.removeValue(forKey: key) }) else { return }
        try? data.write(to: key, options: .atomic)   // never a half-written file a concurrent read could see
        try? FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: key))
    }

    /// File names requested, in order.
    var requested: [String] { lock.withLock { requests } }

    var hooks: CloudVault.Hooks {
        CloudVault.Hooks(isUbiquitous: { _ in true }, state: { CloudVault.state(of: $0) }, request: { [self] item in
            lock.withLock { requests.append(item.url.lastPathComponent) }
            if autoDeliver { deliver(item.url) }
        })
    }
}

/// Lazy, per-kind download of a note's `att/` (docs/attachments.md §4):
/// revisions alone define a note (an evicted or unlisted `att/` never makes
/// it pending), images and PDF pages are requested when a page shows them,
/// other kinds only when used, and a blob is read only once it is local.
@MainActor
struct AttachmentCloudTests {
    static let lecture = AppModelTests.lecture

    /// The fixture with an image and an audio blob in the lecture, referenced by an item.
    static func vaultWithBlobs() throws -> (url: URL, key: URL, image: BlobRef, audio: BlobRef) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let image = try vault.writeBlob(note: lecture, AttachmentEditorTests.png(), type: "image/png")
        let audio = try vault.writeBlob(note: lecture, Data(repeating: 1, count: 500), type: "audio/mp4")
        let page = try #require(try vault.reconstruct(noteId: lecture).pages.first).id
        _ = try vault.apply([.addItem(page: page, item: AttachmentEditorTests.imageItem(image))], to: lecture,
                            deviceState: TS.deviceStateURL(), app: "test/1")
        return (url, key, image, audio)
    }

    @Test func revisionListingsNeverLookInAtt() throws {
        let (url, _, _, _) = try Self.vaultWithBlobs()
        let items = try CloudScan.noteItems(inVault: url, id: Self.lecture)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.url.path.contains("/att/") })
        #expect(try CloudScan.items(inVault: url).allSatisfy { !$0.url.path.contains("/att/") })
    }

    @Test func anEvictedOrUnlistedAttNeverMakesANotePending() throws {
        let (url, _, _, _) = try Self.vaultWithBlobs()
        let cloud = FakeBlobCloud(vault: url)
        try cloud.evictBlobs(of: Self.lecture)
        try CloudVault.requireLocal(note: Self.lecture, vault: url, hooks: cloud.hooks)
        var pass = try ProgressiveLoad.pass(vault: url, hooks: cloud.hooks)
        #expect(pass.pending.isEmpty)
        #expect(pass.ready.contains(Self.lecture))
        #expect(cloud.requested.isEmpty, "nothing in att/ was asked for")
        // An att/ folder iCloud has listed empty (its files not yet known).
        let (unlistedURL, _, _, _) = try Self.vaultWithBlobs()
        let unlisted = FakeBlobCloud(vault: unlistedURL)
        try unlisted.unlistBlobs(of: Self.lecture)
        try CloudVault.requireLocal(note: Self.lecture, vault: unlistedURL, hooks: unlisted.hooks)
        pass = try ProgressiveLoad.pass(vault: unlistedURL, hooks: unlisted.hooks)
        #expect(pass.pending.isEmpty)
        #expect(pass.unlisted.isEmpty)
        #expect(unlisted.requested.isEmpty)
    }

    @Test func blobListingsGiveKindsAndPlaceholders() throws {
        let (url, _, image, audio) = try Self.vaultWithBlobs()
        let cloud = FakeBlobCloud(vault: url)
        try cloud.evictBlobs(of: Self.lecture)
        try Data().write(to: cloud.attURL(Self.lecture).appendingPathComponent("not-a-blob.age"))
        let listed = try CloudScan.blobItems(inVault: url, id: Self.lecture)
        #expect(listed.allSatisfy { $0.item.placeholder })
        let kinds = Set(listed.map(\.kind))
        #expect(kinds.contains(.image) && kinds.contains(.audio))
        #expect(!listed.contains { $0.item.url.lastPathComponent == "not-a-blob.age" })
        #expect(image.kind == .image && audio.kind == .audio)
        #expect(try CloudScan.blobItems(inVault: url, id: UUID()).isEmpty, "no att/: nothing")
    }

    @Test func onlyImagesAndPDFPagesComeWithThePage() {
        let image = BlobRef(content: Data("i".utf8), type: "image/jpeg")
        let pdf = BlobRef(content: Data("p".utf8), type: "application/pdf")
        let other = BlobRef(content: Data("x".utf8), type: "application/x-thing")
        let items: [Item] = [
            .image(blob: image, pixelSize: Size(w: 1, h: 1), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "b"),
            .image(blob: image, pixelSize: Size(w: 1, h: 1), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "c"),
            .pdfPage(blob: pdf, pageIndex: 0, pageSize: Size(w: 1, h: 1), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "a"),
            Item(kind: ItemKind(rawValue: "video"), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "d"),
            .image(blob: other, pixelSize: Size(w: 1, h: 1), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "e"),
        ]
        #expect(BlobFetchPolicy.prefetch(for: items) == [pdf, image], "background first, each once, no bin")
        #expect(BlobFetchPolicy.fetchesWithPage(.image) && BlobFetchPolicy.fetchesWithPage(.pdf))
        #expect(!BlobFetchPolicy.fetchesWithPage(.audio) && !BlobFetchPolicy.fetchesWithPage(.transcript)
                && !BlobFetchPolicy.fetchesWithPage(.video))
    }

    @Test func aBlobIsReadOnlyOnceLocal() async throws {
        let (url, key, image, _) = try Self.vaultWithBlobs()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let cloud = FakeBlobCloud(vault: url)
        cloud.autoDeliver = false
        try cloud.evictBlobs(of: Self.lecture)
        let name = try vault.blobFileName(for: image)
        #expect(throws: CloudVault.CloudError.blobNotLocal(name: name)) {
            try CloudVault.requireBlob(note: Self.lecture, fileName: name, vault: url, hooks: cloud.hooks)
        }
        // A download waits until iCloud delivers the file.
        let wait = Task {
            try await CloudVault.downloadBlob(note: Self.lecture, fileName: name, vault: url, hooks: cloud.hooks,
                                              stallTimeout: .seconds(5), pollInterval: .milliseconds(10))
        }
        #expect(await TS.waitUntil { cloud.requested == [name] })
        cloud.deliver(cloud.attURL(Self.lecture).appendingPathComponent(name))
        try await wait.value
        try CloudVault.requireBlob(note: Self.lecture, fileName: name, vault: url, hooks: cloud.hooks)
        #expect(try vault.readBlob(note: Self.lecture, image) == AttachmentEditorTests.png())
        // A name that is not there at all is not waited for (the read reports it missing).
        try CloudVault.requireBlob(note: Self.lecture, fileName: String(repeating: "0", count: 64) + ".image.age",
                                   vault: url, hooks: cloud.hooks)
    }

    @Test func theModelFetchesOnlyTheBlobsItDraws() async throws {
        let (url, key, image, audio) = try Self.vaultWithBlobs()
        let cloud = FakeBlobCloud(vault: url)
        try cloud.evictBlobs(of: Self.lecture)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudIdleInterval = .milliseconds(20)
        model.blobCacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await model.openVault(at: url)
        #expect(model.isCloudVault)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let vault = try #require(model.vault)
        // Showing a page asks for its image, not for the audio.
        let state = try vault.reconstruct(noteId: Self.lecture)
        model.prefetchBlobs(note: Self.lecture, items: state.pages.flatMap(\.items))
        let imageName = try vault.blobFileName(for: image), audioName = try vault.blobFileName(for: audio)
        #expect(await TS.waitUntil { cloud.requested.contains(imageName) })
        #expect(!cloud.requested.contains(audioName))
        // Drawing it reads it through the cache, downloaded first.
        let cache = try #require(model.attachmentCache())
        let file = try await cache.acquire(note: Self.lecture, ref: image)
        #expect(try Data(contentsOf: file) == AttachmentEditorTests.png())
        await cache.release(note: Self.lecture, ref: image)
        #expect(!cloud.requested.contains(audioName), "audio waits until it is played")
        model.close()
    }

    /// Adding content the note already has as an evicted blob: the blob is
    /// downloaded and reused, never written a second time under its
    /// write-once name next to iCloud's placeholder.
    @Test func addingContentWhoseBlobIsEvictedDownloadsAndReusesIt() async throws {
        let (url, key, image, _) = try Self.vaultWithBlobs()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let name = try Vault.open(at: url, identities: [identity]).blobFileName(for: image)
        let cloud = FakeBlobCloud(vault: url)
        let file = cloud.attURL(Self.lecture).appendingPathComponent(name)
        let original = try Data(contentsOf: file)
        try cloud.evictBlobs(of: Self.lecture)
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudIdleInterval = .milliseconds(20)
        model.blobCacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        let editor = try #require(model.editor)
        #expect(editor.prepareBlobWrite != nil)
        let page = try #require(editor.currentPage).id
        let item = try await editor.addAttachment(data: AttachmentEditorTests.png(), type: "image/png", on: page) {
            AttachmentEditorTests.imageItem($0)
        }
        #expect(item.blob == image)
        #expect(cloud.requested.contains(name), "the evicted copy was downloaded first")
        #expect(try Data(contentsOf: file) == original, "the write-once blob was reused, not rewritten")
        let names = try FileManager.default.contentsOfDirectory(atPath: cloud.attURL(Self.lecture).path)
        #expect(!names.contains(".\(name).icloud"), "no placeholder left beside a second copy")
        #expect(try BlobPlanning.ref(ofFile: file, type: "x").size == Int64(original.count))
        model.close()
    }
}
