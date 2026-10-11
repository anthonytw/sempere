import Foundation
import XCTest

/// Security review 2026-10 stage 4, S14 (and P2): a vault's secret key leaves the app only through
/// `SecretPasteboard` (local only, expiring) or a share sheet without Copy (`SecretSharing`). The new-vault
/// and upgrade screens had a `ShareLink` of the raw key, whose Copy puts it on the general pasteboard with
/// no expiry (Universal Clipboard, clipboard managers), and selectable key text, whose ⌘C does the same.
/// The app builds only in the CI `app` job, so this reads the sources (on Linux too, in every `swift test`).
final class SecretKeySharingTests: XCTestCase {
    static let appSources = LocalizationCatalogTests.apps.appendingPathComponent("SempereApp")
    /// The views that show a secret key.
    static let keyViews = ["NewVaultView.swift", "MigrationView.swift", "KeysWindowView.swift", "KeyExportViews.swift"]

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.appSources.path),
                          "the app sources are not part of this checkout")
    }

    func source(_ name: String) throws -> String {
        try String(contentsOf: Self.appSources.appendingPathComponent(name), encoding: .utf8)
    }

    func testSecretKeysAreNeverSharedWithCopyOrSelectable() throws {
        for name in Self.keyViews {
            let text = try source(name)
            XCTAssertFalse(text.contains("ShareLink("), "\(name): share a key with ShareSheet(items:secret: true)")
            // The key window lists public keys (selectable); its secret key text is not.
            if name != "KeysWindowView.swift" {
                XCTAssertFalse(text.contains(".textSelection(.enabled)"), "\(name): a key's text must not be selectable")
            }
        }
        let window = try source("KeysWindowView.swift")
        XCTAssertTrue(window.contains("Text(generated.secret).font(.caption.monospaced())\n"), "the secret is plain text")
        // The general pasteboard is written in one place (SecretPasteboard) plus the public key's Copy.
        var writes: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.appSources.path) where name.hasSuffix(".swift") {
            for line in try source(name).split(separator: "\n") where line.contains("UIPasteboard.general") {
                writes.append(name + ": " + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertEqual(writes.count, 2, "\(writes)")
        XCTAssertTrue(writes.allSatisfy { $0.hasPrefix("KeyExportViews.swift: UIPasteboard.general.setItems")
                                          || $0.contains("key.recipient") }, "\(writes)")
        // Every share sheet of a key leaves Copy out.
        let exports = try source("KeyExportViews.swift")
        XCTAssertTrue(exports.contains("ShareSheet(items: [shared], secret: true)"))
        for name in ["NewVaultView.swift", "MigrationView.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("secret: true"), name)
            XCTAssertTrue(text.contains("SecretPasteboard.copy("), name)
        }
        let sheet = try source("ExportSheet.swift")
        XCTAssertTrue(sheet.contains("static let excluded: [UIActivity.ActivityType] = [.copyToPasteboard]"))
    }
}
