import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere insights` (docs/cli.md "Note insights") with the fake providers (`SEMPERE_INSIGHTS_FAKE=1`, debug builds):
/// update, show, related, search, status, map (JSON and SVG), topic, title, work-device and purge, with --json; exit 3
/// where the model work cannot run, 7 for a read-only open.
final class CLIInsightsTests: CLITestCase {
    let fake = ["SEMPERE_INSIGHTS_FAKE": "1"]

    static let texts = [
        ("Springs 1", "The damping ratio decides whether a spring mass system oscillates. Critical damping returns fastest. Resonance amplifies the amplitude."),
        ("Springs 2", "Damped oscillation of a spring and mass: the amplitude decays with the damping ratio. Resonance happens near the natural frequency."),
        ("Springs 3", "Forced oscillation of a spring mass system near resonance: the amplitude peaks when damping is small."),
        ("Bread 1", "Sourdough starter needs flour and water fed daily. Knead the dough and let it rise in a warm oven."),
        ("Bread 2", "Knead sourdough dough for ten minutes, proof it overnight, bake it in a hot oven with steam."),
        ("Bread 3", "Feed the starter with flour, wait for bubbles, then mix the dough and knead it well."),
    ]

    func setUpVault() throws -> (args: [String], vault: Vault) {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let v = try makeVault()
        let opened = try Vault.open(at: v.vault.url, identities: [v.identity])
        let state = tmp.appendingPathComponent("lib-device.json")
        for (title, text) in Self.texts {
            let page = UUID()
            var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: title.hasPrefix("Bread") ? "Kitchen" : nil, pageId: page)
            ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
            try opened.apply(ops, to: UUID(), deviceState: state, app: "test/1", wall: Date().addingTimeInterval(-3600))
        }
        return (["--vault", v.vault.url.path, "--identity", v.keyPath], opened)
    }

    func json(_ r: CLIResult, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        XCTAssertEqual(r.status, 0, r.err, file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    func testUpdateAndTheReaders() throws {
        let (args, _) = try setUpVault()
        // Off by default: nothing written.
        let off = try cli(["insights", "update"] + args, env: fake)
        XCTAssertEqual(off.status, 1)
        XCTAssertTrue(off.err.contains("insights.enabled"), off.err)
        XCTAssertEqual(try cli(["settings", "set", "insights.enabled", "true"] + args).status, 0)
        let dry = json(try cli(["insights", "update", "--dry-run", "--json"] + args, env: fake))
        XCTAssertEqual(dry["dryRun"] as? Bool, true)
        XCTAssertEqual((dry["generated"] as? [String])?.count, 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: args[1]).appendingPathComponent("insights").path))
        let up = json(try cli(["insights", "update", "--json"] + args, env: fake))
        XCTAssertEqual((up["generated"] as? [String])?.count, 6)
        XCTAssertEqual((up["embedded"] as? [String])?.count, 6)
        XCTAssertEqual(up["mapBuilt"] as? Bool, true)
        XCTAssertEqual(up["claimedWorkDevice"] as? Bool, true)
        // show
        let show = json(try cli(["insights", "show", "Springs 1", "--json"] + args, env: fake))
        XCTAssertEqual(show["state"] as? String, "current")
        XCTAssertFalse((show["keywords"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual(try cli(["insights", "show", "Springs 1"] + args, env: fake).status, 0)
        // related: the springs, never the bread; same shape without an embedder (keywords only).
        let related = json(try cli(["insights", "related", "Springs 1", "--json"] + args, env: fake))
        XCTAssertEqual(related["basis"] as? String, "vectors")
        let titles = (related["related"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        XCTAssertFalse(titles.isEmpty)
        XCTAssertTrue(titles.allSatisfy { $0.hasPrefix("Springs") }, "\(titles)")
        let noVectors = json(try cli(["insights", "related", "Springs 1", "--json"] + args,
                                     env: fake.merging(["SEMPERE_INSIGHTS_FAKE_EMBEDDER": "off"]) { $1 }))
        XCTAssertEqual(noVectors["basis"] as? String, "vectors", "a vector reader reads the shared vectors as they are")
        // search
        let search = try XCTUnwrap(try cli(["insights", "search", "sourdough", "--json"] + args, env: fake).json as? [[String: Any]])
        XCTAssertFalse(search.isEmpty)
        XCTAssertTrue(search.allSatisfy { ($0["title"] as? String)?.hasPrefix("Bread") == true })
        // status
        let status = json(try cli(["insights", "status", "--json"] + args, env: fake))
        XCTAssertEqual(status["processed"] as? Int, 6)
        XCTAssertEqual(status["pin"] as? Int, 1)
        XCTAssertEqual(status["compatibility"] as? String, "workDevice")
        XCTAssertEqual((status["devices"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try cli(["insights", "status"] + args, env: fake).status, 0)
        // map
        let map = json(try cli(["insights", "map", "--json"] + args, env: fake))
        XCTAssertEqual((map["nodes"] as? [Any])?.count, 6)
        let svg = try cli(["insights", "map", "--format", "svg"] + args, env: fake)
        XCTAssertEqual(svg.status, 0, svg.err)
        XCTAssertTrue(svg.out.hasPrefix("<svg"))
        // topic: the update summarized the Kitchen notebook.
        let topic = json(try cli(["insights", "topic", "--notebook", "Kitchen", "--json"] + args, env: fake))
        XCTAssertEqual(topic["generated"] as? Bool, true)
        XCTAssertEqual((topic["members"] as? [String])?.count, 3)
        XCTAssertEqual(try cli(["insights", "topic", "--notebook", "Kitchen", "--tag", "x"] + args, env: fake).status, 2)
        // title: only for voice notes.
        let title = json(try cli(["insights", "title", "Springs 1", "--json"] + args, env: fake))
        XCTAssertEqual(title["action"] as? String, "notVoiceNote")
        // verify lists them as hints, healthy.
        let verify = json(try cli(["vault", "verify", "--json"] + args))
        XCTAssertEqual(verify["healthy"] as? Bool, true)
        XCTAssertGreaterThanOrEqual((verify["insights"] as? [Any])?.count ?? 0, 8)
    }

    func testWorkDevicePinAndPurge() throws {
        let (args, vault) = try setUpVault()
        XCTAssertEqual(try cli(["settings", "set", "insights.enabled", "true"] + args).status, 0)
        let none = json(try cli(["insights", "work-device", "--json"] + args, env: fake))
        XCTAssertNil(none["workDevice"] as? String)
        let me = try XCTUnwrap(vault.manifest.devices.first?.id)
        let claimed = json(try cli(["insights", "work-device", "--claim", "--json"] + args, env: fake))
        XCTAssertEqual(claimed["workDevice"] as? String, me)
        XCTAssertEqual(try cli(["insights", "work-device", "00000000"] + args, env: fake).status, 1, "not a device of the vault")
        XCTAssertEqual(try cli(["insights", "work-device", "nothex"] + args, env: fake).status, 2)
        XCTAssertEqual(json(try cli(["insights", "work-device", me, "--json"] + args, env: fake))["changed"] as? Bool, true)
        // --pin needs --yes.
        XCTAssertEqual(try cli(["insights", "map", "--pin", "2"] + args, env: fake).status, 2)
        let pinned = json(try cli(["insights", "map", "--pin", "2", "--yes", "--json"] + args, env: fake))
        XCTAssertEqual(pinned["revision"] as? Int, 2)
        XCTAssertEqual(try cli(["settings", "get", "insights.embeddingRevision"] + args).out.trimmingCharacters(in: .whitespacesAndNewlines),
                       #"{"en":2}"#)
        XCTAssertEqual(try cli(["settings", "set", "insights.embeddingRevision", #"{"en":1}"#] + args).status, 0)
        XCTAssertEqual(try cli(["insights", "update"] + args, env: fake).status, 0)
        XCTAssertFalse(InsightsStore.names(in: vault.insightsURL).isEmpty)
        let purge = json(try cli(["insights", "purge", "--json"] + args, env: fake))
        XCTAssertFalse((purge["deleted"] as? [String] ?? []).isEmpty)
        XCTAssertTrue(InsightsStore.names(in: vault.insightsURL).isEmpty)
        XCTAssertEqual(try cli(["settings", "get", "insights.enabled"] + args).out.trimmingCharacters(in: .whitespacesAndNewlines), "false")
        XCTAssertEqual(try cli(["settings", "set", "insights.voiceNoteTitle", "{when}"] + args).status, 2, "tokens only")
        XCTAssertEqual(try cli(["settings", "set", "insights.voiceNoteTitle", "{slug} ({date})"] + args).status, 0)
    }

    func testExitCodes() throws {
        let (args, _) = try setUpVault()
        XCTAssertEqual(try cli(["settings", "set", "insights.enabled", "true"] + args).status, 0)
        // No model here: exit 3 with the reason, nothing written.
        let noModel = try cli(["insights", "update"] + args, env: fake.merging(["SEMPERE_INSIGHTS_FAKE_MODEL": "off"]) { $1 })
        XCTAssertEqual(noModel.status, 3, noModel.err)
        XCTAssertTrue(noModel.err.contains("disabled"), noModel.err)
        let noEmbedder = try cli(["insights", "update", "--embeddings-only"] + args,
                                 env: fake.merging(["SEMPERE_INSIGHTS_FAKE_EMBEDDER": "off"]) { $1 })
        XCTAssertEqual(noEmbedder.status, 3, noEmbedder.err)
        XCTAssertEqual(try cli(["insights", "work-device", "--claim"] + args,
                               env: fake.merging(["SEMPERE_INSIGHTS_FAKE_EMBEDDER": "off"]) { $1 }).status, 3)
        XCTAssertEqual(try cli(["insights", "topic", "--tag", "x", "--generate"] + args,
                               env: fake.merging(["SEMPERE_INSIGHTS_FAKE_MODEL": "off"]) { $1 }).status, 3)
        #if os(Linux)
        // Linux has neither framework (D18).
        for cmd in [["update"], ["map", "--rebuild"], ["work-device", "--claim"], ["topic", "--tag", "x", "--generate"]] {
            let r = try cli(["insights"] + cmd + args)
            XCTAssertEqual(r.status, 3, "\(cmd): \(r.err)")
            XCTAssertTrue(r.err.contains("macOS 26"), r.err)
        }
        // Readers work.
        XCTAssertEqual(try cli(["insights", "status", "--json"] + args).status, 0)
        #endif
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: args[1]).appendingPathComponent("insights").path))
    }
}
