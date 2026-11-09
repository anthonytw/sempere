import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// New-note layouts (`NewNoteLayout`) and the page strip's rules (`PageStrip`).
struct PageLayoutChoiceTests {
    @Test func newNoteLayouts() throws {
        #expect(NewNoteLayout.letter.pageSize == .letter)
        #expect(NewNoteLayout.a4.pageSize == .a4)
        #expect(NewNoteLayout.pagelessA4.pageSize == PageSize(width: 595, height: 842, infinite: true, breakHeight: 842))
        let defaults = MemoryKeyValueStore()
        #expect(NewNoteLayout.load(from: defaults) == .letter)
        NewNoteLayout.save(.pagelessLetter, to: defaults)
        #expect(NewNoteLayout.load(from: defaults) == .pagelessLetter)
    }

    @Test func stripMoveIndexAndThumbnailSize() {
        #expect(PageStrip.targetIndex(from: 0, toOffset: 2) == 1)   // down past one row
        #expect(PageStrip.targetIndex(from: 2, toOffset: 0) == 0)
        #expect(PageStrip.targetIndex(from: 1, toOffset: 3) == 2)
        #expect(PageStrip.thumbnailHeight(width: 85, pageSize: .letter) == 110)
        #expect(PageStrip.thumbnailHeight(width: 100, pageSize: PageSize(width: .nan, height: 1)) == 100 * 11 / 8.5)
    }
}
