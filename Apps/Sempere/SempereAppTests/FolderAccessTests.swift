import Foundation
import Testing
@testable import SempereApp

/// Saved folder access: what counts as "the system refused", and the check
/// that runs before a vault opens.
struct FolderAccessTests {
    @Test func permissionErrorsAreRecognisedWhereverTheyAreNested() {
        #expect(FolderAccess.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        #expect(FolderAccess.isPermissionDenied(CocoaError(.fileWriteNoPermission)))
        #expect(FolderAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(FolderAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let nested = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(FolderAccess.isPermissionDenied(nested))
        #expect(!FolderAccess.isPermissionDenied(CocoaError(.fileNoSuchFile)))
        #expect(!FolderAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    @Test func aReadableFolderPasses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FolderAccess.check(dir, scoped: false)
        try FolderAccess.check(dir, scoped: true)
    }

    @Test func aMissingFolderIsLeftToTheVaultToReport() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FolderAccess.check(missing, scoped: false)
    }

    @Test func aFolderTheSystemRefusesIsReportedByName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Locked-\(UUID().uuidString).sempere")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        guard geteuid() != 0 else { return }   // root ignores permissions
        let name = VaultLibrary.displayName(of: dir)
        #expect(throws: FolderAccess.Problem.noAccess(name: name, scoped: false)) {
            try FolderAccess.check(dir, scoped: false)
        }
    }

    @Test func theMessageNamesTheFolderAndTheWayOut() {
        let text = FolderAccess.Problem.noAccess(name: "Notes", scoped: false).description
        #expect(text.contains("“Notes”"))
        #expect(text.contains("choose"))
        #expect(!FolderAccess.Problem.noAccess(name: "Notes", scoped: true).description.contains("did not come back"))
    }
}
