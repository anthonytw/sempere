import Age
import CLITestSupport
import Foundation
import FuzzSupport
import Sempere
import XCTest

/// The device list from the CLI (docs/design/key-hierarchy.md §6, KH2): `vault init` makes this machine
/// the vault's home, `device init` / `devices approve` / `device confirm` join another machine by typed
/// words both ways, `devices rename` on home, the recovery key reads only (`--recovery-key [--root]`), and
/// the kit's frozen script opens a vault the CLI made with stock `age` and `jq`.
final class CLIDevicesTests: CLITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    /// `age` 1.3 or later (post-quantum keys) on PATH or in the usual places; nil when there is none.
    static func agePQ() -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let age = "\(dir)/age"
            guard FileManager.default.isExecutableFile(atPath: age) else { continue }
            guard let run = try? ExternalTool.run(URL(fileURLWithPath: age), ["--version"]) else { continue }
            let v = String(decoding: run.out, as: UTF8.self)
            let parts = v.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
                .split(separator: ".").prefix(2).compactMap { Int($0) }
            if parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) { return age }
        }
        return nil
    }

    /// Another machine: its own state directory (device keys and trust records).
    func machine(_ name: String) -> [String: String] { ["XDG_STATE_HOME": path("state-\(name)")] }

    /// `vault init` on machine "home", with the recovery key written to `recovery.key`; returns the vault's
    /// path and its init JSON.
    func initVault(_ extra: [String] = [], env: [String: String] = [:]) throws -> (vault: String, json: [String: Any]) {
        let vault = path("v.sempere")
        let r = try cli(["vault", "init", vault, "--name", "Home Mac", "--kind", "mac", "--recovery-out", path("recovery.key"),
                         "--json"] + extra, env: machine("home").merging(env) { $1 })
        XCTAssertEqual(r.status, 0, r.err)
        return (vault, try XCTUnwrap(r.json as? [String: Any]))
    }

    func testVaultInitMakesThisMachineTheHome() throws {
        let (vault, json) = try initVault()
        let root = try XCTUnwrap(json["root"] as? String)
        XCTAssertEqual(root.count, 64)
        let deviceKey = try XCTUnwrap(json["deviceKey"] as? String)
        XCTAssertTrue(deviceKey.hasPrefix(path("state-home")), deviceKey)
        let mode = try FileManager.default.attributesOfItem(atPath: deviceKey)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // The default key is this machine's device key: no --identity needed.
        let home = ["--vault", vault]
        let new = try cli(["notes", "new", "Synthetic", "--json"] + home, env: machine("home"))
        XCTAssertEqual(new.status, 0, new.err)
        let list = try XCTUnwrap(try cli(["devices", "list", "--json"] + home, env: machine("home")).json as? [String: Any])
        let rows = try XCTUnwrap(list["devices"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows[0]["device"] as? [String: Any])?["home"] as? Bool, true)
        XCTAssertEqual(rows[0]["thisDevice"] as? Bool, true)
        XCTAssertEqual(list["thisDeviceIsHome"] as? Bool, true)
        let verify = try cli(["vault", "verify"] + home, env: machine("home"))
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)
        // A machine that never joined has no key for it.
        XCTAssertEqual(try cli(["notes", "list"] + home, env: machine("stranger")).status, 4)
        // The recovery key file is the kit's identity, mode 0600; the kit prints from it.
        let recovery = path("recovery.key")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: recovery)[.posixPermissions] as? Int, 0o600)
        let kit = try cli(["keys", "paper", "--vault", vault, "--identity", recovery, "--out", path("kit.pdf"), "--json"])
        XCTAssertEqual(kit.status, 0, kit.err)
        let notRecovery = try cli(["keys", "paper", "--vault", vault, "--identity", deviceKey, "--out", path("kit2.pdf")])
        XCTAssertEqual(notRecovery.status, 4, notRecovery.err)
    }

    /// `devices decline` (build 12: "there's no way to decline a request, so if there is one bad request ahead of
    /// others, you're stuck"): by words, by id (an unreadable request too), or all; only on home; and no request,
    /// readable or not, keeps another from being approved.
    func testDeclineJoinRequests() throws {
        let (vault, _) = try initVault()
        let v = ["--vault", vault]
        func ask(_ name: String) throws -> (words: [String], file: String) {
            let r = try cli(["device", "init", "--name", name, "--json"] + v, env: machine(name.lowercased()))
            XCTAssertEqual(r.status, 0, r.err)
            let json = try XCTUnwrap(r.json as? [String: Any])
            return (try XCTUnwrap(json["words"] as? [String]), try XCTUnwrap(json["request"] as? String))
        }
        let laptop = try ask("Laptop"), tablet = try ask("Tablet"), phone = try ask("Phone")
        // A request that does not parse, named so it sorts first.
        let junk = (vault as NSString).appendingPathComponent("joins/0000aaaa.join.json")
        try Data("not json".utf8).write(to: URL(fileURLWithPath: junk))
        func exists(_ file: String) -> Bool { FileManager.default.fileExists(atPath: (vault as NSString).appendingPathComponent(file)) }

        XCTAssertEqual(try cli(["devices", "decline", "--all"] + v, env: machine("laptop")).status, 4, "not listed: no key")
        XCTAssertEqual(try cli(["devices", "decline"] + v, env: machine("home")).status, 2, "words, --id or --all (a usage error)")
        let byWords = try cli(["devices", "decline", "--json"] + laptop.words + v, env: machine("home"))
        XCTAssertEqual(byWords.status, 0, byWords.err)
        XCTAssertEqual((byWords.json as? [String: Any])?["declined"] as? [String],
                       [String((laptop.file as NSString).lastPathComponent.prefix(8))])
        XCTAssertFalse(exists(laptop.file))
        XCTAssertEqual(try cli(["devices", "approve"] + laptop.words + v, env: machine("home")).status, 1, "declined: gone")

        // The unreadable request and the tablet's do not block the phone's approval.
        let approve = try cli(["devices", "approve"] + phone.words + v, env: machine("home"))
        XCTAssertEqual(approve.status, 0, approve.err)
        let byID = try cli(["devices", "decline", "--id", "0000aaaa", "--id",
                            String((tablet.file as NSString).lastPathComponent.prefix(6))] + v, env: machine("home"))
        XCTAssertEqual(byID.status, 0, byID.err)
        XCTAssertFalse(exists("joins/0000aaaa.join.json"))
        XCTAssertFalse(exists(tablet.file))
        XCTAssertEqual(try cli(["devices", "decline", "--id", "ffff"] + v, env: machine("home")).status, 1)
        // --all says what it skipped: a file named like no request (review of #124, note 8).
        let odd = (vault as NSString).appendingPathComponent("joins/Not-A-Request.join.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: odd))
        let none = try cli(["devices", "decline", "--all", "--json"] + v, env: machine("home"))
        XCTAssertEqual(none.status, 0, none.err)
        XCTAssertEqual((none.json as? [String: Any])?["declined"] as? [String], [])
        XCTAssertEqual((none.json as? [String: Any])?["skipped"] as? [String], ["Not-A-Request.join.json"])
        let text = try cli(["devices", "decline", "--all"] + v, env: machine("home"))
        XCTAssertTrue((text.out + text.err).contains("Skipped 1 file(s)"), text.out + text.err)
        XCTAssertTrue(exists("joins/Not-A-Request.join.json"), "never declined silently")
    }

    func testJoinByApprovalWithTypedWordsBothWays() throws {
        let (vault, _) = try initVault()
        let v = ["--vault", vault]
        // The new machine asks to join and shows six words.
        let ask = try cli(["device", "init", "--name", "Laptop", "--json"] + v, env: machine("laptop"))
        XCTAssertEqual(ask.status, 0, ask.err)
        let askJSON = try XCTUnwrap(ask.json as? [String: Any])
        let words = try XCTUnwrap(askJSON["words"] as? [String])
        XCTAssertEqual(words.count, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (vault as NSString).appendingPathComponent(
            try XCTUnwrap(askJSON["request"] as? String))))
        XCTAssertEqual(try cli(["notes", "list"] + v, env: machine("laptop")).status, 4, "not listed yet")
        // Only home approves, and only the typed words of a request.
        XCTAssertEqual(try cli(["devices", "approve"] + words + v, env: machine("laptop")).status, 4)
        var wrong = words
        wrong[0] = wrong[0] == "abandon" ? "ability" : "abandon"
        XCTAssertEqual(try cli(["devices", "approve"] + wrong + v, env: machine("home")).status, 1)
        let approve = try cli(["devices", "approve", "--json"] + words.map { $0.uppercased() } + v, env: machine("home"))
        XCTAssertEqual(approve.status, 0, approve.err)
        let reply = try XCTUnwrap((approve.json as? [String: Any])?["reply"] as? [String])
        XCTAssertEqual(reply.count, 6)
        // Listed now, but not confirmed: it reads, and writes nothing until the reply words are typed.
        XCTAssertEqual(try cli(["notes", "list"] + v, env: machine("laptop")).status, 0)
        XCTAssertEqual(try cli(["notes", "new", "Too soon"] + v, env: machine("laptop")).status, 6)
        var badReply = reply
        badReply[5] = badReply[5] == "zoo" ? "zone" : "zoo"
        XCTAssertEqual(try cli(["device", "confirm"] + badReply + v, env: machine("laptop")).status, 1)
        let confirm = try cli(["device", "confirm"] + reply + v, env: machine("laptop"))
        XCTAssertEqual(confirm.status, 0, confirm.err)
        let write = try cli(["notes", "new", "From the laptop"] + v, env: machine("laptop"))
        XCTAssertEqual(write.status, 0, write.err)
        // Two devices; the laptop is not home, so it neither approves nor renames.
        let list = try XCTUnwrap(try cli(["devices", "list", "--json"] + v, env: machine("laptop")).json as? [String: Any])
        let rows = try XCTUnwrap(list["devices"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(list["thisDeviceIsHome"] as? Bool, false)
        let laptopID = try XCTUnwrap(rows.compactMap { $0["device"] as? [String: Any] }.first { $0["name"] as? String == "Laptop" }?["id"]
                                     as? String)
        XCTAssertEqual(try cli(["devices", "rename", laptopID, "Old laptop"] + v, env: machine("laptop")).status, 1)
        let rename = try cli(["devices", "rename", laptopID, "Work laptop", "--json"] + v, env: machine("home"))
        XCTAssertEqual(rename.status, 0, rename.err)
        XCTAssertEqual((rename.json as? [String: Any])?["name"] as? String, "Work laptop")
        // The laptop takes the rename (a later version of the same epoch) and keeps writing.
        XCTAssertEqual(try cli(["notes", "new", "Still writing"] + v, env: machine("laptop")).status, 0)
        let again = try XCTUnwrap(try cli(["vault", "info", "--json"] + v, env: machine("laptop")).json as? [String: Any])
        XCTAssertEqual((again["list"] as? [String: Any])?["status"] as? String, "verified")
    }

    func testTheRecoveryKeyReadsAndNeverWrites() throws {
        let (vault, json) = try initVault(["--recovery-passphrase", "--work-factor", "10"],
                                          env: ["SEMPERE_PASSPHRASE": "Wafwi4-nokmoj-jykpuf"])
        let root = try XCTUnwrap(json["root"] as? String)
        XCTAssertEqual(try cli(["notes", "new", "Synthetic", "--vault", vault], env: machine("home")).status, 0)
        let recovery = ["--vault", vault, "--recovery-key", path("recovery.key")]
        // Reads with the root, from anywhere; never writes (exit 7).
        let list = try cli(["notes", "list", "--json", "--root", root] + recovery, env: machine("elsewhere"))
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertEqual((list.json as? [[String: Any]])?.count, 1)
        let groups = KitRecovery.rootGroups(try XCTUnwrap(Hex.decode(root))).map { "\($0.group) (\($0.checksum))" }
        XCTAssertEqual(try cli(["notes", "list", "--root", groups.joined(separator: " ")] + recovery).status, 0,
                       "the kit's groups with their checksums")
        let write = try cli(["notes", "new", "Nope", "--root", root] + recovery)
        XCTAssertEqual(write.status, 7, write.err)
        // Without the root it warns; with another root it refuses.
        let unchecked = try cli(["notes", "list"] + recovery)
        XCTAssertEqual(unchecked.status, 0)
        XCTAssertTrue(unchecked.err.contains("without checking"), unchecked.err)
        XCTAssertEqual(try cli(["notes", "list", "--root", String(repeating: "ab", count: 32)] + recovery).status, 6)
        // The passphrase copy carries the root: the passphrase alone reads.
        let copies = try FileManager.default.contentsOfDirectory(atPath: (vault as NSString).appendingPathComponent("keys"))
        XCTAssertEqual(copies.count, 1)
        let copy = (vault as NSString).appendingPathComponent("keys/" + copies[0])
        let fromCopy = try cli(["notes", "list", "--vault", vault, "--recovery-key", copy],
                               env: ["SEMPERE_PASSPHRASE": "Wafwi4-nokmoj-jykpuf"])
        XCTAssertEqual(fromCopy.status, 0, fromCopy.err)
        XCTAssertFalse(fromCopy.err.contains("without checking"), fromCopy.err)
        XCTAssertEqual(try cli(["notes", "list", "--vault", vault, "--recovery-key", copy],
                               env: ["SEMPERE_PASSPHRASE": "wrong"]).status, 4)
    }

    /// Any passphrase is taken for the recovery copy, a one-letter one too.
    func testAWeakRecoveryPassphraseIsAccepted() throws {
        let r = try cli(["vault", "init", path("w.sempere"), "--recovery-out", path("r.key"), "--recovery-passphrase",
                         "--work-factor", "10", "--json"], env: machine("home").merging(["SEMPERE_PASSPHRASE": "a"]) { $1 })
        XCTAssertEqual(r.status, 0, r.err)
        let keys = try FileManager.default.contentsOfDirectory(atPath: path("w.sempere/keys"))
        XCTAssertEqual(keys.count, 1)
        let root = try XCTUnwrap((r.json as? [String: Any])?["root"] as? String)
        let read = try cli(["notes", "list", "--vault", path("w.sempere"), "--root", root, "--recovery-key",
                            path("w.sempere/keys/" + keys[0])], env: ["SEMPERE_PASSPHRASE": "a"])
        XCTAssertEqual(read.status, 0, read.err)
    }

    /// The kit's frozen script (format.md §15.13), steps 1 to 3, opens every note of a vault the CLI made,
    /// with stock `age` 1.3+ and `jq`, from the printed recovery key and from the passphrase copy's
    /// plaintext. CI requires both tools (SEMPERE_REQUIRE_AGE_PQ).
    func testTheKitScriptOpensAGeneratedVault() throws {
        let required = ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard let age = Self.agePQ(), ExternalTool.find("jq") != nil else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age >= 1.3 or jq is not on PATH") }
            throw XCTSkip("age >= 1.3 or jq not on PATH")
        }
        let pass = "Wafwi4-nokmoj-jykpuf"
        let (vault, _) = try initVault(["--recovery-passphrase", "--work-factor", "10"], env: ["SEMPERE_PASSPHRASE": pass])
        var notes: [String: String] = [:]
        for title in ["First synthetic note", "Second synthetic note"] {
            let r = try cli(["notes", "new", title, "--json", "--vault", vault], env: machine("home"))
            XCTAssertEqual(r.status, 0, r.err)
            notes[try XCTUnwrap(((r.json as? [String: Any])?["note"] as? [String: Any])?["id"] as? String)] = title
        }
        let copy = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: (vault as NSString).appendingPathComponent("keys")).first)
        let plaintext = try Vault.openPassphraseCopy(Data(contentsOf: URL(fileURLWithPath: vault).appendingPathComponent("keys/\(copy)")),
                                                     passphrase: pass).plaintext
        let script = KitRecovery.script
        let step3 = try XCTUnwrap(script.range(of: "# 3. Any note, as before."))
        for (label, recoveryText) in [("printed key", try String(contentsOfFile: path("recovery.key"), encoding: .utf8)),
                                      ("passphrase copy", plaintext)] {
            let work = path("kit-\(label.replacingOccurrences(of: " ", with: "-"))")
            try FileManager.default.copyItem(atPath: vault, toPath: work)
            try recoveryText.write(toFile: (work as NSString).appendingPathComponent("recovery.txt"), atomically: true, encoding: .utf8)
            var sh = "set -u\ncd \(ExternalTool.shellQuote(work))\n"
            sh += "PATH=\(ExternalTool.shellQuote((age as NSString).deletingLastPathComponent)):$PATH\n"
            sh += String(script[..<step3.lowerBound])
            for id in notes.keys.sorted() {
                sh += "for f in notes/\(id)/*.age; do echo \"== \(id)\"; age -d -i vault-keys.txt \"$f\" | tail -c +38 | gunzip | jq -c .; done\n"
            }
            let run = try ExternalTool.run(URL(fileURLWithPath: "/bin/sh"), ["-c", sh])
            let out = String(decoding: run.out, as: UTF8.self)
            for (id, title) in notes {
                XCTAssertTrue(out.contains("== \(id)\n") && out.contains(title), "\(label): \(id) did not open:\n\(out)\n\(run.errText)")
            }
        }
    }
}
