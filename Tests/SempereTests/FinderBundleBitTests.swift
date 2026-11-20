import Foundation
@testable import Sempere
import TempDirSupport
import XCTest
#if canImport(Darwin)
import Darwin
#endif

/// Owner's build 12: iCloud vault folders carried a `com.apple.FinderInfo` whose Finder flags had `kHasBundle` set
/// (`00 00 00 00 00 00 00 00 20 00 …`), so the Finder, Files and iCloud Drive took them for packages. Sempere clears
/// that one bit and keeps every other byte (docs/io.md "Vaults are folders").
final class FinderBundleBitTests: TempDirTestCase {
    private func info(_ bytes: [Int: UInt8]) -> Data {
        var data = Data(count: 32)
        for (i, b) in bytes { data[i] = b }
        return data
    }

    func testTheOwnersBytesLoseTheAttribute() {
        let owner = info([8: 0x20])
        XCTAssertTrue(FinderBundleBit.isSet(in: owner))
        XCTAssertEqual(FinderBundleBit.cleared(owner), .remove, "all zero once cleared: the attribute goes")
    }

    func testOtherFlagsAndBytesAreKept() {
        // kHasBundle with kIsInvisible (0x4000) and a color label (0x000E), plus a window position.
        let mixed = info([0: 0x00, 1: 0x10, 3: 0x20, 8: 0x60, 9: 0x0E])
        guard case .rewrite(let out) = FinderBundleBit.cleared(mixed) else { return XCTFail("rewritten") }
        XCTAssertEqual(out.count, 32)
        XCTAssertEqual(out[8], 0x40, "only 0x2000 cleared; kIsInvisible stays")
        XCTAssertEqual(out[9], 0x0E, "the label stays")
        XCTAssertEqual(out[1], 0x10)
        XCTAssertEqual(out[3], 0x20, "a 0x20 elsewhere is not the flag")
        XCTAssertFalse(FinderBundleBit.isSet(in: out))
        XCTAssertEqual(FinderBundleBit.cleared(out), .unchanged)
    }

    func testUnsetShortAndEmptyAreLeftAlone() {
        XCTAssertEqual(FinderBundleBit.cleared(info([:])), .unchanged)
        XCTAssertEqual(FinderBundleBit.cleared(info([9: 0x20])), .unchanged, "the low byte's 0x20 is another flag")
        XCTAssertEqual(FinderBundleBit.cleared(Data([0, 0, 0, 0, 0, 0, 0, 0])), .unchanged, "too short to hold the flags")
        XCTAssertEqual(FinderBundleBit.cleared(Data()), .unchanged)
        // A slice (non-zero start index) reads the right byte.
        let padded = Data([0xFF, 0xFF]) + info([8: 0x20])
        XCTAssertTrue(FinderBundleBit.isSet(in: padded.dropFirst(2)))
        XCTAssertEqual(FinderBundleBit.cleared(padded.dropFirst(2)), .remove)
    }

    func testOnlyVaultAndBackupFoldersApply() {
        XCTAssertTrue(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/Wompa.sempere")))
        XCTAssertTrue(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/Wompa.SEMPERE-backup")))
        XCTAssertFalse(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/Foo.app")))
        XCTAssertFalse(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/Notes")))
        // A sync folder 1.3 makes (`SyncFolderName`), by name; a folder of any other name only by what it holds
        // (`testAFolderOfAnyNameHoldingAVaultApplies`).
        XCTAssertTrue(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/Notes 2.sempere-vault")))
        XCTAssertTrue(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/v1.2.Sempere-Vault")))
        XCTAssertFalse(FinderBundleBit.appliesTo(URL(fileURLWithPath: "/x/Notes Sempere Vault 2")))
    }

    func testAFolderOfAnyNameHoldingAVaultApplies() throws {
        let vault = tmp.appendingPathComponent("Bare", isDirectory: true)
        let backup = tmp.appendingPathComponent("Kept", isDirectory: true)
        for dir in [vault, backup] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        XCTAssertFalse(FinderBundleBit.appliesTo(vault))
        try Data("{}".utf8).write(to: vault.appendingPathComponent("vault.json"))
        try Data("{}".utf8).write(to: backup.appendingPathComponent("backup.json"))
        XCTAssertTrue(FinderBundleBit.appliesTo(vault))
        XCTAssertTrue(FinderBundleBit.appliesTo(backup))
    }

    #if canImport(Darwin)
    private func attribute(_ url: URL) -> Data? {
        let size = getxattr(url.path, FinderBundleBit.attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        _ = getxattr(url.path, FinderBundleBit.attributeName, &buffer, size, 0, 0)
        return Data(buffer)
    }

    private func setAttribute(_ url: URL, _ data: Data) throws {
        let rc = data.withUnsafeBytes { setxattr(url.path, FinderBundleBit.attributeName, $0.baseAddress, data.count, 0, 0) }
        XCTAssertEqual(rc, 0, "setxattr")
    }

    /// On disk: a folder with the owner's bytes is a package to the system; cleared, the attribute is gone and it is
    /// a folder again. Mixed flags keep the rest. A second clear does nothing.
    func testClearOnAFolder() throws {
        let vault = tmp.appendingPathComponent("Wompa.sempere", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        XCTAssertFalse(FinderBundleBit.clear(at: vault), "no attribute: nothing to do")
        try setAttribute(vault, info([8: 0x20]))
        var fresh = URL(fileURLWithPath: vault.path)
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.isPackageKey]).isPackage, true, "the bit makes a package")
        XCTAssertTrue(FinderBundleBit.clear(at: vault))
        XCTAssertNil(attribute(vault), "the attribute was all zero: removed")
        fresh = URL(fileURLWithPath: vault.path)
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.isPackageKey]).isPackage, false, "a folder again")
        XCTAssertFalse(FinderBundleBit.clear(at: vault))

        try setAttribute(vault, info([8: 0x60, 9: 0x0E]))
        XCTAssertTrue(FinderBundleBit.clear(at: vault))
        XCTAssertEqual(attribute(vault), info([8: 0x40, 9: 0x0E]), "other flags kept")
        XCTAssertFalse(FinderBundleBit.clear(at: tmp.appendingPathComponent("missing.sempere")))
    }

    /// The read-only check and the reporting clear (`sempere vault conflicts`, `BundleBitRepair`'s log): a missing
    /// folder or attribute is "not set", never a failure (that would log an error before a target's first run).
    func testIsSetAndClearReporting() throws {
        let vault = tmp.appendingPathComponent("Report.sempere", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        XCTAssertEqual(FinderBundleBit.isSet(at: vault), false)
        XCTAssertEqual(FinderBundleBit.clearReporting(at: vault), .notSet)
        XCTAssertEqual(FinderBundleBit.clearReporting(at: tmp.appendingPathComponent("missing.sempere")), .notSet)
        try setAttribute(vault, info([8: 0x20]))
        XCTAssertEqual(FinderBundleBit.isSet(at: vault), true)
        XCTAssertEqual(FinderBundleBit.clearReporting(at: vault), .cleared)
        XCTAssertEqual(FinderBundleBit.isSet(at: vault), false)
    }
    #endif
}
