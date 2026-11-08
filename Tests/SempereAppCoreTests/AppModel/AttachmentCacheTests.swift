import Age
import Foundation
import Sempere
import SempereAppCore
import SempereRender
import TempDirSupport
import Testing

extension AppModelSuites {
    /// The open vault's attachment caches and the item clipboard (`AppModel+Attachments`, wave 5b part 3): the
    /// decrypted blobs, the drawn ones (`RenderStore`), and copy and paste, all forgotten with the vault.
    @MainActor
    struct AttachmentCacheTests {
        static let lecture = ModelFixture.lecture

        func unlockedModel() async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            return model
        }

        @Test func theClipboardPastesBesideTheCopyAndTheVaultsCachesGoWithIt() async throws {
            let model = try await unlockedModel()
            model.selectedNoteID = Self.lecture
            try await model.openEditor(for: Self.lecture)
            let editor = try #require(model.editor)
            let page = try #require(editor.currentPage).id
            let image = try await editor.addAttachment(data: AttachmentIndexTests.png, type: "image/png", on: page) {
                .image(blob: $0, pixelSize: Size(w: 1, h: 1), frame: Rect(x: 40, y: 50, w: 120, h: 90), z: "a")
            }
            #expect(model.clipboardPaste(onto: page, of: editor)?.offset == nil, "nothing copied")
            model.itemClipboard.copy([image], from: editor.noteID)
            let first = try #require(model.clipboardPaste(onto: page, of: editor))
            #expect(first.offset == 20, "a paste on the same page lands beside the original")
            let pasted = try await editor.pasteItems(first.entry.items, from: first.entry.note, on: page, dx: first.offset,
                                                     dy: first.offset, prepare: first.prepare)
            #expect(pasted.count == 1)
            #expect(pasted[0].frame.x == image.frame.x + 20)
            #expect(model.clipboardPaste(onto: page, of: editor)?.offset == 40, "the next one lands further on")

            // The blob cache serves the image; the render cache is made once per vault.
            let cache = try #require(model.attachmentCache())
            let file = try await cache.acquire(note: Self.lecture, ref: try #require(image.blob))
            #expect(FileManager.default.fileExists(atPath: file.path))
            await cache.release(note: Self.lecture, ref: try #require(image.blob))
            let renders = try #require(model.attachmentRenders() as? RenderStore<DataPictureCodec>)
            #expect(model.attachmentRenders() === renders)

            // Closing the vault empties the clipboard and both caches.
            model.close()
            #expect(model.itemClipboard.entry == nil)
            #expect(model.blobCache == nil)
            #expect(model.renderCache == nil)
            #expect(renders.isClosed)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !FileManager.default.fileExists(atPath: file.path) })
        }

        @Test func aPageFetchesOnlyItsPicturesEachOnce() {
            let image = BlobRef(content: Data("i".utf8), type: "image/png")
            let audio = BlobRef(content: Data("a".utf8), type: "audio/mp4")
            let items: [Item] = [
                .image(blob: image, pixelSize: Size(w: 1, h: 1), frame: Rect(x: 0, y: 0, w: 1, h: 1), z: "b"),
                .image(blob: image, pixelSize: Size(w: 1, h: 1), frame: Rect(x: 2, y: 0, w: 1, h: 1), z: "a"),
            ]
            #expect(BlobFetchPolicy.prefetch(for: items) == [image])
            #expect(BlobFetchPolicy.fetchesWithPage(.pdf))
            #expect(!BlobFetchPolicy.fetchesWithPage(audio.kind))
        }
    }

    /// The render cache's store (`RenderStore`, the app's `RenderCache` over CoreGraphics pictures), on plain bytes.
    struct RenderStoreTests {
        typealias Store = RenderStore<DataPictureCodec>

        @Test func picturesAreSealedPerVaultAndReadBackByALaterStore() async throws {
            let (vault, _) = try await TS.unlockedFixture()
            let root = TestTemp.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let first = Store(root: root, vault: vault, capBytes: Store.defaultCapBytes, salt: "s", memoryWarning: nil)
            let picture = Data(repeating: 7, count: 1000)
            first.store(picture, label: "label")
            #expect(first.pictureInMemory("label") == picture)
            let dir = try #require(first.directory)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files.count == 1)
            #expect(!files[0].contains("label"), "file names are keyed by the vault secret")
            let sealed = try Data(contentsOf: dir.appendingPathComponent(files[0]))
            #expect(sealed.range(of: picture) == nil, "the file is sealed")

            // A later launch: the disk level answers, then memory.
            let next = Store(root: root, vault: vault, capBytes: Store.defaultCapBytes, salt: "s", memoryWarning: nil)
            #expect(next.picture("label") == picture)
            #expect(next.diskHits == 1)
            #expect(next.picture("label") == picture)
            #expect(next.memoryHits == 1)
            #expect(next.picture("other") == nil)
            #expect(next.misses == 1)

            // Closing deletes the vault's folder.
            next.close()
            #expect(next.picture("label") == nil)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }

        @Test func withoutARootOnlyMemoryIsUsedAndAWarningDropsIt() async throws {
            let (vault, _) = try await TS.unlockedFixture()
            let warning = Notification.Name("RenderStoreTests.memoryWarning.\(UUID().uuidString)")
            let store = Store(root: nil, vault: vault, capBytes: Store.defaultCapBytes, salt: "", memoryWarning: warning)
            #expect(store.directory == nil)
            store.storeInBackground(Data([1, 2, 3]), label: "x")
            await store.waitForWrites()
            #expect(store.bytesInMemory == 3)
            NotificationCenter.default.post(name: warning, object: nil)
            #expect(store.bytesInMemory == 0)
            #expect(store.picture("x") == nil)
        }

        @Test func labelsNameWhatTheDrawingDependsOn() throws {
            let blob = BlobRef(content: Data("pdf".utf8), type: "application/pdf")
            let page = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 612, h: 792),
                                    frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a")
            let label = try #require(Store.previewLabel(page, scale: 2))
            var moved = page
            moved.frame.x = 50
            #expect(Store.previewLabel(moved, scale: 2) == label, "where it is does not matter")
            #expect(Store.previewLabel(page, scale: 3) != label)
            #expect(Store.pictureLabel(ItemRenderKey(page, scale: 2, paper: .blank), salt: "s") == nil, "PDF pages are previews")
            let text = Item.text(TextContent(size: 14, color: .black, runs: [TextRun("Hello")]),
                                 frame: Rect(x: 10, y: 10, w: 200, h: 40), z: "a")
            let textLabel = try #require(Store.pictureLabel(ItemRenderKey(text, scale: 2, paper: .blank), salt: "fonts"))
            #expect(textLabel.hasPrefix("txt|fonts|"))
            #expect(Store.pictureLabel(ItemRenderKey(text, scale: 2, paper: .blank), salt: "other") != textLabel)
            #expect(Store.previewScale(for: page, screenScale: 2) == 2)
        }
    }
}
