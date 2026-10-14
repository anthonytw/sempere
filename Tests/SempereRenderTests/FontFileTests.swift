import Foundation
import Sempere
import XCTest

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import SempereRender

/// Font files come from directories anyone on the machine may have put
/// files in (`SEMPERE_FONT_DIR`, `~/.local/share/sempere/fonts`, system
/// folders): read as bounded regular files, never blocking (format.md §9).
final class FontFileTests: XCTestCase {
    func testAFIFONamedLikeAFontIsRefusedWithoutBlocking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("Trap-Regular.ttf")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        XCTAssertThrowsError(try OpenTypeFont(contentsOf: fifo))
        // A pack directory holding it: the scan skips it and finds nothing.
        let library = FontLibrary(bundled: nil, packs: [dir])
        XCTAssertNil(library.fallback(for: 0x4E2D, lang: nil, generic: .sans, bold: false, italic: false))
    }
}
