import Foundation
import Sempere
import SempereAppCore
import SempereRender
import Testing
@testable import SempereApp

/// The app's words for the inserts' and opened files' values (`Insert+Text.swift`; the model's cases are the core's
/// `InsertTests` and `OpenedFilesTests`), and the platform's preparation the app hands the model.
@MainActor
struct InsertTextTests {
    @Test func theNoticesSayWhatFailedAndWhy() {
        let why = ImagePreparation.Failure.unreadable
        #expect(InsertNotice.imageNotAdded(why).text == "Could not add the image. \(why.description)")
        #expect(InsertNotice.imageNotReplaced(why).text == "Could not replace the image. \(why.description)")
        #expect(InsertNotice.pdfNotImported(PDFLocked.needsPassword).text
                == "Could not import the PDF. This PDF is protected with a password.")
        #expect(InsertNotice.videoNotAdded(VideoPreparation.Failure.unreadable).text
                == "Could not add the video. This file is not a video Sempere can read.")
        #expect(InsertNotice.fileNotOpened(name: "Paper.pdf", CocoaError(.fileNoSuchFile)).text.hasPrefix("Could not open “Paper.pdf”. "))
        #expect("\(PDFLocked.wrongPassword)" == "That password does not open this PDF.")
    }

    /// The model's alert and the detail pane's failure are typed (step 7); the app words them as the strings were
    /// before: a thrown error as its description, a notice as its sentence, the app's own sentence as given.
    @Test func theAlertAndTheEditorFailureAreWordedAsBefore() {
        let pageless = InsertNotice.pdfNotImported(AttachmentOpsError.pagelessNote)
        #expect(AppModelAlert.insert(pageless).text == pageless.text)
        #expect(AppModelAlert.notice(.transcriptionModelMissing).text == AppModelNotice.transcriptionModelMissing.text)
        #expect(AppModelAlert.error(AppModelError.noVaultOpen).text == "\(AppModelError.noVaultOpen)")
        #expect(AppModelAlert.worded("Could not paste: x").text == "Could not paste: x")
        #expect(EditorFailure.unreadable(nil).text == "This note could not be read.")
        #expect(EditorFailure.unreadable(.deleted).text == NoteReadOnly.deleted.text)
        #expect(EditorFailure.failed(AppModelError.noteNotFound).text == "\(AppModelError.noteNotFound)")
    }

    @Test func tooLargeFilesNameTheirSizeAndTheLimit() {
        let pdf = "\(AttachmentTooLarge.pdf(2 << 30))"
        #expect(pdf.hasPrefix("This PDF is too large to add (2 GB; at most 1 GB)"), "\(pdf)")
        let video = "\(AttachmentTooLarge.video(3 << 30))"
        #expect(video.hasSuffix("Trim it first."), "\(video)")
        #expect(video.contains("3 GB"))
        #expect(AppModel.describe(AttachmentTooLarge.pdf(2 << 30)) == pdf)
    }

    @Test func describeWordsEveryPreparationError() {
        #expect(AppModel.describe(PDFPreparation.Failure.pages("the PDF has no pages")) == "The PDF has no pages.")
        #expect(AppModel.describe(AttachmentOpsError.pagelessNote).contains("pageless"))
        #expect(AppModel.describe(ImageIngestError.unsupportedFormat) == ImageIngestError.unsupportedFormat.description)
    }

    @Test func theOpenedVaultAlertNamesTheOpenVault() {
        let named = AppModel.OpenedVaultConfirmation(url: URL(fileURLWithPath: "/x/B.sempere"), name: "B", current: "A")
        #expect(named.currentName == "A")
        let unnamed = AppModel.OpenedVaultConfirmation(url: URL(fileURLWithPath: "/x/B.sempere"), name: "B", current: nil)
        #expect(unnamed.currentName == "Vault")
    }

    /// The model prepares with the platform's frameworks in the app (PDFKit and Core Graphics, ImageIO,
    /// AVFoundation) and tells PDFs by their `UTType`.
    @Test func theAppPreparesWithItsFrameworks() throws {
        #expect(AppHost.makeServices().attachmentPreparation is AppAttachmentPreparation)
        let url = try PDFImportTests.makePDF(pages: 1)
        defer { ImportWorkFolder.discard(url) }
        let typed = url.deletingLastPathComponent().appendingPathComponent("typed.pdf")
        try FileManager.default.copyItem(at: url, to: typed)
        #expect(AppAttachmentPreparation().isPDFType(typed))
        #expect(!AppAttachmentPreparation().isPDFType(URL(fileURLWithPath: "/x/Notes.sempere", isDirectory: true)))
        let encrypted = try PDFImportTests.makePDF(pages: 1, userPassword: "pw", ownerPassword: "owner")
        defer { ImportWorkFolder.discard(encrypted) }
        #expect(throws: PDFLocked.needsPassword) { try AppAttachmentPreparation().preparePDF(encrypted, password: nil) }
    }
}
