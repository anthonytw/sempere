import Foundation
import Sempere
import PencilKit
import Testing
@testable import SempereApp

/// Counts the `verify` calls of `NoteEditor.mergeRevisions` (made by each
/// read of the note, twice per read, on a background thread) and can hold the
/// first call of the first `blockedReads` reads until the test releases it,
/// so the test can write while a merge read is in flight.
final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let gate = DispatchSemaphore(value: 0)
    private let blockedReads: Int

    init(blockedReads: Int) { self.blockedReads = blockedReads }

    /// How many times `verify` was called.
    var calls: Int { lock.withLock { count } }

    /// The closure handed to `mergeRevisions`.
    func verify() throws {
        let n = lock.withLock { () -> Int in count += 1; return count }
        // Odd calls are the first of a read (before the note is loaded).
        if n % 2 == 1, (n + 1) / 2 <= blockedReads { _ = gate.wait(timeout: .now() + 10) }
    }

    /// Lets the held read go on.
    func release() { gate.signal() }
}

/// GA-54: "every write an editor starts bumps `writeEpoch`, and a merge whose
/// read overlapped a write reads again" (`NoteEditor.mergeRevisions`). The
/// epoch is private, so the tests observe it through the number of reads the
/// merge makes (`verify` is called twice per read) and through what the editor
/// and the disk hold afterwards.
@MainActor
struct WriteEpochMergeTests {
    /// Runs `mergeRevisions` with `probe` on a task of its own.
    static func startMerge(_ f: RemoteMergeTests.Fixture, _ probe: ReadProbe) -> Task<NoteEditor.RemoteMergeOutcome, any Error> {
        let editor = f.editor, vault = f.vault, clock = f.clock
        return Task { @MainActor in
            try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: { try probe.verify() })
        }
    }

    /// The user draws one more stroke on `page` and it is saved, as a save
    /// starting in the middle of the merge's read would do.
    static func drawAndSave(_ f: RemoteMergeTests.Fixture, page: UUID, drawing: inout PKDrawing, x: Double) async {
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: x, y: 700)))
        _ = f.editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
        await f.editor.flush()
    }

    @Test func aMergeWithNoWriteDuringItsReadReadsOnce() async throws {
        let f = try await RemoteMergeTests.open()
        let probe = ReadProbe(blockedReads: 0)
        let outcome = try await Self.startMerge(f, probe).value
        #expect(outcome == .unchanged)
        #expect(probe.calls == 2, "one read, two verify calls")
        await f.editor.close()
    }

    @Test func aSaveDuringTheReadMakesTheMergeReadAgainAndKeepsTheInk() async throws {
        let f = try await RemoteMergeTests.open()
        let page = try #require(f.editor.currentPage)
        var drawing = f.editor.drawing(for: page.id)
        let probe = ReadProbe(blockedReads: 1)
        let merge = Self.startMerge(f, probe)
        #expect(await TS.waitUntil { probe.calls == 1 }, "the first read is under way")

        await Self.drawAndSave(f, page: page.id, drawing: &drawing, x: 60)
        let mine = try #require(f.editor.liveStrokes(of: page.id).last)
        probe.release()

        let outcome = try await merge.value
        #expect(outcome != .skipped && outcome != .unreadable)
        #expect(probe.calls == 4, "the first read missed the save, so it was read again")
        // The first read did not hold the stroke; applying it would have dropped the stroke as removed elsewhere.
        #expect(f.editor.liveStrokes(of: page.id).contains { $0.id == mine.id })
        #expect(try f.onDisk().pages.first { $0.id == page.id }?.strokes.contains { $0.id == mine.id } == true)
        await f.editor.close()
        #expect(try f.mine().count == 1, "one delta for the stroke, nothing echoed for the merge")
    }

}
