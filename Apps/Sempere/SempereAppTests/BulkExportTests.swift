import Foundation
import Sempere
import SempereAppCore
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// "Export to Folder or Zip…" in the app: the menu, the sheet's words and the zip's hand-off. The model's runs are
/// `BulkExportTests` in `SempereAppCoreTests`.
@MainActor
struct BulkExportAppTests {
    func folder() throws -> URL {
        try BrowserTests.tempDir().appendingPathComponent("bulk-out", isDirectory: true)
    }

    /// Files below `dir` (not the hidden manifest), relative to it.
    func files(_ dir: URL) -> [String] { TS.regularFiles(under: dir, skipHidden: true) }

    func run(_ model: AppModel, _ scope: BulkExportScope, _ options: BulkExportOptions, into dir: URL,
             progress: @escaping @MainActor (BulkExportProgress) -> Void = { _ in }) async throws -> BulkExportResult {
        let jobs = model.bulkExportJobs(scope, options: options)
        let session = try BulkExportSession(destination: .folder(dir), options: options, jobs: jobs)
        return try await model.runBulkExport(jobs, session: session, progress: progress)
    }

    @Test func theSheetsTitle() {
        #expect(BulkExportRequest(scope: .vault).title == "All Notes")
        #expect(BulkExportRequest(scope: .notes([UUID(), UUID(), UUID()])).title == "3 Notes")
        #expect(BulkExportRequest(scope: .notebook("School/Math")).title == "Notebook “Math”")
    }

    @Test func fileMenuCommand() {
        #expect(MenuCommand.bulkExport.title == "Export to Folder or Zip…")
        #expect(MenuLayout.all.contains(.bulkExport))
        #expect(!MenuCommand.bulkExport.isEnabled(in: MenuCommand.Context(window: .library, vault: .locked)))
        #expect(MenuCommand.bulkExport.isEnabled(in: MenuCommand.Context(window: .library, vault: .unlocked)))
        #expect(!MenuCommand.bulkExport.isEnabled(in: MenuCommand.Context(window: .note, vault: .unlocked)))
    }

    @Test func sheetDescribesTheShape() {
        for format in BulkExportFormat.allCases {
            #expect(BulkExportSheet.shape(BulkExportOptions(format: format), zip: false).contains("skips"))
            #expect(BulkExportSheet.shape(BulkExportOptions(format: format), zip: true).contains("zip"))
        }
    }

    /// The finished zip's Share… and Save… go through `ExportHandOff` like a
    /// single note's export (#103): on a Mac UIKit presents them from the
    /// button, never a SwiftUI sheet hosted in this sheet (the build 7 Mac
    /// export crash); elsewhere, or before the anchor exists, the sheets.
    @Test func theZipHandOffAvoidsSwiftUISheetsOnAMac() {
        let zip = [URL(fileURLWithPath: "/tmp/notes.zip")]
        var sheets: [Bool] = []
        let anchor = PresentationAnchor.Box()
        for save in [false, true] {
            #expect(!ExportHandOff.deliver(zip, save: save, anchor: anchor, isMac: true) { sheets.append($0) })
        }
        #expect(sheets == [false, true], "no anchor yet: the sheets")
        let view = UIView()
        anchor.view = view
        sheets = []
        for save in [false, true] {
            #expect(ExportHandOff.deliver(zip, save: save, anchor: anchor, isMac: true) { sheets.append($0) })
            #expect(!ExportHandOff.deliver(zip, save: save, anchor: anchor, isMac: false) { sheets.append($0) })
        }
        #expect(sheets == [false, true], "a Mac never uses the SwiftUI sheets once the anchor exists")
    }
}
