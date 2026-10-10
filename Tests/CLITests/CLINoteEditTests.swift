import CLITestSupport
import Foundation
import XCTest

/// The note-editing commands (`notes new|rename|tag|move|paper|delete|undelete`,
/// `notebooks`, `tags`, `pages`) on a copy of the fixture vault.
final class CLINoteEditTests: CLITestCase {
    var vault: String!
    var access: [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        vault = try copyFixtureVault()
    }

    func revisions(_ id: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vault + "/notes/\(id)").sorted()
    }

    /// Runs a command that must succeed and returns its JSON object.
    func json(_ args: [String]) throws -> [String: Any] {
        let r = try cli(args + access + ["--json"])
        XCTAssertEqual(r.status, 0, r.err)
        return try XCTUnwrap(r.json as? [String: Any], r.out)
    }

    func note(_ obj: [String: Any]) throws -> [String: Any] { try XCTUnwrap(obj["note"] as? [String: Any]) }

    func testNewCreatesOneDeltaWithEveryField() throws {
        let obj = try json(["notes", "new", " Week 1 ", "--notebook", " School // Math ", "--tag", "Physics",
                            "--tag", "physics", "--paper", "grid", "--spacing", "30", "--page-size", "a4"])
        let n = try note(obj)
        let id = try XCTUnwrap(n["id"] as? String)
        XCTAssertEqual(n["title"] as? String, "Week 1")
        XCTAssertEqual(n["notebook"] as? String, "School/Math")
        XCTAssertEqual(n["tags"] as? [String], ["Physics"])
        XCTAssertEqual(n["pages"] as? Int, 1)
        XCTAssertEqual(try revisions(id), [try XCTUnwrap(obj["file"] as? String)])

        let pages = try json(["pages", "list", id])
        let paper = try XCTUnwrap(pages["paper"] as? [String: Any])
        XCTAssertEqual(paper["kind"] as? String, "grid")
        XCTAssertEqual(paper["spacing"] as? Double, 30)
        XCTAssertEqual((pages["pageSize"] as? [String: Any])?["width"] as? Double, 595)

        // Plain output is the id alone on stdout.
        let plain = try cli(["notes", "new", "Second"] + access)
        XCTAssertEqual(plain.status, 0, plain.err)
        XCTAssertNotNil(UUID(uuidString: plain.out.trimmingCharacters(in: .whitespacesAndNewlines)), plain.out)
    }

    /// Without a title the note is named after the date and time, as in the app.
    func testNewWithoutATitleUsesTheDateAndTime() throws {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let obj = try json(["notes", "new", "--title-format", "'Note' yyyy"])
        let title = try XCTUnwrap(try note(obj)["title"] as? String)
        // The year may turn between the command and this line only on New Year's Eve at midnight.
        XCTAssertTrue(title == "Note \(year)" || title == "Note \(year + 1)", title)

        let plain = try json(["notes", "new"])
        let defaultTitle = try XCTUnwrap(try note(plain)["title"] as? String)
        XCTAssertFalse(defaultTitle.isEmpty)
        XCTAssertTrue(defaultTitle.contains(String(year)) || defaultTitle.contains(String(year % 100)), defaultTitle)

        // An explicit empty title stays empty.
        XCTAssertEqual(try note(try json(["notes", "new", ""]))["title"] as? String, "")

        // strftime, and the machine's setting from the environment.
        let strf = try json(["notes", "new", "--title-format", "Note %Y"])
        let strfTitle = try XCTUnwrap(try note(strf)["title"] as? String)
        XCTAssertTrue(strfTitle == "Note \(year)" || strfTitle == "Note \(year + 1)", strfTitle)
        let env = try cli(["notes", "new", "--json"] + access, env: ["SEMPERE_TITLE_FORMAT": "'Env' yyyy"])
        XCTAssertEqual(env.status, 0, env.err)
        let envTitle = ((env.json as? [String: Any])?["note"] as? [String: Any])?["title"] as? String
        XCTAssertTrue(envTitle == "Env \(year)" || envTitle == "Env \(year + 1)", "\(String(describing: envTitle))")
    }

    /// A format the app's setting would refuse is refused with the same reason, before anything is written.
    func testNewRefusesAFormatItCannotUse() throws {
        func noteFolders() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: vault + "/notes").count }
        let notes = try noteFolders()
        for (format, reason) in [("'Lecture d MMM", "never closed"), ("Lecture d MMM", "not a date field"),
                                 ("%Y %Q", "strftime directive")] {
            let r = try cli(["notes", "new", "--title-format", format] + access)
            XCTAssertEqual(r.status, 2, format)
            XCTAssertTrue(r.err.contains(reason), r.err)
        }
        let env = try cli(["notes", "new"] + access, env: ["SEMPERE_TITLE_FORMAT": "%Q"])
        XCTAssertEqual(env.status, 2)
        XCTAssertTrue(env.err.contains("SEMPERE_TITLE_FORMAT"), env.err)
        // A typed title needs no format.
        XCTAssertEqual(try cli(["notes", "new", "Typed"] + access, env: ["SEMPERE_TITLE_FORMAT": "%Q"]).status, 0)
        XCTAssertEqual(try noteFolders(), notes + 1)
    }

    func testRenameByTitleAndPrefixWritesOneDeltaOrNothing() throws {
        let before = try revisions(Self.lecture)
        let obj = try json(["notes", "rename", "fixture LECTURE", "  Renamed  "])
        XCTAssertEqual(obj["changed"] as? Bool, true)
        XCTAssertEqual(try note(obj)["title"] as? String, "Renamed")
        let file = try XCTUnwrap(obj["file"] as? String)
        XCTAssertEqual(try revisions(Self.lecture), (before + [file]).sorted())

        let again = try json(["notes", "rename", "1111", "Renamed"])
        XCTAssertEqual(again["changed"] as? Bool, false)
        XCTAssertNil(again["file"] as? String)
        XCTAssertEqual(try revisions(Self.lecture).count, before.count + 1)

        // The delta is stamped with this machine's device id, as for snapshot.
        let device = try String(contentsOf: tmp.appendingPathComponent("state/sempere/device.json"), encoding: .utf8)
        XCTAssertTrue(device.contains(file.split(separator: "-")[1]), device)
    }

    func testFavoriteSetsAndClearsTheMarkAndListFilters() throws {
        let before = try revisions(Self.lecture)
        let on = try json(["notes", "favorite", "fixture LECTURE"])
        XCTAssertEqual(on["changed"] as? Bool, true)
        XCTAssertEqual(try note(on)["favorite"] as? Bool, true)
        XCTAssertEqual(try revisions(Self.lecture).count, before.count + 1)

        let again = try json(["notes", "favorite", "1111"])
        XCTAssertEqual(again["changed"] as? Bool, false)
        XCTAssertEqual(try revisions(Self.lecture).count, before.count + 1)

        let listed = try cli(["notes", "list", "--favorites", "--json"] + access)
        XCTAssertEqual(listed.status, 0, listed.err)
        let favorites = try XCTUnwrap(listed.json as? [[String: Any]])
        XCTAssertEqual(favorites.compactMap { $0["id"] as? String }, [Self.lecture])

        let off = try json(["notes", "favorite", Self.lecture, "--off"])
        XCTAssertEqual(off["changed"] as? Bool, true)
        XCTAssertEqual(try note(off)["favorite"] as? Bool, false)
        let none = try cli(["notes", "list", "--favorites", "--json"] + access)
        XCTAssertEqual((none.json as? [[String: Any]])?.count, 0)
        XCTAssertEqual(try json(["notes", "favorite", Self.lecture, "--off"])["changed"] as? Bool, false)
    }

    func testUnknownNoteIsAnError() throws {
        let r = try cli(["notes", "rename", "no such note", "x"] + access)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.hasPrefix("sempere:"), r.err)
    }

    func testTagsAddWithVaultSpellingAndRemoveEveryInstance() throws {
        // The fixture note carries "fixture" from a legacy snapshot.
        let id = try XCTUnwrap(try note(try json(["notes", "new", "Other", "--tag", "Physics"]))["id"] as? String)
        let added = try json(["notes", "tag", Self.lecture, "--add", "physics", "--add", "  New   one "])
        XCTAssertEqual(try note(added)["tags"] as? [String], ["fixture", "Physics", "New one"])
        // Already there in another spelling: nothing written.
        XCTAssertEqual(try json(["notes", "tag", Self.lecture, "--add", "NEW ONE"])["changed"] as? Bool, false)

        let removed = try json(["notes", "tag", Self.lecture, "--remove", "FIXTURE", "--remove", "physics"])
        XCTAssertEqual(try note(removed)["tags"] as? [String], ["New one"])

        let list = try cli(["tags", "list"] + access + ["--json"])
        XCTAssertEqual(list.status, 0, list.err)
        let rows = try XCTUnwrap(list.json as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["tag"] as? String }, ["New one", "Physics"])
        XCTAssertEqual(rows.map { $0["notes"] as? Int }, [1, 1])
        _ = id

        let both = try cli(["notes", "tag", Self.lecture, "--add", "x", "--remove", "X"] + access)
        XCTAssertEqual(both.status, 2, both.err)
        let none = try cli(["notes", "tag", Self.lecture, "--add", "  "] + access)
        XCTAssertEqual(none.status, 2, none.err)
    }

    func testNewUsesTheVaultSpellingOfItsTags() throws {
        _ = try json(["notes", "new", "First", "--tag", "Physics"])
        let second = try json(["notes", "new", "Second", "--tag", "PHYSICS", "--tag", " lab  work "])
        XCTAssertEqual(try note(second)["tags"] as? [String], ["Physics", "lab work"])
        // The lecture's "fixture" (any case) is reused too.
        XCTAssertEqual(try note(try json(["notes", "new", "Third", "--tag", "FIXTURE"]))["tags"] as? [String], ["fixture"])
    }

    func testMoveAndNotebookRenameOfASubtree() throws {
        func new(_ title: String, _ notebook: String) throws -> String {
            try XCTUnwrap(try note(try json(["notes", "new", title, "--notebook", notebook]))["id"] as? String)
        }
        let a = try new("a", "School/Math"), b = try new("b", "School/Math/Algebra"), c = try new("c", "School/Mathematics")
        XCTAssertEqual(try note(try json(["notes", "move", Self.lecture, " School / Math "]))["notebook"] as? String,
                       "School/Math")
        _ = try json(["notes", "delete", b])   // deleted notes move with their notebook

        let listed = try cli(["notes", "list", "--notebook", "School/Math", "--deleted", "-q"] + access)
        XCTAssertEqual(listed.status, 0, listed.err)
        XCTAssertEqual(Set(listed.out.split(separator: "\n").map { String($0.prefix(36)) }), [a, b, Self.lecture])

        let dry = try json(["notebooks", "rename", "School/Math", "Uni/Maths", "--dry-run"])
        XCTAssertEqual((dry["notes"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(try revisions(a).count, 1)

        let done = try json(["notebooks", "rename", "School/Math", "Uni/Maths"])
        let changes = try XCTUnwrap(done["notes"] as? [[String: Any]])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: changes.map { ($0["note"] as! String, $0["to"] as! String) }),
                       [a: "Uni/Maths", b: "Uni/Maths/Algebra", Self.lecture: "Uni/Maths"])
        XCTAssertTrue(changes.allSatisfy { ($0["file"] as? String)?.hasSuffix(".delta.age") == true })
        XCTAssertEqual(try revisions(c).count, 1)   // School/Mathematics is not inside School/Math

        let tree = try cli(["notebooks", "list", "--json"] + access)
        let rows = try XCTUnwrap(tree.json as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["path"] as? String }, ["School", "School/Mathematics", "Uni", "Uni/Maths"])
        XCTAssertEqual(rows.map { $0["total"] as? Int }, [1, 1, 2, 2])   // b is deleted

        // An empty target lifts the notebook's notes out of it.
        _ = try json(["notebooks", "rename", "Uni", ""])
        XCTAssertEqual(try note(try json(["notes", "move", a, "--none"]))["notebook"] as? String, nil)
        let out = try cli(["notes", "move", a] + access)
        XCTAssertEqual(out.status, 2, out.err)
    }

    /// `notebooks move`: what dragging a notebook onto another does in the app.
    func testNotebookMoveNestsUnnestsAndRefusesCycles() throws {
        func new(_ title: String, _ notebook: String) throws -> String {
            try XCTUnwrap(try note(try json(["notes", "new", title, "--notebook", notebook]))["id"] as? String)
        }
        func notebookOf(_ id: String) throws -> String? { try note(try json(["notes", "show", id]))["notebook"] as? String }
        let a = try new("a", "School/Math"), b = try new("b", "School/Math/Algebra"), c = try new("c", "School/Mathematics")
        let before = try revisions(c).count

        // Nest School/Math into Archive: it keeps its last level, the subtree comes along.
        let dry = try json(["notebooks", "move", "School/Math", "Archive", "--dry-run"])
        XCTAssertEqual((dry["notes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(try notebookOf(a), "School/Math")
        let done = try json(["notebooks", "move", "School/Math", " Archive ", "--json"])
        XCTAssertEqual(done["from"] as? String, "School/Math")
        XCTAssertEqual(done["to"] as? String, "Archive/Math")
        XCTAssertEqual(try notebookOf(a), "Archive/Math")
        XCTAssertEqual(try notebookOf(b), "Archive/Math/Algebra")
        XCTAssertEqual(try notebookOf(c), "School/Mathematics")
        XCTAssertEqual(try revisions(c).count, before, "a sibling with a longer name is untouched")

        // Un-nest: to the top level, by "" or by the flag.
        XCTAssertEqual(try json(["notebooks", "move", "Archive/Math", ""])["to"] as? String, "Math")
        XCTAssertEqual(try notebookOf(b), "Math/Algebra")
        XCTAssertEqual(try json(["notebooks", "move", "Math/Algebra", "--top-level"])["to"] as? String, "Algebra")
        XCTAssertEqual(try notebookOf(b), "Algebra")

        // Into itself or a descendant: usage error, nothing written.
        let count = try revisions(a).count
        for args in [["notebooks", "move", "Math", "Math"], ["notebooks", "move", "Math", "Math/Sub"]] {
            let r = try cli(args + access)
            XCTAssertEqual(r.status, 2, "\(args): \(r.err)")
            XCTAssertTrue(r.err.contains("into itself"), r.err)
        }
        XCTAssertEqual(try revisions(a).count, count)
        // Exactly one of a parent and --top-level.
        XCTAssertEqual(try cli(["notebooks", "move", "Math"] + access).status, 2)
        XCTAssertEqual(try cli(["notebooks", "move", "Math", "X", "--top-level"] + access).status, 2)
        // Moving into the notebook it already is in changes nothing.
        let same = try json(["notebooks", "move", "School/Mathematics", "School"])
        XCTAssertEqual((same["notes"] as? [Any])?.count, 0)
    }

    func testNotebookRenameRefusesWhenANoteIsUnreadable() throws {
        let junk = vault + "/notes/\(Self.lecture)/17000000000000000-deadbeef-1.delta.age"
        try Data("junk".utf8).write(to: URL(fileURLWithPath: junk))
        let r = try cli(["notebooks", "rename", "A", "B"] + access)
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("cannot be read"), r.err)
    }

    func testDeleteUndeleteAndPagesOfADeletedNote() throws {
        let before = try revisions(Self.lecture).count
        XCTAssertEqual(try note(try json(["notes", "delete", Self.lecture]))["deleted"] as? Bool, true)
        XCTAssertEqual(try json(["notes", "delete", Self.lecture])["changed"] as? Bool, false)
        let refused = try cli(["pages", "add", Self.lecture] + access)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.err.contains("undelete"), refused.err)
        XCTAssertEqual(try note(try json(["notes", "undelete", Self.lecture]))["deleted"] as? Bool, false)
        XCTAssertEqual(try json(["notes", "undelete", Self.lecture])["changed"] as? Bool, false)
        XCTAssertEqual(try revisions(Self.lecture).count, before + 2)
    }

    func testPagesAddAndPaperForOnePageOrAll() throws {
        XCTAssertEqual(try note(try json(["pages", "add", Self.lecture, "--count", "2"]))["pages"] as? Int, 4)

        let one = try json(["notes", "paper", Self.lecture, "cornell", "--page", "2", "--cue-width", "120"])
        XCTAssertEqual(one["changed"] as? Bool, true)
        XCTAssertEqual((one["paper"] as? [String: Any])?["cueWidth"] as? Double, 120)
        var pages = try XCTUnwrap(try json(["pages", "list", Self.lecture])["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.map { ($0["paper"] as? [String: Any])?["kind"] as? String }, [nil, "cornell", nil, nil])

        // Without a kind the current paper is edited: the page's own.
        let edited = try json(["notes", "paper", Self.lecture, "--page", "2", "--line-color", "#112233"])
        XCTAssertEqual((edited["paper"] as? [String: Any])?["kind"] as? String, "cornell")
        XCTAssertEqual((edited["paper"] as? [String: Any])?["lineColor"] as? String, "#112233FF")

        // The whole note: every page follows the note's paper again.
        let all = try json(["notes", "paper", Self.lecture, "margin-ruled", "--margin-left", "90"])
        XCTAssertEqual((all["paper"] as? [String: Any])?["kind"] as? String, "marginRuled")
        let listed = try json(["pages", "list", Self.lecture])
        pages = try XCTUnwrap(listed["pages"] as? [[String: Any]])
        XCTAssertTrue(pages.allSatisfy { $0["paper"] == nil })
        XCTAssertEqual((listed["paper"] as? [String: Any])?["marginLeft"] as? Double, 90)
        XCTAssertEqual(try json(["notes", "paper", Self.lecture, "--margin-left", "90"])["changed"] as? Bool, false)

        for bad in [["--spacing", "1"], ["--spacing", "nan"], ["--line-color", "red"], ["--page", "0", "dot"],
                    ["--page", "9", "dot"], ["origami"], []] {
            let r = try cli(["notes", "paper", Self.lecture] + bad + access)
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
        }
        let tooMany = try cli(["pages", "add", Self.lecture, "--count", "0"] + access)
        XCTAssertEqual(tooMany.status, 2)
    }

    /// The app's page gestures from the CLI (format.md §5.4.3): insert after a
    /// page, move, duplicate, delete; one delta each, nothing for a no-op.
    func testPagesInsertMoveDuplicateDelete() throws {
        func ids() throws -> [String] {
            try XCTUnwrap(try json(["pages", "list", Self.lecture])["pages"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        }
        func strokes() throws -> [Int] {
            try XCTUnwrap(try json(["pages", "list", Self.lecture])["pages"] as? [[String: Any]]).compactMap { $0["strokes"] as? Int }
        }
        let start = try ids()
        XCTAssertEqual(start.count, 2)
        let inked = try strokes()

        XCTAssertEqual(try json(["pages", "add", Self.lecture, "--after", "1"])["changed"] as? Bool, true)
        var now = try ids()
        XCTAssertEqual(now.count, 3)
        XCTAssertEqual([now[0], now[2]], start, "the blank page went between them")

        let before = try revisions(Self.lecture).count
        XCTAssertEqual(try json(["pages", "move", Self.lecture, "3", "--to", "1"])["changed"] as? Bool, true)
        now = try ids()
        XCTAssertEqual(now[0], start[1])
        XCTAssertEqual(try json(["pages", "move", Self.lecture, "1", "--to", "1"])["changed"] as? Bool, false)

        XCTAssertEqual(try json(["pages", "duplicate", Self.lecture, "1"])["changed"] as? Bool, true)
        now = try ids()
        XCTAssertEqual(now.count, 4)
        XCTAssertEqual(try strokes()[0], try strokes()[1], "the copy has the page's ink")
        XCTAssertEqual(try strokes()[1], inked[1])

        XCTAssertEqual(try json(["pages", "delete", Self.lecture, "2"])["changed"] as? Bool, true)
        XCTAssertEqual(try ids(), [now[0], now[2], now[3]], "the copy is gone")
        XCTAssertEqual(try revisions(Self.lecture).count, before + 3)

        for bad in [["move", Self.lecture, "9", "--to", "1"], ["move", Self.lecture, "1", "--to", "0"],
                    ["delete", Self.lecture, "0"], ["duplicate", Self.lecture, "4"], ["add", Self.lecture, "--after", "9"]] {
            let r = try cli(["pages"] + bad + access)
            XCTAssertEqual(r.status, 1, "\(bad): \(r.err)")
        }
        for _ in 0..<2 { _ = try json(["pages", "delete", Self.lecture, "1"]) }
        let last = try cli(["pages", "delete", Self.lecture, "1"] + access)
        XCTAssertEqual(last.status, 1)
        XCTAssertTrue(last.err.contains("at least one page"), last.err)
        XCTAssertEqual(try cli(["vault", "verify"] + access).status, 0)
    }

    func testEditsAreRefusedOnALegacyVault() throws {
        let legacy = try copyLegacyVault()
        for args in [["notes", "rename", Self.lecture, "x"], ["notes", "new", "x"], ["notebooks", "list"],
                     ["notebooks", "rename", "a", "b"], ["notebooks", "move", "a", "b"], ["tags", "list"], ["pages", "list", Self.lecture]] {
            let r = try cli(args + ["--vault", legacy, "--identity", Self.legacyKey])
            XCTAssertEqual(r.status, 5, "\(args): \(r.err)")
        }
    }
}
