import Foundation
import XCTest
@testable import Sempere

/// Two devices edit one note at the same time, each in its own copy of the
/// vault folder (offline, or before iCloud delivers), and exchange revision
/// files between rounds, as a sync service does. This is what the app does
/// when a note is open on both: each device merges the other's revisions into
/// the open note by reading the folder again (`NoteEditor.mergeRevisions`).
/// After every exchange both devices reconstruct the same note, whatever the
/// order the revisions are read in, and the format's rules decide each
/// concurrent edit (format.md §5.3, §8.2.2).
final class InterleavedDevicesTests: VaultTestCase {
    private func revisionFiles(_ vault: Vault, _ note: UUID) throws -> Set<String> {
        Set(try vault.revisionNames(of: note).map(\.filename))
    }

    /// Copies the revision files `from` holds and `to` lacks: what a sync service delivers.
    private func deliver(_ note: UUID, from: Vault, to: Vault) throws {
        let folder = { (v: Vault) in
            v.url.appendingPathComponent("notes").appendingPathComponent(note.uuidString.lowercased())
        }
        for name in try revisionFiles(from, note).subtracting(try revisionFiles(to, note)) {
            try FileManager.default.copyItem(at: folder(from).appendingPathComponent(name),
                                             to: folder(to).appendingPathComponent(name))
        }
    }

    /// Both devices read the same note, in every order tried.
    private func assertConverged(_ a: Vault, _ b: Vault, _ note: UUID, seed: UInt64,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> NoteState {
        let onA = try a.reconstruct(noteId: note)
        XCTAssertEqual(onA, try b.reconstruct(noteId: note), "A and B differ", file: file, line: line)
        let revisions = try a.loadNote(note).revisions
        var rng = SplitMix64(seed: seed)
        for _ in 0..<12 {
            XCTAssertEqual(try NoteReducer.reconstruct(revisions.shuffled(using: &rng)), onA, "order matters",
                           file: file, line: line)
        }
        return onA
    }

    func testTwoDevicesInterleavedDeltasReconstructIdentically() throws {
        let identity = try pqIdentity()
        let a = try makeVault(identity, name: "A")
        let note = UUID()
        let stateA = tmp.appendingPathComponent("a.json"), stateB = tmp.appendingPathComponent("b.json")
        try a.apply(NoteOps.newNote(title: "Shared"), to: note, deviceState: stateA, app: "a")
        try FileManager.default.copyItem(at: a.url, to: vaultURL("B"))
        let b = try Vault.open(at: vaultURL("B"), identities: [identity])
        var state = try assertConverged(a, b, note, seed: 1)
        let page = try XCTUnwrap(state.pages.first)

        // Round 1: both draw; A also places a text box.
        let sA = Stroke(ink: Ink(tool: .pen, color: .black, width: 2), points: [StrokePoint(x: 1, y: 1, w: 2, h: 2), StrokePoint(x: 9, y: 9, w: 2, h: 2)])
        let sB = Stroke(ink: Ink(tool: .pen, color: .black, width: 2), points: [StrokePoint(x: 5, y: 1, w: 2, h: 2), StrokePoint(x: 5, y: 9, w: 2, h: 2)])
        let box = Item.text(TextContent(size: 14, color: .black, runs: [TextRun("board")]),
                            frame: Rect(x: 10, y: 10, w: 100, h: 30), z: "a")
        try a.apply([.addStroke(page: page.id, stroke: sA)] + NoteOps.addItems([box], to: page).ops, to: note,
                    deviceState: stateA, app: "a")
        try b.apply([.addStroke(page: page.id, stroke: sB)], to: note, deviceState: stateB, app: "b")
        try deliver(note, from: a, to: b)
        try deliver(note, from: b, to: a)
        state = try assertConverged(a, b, note, seed: 2)
        XCTAssertEqual(Set(state.pages[0].strokes.map(\.id)), [sA.id, sB.id])
        let placed = try XCTUnwrap(state.pages[0].items.first)

        // Round 2, concurrent: both move the box; B erases A's stroke while A
        // draws again; B adds a page while A renames the note.
        let shared = state.pages[0]
        let toA = Rect(x: 200, y: 10, w: 100, h: 30), toB = Rect(x: 10, y: 400, w: 100, h: 30)
        let sA2 = Stroke(ink: Ink(tool: .pen, color: .black, width: 2), points: [StrokePoint(x: 3, y: 3, w: 2, h: 2), StrokePoint(x: 7, y: 2, w: 2, h: 2)])
        try a.apply(try XCTUnwrap(NoteOps.setFrame(placed.id, to: toA, on: shared)).ops
                    + [.addStroke(page: page.id, stroke: sA2), .setMeta(.title("Renamed on A"))],
                    to: note, deviceState: stateA, app: "a")
        let added = NoteOps.addPage(at: 1, in: state.pages)
        try b.apply(try XCTUnwrap(NoteOps.setFrame(placed.id, to: toB, on: shared)).ops
                    + [.removeStroke(page: page.id, strokeId: sA.id)] + added.ops,
                    to: note, deviceState: stateB, app: "b")
        let lastA = try XCTUnwrap(try a.revisionNames(of: note).max { $0.hlc < $1.hlc })
        let lastB = try XCTUnwrap(try b.revisionNames(of: note).max { $0.hlc < $1.hlc })
        try deliver(note, from: a, to: b)
        try deliver(note, from: b, to: a)
        state = try assertConverged(a, b, note, seed: 3)

        // The format decides: the later stamp's frame (LWW, ties by device), both strokes' fates, both pages.
        let bWins = (lastB.hlc, lastB.device) > (lastA.hlc, lastA.device)
        XCTAssertEqual(state.pages[0].items.first { $0.id == placed.id }?.frame, bWins ? toB : toA)
        XCTAssertEqual(Set(state.pages[0].strokes.map(\.id)), [sB.id, sA2.id])
        XCTAssertEqual(state.pages.count, 2)
        XCTAssertEqual(state.meta.title, "Renamed on A")

        // Round 3: A writes on top of what it merged; B, having merged too, reads it unchanged.
        try a.apply([.removeStroke(page: page.id, strokeId: sB.id)], to: note, deviceState: stateA, app: "a")
        try deliver(note, from: a, to: b)
        state = try assertConverged(a, b, note, seed: 4)
        XCTAssertEqual(state.pages[0].strokes.map(\.id), [sA2.id])
        XCTAssertTrue(a.verify().isHealthy)
        XCTAssertTrue(b.verify().isHealthy)
    }
}
