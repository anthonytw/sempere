import ArgumentParser
import Foundation
import Sempere

/// `sempere about`: the version, the GPL notice, the links (licence, security
/// policy, source) and the third-party software in this build.
struct AboutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "about",
        abstract: "Print the version, the licence and warranty notice, links, and third-party software.",
        discussion: """
            Sempere is free software under the GNU GPL v3 or later and comes with no warranty.
            `--version` prints the same notice without the third-party list.
            """
    )

    @OptionGroup var output: OutputOptions

    /// The `--json` shape.
    struct Report: Encodable {
        var program: String
        var version: String
        var copyright: String
        var notice: String
        var license: String
        var licenseURL: URL
        var repositoryLicenseURL: URL
        var sourceURL: URL
        var securityPolicyURL: URL
        var reportVulnerabilityURL: URL
        var securityDesignURL: URL
        var thirdParty: [SempereAbout.Component]
    }

    static var report: Report {
        Report(program: "sempere", version: sempereVersion, copyright: SempereAbout.copyright,
               notice: SempereAbout.notice, license: SempereAbout.licenseIdentifier,
               licenseURL: SempereAbout.licenseURL, repositoryLicenseURL: SempereAbout.repositoryLicenseURL,
               sourceURL: SempereAbout.sourceURL, securityPolicyURL: SempereAbout.securityPolicyURL,
               reportVulnerabilityURL: SempereAbout.reportVulnerabilityURL,
               securityDesignURL: SempereAbout.securityDesignURL,
               thirdParty: SempereAbout.components(for: .cli))
    }

    func run() throws {
        if output.json {
            try output.emitJSON(Self.report)
            return
        }
        print(SempereAbout.versionText(program: "sempere", version: sempereVersion))
        if output.quiet { return }
        print("Source: \(SempereAbout.sourceURL.absoluteString)")
        print("Report a vulnerability: \(SempereAbout.reportVulnerabilityURL.absoluteString)")
        print("Security design and limits: \(SempereAbout.securityDesignURL.absoluteString)")
        print("")
        print("Third-party software in this build:")
        for c in SempereAbout.components(for: .cli) {
            print("  \(c.name) (\(c.license)), \(c.url.absoluteString)")
            if output.verbose { print("    \(c.note)") }
        }
    }
}
