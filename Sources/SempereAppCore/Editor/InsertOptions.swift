import Foundation

/// Which file the editor's file importer is choosing.
public enum EditorFileImport: Equatable, Sendable {
    case pdf, video
    /// A picture to replace an image with (Replace Image from Files).
    case image
    /// PDF pages for a pageless note: the note is switched to pages only
    /// once a PDF is picked, so canceling the picker changes nothing.
    case pdfSwitchingToPages
}

/// What a drop or a paste brings: image bytes, or a PDF or video clip copied into a work folder.
/// (The app's `CanvasDrop` reads the item providers into these.)
public enum CanvasDropContent: Sendable {
    case image(Data)
    case pdf(URL)
    /// A clip (format.md §8.2.7), copied into a work folder.
    case video(URL)
    /// Something that could not be read (too large, unreadable): why.
    case failed(String)
}

/// Which ways of adding images and PDFs the editor offers (pure, tested on
/// each platform): the camera only where there is one and never on a Mac,
/// PDF pages only on a paged note (a pageless note has one infinite page:
/// import the PDF as a new note instead).
public enum InsertOptions {
    /// Where the Insert menu's PDF entry puts the pages, for the app to word.
    public enum PDFPagesPlacement: Equatable, Sendable {
        /// A pageless note: it is switched to pages first (its one page stays the first).
        case switchToPages
        /// No page to go by.
        case anywhere
        /// After the last page.
        case atEnd
        /// After this page, 1-based.
        case afterPage(Int)
    }

    public static func offersCamera(isMac: Bool, cameraAvailable: Bool) -> Bool { !isMac && cameraAvailable }

    public static func offersPDFPages(pageless: Bool) -> Bool { !pageless }

    /// What the Insert menu's PDF entry picks: on a pageless note the switch
    /// to pages waits for the PDF (`EditorInsert.preparePages`), so a
    /// canceled picker leaves the note as it was.
    public static func pdfImport(pageless: Bool) -> EditorFileImport { pageless ? .pdfSwitchingToPages : .pdf }

    /// Where the Insert menu's PDF entry puts the pages: after the
    /// current page (`pageIndex`, 0-based) of a paged note; a pageless note
    /// is switched to pages first.
    public static func pdfPagesPlacement(pageless: Bool, pageIndex: Int, pageCount: Int) -> PDFPagesPlacement {
        if pageless { return .switchToPages }
        if pageCount <= 0 { return .anywhere }
        let n = min(max(pageIndex, 0), pageCount - 1) + 1
        return n == pageCount ? .atEnd : .afterPage(n)
    }

    /// Where the `index`-th of several images added at once goes: each a
    /// little further down and right, so none hides another.
    public static func cascade(_ point: CGPoint?, index: Int) -> CGPoint? {
        point.map { CGPoint(x: $0.x + CGFloat(index) * 20, y: $0.y + CGFloat(index) * 20) }
    }
}
