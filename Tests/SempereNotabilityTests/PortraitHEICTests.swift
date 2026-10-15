import Foundation
import ImportTestSupport
import Sempere
import XCTest
@testable import SempereNotability

/// Device check c35 ("Portrait HEIC from Notability"), without an iPhone: `Fixtures/notability/portrait.heic` is a
/// landscape 240 × 160 HEIC (left half red, right half blue, a green square top-left) whose `irot` turns it upright
/// to portrait 160 × 240 with red on top, written by ImageIO as an iPhone writes portrait photos.
/// `portrait-heic.note` wraps it in a Notability note; the app's tests import it and check the pixels of the
/// canvas and of PDF and PNG exports (`PortraitHEICAppTests`). `SEMPERE_UPDATE_FIXTURES=1` rewrites the note.
final class PortraitHEICTests: NotabilityTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/notability")
    static let imagePath = "Images/IMG_0001.HEIC"

    static func package() throws -> Data {
        let heic = try Data(contentsOf: fixtures.appendingPathComponent("portrait.heic"))
        let session = SyntheticNote.session(typed: "", curves: [], media: { a in
            [AttachmentFixtures.imageObject(&a, file: imagePath, origin: (100, 100), size: (160, 240))]
        }, name: "Portrait photo")
        var files = SyntheticNote.files(curves: [], handwriting: false).filter { !$0.0.hasSuffix("Session.plist") }
        files = files.map { $0.0.hasSuffix("metadata.plist")
            ? ($0.0, SyntheticNote.metadata(uuid: "5A1E0000-0000-4000-8000-0000000000C5", name: "Portrait photo")) : $0 }
        files.append(("Synthetic note/Session.plist", session))
        files.append(("Synthetic note/" + imagePath, heic))
        return TestZip.write(files.map { .init(path: $0.0, data: $0.1, deflate: !$0.0.hasSuffix(".png")) })
    }

    func testFixtureIsCurrent() throws {
        let url = Self.fixtures.appendingPathComponent("portrait-heic.note")
        let data = try Self.package()
        if ProcessInfo.processInfo.environment["SEMPERE_UPDATE_FIXTURES"] == "1" { try data.write(to: url) }
        XCTAssertEqual(try Data(contentsOf: url), data, "run with SEMPERE_UPDATE_FIXTURES=1 to regenerate")
    }

    func testThePortraitPhotoIsStoredWithItsTurnAndAPortraitSize() throws {
        let (r, state) = try importFile(try Self.package(), into: try makeVault())
        XCTAssertEqual(r.attachments.images, 1)
        let item = try XCTUnwrap(state.pages.first?.items.first)
        XCTAssertEqual(item.blob?.type, "image/heic")
        XCTAssertEqual(item.pixelSize, Size(w: 160, h: 240), "upright size")
        XCTAssertEqual(item.orientation, 6, "irot: one anticlockwise quarter turn of the display = EXIF 6")
        XCTAssertGreaterThan(item.frame.h, item.frame.w, "a portrait frame")
    }
}
