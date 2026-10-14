import Foundation
import Sempere
import XCTest

/// `SempereAbout`: the notice the CLI and the app print, and the third-party
/// list, checked against what the package and the app project actually link
/// and bundle (the app only builds in CI, so its project file is read here).
final class AboutTests: XCTestCase {
    static let repo = LocalizationCatalogTests.repo
    static let apps = LocalizationCatalogTests.apps

    func testNoticeIsTheStandardGPLNotice() {
        XCTAssertEqual(SempereAbout.copyright, "Copyright (C) 2026 Anthony Wertz.")
        XCTAssertEqual(SempereAbout.notice,
                       "This program comes with ABSOLUTELY NO WARRANTY. This is free software, and you are welcome to redistribute it under the terms of the GNU GPL v3 or later.")
        let text = SempereAbout.versionText(program: "sempere", version: "1.2.3")
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "sempere 1.2.3", "release.yml and the Homebrew test read the first line")
        XCTAssertTrue(text.contains(SempereAbout.licenseURL.absoluteString))
        XCTAssertTrue(text.contains(SempereAbout.securityPolicyURL.absoluteString))
    }

    func testLinksPointAtThisRepository() {
        for url in [SempereAbout.sourceURL, SempereAbout.securityPolicyURL, SempereAbout.reportVulnerabilityURL,
                    SempereAbout.securityDesignURL, SempereAbout.repositoryLicenseURL] {
            XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/anthonytw/sempere"), url.absoluteString)
        }
        // The files the links name exist in the repository.
        for path in ["SECURITY.md", "docs/security.md", "LICENSE", "LICENSE-EXCEPTION"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repo.appendingPathComponent(path).path), path)
        }
    }

    /// Every package in `Package.resolved` is acknowledged.
    func testEveryResolvedPackageIsListed() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("Package.resolved"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        let names = Set(SempereAbout.components.map { $0.name.lowercased() })
        XCTAssertFalse(pins.isEmpty)
        for pin in pins {
            let identity = try XCTUnwrap(pin["identity"] as? String)
            XCTAssertTrue(names.contains(identity.lowercased()), "\(identity) is not in SempereAbout.components")
        }
        let cli = Set(SempereAbout.components(for: .cli).map(\.name))
        XCTAssertTrue(cli.isSuperset(of: ["swift-crypto", "swift-argument-parser"]))
        XCTAssertFalse(cli.contains("SwiftMath"), "the CLI does not link SwiftMath")
    }

    /// Every Swift package the app project adds is acknowledged for the app,
    /// and the bundled notices name every component of the app.
    func testAppPackagesAndNoticesAreListed() throws {
        let pbx = Self.apps.appendingPathComponent("Sempere.xcodeproj/project.pbxproj")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pbx.path), "the app is not part of this checkout")
        let project = try String(contentsOf: pbx, encoding: .utf8)
        let app = SempereAbout.components(for: .app)
        let appNames = Set(app.map(\.name))
        let regex = try NSRegularExpression(pattern: #"XCRemoteSwiftPackageReference "([^"]+)""#)
        let found = Set(regex.matches(in: project, range: NSRange(project.startIndex..., in: project)).compactMap {
            Range($0.range(at: 1), in: project).map { String(project[$0]) }
        })
        XCTAssertFalse(found.isEmpty)
        for name in found { XCTAssertTrue(appNames.contains(name), "\(name) is not acknowledged for the app") }
        XCTAssertFalse(appNames.contains("swift-argument-parser"), "the app does not link the argument parser")

        let notices = try String(contentsOf: Self.apps.appendingPathComponent("SempereApp/ThirdPartyNotices.txt"), encoding: .utf8)
        for component in app {
            XCTAssertTrue(notices.contains(component.name), "ThirdPartyNotices.txt does not name \(component.name)")
        }
        XCTAssertTrue(notices.contains("Version 2.0, January 2004"), "the Apache-2.0 text is bundled")
        XCTAssertTrue(notices.contains("Permission is hereby granted, free of charge"), "the MIT text is bundled")
        XCTAssertTrue(notices.contains("SIL OPEN FONT LICENSE Version 1.1"), "the OFL text is bundled")
    }

    /// The app bundles the repository's own licence files (About ▸ Licence).
    func testAppBundlesTheLicence() throws {
        let pbx = Self.apps.appendingPathComponent("Sempere.xcodeproj/project.pbxproj")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pbx.path), "the app is not part of this checkout")
        let project = try String(contentsOf: pbx, encoding: .utf8)
        // The app target's Resources phase (the first one) lists both files.
        let phase = try XCTUnwrap(project.range(of: "A10000000000000000005001 /* Resources */ = {"))
        let body = project[phase.upperBound...].prefix(while: { $0 != "}" })
        XCTAssertTrue(body.contains("/* LICENSE in Resources */"))
        XCTAssertTrue(body.contains("/* LICENSE-EXCEPTION in Resources */"))
        XCTAssertTrue(project.contains("path = ../../LICENSE;"))
        XCTAssertTrue(project.contains("path = \"../../LICENSE-EXCEPTION\";"))
    }
}
