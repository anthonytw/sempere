import Foundation

/// What Sempere says about itself: the copyright and no-warranty notice, the
/// links behind it and the third-party software each product ships. The CLI
/// (`sempere --version`, `sempere about`) and the app's About screen both read
/// it, so the wording and the links live in one place.
///
/// The notice is the one the GPL suggests for interactive programs (GPL-3
/// "How to Apply These Terms"); it states the licence and the absence of a
/// warranty, and promises nothing.
public enum SempereAbout {
    /// The copyright line.
    public static let copyright = "Copyright (C) 2026 Anthony Wertz."

    /// The standard GPL-3 notice, after the copyright line.
    public static let notice = """
        This program comes with ABSOLUTELY NO WARRANTY. This is free software, and you are \
        welcome to redistribute it under the terms of the GNU GPL v3 or later.
        """

    /// The project's licence identifier (`LICENSE`, `LICENSE-EXCEPTION`).
    public static let licenseIdentifier = "GPL-3.0-or-later WITH LicenseRef-Sempere-App-Store-Exception"

    /// The full text of the GNU GPL v3.
    public static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    /// The repository's own copy of the licence and its App Store exception.
    public static let repositoryLicenseURL = URL(string: "https://github.com/anthonytw/sempere/blob/main/LICENSE")!
    /// The source code.
    public static let sourceURL = URL(string: "https://github.com/anthonytw/sempere")!
    /// The security policy: how to report a vulnerability and what happens next.
    public static let securityPolicyURL = URL(string: "https://github.com/anthonytw/sempere/blob/main/SECURITY.md")!
    /// GitHub's private vulnerability reporting form for the repository.
    public static let reportVulnerabilityURL = URL(string: "https://github.com/anthonytw/sempere/security/advisories/new")!
    /// The security design and its limits (what the encryption does and does not protect).
    public static let securityDesignURL = URL(string: "https://github.com/anthonytw/sempere/blob/main/docs/security.md")!

    /// Which build of Sempere ships a component.
    public enum Product: String, Codable, Sendable, CaseIterable {
        case cli
        case app
    }

    /// Third-party software compiled into, or bundled with, a product.
    public struct Component: Codable, Sendable, Equatable {
        /// The project's name.
        public var name: String
        /// SPDX expression of its licence(s).
        public var license: String
        /// Where to find it.
        public var url: URL
        /// One line on what it is and what it contains.
        public var note: String
        /// The products that ship it.
        public var products: [Product]
    }

    /// Every third-party component, in display order. Package checkouts and the
    /// app's Swift packages are checked against this list by the tests
    /// (`AboutTests`), so a new dependency must be added here.
    public static let components: [Component] = [
        Component(name: "swift-crypto", license: "Apache-2.0",
                  url: URL(string: "https://github.com/apple/swift-crypto")!,
                  note: "Cryptography. On Apple platforms a layer over CryptoKit; on Linux it includes BoringSSL (Apache-2.0; fiat-crypto parts MIT OR Apache-2.0 OR BSD-1-Clause) and XKCP Keccak (CC0-1.0).",
                  products: [.cli, .app]),
        // Resolved for swift-crypto's extras, which Sempere does not link (only its `Crypto` product).
        Component(name: "swift-asn1", license: "Apache-2.0",
                  url: URL(string: "https://github.com/apple/swift-asn1")!,
                  note: "ASN.1 encoding for swift-crypto's extras; resolved by the package manager, not linked into Sempere.",
                  products: []),
        Component(name: "swift-argument-parser", license: "Apache-2.0",
                  url: URL(string: "https://github.com/apple/swift-argument-parser")!,
                  note: "Command-line parsing.",
                  products: [.cli]),
        Component(name: "SwiftMath", license: "MIT",
                  url: URL(string: "https://github.com/mgriebling/SwiftMath")!,
                  note: "Equation typesetting, based on iosMath (MIT). Its math fonts are under the SIL Open Font License 1.1, the GUST Font License and the STIX Font License.",
                  products: [.app]),
        Component(name: "Noto fonts", license: "OFL-1.1",
                  url: URL(string: "https://fonts.google.com/noto")!,
                  note: "Text in exports on systems without the app's fonts.",
                  products: [.cli]),
        Component(name: "zlib", license: "Zlib",
                  url: URL(string: "https://zlib.net")!,
                  note: "Compression, from the system library.",
                  products: [.cli, .app]),
    ]

    /// The components a product ships, in display order.
    public static func components(for product: Product) -> [Component] {
        components.filter { $0.products.contains(product) }
    }

    /// The text `sempere --version` prints: the version line, the notice and
    /// the links. The first line is `sempere VERSION` (release checks read it).
    public static func versionText(program: String, version: String) -> String {
        """
        \(program) \(version)
        \(copyright)
        \(notice)
        License: \(licenseURL.absoluteString) (with an App Store exception: \(repositoryLicenseURL.absoluteString))
        Security: \(securityPolicyURL.absoluteString)
        """
    }
}
