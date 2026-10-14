import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// What a card's button asked for.
@MainActor
final class ToggleLog {
    var ids: [UUID] = []
}

/// Recordings on the page in the app (format.md §8.2.9, TestFlight build 7
/// feedback): stopping a recording places its card in the same delta,
/// deleting a recording takes its cards, the card is drawn and has a
/// play/pause button, the Recordings list command, and the export of a
/// note with a recording ("PDF + attachments", which crashed on the Mac)
/// with its hand-off to the system. Serialized with the recording tests'
/// one-recording-at-a-time rule in mind.
@Suite(.serialized)
@MainActor
struct AudioItemAppTests {
    static let lecture = AppModelTests.lecture

    @Test func stoppingARecordingPlacesItsCardInTheSameDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        try editor.startRecording(root: RecordingTests.root(), backend: FakeCapture())
        let saved = try #require(await editor.stopRecording())
        let cards = editor.items(on: page).filter { $0.kind == .audio }
        #expect(cards.map(\.recording) == [saved.id])
        let card = try #require(cards.first)
        #expect(card.frame.w <= NoteOps.audioItemSize.w && card.frame.h == NoteOps.audioItemSize.h)
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1, "the recording and its card: one delta")
        #expect(deltas.first?.count == 2)
        guard case .addRecording(let r)? = deltas.first?.first, case .addItem(let p, let item)? = deltas.first?.last else {
            Issue.record("\(deltas)")
            return
        }
        #expect(r.id == saved.id && p == page && item.id == card.id)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.recording(shownBy: card)?.id == saved.id)
    }

    @Test func deletingARecordingTakesItsCardsAndPlacingAddsOne() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .milliseconds(50))
        let page = try #require(editor.currentPage).id
        let r = try await editor.addRecording(file: RecordingTests.tone, started: Date(timeIntervalSince1970: 1_800_000_000),
                                              place: true)
        let second = try #require(editor.placeRecording(r.id))
        #expect(editor.audioItems(showing: r.id).map(\.item.id).contains(second.id))
        await editor.flush()
        #expect(editor.items(on: page).filter { $0.kind == .audio }.count == 2)
        let before = try NoteEditorTests.myDeltas(vault, clock).count
        await editor.removeRecording(r.id)
        #expect(editor.recordings.isEmpty)
        #expect(editor.items(on: page).allSatisfy { $0.kind != .audio })
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == before + 1, "the recording and its cards: one delta")
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.recordings.isEmpty)
        #expect(state.pages.flatMap(\.items).allSatisfy { $0.kind != .audio })
    }

    @Test func cardsAreNotPastedIntoAnotherNote() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let card = Item.audio(recording: UUID(), frame: Rect(x: 10, y: 10, w: 200, h: 60), z: "a")
        let pasted = try await editor.pasteItems([card], from: AppModelTests.deleted, on: page)
        #expect(pasted.isEmpty)
        let same = try await editor.pasteItems([card], from: Self.lecture, on: page)
        #expect(same.count == 1, "within its own note a card is copied")
    }

    @Test func theCardIsDrawnFromItsRecording() async throws {
        let recording = Recording(blob: BlobRef(content: Data("x".utf8), type: "audio/mp4"), started: Date(), duration: 75,
                                  title: "Lecture")
        let card = Item.audio(recording: recording.id, frame: Rect(x: 10, y: 10, w: 300, h: 96), z: "a")
        let key = ItemRenderKey(card, scale: 2, paper: .blank, recording: recording)
        guard case .image(_, let bounds) = await ItemRendering.render(key, note: Self.lecture, cache: nil) else {
            Issue.record("the card is drawn")
            return
        }
        #expect(bounds.w >= 300 && bounds.h >= 96)
        let missing = ItemRenderKey(card, scale: 2, paper: .blank)
        guard case .placeholder = await ItemRendering.render(missing, note: Self.lecture, cache: nil) else {
            Issue.record("a missing recording is a placeholder")
            return
        }
        // A renamed recording draws the card again.
        var renamed = recording
        renamed.title = "Seminar"
        #expect(ItemRenderKey(card, scale: 2, paper: .blank, recording: renamed) != key)
    }

    @Test func eachCardHasAPlayPauseButton() throws {
        let canvas = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controls = AudioCardControls()
        controls.attach(to: canvas)
        let recording = Recording(blob: BlobRef(content: Data("x".utf8), type: "audio/mp4"), started: Date(), title: "Talk")
        let card = Item.audio(recording: recording.id, frame: Rect(x: 0, y: 0, w: 300, h: 96), z: "a")
        let orphan = Item.audio(recording: UUID(), frame: Rect(x: 0, y: 200, w: 300, h: 96), z: "b")
        let toggled = ToggleLog()
        controls.layout([card, orphan], recordings: [recording], playing: nil, zoom: 2, hidden: nil) { toggled.ids.append($0) }
        let button = try #require(controls.shownButtons[card.id])
        #expect(controls.shownButtons.count == 1, "no button for a missing recording")
        #expect(button.superview === canvas)
        #expect(!button.isPlaying)
        #expect(button.accessibilityLabel == "Play Talk")
        // Over the icon's lower right, in canvas points at zoom 2.
        #expect(abs(button.center.x - 2 * 29.6) < 0.001 && abs(button.center.y - 2 * 29.6) < 0.001)
        button.sendActions(for: .primaryActionTriggered)
        #expect(toggled.ids == [recording.id])
        controls.layout([card], recordings: [recording], playing: AudioPlayState(recording: recording.id, isPlaying: true),
                        zoom: 1, hidden: nil) { toggled.ids.append($0) }
        #expect(controls.shownButtons[card.id]?.isPlaying == true)
        #expect(controls.shownButtons[card.id]?.accessibilityLabel == "Pause Talk")
        // Selection mode (no toggle) and a card being edited show none.
        controls.layout([card], recordings: [recording], playing: nil, zoom: 1, hidden: nil, toggle: nil)
        #expect(controls.shownButtons.isEmpty)
        #expect(button.superview == nil)
        controls.layout([card], recordings: [recording], playing: nil, zoom: 1, hidden: card.id) { _ in }
        #expect(controls.shownButtons.isEmpty)
    }

    @Test func aCardsMenuPlaysPausesAndShowsTheTranscript() {
        let card = Item.audio(recording: UUID(), frame: Rect(x: 0, y: 0, w: 300, h: 96), z: "a")
        func entries(_ audio: ItemMenu.AudioState?, editable: Bool = true) -> [ItemMenu.Entry] {
            ItemMenu.entries(for: card, editable: editable, canPlay: true, canCrop: true, canReplace: true, canPaste: false,
                             audio: audio)
        }
        #expect(entries(.init(canToggle: true, isPlaying: false, hasTranscript: true))
                == [.playRecording, .showTranscript, .copy, .duplicate, .rotateLeft, .rotateRight, .bringToFront, .delete])
        #expect(entries(.init(canToggle: true, isPlaying: true, hasTranscript: false), editable: false)
                == [.pauseRecording, .copy])
        #expect(entries(nil) == [.copy, .duplicate, .rotateLeft, .rotateRight, .bringToFront, .delete], "a missing recording: nothing to play")
        let video = Item(kind: .video, frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "a")
        #expect(!ItemMenu.entries(for: video, editable: false, canPlay: true, canCrop: false, canReplace: false, canPaste: false,
                                  audio: .init(canToggle: true, isPlaying: false, hasTranscript: true))
            .contains(.playRecording), "only audio items play recordings")
    }

    @Test func recordingsListIsANoteMenuCommand() {
        var c = MenuCommand.Context(window: .note, vault: .unlocked)
        #expect(!MenuCommand.showRecordings.isEnabled(in: c))
        c.hasPage = true
        #expect(MenuCommand.showRecordings.isEnabled(in: c))
        c.vault = .locked
        #expect(!MenuCommand.showRecordings.isEnabled(in: c))
        #expect(MenuLayout.note.flatMap { $0 }.contains(.showRecordings))
        let ui = WindowUI()
        #expect(EditorCommands.perform(.showRecordings, editor: nil, ui: ui))
        #expect(!ui.showingRecordings, "no note open: nothing to list")
    }

    // MARK: - Export (TestFlight build 7: crashed on the Mac)

    /// "PDF + attachments" of a note with a recording and its card: the card
    /// is drawn (no placeholder), the audio is attached once, with its
    /// transcript, and nothing fails.
    @Test func exportingANoteWithAudioAttachesTheRecording() async throws {
        let model = try await RecordingTests.model()
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: RecordingTests.tone, started: Date(timeIntervalSince1970: 1_800_000_000),
                                              title: "Lecture", place: true)
        await model.transcribe(r, in: editor)
        await editor.flush()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for attach in [true, false] {
            let out = dir.appendingPathComponent(attach ? "with" : "without")
            let result = try await model.exportNotes([Self.lecture], options: ShareOptions(format: .pdf, pdfAttachments: attach),
                                                     into: out) { _ in }
            #expect(result.failures.isEmpty)
            #expect(result.exported == 1)
            #expect(result.placeholders == 0, "the card is drawn")
            #expect(result.recordingsAttached == (attach ? 1 : 0))
            let pdf = try Data(contentsOf: try #require(result.items.first))
            let audio = try Data(contentsOf: RecordingTests.tone)
            #expect((pdf.range(of: audio) != nil) == attach)
            #expect((pdf.range(of: Data("/F (Lecture.txt)".utf8)) != nil) == attach)
            // "PDF + attachments" ends with the attachment list, linked to both files (task C4).
            #expect((pdf.range(of: Data("/Subtype /FileAttachment".utf8)) != nil) == attach)
        }
        // PNG pages of the same note draw the card too.
        let png = try await model.exportNotes([Self.lecture], options: ShareOptions(format: .png), into: dir.appendingPathComponent("png")) { _ in }
        #expect(png.placeholders == 0 && png.failures.isEmpty)
    }

    /// "Media" (task C4): the recording as stored and its transcript as text,
    /// in a folder named after the note, with `media.json`; in the bulk
    /// export too, which leaves out notes without media.
    @Test func mediaExportWritesTheRecordingAndItsTranscript() async throws {
        let model = try await RecordingTests.model()
        let editor = try #require(model.editor)
        let r = try await editor.addRecording(file: RecordingTests.tone, started: Date(timeIntervalSince1970: 1_800_000_000),
                                              title: "Lecture", place: true)
        await model.transcribe(r, in: editor)
        await editor.flush()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.canExport(.media, ids: [Self.lecture]))
        let result = try await model.exportNotes([Self.lecture], options: ShareOptions(format: .media), into: dir) { _ in }
        #expect(result.failures.isEmpty)
        #expect(result.exported == 1)
        #expect(result.mediaFiles == 2, "the audio and its transcript")
        let folder = try #require(result.items.first)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let audioName = try #require(names.first { $0.hasSuffix("-Recording-1-Lecture.m4a") })
        #expect(names.contains(MediaExport.manifestName))
        #expect(names.contains(audioName.replacingOccurrences(of: ".m4a", with: ".txt")))
        #expect(try Data(contentsOf: folder.appendingPathComponent(audioName)) == Data(contentsOf: RecordingTests.tone))
        let manifest = try JSONDecoder().decode(MediaManifest.self,
                                                from: Data(contentsOf: folder.appendingPathComponent(MediaExport.manifestName)))
        #expect(manifest.files.map(\.kind) == [.recording])
        #expect(manifest.files.first?.title == "Lecture")

        let options = BulkExportOptions(format: .media, layout: .flat)
        let jobs = model.bulkExportJobs(.vault, options: options)
        #expect(jobs.map(\.noteId) == [Self.lecture], "only the note with media")
        let bulk = dir.appendingPathComponent("bulk")
        let session = try BulkExportSession(destination: .folder(bulk), options: options, jobs: jobs)
        let done = try await model.runBulkExport(jobs, session: session) { _ in }
        #expect(done.exported.count == 1)
        #expect(done.exported.first?.files.contains { $0.hasSuffix("/" + MediaExport.manifestName) } == true)
        model.close()
    }

    /// The share sheet's completion handler is called on whatever thread the
    /// system likes (on a Mac, the sharing service's): it must not be a
    /// main-actor closure, which stops the app when called elsewhere, and
    /// it must still report back on the main actor.
    @Test func theShareSheetsCompletionIsSafeOffTheMainThread() async {
        let reported = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            nonisolated(unsafe) let handler = ExportHandOff.completion { done.resume(returning: Thread.isMainThread) }
            DispatchQueue.global(qos: .userInitiated).async { handler(nil, true, nil, nil) }
        }
        #expect(reported, "reported on the main actor")
        let picked = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            nonisolated(unsafe) let coordinator = SaveToFiles.Coordinator { done.resume(returning: Thread.isMainThread) }
            nonisolated(unsafe) let picker = UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: "/dev/null")],
                                                                            asCopy: true)
            DispatchQueue.global().async { coordinator.documentPickerWasCancelled(picker) }
        }
        #expect(picked)
    }
}
