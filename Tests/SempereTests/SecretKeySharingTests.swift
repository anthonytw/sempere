import Foundation
import XCTest

/// Security review 2026-10 stage 4, S14 (and P2): a vault's secret key leaves the app only through
/// `SecretPasteboard` (local only, expiring) or a share sheet without Copy (`SecretSharing`). The new-vault
/// screen (and a former upgrade screen) had a `ShareLink` of the raw key, whose Copy puts it on the general pasteboard with
/// no expiry (Universal Clipboard, clipboard managers), and selectable key text, whose ⌘C does the same.
/// The app builds only in the CI `app` job, so this reads the sources (on Linux too, in every `swift test`).
final class SecretKeySharingTests: XCTestCase {
    static let appSources = LocalizationCatalogTests.apps.appendingPathComponent("SempereApp")
    /// The views that show a secret key.
    static let keyViews = ["NewVaultView.swift", "KeysWindowView.swift", "KeyExportViews.swift"]

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
        // The key window shows no secret key since KH2 (device keys never leave the device; the device list, KH5).
        XCTAssertFalse(try source("KeysWindowView.swift").contains("secret"), "the key window shows no secret key")
        // The general pasteboard is written in one place (SecretPasteboard); the key window no longer copies
        // public keys (KH5's device list shows ids, not keys).
        var writes: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.appSources.path) where name.hasSuffix(".swift") {
            for line in try source(name).split(separator: "\n") where line.contains("UIPasteboard.general") {
                writes.append(name + ": " + line.trimmingCharacters(in: .whitespaces))
            }
        }
        // SecretPasteboard is the one writer; on a Mac it also clears the item itself (Catalyst ignores the
        // expiration date), and the line that sets the item is the one with `setItems`.
        // The one other write is Ask's explicit Copy button: the answer's text only (docs/design/1.3-ask.md §3.6, §5).
        let others = writes.filter { !$0.hasPrefix("KeyExportViews.swift:") }
        XCTAssertEqual(others.count, 1, "\(writes)")
        XCTAssertTrue(others.first?.hasPrefix("AskViews.swift: UIPasteboard.general.string = result.answer") == true, "\(writes)")
        XCTAssertEqual(writes.filter { $0.contains("UIPasteboard.general.setItems") }.count, 1, "\(writes)")
        let board = try source("KeyExportViews.swift")
        XCTAssertTrue(board.contains("targetEnvironment(macCatalyst)") && board.contains("UIPasteboard.general.items = []"),
                      "a Mac clears the copied key itself")
        XCTAssertTrue(board.contains("org.nspasteboard.ConcealedType") && board.contains("org.nspasteboard.TransientType"))
        // Every share sheet of a key leaves Copy out.
        let exports = try source("KeyExportViews.swift")
        XCTAssertTrue(exports.contains("ShareSheet(items: [shared], secret: true)"))
        for name in ["NewVaultView.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("secret: true"), name)
            XCTAssertTrue(text.contains("SecretPasteboard.copy("), name)
        }
        let sheet = try source("ExportSheet.swift")
        XCTAssertTrue(sheet.contains("static let excluded: [UIActivity.ActivityType] = [.copyToPasteboard]"))
    }

    /// A key view shares a key only through `SecretSharing.present(` (UIKit over the screen) or its fallback
    /// `ShareSheet(…, secret: true)`, and copies it only through `SecretPasteboard.copy(`: no share controller of its
    /// own, no other pasteboard write.
    func testSecretSharingAndSecretPasteboardAreTheOnlyPaths() throws {
        for name in ["NewVaultView.swift", "KeyExportViews.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("SecretSharing.present("), name)
            XCTAssertFalse(text.contains("UIActivityViewController("), "\(name): share a key through SecretSharing")
            for line in text.split(separator: "\n") where line.contains("ShareSheet(") {
                XCTAssertTrue(line.contains("secret: true"), "\(name): \(line)")
            }
        }
        let receipt = try source("NewVaultView.swift")
        XCTAssertTrue(receipt.contains("SecretPasteboard.copy("))
        for line in receipt.split(separator: "\n") where line.contains("Pasteboard") && !line.contains("//") {
            XCTAssertTrue(line.contains("SecretPasteboard.copy("), "NewVaultView.swift: \(line)")
        }
        // The one secret share controller is `SecretSharing.controller`, which `present` and `ShareSheet` use.
        let sheet = try source("ExportSheet.swift")
        XCTAssertTrue(sheet.contains("if secret { return SecretSharing.controller(items: items)"))
        XCTAssertTrue(sheet.contains("let controller = controller(items: items)"))
    }
}
