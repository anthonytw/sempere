import CLITestSupport
import Foundation
import XCTest

/// CLI tests drive the built `sempere` binary as a subprocess, which works
/// identically on Linux and macOS and avoids linking the executable's `main`
/// into the test bundle.
final class CLISmokeTests: XCTestCase {
    static var binary: URL { CLITestCase.binary }

    static func run(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testVersion() throws {
        let r = try Self.run(["--version"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertFalse(r.out.isEmpty)
    }
}
