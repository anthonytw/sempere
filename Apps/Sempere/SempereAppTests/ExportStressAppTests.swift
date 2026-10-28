import Age
import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// Device check c42 ("Export right after drawing"), in the app on the simulator and on Mac Catalyst: with the
/// real autosave debounce (1.5 s), ink drawn 0, 0.5 and 1.4 s before an export, during the autosave's own write,
/// and while drawing continues, is always in the exported file. (The owner asked why this was not done in the
/// simulator: it is, here.)
extension ExportTests {
    /// The fixture lecture opened in a model with the default debounce.
    func openLecture() async throws -> (AppModel, NoteEditor) {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"),
                             editorDebounce: NoteEditor.defaultDebounce)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        return (model, try #require(model.editor))
    }

    func draw(_ editor: NoteEditor, x: Double) throws {
        let page = try #require(editor.currentPage)
        var canvas = editor.drawing(for: page.id)
        canvas.strokes.append(TS.canvasStroke(TS.stroke(x: x, y: 640)))
        editor.drawingDidChange(pageID: page.id, drawing: canvas, tool: nil)
    }

    func pathCount(_ model: AppModel) async throws -> Int {
        let r = try await export(model, [Self.lecture], ShareOptions(format: .html), into: try scratch())
        return try String(contentsOf: try #require(r.items.first), encoding: .utf8).components(separatedBy: "<path").count
    }

    @Test(arguments: [0, 500, 1_400]) func inkDrawnJustBeforeAnExportIsInIt(delayMS: Int) async throws {
        let (model, editor) = try await openLecture()
        let before = try await pathCount(model)
        try draw(editor, x: 150)
        try await Task.sleep(for: .milliseconds(delayMS))
        #expect(try await pathCount(model) == before + 1, "exported \(delayMS) ms after the stroke")
        #expect(editor.deltasWritten == 1, "one save, not two")
        model.close()
    }

    @Test func anExportDuringTheAutosavesOwnWriteHasTheInk() async throws {
        let (model, editor) = try await openLecture()
        let before = try await pathCount(model)
        try draw(editor, x: 150)
        // Right at the debounce: the autosave and the export's flush race for the same pending change.
        try await Task.sleep(for: NoteEditor.defaultDebounce)
        async let exported = pathCount(model)
        #expect(try await exported == before + 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(editor.deltasWritten == 1, "the stroke is written once")
        model.close()
    }

    @Test func exportingEvery100msWhileDrawingAlwaysHasEveryStroke() async throws {
        let (model, editor) = try await openLecture()
        let before = try await pathCount(model)
        for i in 1...10 {
            try draw(editor, x: 100 + Double(i * 20))
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await pathCount(model) == before + i, "export \(i)")
        }
        model.close()
    }

    @Test func aBulkExportRightAfterDrawingHasTheInk() async throws {
        let (model, editor) = try await openLecture()
        try draw(editor, x: 150)
        let dir = try scratch()
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        let jobs = model.bulkExportJobs(.notes([Self.lecture]), options: options)
        let session = try BulkExportSession(destination: .folder(dir), options: options, jobs: jobs)
        let result = try await model.runBulkExport(jobs, session: session) { _ in }
        #expect(result.exported.count == 1)
        #expect(editor.deltasWritten == 1, "saved before the export read the note")
        model.close()
    }
}

/// Device check c36 ("Sharing with one broken note"), in the app: notes broken on disk the ways a sync or a disk
/// can break them (a truncated revision, a revision of garbage, a damaged picture), exported as separate PDFs
/// with the share export and with Export to Folder. (The owner asked how to break a note: this is how.)
extension BulkExportAppTests {
    /// The fixture vault plus `count` notes with ink and a picture, and the ids of those notes.
    static func vaultWithNotes(_ count: Int) throws -> (url: URL, key: URL, ids: [UUID]) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let state = url.deletingLastPathComponent().appendingPathComponent("writer.json")
        var ids: [UUID] = []
        for i in 0..<count {
            let id = UUID()
            let page = UUID()
            var ops = NoteOps.newNote(title: "Note \(i)", pageId: page)
            ops.append(.addStroke(page: page, stroke: TS.stroke(x: 100 + Double(i), y: 200)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).pngData { ctx in
                UIColor(red: CGFloat(i) / 10, green: 0.5, blue: 0.2, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            let ref = try vault.writeBlob(note: id, png, type: "image/png")
            ops.append(.addItem(page: page, item: .image(id: UUID(), blob: ref, pixelSize: Size(w: 4, h: 4),
                                                         frame: Rect(x: 50, y: 300, w: 100, h: 100), z: "a0")))
            try vault.apply(ops, to: id, deviceState: state, app: "stress/1")
            ids.append(id)
        }
        return (url, key, ids)
    }

    enum Damage { case truncate, garbage, picture }

    static func damage(_ vault: URL, _ note: UUID, _ how: Damage) throws {
        let dir = vault.appendingPathComponent("notes/\(note.uuidString.lowercased())")
        let fm = FileManager.default
        switch how {
        case .truncate, .garbage:
            let name = try #require(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".age") }.sorted().first)
            let file = dir.appendingPathComponent(name)
            let data = try Data(contentsOf: file)
            try (how == .truncate ? data.prefix(data.count / 2) : Data(repeating: 0x41, count: data.count)).write(to: file)
        case .picture:
            let att = dir.appendingPathComponent("att")
            let name = try #require(try fm.contentsOfDirectory(atPath: att.path).sorted().first)
            var bytes = try Data(contentsOf: att.appendingPathComponent(name))
            bytes[bytes.count - 20] ^= 0xFF
            try bytes.write(to: att.appendingPathComponent(name))
        }
    }

    @Test func brokenNotesOnDiskAreReportedAndTheOthersExported() async throws {
        let (url, key, ids) = try Self.vaultWithNotes(6)
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(Set(ids).isSubset(of: Set(model.notes.map(\.id))), "listed before they break (as a broken sync would)")
        try Self.damage(url, ids[0], .truncate)
        try Self.damage(url, ids[5], .garbage)
        try Self.damage(url, ids[3], .picture)

        // Export to Folder, as separate PDFs.
        let dir = try folder()
        let result = try await run(model, .notes(ids), BulkExportOptions(format: .pdf, layout: .flat), into: dir)
        let failed = Set(result.failures.map(\.job.noteId))
        #expect(failed == [ids[0], ids[5]], "\(result.failureLines)")
        #expect(result.exported.count == 4, "the others, the one with a damaged picture included")
        #expect(files(dir).count == 4)
        #expect(result.failureLines.allSatisfy { !$0.isEmpty })

        // The share export (Share… as separate PDFs): the same notes fail and are named, the rest are handed on.
        let shared = try await model.exportNotes(ids, options: ShareOptions(format: .pdf), into: try folder()) { _ in }
        #expect(shared.exported == 4)
        #expect(shared.failures.count == 2)
        #expect(shared.failures.allSatisfy { f in [ids[0], ids[5]].contains { f.hasPrefix($0.uuidString.lowercased()) } },
                "\(shared.failures)")
        model.close()
    }

    @Test func everyNoteBrokenStillEndsWithAReport() async throws {
        let (url, key, ids) = try Self.vaultWithNotes(3)
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        for id in ids { try Self.damage(url, id, .garbage) }
        let result = try await run(model, .notes(ids), BulkExportOptions(format: .pdf, layout: .flat), into: try folder())
        #expect(result.failures.count == 3 && result.exported.isEmpty)
        model.close()
    }

    // MARK: c57 - read-ahead on evicted iCloud notes

    static var readAheadDepth: Int { AppModel.bulkReadAheadDepth }
}
