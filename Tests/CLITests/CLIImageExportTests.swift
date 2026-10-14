import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `export` options for images (docs/cli.md "Images in exports"). The
/// rendering itself is covered by SempereRenderTests.
final class CLIImageExportTests: CLITestCase {
    func testImageOptions() throws {
        let (_, _, key) = try makeVault()
        let vault = path("mine.sempere")
        let bad = try cli(["export", "--all", "--format", "pdf", "--assets", path("a"), "--out", path("o"),
                           "--vault", vault, "--identity", key])
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.err.contains("--assets only applies to --format svg"), bad.err)

        let svg = try cli(["export", "--all", "--format", "svg", "--assets", path("svg-assets"), "--out", path("svg"),
                           "--vault", vault, "--identity", key])
        XCTAssertEqual(svg.status, 0, svg.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("svg-assets")))
        XCTAssertFalse(svg.err.contains("warning"), svg.err)

        let pdf = try cli(["export", "--all", "--format", "pdf", "--keep-image-metadata", "--out", path("pdf"),
                           "--vault", vault, "--identity", key, "--json"])
        XCTAssertEqual(pdf.status, 0, pdf.err)
        XCTAssertEqual((pdf.json as? [[String: Any]])?.count, 2)
    }
}
