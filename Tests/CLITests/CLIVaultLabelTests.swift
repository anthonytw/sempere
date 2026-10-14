import CLITestSupport
import Foundation
import XCTest

/// `sempere vault label` and `vault init --vault-label` (format.md §2 `label`, task W1).
final class CLIVaultLabelTests: CLITestCase {
    func testShowSetClear() throws {
        let vault = try copyFixtureVault()
        let none = try cli(["vault", "label", "--vault", vault])
        XCTAssertEqual(none.status, 0, none.err)
        XCTAssertEqual(none.out, "")
        let noneJSON = try cli(["vault", "label", "--vault", vault, "--json"])
        XCTAssertEqual(noneJSON.status, 0, noneJSON.err)
        XCTAssertTrue((noneJSON.json as? [String: Any])?["label"] is NSNull, noneJSON.out)

        let locked = try cli(["vault", "label", "Notes", "--vault", vault], env: ["SEMPERE_PASSPHRASE": ""])
        XCTAssertNotEqual(locked.status, 0, "setting needs the key")

        let set = try cli(["vault", "label", "  Notes\n2026 ", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(set.status, 0, set.err)
        XCTAssertEqual((set.json as? [String: Any])?["label"] as? String, "Notes 2026")
        XCTAssertEqual(try cli(["vault", "label", "--vault", vault]).out, "Notes 2026\n")
        let info = try cli(["vault", "info", "--vault", vault, "--json"])
        XCTAssertEqual((info.json as? [String: Any])?["label"] as? String, "Notes 2026")
        XCTAssertTrue(try cli(["vault", "info", "--vault", vault]).out.contains("Label:          Notes 2026"))
        let verify = try cli(["vault", "verify", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)

        for bad in [["   "], ["x", "--clear"]] {
            let r = try cli(["vault", "label"] + bad + ["--vault", vault, "--identity", Self.fixtureKey])
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        let clear = try cli(["vault", "label", "--clear", "--vault", vault, "--identity", Self.fixtureKey])
        XCTAssertEqual(clear.status, 0, clear.err)
        XCTAssertEqual(try cli(["vault", "label", "--vault", vault]).out, "")
    }

    func testInitStoresIt() throws {
        let key = path("a.key")
        let pub = try cli(["keys", "generate", "--out", key, "-q"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let vault = path("labelled.sempere")
        let r = try cli(["vault", "init", vault, "--recipient", pub, "--vault-label", "Work notes"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try cli(["vault", "label", "--vault", vault]).out, "Work notes\n")
    }
}
