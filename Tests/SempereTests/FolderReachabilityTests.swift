import Foundation
import TempDirSupport
import XCTest
@testable import Sempere

/// Offline audit A-P2 (review of #91, M2): a folder reached by its stored path (a sync target's or a backup folder
/// whose bookmark does not resolve) is unavailable only when the removable volume it is on is not mounted; anything
/// else that is not there is gone.
final class FolderReachabilityTests: TempDirTestCase {
    func testAFolderIsReachableOrMissingOffRemovableVolumes() throws {
        let parent = tmp.appendingPathComponent("disk", isDirectory: true)
        let folder = parent.appendingPathComponent("Notes.sempere", isDirectory: true)
        // Deleted with the folder it was in, on a disk that is there: gone, never "offline".
        XCTAssertEqual(FolderReachability.of(path: folder.path), .missing)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(FolderReachability.of(path: folder.path), .reachable)
        let file = parent.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(FolderReachability.of(path: file.path), .missing, "a file under the name is not the folder")
    }

    func testRemovableRoots() {
        XCTAssertEqual(FolderReachability.removableRoot(of: "/Volumes/USB/Notes.sempere"), "/Volumes/USB")
        XCTAssertEqual(FolderReachability.removableRoot(of: "/media/me/USB/a/b"), "/media/me/USB")
        XCTAssertEqual(FolderReachability.removableRoot(of: "/mnt/share/x"), "/mnt/share")
        XCTAssertEqual(FolderReachability.removableRoot(
            of: "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB/Notes"),
            "/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd/USB")
        XCTAssertNil(FolderReachability.removableRoot(of: "/Users/me/Notes.sempere"))
        let absent = "/Volumes/sempere-test-\(UUID().uuidString)/Backups"
        XCTAssertTrue(FolderReachability.isOnAbsentVolume(absent))
        XCTAssertEqual(FolderReachability.of(path: absent + "/Notes"), .unavailable)
        XCTAssertFalse(FolderReachability.isOnAbsentVolume(tmp.appendingPathComponent("x").path))
    }

    /// Review of #90, N2: a plain `/mnt` subfolder (no mount point) is a folder to create, never "drive not
    /// connected"; one `/etc/fstab` lists is a volume's mount point, unavailable while away.
    func testMntFoldersAreVolumesOnlyWhenFstabListsThem() throws {
        let root = "/mnt/sempere-test-\(UUID().uuidString)"
        XCTAssertFalse(FolderReachability.isOnAbsentVolume(root + "/Backups", mountPoints: []))
        XCTAssertEqual(FolderReachability.of(path: root + "/Backups"), .missing)
        XCTAssertTrue(FolderReachability.isOnAbsentVolume(root + "/Backups", mountPoints: [root]))
        // A listed mount point that is there and on the same device as its parent: nothing mounted on it.
        XCTAssertFalse(FolderReachability.isOnAbsentVolume("/mnt", mountPoints: ["/mnt"]), "no volume root")
        let fstab = tmp.appendingPathComponent("fstab")
        try Data("# comment\nUUID=1 / ext4 defaults 0 1\n/dev/sdb1\t/mnt/usb\\040drive vfat noauto 0 0\n".utf8).write(to: fstab)
        XCTAssertEqual(FolderReachability.fstabMountPoints(fstab), ["/", "/mnt/usb drive"])
    }
}
