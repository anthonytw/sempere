import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The small pure rules of the editor's gestures and menus: where text boxes go and the colors the style bar offers,
/// how far a page scrolls, what the Insert menu offers, the mouse-smoothing setting and the title-pattern field.
struct EditorRulesTests {
    // MARK: Text boxes

    @Test func newBoxesStartWhereTapped() {
        let f = TextBoxPlacement.newFrame(at: ItemFrames.Point(x: 100, y: 200), pageWidth: 612, size: 20)
        #expect(f == Rect(x: 100, y: 188, w: 320, h: 24))
        // Near the right edge: narrower, down to the minimum, then moved left.
        #expect(TextBoxPlacement.newFrame(at: ItemFrames.Point(x: 500, y: 10), pageWidth: 612, size: 10).w == 96)
        let edge = TextBoxPlacement.newFrame(at: ItemFrames.Point(x: 600, y: 10), pageWidth: 612, size: 10)
        #expect(edge.w == 60 && edge.x == 552 && edge.y == 4)
        let box = Item.text(TextContent(size: 14, color: .black, runs: [TextRun("Hello")]), frame: Rect(x: 10, y: 10, w: 200, h: 40), z: "a")
        #expect(TextBoxPlacement.textBox(at: ItemFrames.Point(x: 20, y: 20), in: [box], zoom: 1)?.id == box.id)
        #expect(TextBoxPlacement.textBox(at: ItemFrames.Point(x: 400, y: 400), in: [box], zoom: 1) == nil)
    }

    /// The pen's own color comes first when the palette lacks it, opaque; a swatch is named by the palette, the pen
    /// or its hex value.
    @Test func textColoursAreThePensPalette() {
        let palette = [Sempere.Color(r: 0, g: 0, b: 0), Sempere.Color(r: 0, g: 122, b: 255), Sempere.Color(r: 255, g: 59, b: 48)]
        #expect(TextColourPalette.Standard.allCases.count == 5)
        #expect(TextColourPalette.swatches(pen: nil, standard: palette) == palette)
        #expect(TextColourPalette.swatches(pen: palette[1], standard: palette) == palette, "already there")
        let teal = Sempere.Color(r: 0, g: 128, b: 128, a: 100)
        let withPen = TextColourPalette.swatches(pen: teal, standard: palette)
        #expect(withPen.first == Sempere.Color(r: 0, g: 128, b: 128), "first, opaque")
        #expect(withPen.count == palette.count + 1)
        #expect(TextColourPalette.label(of: palette[2], standard: palette, pen: teal) == .standard(index: 2))
        #expect(TextColourPalette.label(of: teal, standard: palette, pen: teal) == .pen)
        #expect(TextColourPalette.label(of: Sempere.Color(r: 1, g: 2, b: 255), standard: palette, pen: nil) == .hex("#0102FF"))
    }

    // MARK: Pages

    @Test func theScrollExtentRuleIsTheSameWithoutAView() {
        let infinite = PageSize(width: 612, height: 792, infinite: true)
        // A phone's screen in page points at the fitted zoom: 956 / (440 / 612).
        let viewport = 956.0 / (440.0 / 612.0)
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: nil, viewportHeight: viewport) == 792 + viewport)
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 3000, viewportHeight: viewport) == 3000 + viewport,
                "past the stored height the ink decides")
        let letter = PageSize(width: 612, height: 792, infinite: false, breakHeight: 792)
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 500) == 792)
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 2000) == 2000, "never less than a screen")
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 500,
                                        footerHeight: PageExtent.footerScreenHeight) == 792 + 120)
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: .infinity, viewportHeight: .nan) == 792, "non-finite counts as 0")
    }

    // MARK: Insert

    @Test func theInsertMenuOffersWhatTheDeviceHas() {
        #expect(InsertOptions.offersCamera(isMac: false, cameraAvailable: true), "iPad and iPhone")
        #expect(!InsertOptions.offersCamera(isMac: false, cameraAvailable: false), "the simulator has none")
        #expect(!InsertOptions.offersCamera(isMac: true, cameraAvailable: true), "Mac (Catalyst)")
        #expect(InsertOptions.offersPDFPages(pageless: false))
        #expect(!InsertOptions.offersPDFPages(pageless: true))
        #expect(InsertOptions.pdfImport(pageless: true) == .pdfSwitchingToPages)
        #expect(InsertOptions.pdfImport(pageless: false) == .pdf)
    }

    @Test func severalImagesCascade() {
        #expect(InsertOptions.cascade(nil, index: 3) == nil)
        #expect(InsertOptions.cascade(CGPoint(x: 10, y: 10), index: 0) == CGPoint(x: 10, y: 10))
        #expect(InsertOptions.cascade(CGPoint(x: 10, y: 10), index: 2) == CGPoint(x: 50, y: 50))
    }

    @Test func pdfPagesGoAfterTheCurrentPageOrSwitchAPagelessNote() {
        func place(pageless: Bool = false, _ i: Int, _ n: Int) -> InsertOptions.PDFPagesPlacement {
            InsertOptions.pdfPagesPlacement(pageless: pageless, pageIndex: i, pageCount: n)
        }
        #expect(place(0, 3) == .afterPage(1))
        #expect(place(1, 3) == .afterPage(2))
        #expect(place(2, 3) == .atEnd)
        #expect(place(9, 3) == .atEnd)
        #expect(place(-4, 3) == .afterPage(1))
        #expect(place(0, 0) == .anywhere)
        #expect(place(pageless: true, 0, 1) == .switchToPages)
    }

    // MARK: Mouse smoothing

    @Test func onlyThePointerOnAMacWithAnInkToolIsSmoothed() {
        func takes(isMac: Bool = true, level: StrokeSmoothing.Level = .light, editable: Bool = true,
                   inking: Bool = true, ruler: Bool = false) -> Bool {
            MouseSmoothing.takesPointer(isMac: isMac, level: level, editable: editable, inkingTool: inking, rulerActive: ruler)
        }
        #expect(takes())
        #expect(takes(level: .strong))
        #expect(!takes(isMac: false), "the iPad is unchanged: PencilKit draws")
        #expect(!takes(level: .off), "Off: PencilKit draws the pointer, as before")
        #expect(!takes(editable: false))
        #expect(!takes(inking: false), "eraser and lasso stay PencilKit's (or the object eraser's)")
        #expect(!takes(ruler: true), "the ruler snaps PencilKit's own strokes")
    }

    @Test func theSettingDefaultsToOff() {
        #expect(MouseSmoothing.load(from: MemoryKeyValueStore()) == .off)
        #expect(MouseSmoothing.load(from: MemoryKeyValueStore([MouseSmoothing.key: StrokeSmoothing.Level.strong.rawValue])) == .strong)
        #expect(MouseSmoothing.load(from: MemoryKeyValueStore([MouseSmoothing.key: StrokeSmoothing.Level.off.rawValue])) == .off)
        #expect(MouseSmoothing.load(from: MemoryKeyValueStore([MouseSmoothing.key: "wobbly"])) == .off)
    }

    // MARK: Title pattern

    @Test func customPatternsArePreviewedOrRefused() {
        let now = Date(timeIntervalSince1970: 1_791_383_400)   // 2026-10-07 14:30 UTC
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(TitlePatternCheck.status(of: "'Day' d, EEE", now: now, locale: posix, timeZone: utc) == .preview("Day 7, Wed"))
        guard case .invalid(.unknownLetter) = TitlePatternCheck.status(of: "Lesson d", now: now, locale: posix, timeZone: utc) else {
            Issue.record("no unknown letter reported")
            return
        }
        #expect(TitlePatternCheck.status(of: "  ", now: now) == .empty)
        #expect(TitlePatternCheck.status(of: "'open", now: now) == .invalid(.unclosedQuote))
        for field in TitlePatternCheck.Field.allCases { #expect(DefaultTitle.check(field.pattern) == nil, "\(field)") }
    }
}
