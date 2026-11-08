import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Settings → Storage's words for the unused-attachments index (the index itself is tested in SempereAppCoreTests,
/// `AttachmentIndexTests`).
struct AttachmentIndexAppTests {
    let day: TimeInterval = 86400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func windowAndKindTexts() {
        let item = AttachmentStorageReport.Unused(note: UUID(), fileName: "f", kind: .audio, bytes: 1, firstSeen: t0,
                                                  deletableFrom: t0.addingTimeInterval(30 * day), lastUse: nil)
        #expect(StorageText.window(item, now: t0).contains("can be deleted from"))
        #expect(!StorageText.window(item, now: t0.addingTimeInterval(30 * day)).contains("can be deleted from"))
        let use = AttachmentIndexEntry.LastUse(revision: "r", wall: nil, type: "audio/mp4", size: 1, duration: 3725.4,
                                               title: "Lecture")
        #expect(StorageText.describe(kind: .audio, lastUse: use) == "Recording, 1:02:05, “Lecture”")
        #expect(StorageText.describe(kind: .image, lastUse: use) == "Image, “Lecture”")
        #expect(StorageText.describe(kind: .pdf, lastUse: nil) == "PDF")
    }
}
