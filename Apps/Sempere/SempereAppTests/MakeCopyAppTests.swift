import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// "Make a Copy…" in the app: the menu entry, the sheet's words and the result's lines. The model's runs are
/// `MakeCopyTests` in `SempereAppCoreTests`; the copy itself is `VaultCopierTests`.
@MainActor
struct MakeCopyAppTests {
    @Test func fileMenuCommand() {
        #expect(MenuCommand.makeCopy.title == "Make a Copy…")
        #expect(MenuLayout.all.contains(.makeCopy))
        #expect(MenuCommand.makeCopy.shortcut == nil, "no shortcut to clash with UIKit's menus")
        #expect(MenuCommand.makeCopy.isEnabled(in: MenuCommand.Context(window: .library, vault: .unlocked, canMakeCopy: true)))
        // A read-only vault is the point; a writable one too.
        #expect(MenuCommand.makeCopy.isEnabled(in: MenuCommand.Context(window: .library, vault: .unlocked,
                                                                       vaultReadOnly: true, canMakeCopy: true)))
        #expect(!MenuCommand.makeCopy.isEnabled(in: MenuCommand.Context(window: .library, vault: .unlocked)),
                "notes still downloading")
        #expect(!MenuCommand.makeCopy.isEnabled(in: MenuCommand.Context(window: .library, vault: .locked, canMakeCopy: true)))
    }

    @Test func theDefaultNameAndTheProgressWords() {
        #expect(MakeCopySheet.defaultName(source: "Work") == "Work Copy")
        #expect(MakeCopySheet.progressText(CopyProgress(done: 2, total: 10, notes: 2, blobBytes: 0)) == "Copying note 3 of 10")
        #expect(MakeCopySheet.progressText(CopyProgress(done: 10, total: 10, notes: 10, blobBytes: 0)) == "Copying note 10 of 10")
    }

    @Test func everyNoticeHasWords() {
        for notice in [MakeCopyNotice.newerContent, .unconfirmedList, .removedDevice, .recoveryKey] {
            #expect(!MakeCopySheet.words(notice).isEmpty)
        }
    }

    @Test func aCopyWithProblemsIsNeverPresentedAsComplete() {
        var report = CopyReport(sourceVaultId: "x")
        report.notes = 3
        #expect(MakeCopySheet.lines(report) == ["3 notes copied"])
        report.failed = [.init(note: "n", reason: "r")]
        report.deletedSkipped = 1
        report.newer = [.init(note: "n", skippedOps: [:], skippedElements: 0, unreadableRevisions: 0, newerRevisions: 1)]
        let lines = MakeCopySheet.lines(report)
        #expect(lines.count == 4)
        #expect(lines.contains { $0.contains("could not be copied") })
        #expect(lines.contains { $0.contains("newer version") })
    }
}
