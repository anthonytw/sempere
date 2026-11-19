import Age
import CLITestSupport
import Foundation
import Sempere
import XCTest

/// `sempere ask` (docs/cli.md "Ask your notes"; docs/design/1.3-ask.md §3.5, §6) with the fake providers
/// (`SEMPERE_INSIGHTS_FAKE=1`, debug builds): the three modes, `--retrieve-only`, `--require-model`, `--explain`,
/// the filters, a machine with no model or embedder, a read-only vault, and that nothing is written.
final class CLIAskTests: CLITestCase {
    let fake = ["SEMPERE_INSIGHTS_FAKE": "1"]
    let noModel = ["SEMPERE_INSIGHTS_FAKE": "1", "SEMPERE_INSIGHTS_FAKE_MODEL": "off"]
    let noEmbedder = ["SEMPERE_INSIGHTS_FAKE": "1", "SEMPERE_INSIGHTS_FAKE_EMBEDDER": "off"]
    let question = "What does the damping ratio decide about a spring?"

    static let texts = [
        ("Springs 1", "The damping ratio decides whether a spring mass system oscillates. Critical damping returns fastest. Resonance amplifies the amplitude."),
        ("Springs 2", "Damped oscillation of a spring and mass: the amplitude decays with the damping ratio. Resonance happens near the natural frequency."),
        ("Bread 1", "Sourdough starter needs flour and water fed daily. Knead the dough and let it rise in a warm oven."),
        ("Bread 2", "Knead sourdough dough for ten minutes, proof it overnight, bake it in a hot oven with steam."),
        ("Bread 3", "Feed the starter with flour, wait for bubbles, then mix the dough and knead it well."),
        ("Bread 4", "Rye bread needs a longer proof than wheat flour; bake at high heat for crust."),
    ]

    func setUpVault(insights: Bool = true) throws -> (args: [String], vault: Vault) {
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
        let args = ["--vault", v.vault.url.path, "--identity", v.keyPath]
        if insights {
            XCTAssertEqual(try cli(["settings", "set", "insights.enabled", "true"] + args).status, 0)
            let up = try cli(["insights", "update", "--json"] + args, env: fake)
            XCTAssertEqual(up.status, 0, up.err)
        }
        return (args, opened)
    }

    func json(_ r: CLIResult, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        XCTAssertEqual(r.status, 0, r.err, file: file, line: line)
        return (r.json as? [String: Any]) ?? [:]
    }

    func titles(_ j: [String: Any]) -> [String] { (j["notes"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String } }

    #if !os(Linux)
    func testAnswerModeCitesTheSpringsNotes() throws {
        let (args, _) = try setUpVault()
        let j = json(try cli(["ask", question, "--json"] + args, env: fake))
        XCTAssertEqual(j["mode"] as? String, "answer")
        XCTAssertEqual(j["enough"] as? Bool, true)
        let answer = try XCTUnwrap(j["answer"] as? [[String: Any]])
        XCTAssertFalse(answer.isEmpty)
        let notes = try XCTUnwrap(j["notes"] as? [[String: Any]])
        let used = notes.filter { $0["used"] as? Bool == true }
        XCTAssertFalse(used.isEmpty)
        XCTAssertTrue(used.allSatisfy { ($0["title"] as? String)?.hasPrefix("Springs") == true }, "\(used)")
        // Every citation is a note id of the list, never an invented one.
        let ids = Set(notes.compactMap { $0["note"] as? String })
        for s in answer { for id in s["sources"] as? [String] ?? [] { XCTAssertTrue(ids.contains(id)) } }
        XCTAssertEqual(j["lang"] as? String, "en")
        let text = try cli(["ask", question] + args, env: fake)
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.hasPrefix("mode: answer"), text.out)
        XCTAssertTrue(text.out.contains("Notes used:"), text.out)
    }

    func testRetrievalWhenTheModelIsOffAndRetrieveOnly() throws {
        let (args, _) = try setUpVault()
        let off = json(try cli(["ask", question, "--json"] + args, env: noModel))
        XCTAssertEqual(off["mode"] as? String, "retrieval")
        XCTAssertEqual(off["enough"] as? Bool, false)
        XCTAssertNotNil(off["missing"] as? String)
        XCTAssertTrue((off["answer"] as? [Any])?.isEmpty == true)
        XCTAssertTrue(titles(off).first?.hasPrefix("Springs") == true, "\(titles(off))")
        let first = try XCTUnwrap((off["notes"] as? [[String: Any]])?.first)
        XCTAssertFalse((first["passages"] as? [[String: Any]] ?? []).isEmpty)
        let only = json(try cli(["ask", question, "--retrieve-only", "--json"] + args, env: fake))
        XCTAssertEqual(only["mode"] as? String, "retrieval")
        XCTAssertNil(only["missing"] as? String)
        XCTAssertEqual(try cli(["ask", question, "--retrieve-only", "--require-model"] + args, env: fake).status, 2)
    }

    func testKeywordModeWithoutAnEmbedderOrInsights() throws {
        let (args, _) = try setUpVault()
        let k = json(try cli(["ask", question, "--retrieve-only", "--json"] + args, env: noEmbedder))
        XCTAssertEqual(k["mode"] as? String, "keyword")
        XCTAssertTrue(titles(k).first?.hasPrefix("Springs") == true)
        // Generation still runs without vectors.
        let a = json(try cli(["ask", question, "--json"] + args, env: noEmbedder))
        XCTAssertEqual(a["mode"] as? String, "answer")
    }

    func testKeywordModeWhenInsightsWasNeverSetUp() throws {
        let (args2, _) = try setUpVault(insights: false)
        let b = json(try cli(["ask", question, "--retrieve-only", "--json"] + args2, env: fake))
        XCTAssertEqual(b["mode"] as? String, "keyword")
        XCTAssertTrue((b["notices"] as? [String] ?? []).contains { $0.contains("Note Insights is off") })
    }

    func testRequireModelExitsThreeWithTheReason() throws {
        let (args, _) = try setUpVault()
        let r = try cli(["ask", question, "--require-model"] + args, env: noModel)
        XCTAssertEqual(r.status, 3, r.err)
        XCTAssertTrue(r.err.contains("disabled"), r.err)
        XCTAssertEqual(try cli(["ask", question, "--require-model"] + args, env: fake).status, 0)
    }

    func testFiltersAndExplain() throws {
        let (args, _) = try setUpVault()
        let kitchen = json(try cli(["ask", "sourdough dough", "--notebook", "Kitchen", "--retrieve-only", "--json"] + args, env: fake))
        XCTAssertFalse(titles(kitchen).isEmpty)
        XCTAssertTrue(titles(kitchen).allSatisfy { $0.hasPrefix("Bread") })
        let none = json(try cli(["ask", question, "--notebook", "Kitchen", "--limit", "2", "--retrieve-only", "--json"] + args, env: fake))
        XCTAssertTrue(titles(none).allSatisfy { $0.hasPrefix("Bread") }, "a filtered-out note is never a candidate")
        XCTAssertLessThanOrEqual(titles(none).count, 2)
        let future = json(try cli(["ask", question, "--since", "2999-01-01", "--json"] + args, env: fake))
        XCTAssertTrue(titles(future).isEmpty)
        XCTAssertEqual(future["enough"] as? Bool, false)
        XCTAssertEqual(try cli(["ask", question, "--since", "yesterdayish"] + args, env: fake).status, 2)
        let ex = json(try cli(["ask", question, "--explain", "--json"] + args, env: fake))
        let explain = try XCTUnwrap(ex["explain"] as? [String: Any])
        XCTAssertFalse((explain["candidates"] as? [Any] ?? []).isEmpty)
        XCTAssertFalse((explain["sent"] as? [Any] ?? []).isEmpty)
        XCTAssertNil(json(try cli(["ask", question, "--json"] + args, env: fake))["explain"])
        let text = try cli(["ask", question, "--explain"] + args, env: fake)
        XCTAssertTrue(text.out.contains("Sent to the model"), text.out)
    }

    func testReadOnlyVaultAndNothingIsWritten() throws {
        let (args, vault) = try setUpVault()
        let before = try snapshotOfFiles(vault.url)
        XCTAssertEqual(try cli(["ask", question] + args, env: fake).status, 0)
        XCTAssertEqual(try snapshotOfFiles(vault.url), before, "Ask writes nothing to the vault")
        XCTAssertEqual(try cli(["ask", ""] + args, env: fake).status, 2)
        XCTAssertEqual(try cli(["ask", question, "--limit", "0"] + args, env: fake).status, 2)
    }

    func snapshotOfFiles(_ url: URL) throws -> [String] {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var out: [String] = []
        while let f = e?.nextObject() as? URL {
            out.append("\(f.path.dropFirst(url.path.count)) \((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")
        }
        return out.sorted()
    }
    #endif

    /// Linux has no model and no embedder: keyword mode, exit 0 (no fakes: the real providers).
    func testKeywordModeWhereThereIsNothing() throws {
        let (args, _) = try setUpVault(insights: false)
        var env: [String: String] = [:]
        #if !os(Linux)
        env = noModel.merging(["SEMPERE_INSIGHTS_FAKE_EMBEDDER": "off"]) { $1 }
        #endif
        let j = json(try cli(["ask", question, "--json"] + args, env: env))
        XCTAssertEqual(j["mode"] as? String, "keyword")
        XCTAssertTrue(titles(j).first?.hasPrefix("Springs") == true, "\(titles(j))")
        XCTAssertEqual(j["enough"] as? Bool, false)
    }
}
