import Age
import CLITestSupport
import Foundation
import XCTest

/// `sempere keys derive` against the shared key-hierarchy vectors
/// (Fixtures/epoch-vectors.json, made by web/scripts/make-epoch-vectors.ts).
final class CLIKeysDeriveTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing or ML-DSA on this OS (needs macOS 26)") }
    }

    func vectors() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("epoch-vectors.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDeriveMatchesTheVectors() throws {
        let v = try vectors()
        let vaultId = try XCTUnwrap(v["vaultId"] as? String)
        let capture = try XCTUnwrap((v["device"] as? [String: Any])?["captureFingerprint"] as? String)
        let epochs = try XCTUnwrap(v["epochs"] as? [[String: Any]])
        for e in epochs {
            let n = try XCTUnwrap(e["epoch"] as? Int)
            let keyFile = path("k\(n).hex")
            try "\(try XCTUnwrap(e["key"] as? String))\n".write(toFile: keyFile, atomically: true, encoding: .utf8)
            let r = try cli(["keys", "derive", "--epoch-key-file", keyFile, "--epoch", String(n), "--vault-id", vaultId,
                             "--capture-fingerprint", capture, "--json"])
            XCTAssertEqual(r.status, 0, r.err)
            let out = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
            for (name, value) in e {
                if let s = value as? String { XCTAssertEqual(out[name] as? String, s, "epoch \(n) \(name)") }
            }
            XCTAssertEqual(out["epoch"] as? Int, n)
            XCTAssertEqual(out["root"] as? String, n == 1 ? v["root"] as? String : nil, "the root comes from epoch 1")
        }
        // Text output names the same values.
        let text = try cli(["keys", "derive", "--epoch-key-file", path("k1.hex")])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("epochId: \(try XCTUnwrap(epochs[0]["epochId"] as? String))"), text.out)
    }

    func testDeriveRefusesBadInput() throws {
        try "ABCD\n".write(toFile: path("bad.hex"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try cli(["keys", "derive", "--epoch-key-file", path("bad.hex")]).status, 1)
        XCTAssertEqual(try cli(["keys", "derive", "--epoch-key-file", path("missing.hex")]).status, 1)
        try "\(String(repeating: "ab", count: 32))\n".write(toFile: path("k.hex"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try cli(["keys", "derive", "--epoch-key-file", path("k.hex"), "--epoch", "0"]).status, 2)
        XCTAssertEqual(try cli(["keys", "derive", "--epoch-key-file", path("k.hex"), "--vault-id", "nope"]).status, 2)
    }
}
