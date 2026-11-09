import Age
import Foundation
import Sempere
import SempereAppCore
import Testing
@testable import SempereApp

/// Vault creation, bookmarks, recents and the sidebar's edits.
@MainActor
struct BrowserTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted

    static func tempDir() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model on a private copy of the fixture vault, unlocked.
    static func unlockedFixtureModel() async throws -> AppModel {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: try tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        return model
    }

    static func library() throws -> VaultLibrary {
        VaultLibrary(storeURL: try tempDir().appendingPathComponent("recents.json"))
    }

    // MARK: - Creating

    /// A passphrase for the recovery key's copy.
    static let strongPassphrase = "vuspot-Bekfu4-qobqag"

    // MARK: - Bookmarks and recents

    @Test func bookmarkRoundTrips() throws {
        let dir = try Self.tempDir()
        let bookmarks = SecurityScopedBookmarks()
        let resolved = try bookmarks.resolve(try bookmarks.bookmark(for: dir))
        #expect(resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
                == dir.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    // MARK: - Edits

    // MARK: - Search and sort

}
