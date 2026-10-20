import Foundation
import Testing
import UIKit
@testable import SempereApp

/// Device checks c27 (a Mac quit leaves no decrypted files and the saved window
/// state names no note) and c28 (the owner check a UI test can answer), the
/// parts that run without the screen (`scripts/app.sh test-mac`). The end-to-end
/// halves are `QuitPurgeMacUITests` and `KeyShareMacUITests`.
@MainActor
@Suite(.serialized)
struct QuitPurgeAndOwnerCheckTests {
    private let fm = FileManager.default

    private func plant(in folder: URL, _ name: String = UUID().uuidString) throws -> URL {
        let dir = folder.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("photo.jpg")
        try Data("plaintext".utf8).write(to: file)
        return file
    }

    /// ⌘Q reaches `applicationWillTerminate`, which empties the real blob folder on a Mac and
    /// keeps it on the iPad (protected at rest there).
    @Test func quittingThroughTheAppDelegatePurgesTheBlobFolderOnAMac() throws {
        let planted = try plant(in: BlobCache.folder)
        defer { try? fm.removeItem(at: planted.deletingLastPathComponent()) }
        SempereAppDelegate().applicationWillTerminate(UIApplication.shared)
        if ProcessInfo.processInfo.isMacCatalystApp {
            #expect(!fm.fileExists(atPath: planted.path))
            #expect(!fm.fileExists(atPath: BlobCache.folder.path), "the whole folder goes")
        } else {
            #expect(fm.fileExists(atPath: planted.path))
        }
    }

    /// ⌘Q also removes the plaintext work copies of PDFs being imported (`PDFPreparation.workFolder`):
    /// one waiting for its password or for a vault to open, or picked for Insert PDF Pages, used to
    /// wait for the next launch's purge.
    @Test func quittingThroughTheAppDelegatePurgesPDFWorkCopies() throws {
        let copy = try PDFPreparation.workFolder().appendingPathComponent("waiting.pdf")
        try Data("%PDF-1.4 plaintext".utf8).write(to: copy)
        SempereAppDelegate().applicationWillTerminate(UIApplication.shared)
        #expect(!fm.fileExists(atPath: copy.path))
        #expect(!fm.fileExists(atPath: TestTemp.systemTemporaryDirectory.appendingPathComponent("SempereImport").path))
    }

    /// Stress: two vaults' folders, a folder a vault close set aside, and files of a fetch
    /// that finished after the quit's purge (the process exits only after the delegate returns):
    /// the quit removes all it sees, and the next launch removes the late file.
    @Test func quitThenLaunchLeaveNothingOfTwoVaultsOrALateFetch() async throws {
        let root = TestTemp.root.appendingPathComponent("QuitPurge-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let first = try plant(in: root, "vault-a")
        let second = try plant(in: root, "vault-b")
        let closed = try plant(in: root, ".closed-\(UUID().uuidString)")
        BlobCache.purgeAtQuit(in: root, keepsAcrossLaunches: false)
        for file in [first, second, closed] { #expect(!fm.fileExists(atPath: file.path)) }
        // A fetch writing its file after the purge, as a quit during a blob fetch can.
        let late = try plant(in: root, "vault-a")
        // A crash or kill skips `applicationWillTerminate`: the next launch purges instead.
        BlobCache.purgeAtLaunch(in: root, keepsAcrossLaunches: false)
        #expect(!fm.fileExists(atPath: late.path), "renamed aside at once, before any vault opens")
        #expect(await TS.waitUntil {
            let left = (self.fm.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
            return !left.contains { $0.hasSuffix("photo.jpg") }
        })
    }

    /// What a note window saves for restoration is two ids, never a title or content.
    @Test func aNoteWindowRestoresFromIdsOnly() throws {
        let value = NoteWindowValue(vaultID: UUID(), noteID: UUID())
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(json.keys) == ["vaultID", "noteID"])
    }

    /// `SEMPERE_DEBUG_OWNER_CHECK` answers the system owner check in debug builds (UI tests
    /// cannot touch Touch ID); unset, the real check runs.
    @Test func theDebugOwnerCheckAnswersAsAsked() async throws {
        defer { unsetenv("SEMPERE_DEBUG_OWNER_CHECK") }
        setenv("SEMPERE_DEBUG_OWNER_CHECK", "pass", 1)
        try await SystemOwnerAuthenticator().authenticate(reason: "test")
        setenv("SEMPERE_DEBUG_OWNER_CHECK", "fail", 1)
        await #expect(throws: AppModel.KeyExportError.notAuthenticated) {
            try await SystemOwnerAuthenticator().authenticate(reason: "test")
        }
        setenv("SEMPERE_DEBUG_OWNER_CHECK", "cancel", 1)
        await #expect(throws: CancellationError.self) { try await SystemOwnerAuthenticator().authenticate(reason: "test") }
        // An unknown value is no answer: the real check would run.
        setenv("SEMPERE_DEBUG_OWNER_CHECK", "yes", 1)
        #expect(DebugLaunch.ownerCheck == nil)
    }

    /// Save Key… through the key window's path: with the owner check passed, the key file the
    /// share sheet gets is this device's key, and the share sheet leaves Copy out (key file
    /// and key text alike).
    @Test func savingFromTheKeyWindowSharesTheKeyFileWithoutCopy() async throws {
        defer { unsetenv("SEMPERE_DEBUG_OWNER_CHECK") }
        setenv("SEMPERE_DEBUG_OWNER_CHECK", "pass", 1)
        let (model, _) = try await KeyManagementTests.unlockedModel()
        let key = try await model.exportThisDeviceKey()
        #expect(model.deviceKeys.contains { $0.recipient == key.recipient && $0.isInUse })
        let staged = try KeyShareFile.stage(key, in: TestTemp.root.appendingPathComponent("KS-\(UUID().uuidString)"))
        defer { KeyShareFile.purge(in: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        for items in [[staged] as [Any], [key.secret] as [Any]] {
            let excluded = SecretSharing.controller(items: items).excludedActivityTypes ?? []
            #expect(excluded.contains(.copyToPasteboard))
        }
    }
}
