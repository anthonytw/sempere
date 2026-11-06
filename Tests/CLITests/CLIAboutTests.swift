import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere --version` and `sempere about`: the notice and the links.
final class CLIAboutTests: CLITestCase {
    /// `--version` is `sempere X.Y.Z` (release checks compare that line with the tag) and then the notice
    /// `SempereAbout` holds; `about --version` and `about -q` print the same; `about` starts with the version and
    /// `-v` adds each component's note. The notice's wording is `SempereAbout`'s (and `AboutTests`'): no literal copy here.
    func testVersionPrintsVersionLineThenNotice() throws {
        let r = try cli(["--version"])
        XCTAssertEqual(r.status, 0, r.err)
        let lines = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertNotNil(lines[0].range(of: #"^sempere \d+\.\d+\.\d+$"#, options: .regularExpression), lines[0])
        XCTAssertTrue(r.out.contains(SempereAbout.notice), r.out)
        XCTAssertEqual(try cli(["about", "--version"]).out, r.out)
        XCTAssertEqual(try cli(["about", "-q"]).out, r.out)
        let about = try cli(["about"])
        XCTAssertEqual(about.status, 0, about.err)
        XCTAssertTrue(about.out.hasPrefix("sempere "))
        XCTAssertFalse(about.out.contains("SwiftMath"), "SwiftMath is in the app only")
        let v = try cli(["about", "-v"])
        XCTAssertTrue(v.out.contains("BoringSSL"), "-v adds each component's note")
    }

    func testAboutJSON() throws {
        let r = try cli(["about", "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let obj = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(obj["program"] as? String, "sempere")
        XCTAssertEqual(obj["copyright"] as? String, SempereAbout.copyright)
        XCTAssertEqual(obj["notice"] as? String, SempereAbout.notice)
        XCTAssertEqual(obj["license"] as? String, "GPL-3.0-or-later WITH LicenseRef-Sempere-App-Store-Exception")
        XCTAssertEqual(obj["securityPolicyURL"] as? String, "https://github.com/anthonytw/sempere/blob/main/SECURITY.md")
        XCTAssertEqual(obj["reportVulnerabilityURL"] as? String,
                       "https://github.com/anthonytw/sempere/security/advisories/new")
        let version = try XCTUnwrap(obj["version"] as? String)
        XCTAssertTrue(try cli(["--version"]).out.hasPrefix("sempere \(version)\n"))
        let parts = try XCTUnwrap(obj["thirdParty"] as? [[String: Any]])
        let names = parts.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, SempereAbout.components(for: .cli).map(\.name))
        for p in parts {
            XCTAssertNotNil(p["license"] as? String)
            XCTAssertNotNil(p["url"] as? String)
            XCTAssertEqual(p["products"] as? [String] == nil, false)
        }
    }
}
