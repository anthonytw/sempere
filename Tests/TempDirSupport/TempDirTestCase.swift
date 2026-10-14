import Foundation
import XCTest

/// Base class of the tests that need a scratch directory: `tmp` is created before each test and removed after it.
open class TempDirTestCase: XCTestCase {
    public var tmp: URL!

    override open func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sempere-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override open func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }
}

extension XCTestCase {
    /// A fresh path in the temporary directory, removed when the test ends. Nothing is created there yet.
    public func makeScratch(_ prefix: String = "sempere-test") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `makeScratch`, with the directory created.
    public func makeScratchDirectory(_ prefix: String = "sempere-test") throws -> URL {
        let url = makeScratch(prefix)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
