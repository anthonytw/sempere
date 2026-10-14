import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere --version` and `sempere about`: the GPL notice and the links.
final class CLIAboutTests: CLITestCase {
    func testVersionPrintsVersionLineThenNotice() throws {
        let r = try cli(["--version"])
        XCTAssertEqual(r.status, 0, r.err)
        let lines = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Release checks compare the first line with `sempere <tag>`.
        XCTAssertTrue(lines[0].hasPrefix("sempere "), lines[0])
        XCTAssertNotNil(lines[0].range(of: #"^sempere \d+\.\d+\.\d+$"#, options: .regularExpression), lines[0])
        XCTAssertTrue(r.out.contains("Copyright (C) 2026 Anthony Wertz."))
        XCTAssertTrue(r.out.contains("This program comes with ABSOLUTELY NO WARRANTY. This is free software, and you are welcome to redistribute it under the terms of the GNU GPL v3 or later."))
        XCTAssertTrue(r.out.contains("https://www.gnu.org/licenses/gpl-3.0.html"))
        XCTAssertTrue(r.out.contains("https://github.com/anthonytw/sempere/blob/main/SECURITY.md"))
    }

    func testSubcommandVersionIsTheSame() throws {
        let root = try cli(["--version"])
        let sub = try cli(["about", "--version"])
        XCTAssertEqual(sub.status, 0, sub.err)
        XCTAssertEqual(sub.out, root.out)
    }

    func testAboutText() throws {
        let r = try cli(["about"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.hasPrefix("sempere "))
        XCTAssertTrue(r.out.contains("ABSOLUTELY NO WARRANTY"))
        XCTAssertTrue(r.out.contains("Report a vulnerability: https://github.com/anthonytw/sempere/security/advisories/new"))
        XCTAssertTrue(r.out.contains("Source: https://github.com/anthonytw/sempere"))
        XCTAssertTrue(r.out.contains("swift-crypto (Apache-2.0)"))
        XCTAssertTrue(r.out.contains("swift-argument-parser (Apache-2.0)"))
        // SwiftMath is in the app only.
        XCTAssertFalse(r.out.contains("SwiftMath"))
        // -v adds each component's note.
        let v = try cli(["about", "-v"])
        XCTAssertTrue(v.out.contains("BoringSSL"))
        // -q keeps only the version and the notice.
        let q = try cli(["about", "-q"])
        XCTAssertEqual(q.status, 0, q.err)
        XCTAssertEqual(q.out, try cli(["--version"]).out)
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
