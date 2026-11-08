import Foundation
import Sempere
import SempereAppCore
import SempereSync
import Testing
@testable import SempereApp

/// Folder targets on the system's bookmarks (`SecurityScopedBookmarks`, the app's `FolderBookmarks`). The rest of
/// folder targets through the model, on path bookmarks: `FolderTargetTests` in `SempereAppCoreTests`.
@MainActor
struct FolderTargetAppTests {
    /// A target folder moved or renamed: its bookmark still finds it (and is saved again when stale).
    @Test func aMovedTargetFolderIsFollowed() async throws {
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let drive = TestTemp.root.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let shared = drive.appendingPathComponent("Shared.sempere", isDirectory: true)
        let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("device-\(UUID().uuidString)/recents.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        defer { model.close() }
        model.vaultStore = library.vaultStore
        model.folderWriteDelay = 0.05
        model.folderArrivalWait = 0.5
        try await model.copyIn(picked: vault, library: library)
        try await model.unlock(identityText: try String(contentsOf: keyURL, encoding: .utf8))
        try model.addFolderTarget(shared, scope: drive, to: try #require(model.vault?.vaultId))
        await model.syncAllTargetsNow()
        #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("vault.json").path))

        let moved = drive.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: drive, to: moved)
        let note = try await model.createNote(title: "After the move", paper: .ruled, notebook: nil)
        let session = try #require(model.syncSessions.first)
        await session.syncNow()
        #expect(!session.needsAttention, "\(session.headline)")
        let notes = moved.appendingPathComponent(shared.lastPathComponent).appendingPathComponent("notes")
        let names = (FileManager.default.enumerator(atPath: notes.path)?.compactMap { $0 as? String }) ?? []
        #expect(names.contains { $0.hasPrefix(note.uuidString.lowercased()) })
    }
}
