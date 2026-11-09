import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// The words of the history list and of thinning (format.md §5.8; `History+Text.swift`,
/// `AppModel+Thinning.swift`). The model's history, Save Version, editing sessions and thinning are `HistoryTests` and
/// `ThinningTests` in `SempereAppCoreTests`.
@MainActor
struct VersionHistoryAppTests {
    static let device = DeviceID("aaaaaaaa")!

    static func point(_ minutes: Double, seq: Int, session: String? = "s1", checkpoint: Checkpoint? = nil,
                      kind: RevisionName.Kind = .delta, complete: Bool = true) -> RestorePoint {
        let ms = Int64(1_760_000_000_000 + minutes * 60_000)
        return RestorePoint(name: RevisionName(hlc: HLC(millis: ms, counter: 0)!, device: device, seq: seq, kind: kind),
                            wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "t", complete: complete,
                            checkpoint: checkpoint, session: session)
    }

    @Test func rowLabels() {
        let points = [Self.point(0, seq: 1, kind: .snapshot), Self.point(1, seq: 2, complete: false),
                      Self.point(2, seq: 3, checkpoint: Checkpoint(name: "Before the exam")),
                      Self.point(3, seq: 4, checkpoint: Checkpoint())]
        let mine = HistoryRow.entries(points, thisDevice: Self.device)
        #expect(mine.map(\.kindLabel) == ["Saved version", "Saved version", "Edit", "Snapshot"])
        #expect(mine.map(\.checkpointTitle) == ["Saved Version", "Before the exam", nil, nil])
        #expect(mine.allSatisfy { $0.deviceLabel == "This device" })
        #expect(mine[2].unavailableReason?.contains("cannot be rebuilt") == true)
        #expect(mine[0].unavailableReason == nil)
        let theirs = HistoryRow.entries(points, thisDevice: nil)
        #expect(theirs.allSatisfy { $0.deviceLabel == "Device aaaa" })
    }

    @Test func theCompactionNoticeIsSaidOnlyForSnapshotsOrIncompletePoints() throws {
        #expect(HistoryRow.compactionNotice([]) == nil)
        #expect(HistoryRow.compactionNotice([Self.point(0, seq: 1)]) == nil)
        let notice = try #require(HistoryRow.compactionNotice([Self.point(0, seq: 1, kind: .snapshot)]))
        #expect(notice.contains("compaction"))
        #expect(HistoryRow.compactionNotice([Self.point(0, seq: 1, complete: false)]) == notice)
    }

    @Test func groupRowLines() {
        let points = [Self.point(0, seq: 1), Self.point(2, seq: 2),
                      Self.point(3, seq: 3, checkpoint: Checkpoint(name: "v1")),
                      Self.point(4, seq: 4), Self.point(30, seq: 5)]
        let entries = HistoryRow.entries(points, thisDevice: Self.device)
        let rows = HistoryGroupRow.rows(points, entries: entries)
        #expect(rows[3].summary == "This device · 2 saves")
        #expect(rows[0].summary == "This device · 1 save")
        #expect(rows[3].timeRange.contains("–"))
        #expect(!rows[0].timeRange.contains("–"))
    }

    // MARK: - Thinning

    /// The schedule and the window's rule are `ThinningTests` (SempereAppCoreTests); here, the choices' words.
    @Test func thinningPreferenceLabels() {
        #expect(ThinningPreference.label(0) == "Never")
        #expect(ThinningPreference.label(30) == "30 days")
        #expect(ThinningPreference.label(365) == "1 year")
    }

    @Test func thinningRulesAndThePreviewSentence() {
        #expect(ThinningRule.allButCheckpoints.title == "Thin everything except checkpoints")
        #expect(ThinningRule.allButCheckpoints.explanation.contains("Keeps every checkpoint"))
        #expect(ThinningRule.olderThan(days: 30).title == "Thin versions older than 30 days")
        let preview = ThinningReport(notes: [NoteThinning(id: UUID(), title: "Lecture", deletions: 4, snapshots: 1,
                                                          bytesDeleted: 4096, bytesAdded: 512)], checked: 2)
        #expect(!ThinningPreviewView.sentence(preview, done: false).isEmpty)
        #expect(ThinningPreviewView.sentence(ThinningReport(rule: .allButCheckpoints), done: false).hasPrefix("Nothing to remove"))
    }

    @Test func thinningProgressHeadline() {
        #expect(ThinningProgress(done: 120, total: 640, dryRun: true).headline == "Checking notes: 120 of 640")
        #expect(ThinningProgress(done: 3, total: 12, dryRun: false).headline == "Thinning notes: 3 of 12")
    }

    // MARK: - Menu

    @Test func saveVersionMenuCommand() {
        #expect(MenuCommand.saveVersion.title == "Save Version…")
        #expect(MenuLayout.note.flatMap { $0 }.contains(.saveVersion))
        var c = MenuCommand.Context(window: .library, vault: .unlocked)
        #expect(!MenuCommand.saveVersion.isEnabled(in: c))
        c.hasNote = true
        #expect(MenuCommand.saveVersion.isEnabled(in: c))
        c.noteDeleted = true
        #expect(!MenuCommand.saveVersion.isEnabled(in: c))
        #expect(!MenuCommand.saveVersion.isEnabled(in: MenuCommand.Context(window: .note, vault: .locked, hasNote: true)))
    }
}
