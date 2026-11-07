import Foundation
import PencilKit
import Sempere
import Testing
@testable import SempereApp

/// The drawing cache (docs/io.md "Opening a note fast"): a miss converts and
/// stores, a hit opens from the cache and is checked against what is read,
/// any change of the note's revisions misses, and a wrong cached drawing is
/// never drawn on.
@MainActor
struct DrawingCacheTests {
    static let lecture = AppModelTests.lecture

    static func tempDir() -> URL {
        TestTemp.root.appendingPathComponent("sempere-drawings-\(UUID().uuidString)")
    }

    /// An unlocked model with a drawing cache, on a copy of the fixture.
    static func model(root: URL) async throws -> (AppModel, vault: URL, key: URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), drawingCacheRoot: root)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return (model, url, key)
    }

    /// Opens `id` in the model's editor and waits until it is fully read.
    static func open(_ model: AppModel, _ id: UUID) async throws -> NoteEditor {
        model.selectedNoteID = id
        try await model.openEditor(for: id)
        let editor = try #require(model.editor)
        await editor.loaded()
        return editor
    }

    static func key(_ vault: URL, _ id: UUID) throws -> DrawingCache.Key {
        DrawingCache.Key(note: id, revisions: try VaultEnumeration.listNotes(vault: vault, only: [id]).first?.names ?? [])
    }

    /// Miss: read, converted off the main actor, stored. Hit: opened from the
    /// layout and the page's drawing, then checked; drawing on it saves
    /// exactly the new stroke (the ledger matches the cached strokes).
    @Test func aMissIsStoredAndTheNextOpenIsAHit() async throws {
        let root = Self.tempDir()
        let (model, url, _) = try await Self.model(root: root)
        let first = try await Self.open(model, Self.lecture)
        #expect(!first.openedFromCache)
        let page = try #require(first.currentPage)
        let drawing = try #require(await first.prepareDrawing(for: page.id))
        #expect(drawing.strokes.count == 2)
        let cache = try #require(model.drawingCache)
        let key = try Self.key(url, Self.lecture)
        #expect(await TS.waitUntil { cache.layout(key) != nil && cache.drawing(key, page: page.id) != nil })
        try await model.openEditor(for: nil)

        let second = try await Self.open(model, Self.lecture)
        #expect(second.openedFromCache)
        #expect(!second.isReadOnly)
        #expect(second.pages.map(\.id) == first.pages.map(\.id))
        var shown = second.readyDrawing(for: page.id)
        if shown == nil { shown = await second.prepareDrawing(for: page.id) }
        let cached = try #require(shown)
        #expect(cached.strokes.count == 2)
        #expect(DrawingPreparation.matches(cached, second.liveStrokes(of: page.id)))

        // Draw on it: one new stroke, nothing else.
        let before = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())").path).count
        var canvas = cached
        canvas.strokes.append(TS.canvasStroke(TS.stroke(x: 300, y: 500)))
        let change = second.drawingDidChange(pageID: page.id, drawing: canvas, tool: nil)
        #expect(change.added.count == 1 && change.removed.isEmpty)
        await second.flush()
        #expect(second.deltasWritten == 1)
        let vault = try #require(model.vault)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.first { $0.id == page.id }?.strokes.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())").path).count == before + 1)
        model.close()
    }

    /// The background read of a note opened from the cache fails: the editor
    /// says so (`loadFailed`, which the model turns into `editorFailure`); and a closed editor's read never
    /// finishes into a writer.
    @Test func aFailedBackgroundReadIsReportedAndAClosedOneStops() async throws {
        struct Unreadable: Error {}
        let root = Self.tempDir()
        let (model, url, _) = try await Self.model(root: root)
        let first = try await Self.open(model, Self.lecture)
        let page = try #require(first.currentPage)
        _ = await first.prepareDrawing(for: page.id)
        let cache = try #require(model.drawingCache)
        let key = try Self.key(url, Self.lecture)
        #expect(await TS.waitUntil { cache.layout(key) != nil })
        try await model.openEditor(for: nil)
        let vault = try #require(model.vault)
        let clock = try DeviceClock(url: TS.deviceStateURL())

        let failing = try await NoteEditor.open(vault: vault, noteID: Self.lecture, clock: clock, verify: { throw Unreadable() },
                                                cache: cache, listedNames: key.revisions)
        #expect(failing.openedFromCache)
        await failing.loaded()
        #expect(failing.loadFailed)
        #expect(failing.isReadOnly)
        #expect(failing.readOnlyReason?.contains("could not be read") == true)

        let gate = Gate()
        await gate.close()
        let closing = try await NoteEditor.open(vault: vault, noteID: Self.lecture, clock: clock, cache: cache,
                                                listedNames: key.revisions, beforeFinishing: { await gate.pass() })
        await gate.waitForArrivals(1)
        let closed = Task { await closing.close() }
        await gate.open()
        await closed.value
        await closing.loaded()
        #expect(closing.isPreparing && !closing.loadFailed, "canceled: neither finished nor failed")
        #expect(closing.isReadOnly)
        model.close()
    }

    /// Another device adds a revision: the names change, the cache misses,
    /// and the note shows the new stroke.
    @Test func aNewRevisionFromElsewhereMisses() async throws {
        let root = Self.tempDir()
        let (model, url, keyURL) = try await Self.model(root: root)
        let first = try await Self.open(model, Self.lecture)
        let page = try #require(first.currentPage)
        _ = await first.prepareDrawing(for: page.id)
        let cache = try #require(model.drawingCache)
        let oldKey = try Self.key(url, Self.lecture)
        #expect(await TS.waitUntil { cache.drawing(oldKey, page: page.id) != nil })
        try await model.openEditor(for: nil)

        try TS.writeAsAnotherDevice([.addStroke(page: page.id, stroke: TS.stroke(x: 100, y: 600))], to: Self.lecture,
                                    vault: url, key: keyURL)
        let second = try await Self.open(model, Self.lecture)
        #expect(!second.openedFromCache)
        let drawing = try #require(await second.prepareDrawing(for: page.id))
        #expect(drawing.strokes.count == 3)
        model.close()
    }

    /// A cached drawing that is not the note's (damaged, or from another
    /// conversion) is shown at most until the note is read, never drawn on,
    /// and replaced by the real one; the cache is corrected.
    @Test func aWrongCachedDrawingIsReplacedBeforeAnythingIsDrawn() async throws {
        let root = Self.tempDir()
        let (model, url, _) = try await Self.model(root: root)
        let first = try await Self.open(model, Self.lecture)
        let page = try #require(first.currentPage)
        _ = await first.prepareDrawing(for: page.id)
        let cache = try #require(model.drawingCache)
        let key = try Self.key(url, Self.lecture)
        // The layout is written by a utility-priority task: on a busy runner it can come after the page.
        #expect(await TS.waitUntil(timeout: .seconds(10)) { cache.drawing(key, page: page.id) != nil && cache.layout(key) != nil })
        try await model.openEditor(for: nil)
        // One foreign stroke where the note has two.
        cache.store(drawing: PKDrawing(strokes: [TS.canvasStroke(TS.stroke(x: 10, y: 10))]).dataRepresentation(), for: key, page: page.id)

        let gate = Gate()
        await gate.close()
        model.editorLoadHook = { await gate.pass() }
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        #expect(editor.openedFromCache)
        #expect(editor.isPreparing && editor.isReadOnly, "nothing can be drawn before the note is read")
        let generation = editor.canvasGeneration
        let shown = try #require(await editor.prepareDrawing(for: page.id))   // what the canvas shows while reading
        #expect(shown.strokes.count == 1)
        #expect(editor.liveStrokes(of: page.id).isEmpty)
        await gate.open()
        await editor.loaded()
        #expect(!editor.isReadOnly)
        #expect(editor.canvasGeneration != generation, "the canvas is told to reload")
        #expect(editor.readyDrawing(for: page.id) == nil, "the wrong drawing is not kept")
        let real = try #require(await editor.prepareDrawing(for: page.id))
        #expect(real.strokes.count == 2)
        #expect(DrawingPreparation.matches(real, editor.liveStrokes(of: page.id)))
        // Corrected in the cache too (written in the background, after the page is shown).
        let strokes = editor.liveStrokes(of: page.id)
        #expect(await TS.waitUntil {
            cache.drawing(key, page: page.id).flatMap { DrawingPreparation.fromCache($0, strokes: strokes) } != nil
        })
        model.close()
    }

    /// Audit B1: the note changed between the listing and the read, and a
    /// page that is not the current one was shown from the cache (the paged
    /// stack). Its cached drawing fails the check, so every canvas is told to
    /// reload: none keeps the stale ink to draw on, which would remove the
    /// other device's stroke.
    @Test func aStaleCachedDrawingOnAnotherPageIsReloaded() async throws {
        let root = Self.tempDir()
        let (model, url, keyURL) = try await Self.model(root: root)
        let first = try await Self.open(model, Self.lecture)
        #expect(first.pages.count == 2)
        let current = try #require(first.currentPage).id
        let other = first.pages[1].id
        #expect(other != current)
        _ = await first.prepareDrawing(for: other)
        let cache = try #require(model.drawingCache)
        let key = try Self.key(url, Self.lecture)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { cache.drawing(key, page: other) != nil && cache.layout(key) != nil })
        try await model.openEditor(for: nil)
        // Listed as `key`, then another device writes before the note is read.
        let remote = TS.stroke(x: 100, y: 600)
        try TS.writeAsAnotherDevice([.addStroke(page: other, stroke: remote)], to: Self.lecture, vault: url, key: keyURL)
        let vault = try #require(model.vault)
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let gate = Gate()
        await gate.close()
        let editor = try await NoteEditor.open(vault: vault, noteID: Self.lecture, clock: clock, cache: cache,
                                               listedNames: key.revisions, beforeFinishing: { await gate.pass() })
        #expect(editor.openedFromCache)
        #expect(editor.currentPage?.id == current)
        let generation = editor.canvasGeneration
        let shown = try #require(await editor.prepareDrawing(for: other))   // the stack's second canvas
        #expect(shown.strokes.count == 2)
        await gate.open()
        await editor.loaded()
        #expect(!editor.isReadOnly)
        #expect(editor.liveStrokes(of: other).contains { $0.id == remote.id })
        #expect(editor.canvasGeneration != generation, "every canvas is told to reload")
        #expect(editor.readyDrawing(for: other) == nil, "the stale drawing is not kept")
        let real = try #require(await editor.prepareDrawing(for: other))
        #expect(DrawingPreparation.matches(real, editor.liveStrokes(of: other)))
        await editor.close()
        model.close()
    }

    /// Closing an edited note stores its new version: the next open is a hit
    /// showing the edit.
    @Test func closingAnEditedNoteStoresItsNewVersion() async throws {
        let root = Self.tempDir()
        let (model, url, _) = try await Self.model(root: root)
        let editor = try await Self.open(model, Self.lecture)
        let page = try #require(editor.currentPage)
        var canvas = try #require(await editor.prepareDrawing(for: page.id))
        canvas.strokes.append(TS.canvasStroke(TS.stroke(x: 200, y: 450)))
        editor.drawingDidChange(pageID: page.id, drawing: canvas, tool: nil)
        try await model.openEditor(for: nil)   // saves, then stores
        let cache = try #require(model.drawingCache)
        let key = try Self.key(url, Self.lecture)
        #expect(await TS.waitUntil { cache.layout(key) != nil && cache.drawing(key, page: page.id) != nil })

        let again = try await Self.open(model, Self.lecture)
        #expect(again.openedFromCache)
        var shown = again.readyDrawing(for: page.id)
        if shown == nil { shown = await again.prepareDrawing(for: page.id) }
        let drawing = try #require(shown)
        #expect(drawing.strokes.count == 3)
        #expect(DrawingPreparation.matches(drawing, again.liveStrokes(of: page.id)))
        model.close()
    }

    /// Closing the vault deletes its drawings; nothing is written after.
    @Test func closingTheVaultClearsTheCache() async throws {
        let root = Self.tempDir()
        let (model, _, _) = try await Self.model(root: root)
        let editor = try await Self.open(model, Self.lecture)
        _ = await editor.prepareDrawing(for: try #require(editor.currentPage).id)
        let cache = try #require(model.drawingCache)
        #expect(await TS.waitUntil { cache.totalBytes > 0 })
        model.close()
        #expect(cache.isClosed)
        #expect(await TS.waitUntil {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).allSatisfy { $0.hasPrefix(".closed-") }
        })
        cache.store(drawing: Data("late".utf8), for: DrawingCache.Key(note: UUID(), revisions: []), page: UUID())
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    /// The visible-first conversion hands over the strokes on screen, then
    /// the whole page in stored order; `matches` accepts exactly that.
    @Test func visibleStrokesComeFirstAndTheResultMatches() {
        var strokes: [Stroke] = []
        for i in 0..<(DrawingPreparation.visibleFirstThreshold + 50) {
            strokes.append(TS.stroke(x: 40, y: Double(i % 2 == 0 ? 100 : 3000), n: 6))
        }
        var partial: PKDrawing?
        let prepared = DrawingPreparation.convert(strokes, visible: CGRect(x: 0, y: 0, width: 800, height: 1000)) { partial = $0 }
        #expect(partial?.strokes.count == strokes.count / 2)
        #expect(prepared.drawing.strokes.count == strokes.count)
        #expect(prepared.infos.count == strokes.count)
        #expect(DrawingPreparation.matches(prepared.drawing, strokes))
        #expect(!DrawingPreparation.matches(prepared.drawing, Array(strokes.dropLast())))
        #expect(!DrawingPreparation.matches(prepared.drawing, strokes.reversed()))
        var other = strokes
        other[3].id = UUID()
        #expect(!DrawingPreparation.matches(prepared.drawing, other), "the texture seed comes from the stroke id")
        // Every canvas stroke carries its stored stroke's id, also through PencilKit's data.
        #expect(prepared.drawing.strokes.map(\.id) == strokes.map(\.id))
        let decoded = try? PKDrawing(data: prepared.drawing.dataRepresentation())
        #expect(decoded?.strokes.map(\.id) == strokes.map(\.id))
        var reseeded = prepared.drawing
        reseeded.strokes[0].id = UUID()
        #expect(!DrawingPreparation.matches(reseeded, strokes), "a canvas stroke with another id")
        // Small pages: one go.
        var none = false
        _ = DrawingPreparation.convert(Array(strokes.prefix(10)), visible: .zero) { _ in none = true }
        #expect(!none)
    }
}
