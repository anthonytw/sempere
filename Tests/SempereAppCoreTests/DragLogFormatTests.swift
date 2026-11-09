import Foundation
@testable import SempereAppCore
import TempDirSupport
import Testing

/// What the drag log keeps public (`DragLogFormat`; the logger is the app's `DragLog`). The classifier's test moved from
/// the app's `MacCatalystTests.aLoggedDragErrorKeepsOnlyItsClassifierPublic`, which keeps the app's own error type.
struct DragLogFormatTests {
    @Test func aLoggedErrorKeepsOnlyItsClassifierPublic() {
        let path = "/Users/someone/Secret plans.pdf"
        let error = NSError(domain: NSCocoaErrorDomain, code: 513,
                            userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "Secret plans could not be saved"])
        let kind = DragLogFormat.classify(error)
        #expect(kind.contains("domain=\(NSCocoaErrorDomain)"))
        #expect(kind.contains("code=513"))
        #expect(!kind.contains("Secret"), "no title or path in the public part")
        struct Plain: Error {}
        #expect(DragLogFormat.classify(Plain()).contains("Plain"))
    }

    @Test func aNoteIsAnEightDigitPrefix() {
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        #expect(DragLogFormat.id(id) == "abcdef12")
    }

    @Test func aThreadSaysMainOrBackground() {
        let text = DragLogFormat.thread
        #expect(text.hasPrefix("thread=main qos=") || text.hasPrefix("thread=bg qos="))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var off = ""
        Thread.detachNewThread {
            off = DragLogFormat.thread
            done.signal()
        }
        done.wait()
        #expect(off.hasPrefix("thread=bg qos="))
    }

    /// A file is described by its extension, size, existence and the last folders of its path: never its name.
    @Test func aFileIsDescribedWithoutItsName() throws {
        let dir = TestTemp.root.appendingPathComponent("SempereExport/model/export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Secret title.pdf")
        try Data("%PDF-1".utf8).write(to: file)
        let text = DragLogFormat.describe(file: file)
        #expect(text.contains("ext=pdf") && text.contains("bytes=6") && text.contains("regular=true") && text.contains("exists=true"))
        #expect(text.contains("folder=SempereExport/model/export-"))
        #expect(!text.contains("Secret"))
        let missing = DragLogFormat.describe(file: dir.appendingPathComponent("gone.pdf"))
        #expect(missing.contains("bytes=-1") && missing.contains("exists=false"))
    }
}
