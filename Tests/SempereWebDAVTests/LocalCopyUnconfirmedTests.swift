import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// `LocalCopy.unconfirmedChanges` counts everything a copy holds that the server never confirmed, the
/// quick-capture inbox and `settings.age` included (review of #72, G1: the app's carry-over of old WebDAV
/// copies and the remove confirmation rely on it, and a voice note recorded offline counted as nothing).
extension LocalCopyTests {
    func testAnUnuploadedCaptureCounts() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try mirror("A", server)
        let c = copy("iPad")
        _ = try c.download(client: try client(server))
        XCTAssertEqual(c.unconfirmedChanges(), 0)
        // A capture recorded offline into the copy's inbox (P5 delivers captures there).
        let inbox = c.folder.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("sealed voice note".utf8).write(to: inbox.appendingPathComponent("20261020T120000Z-0123456789abcdef.m4a.age"))
        XCTAssertEqual(c.unconfirmedChanges(), 1, "an unuploaded capture counts")
        try Data().write(to: inbox.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(c.unconfirmedChanges(), 1, "hidden files do not")
    }

    func testChangedSettingsCount() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try mirror("A", server)
        let c = copy("iPad")
        _ = try c.download(client: try client(server))
        XCTAssertEqual(c.unconfirmedChanges(), 0)
        try Data("settings written here".utf8).write(to: c.folder.appendingPathComponent(SharedSettings.fileName))
        XCTAssertEqual(c.unconfirmedChanges(), 1, "settings.age the server never had")
    }
}
