import FuzzSupport
import TempDirSupport
import XCTest
import Foundation
import Sempere
@testable import SempereRender

/// `BulkExportPlan` and `BulkExportSession`: the app's "Export Notes…" and
/// `sempere export --all --format pdf|png`.
final class BulkExportTests: XCTestCase {
    static let when = Date(timeIntervalSince1970: 1_760_000_000)

    func id(_ n: Int, prefix: String = "0d1c6a1e") -> UUID {
        UUID(uuidString: String(format: "\(prefix)-0000-4000-8000-%012d", n))!
    }

    func summary(_ n: Int, _ title: String, notebook: String? = nil, deleted: Bool = false, prefix: String = "0d1c6a1e") -> NoteSummary {
        NoteSummary(id: id(n, prefix: prefix), title: title, tags: [], notebook: notebook, deleted: deleted, pages: 1,
                    strokes: 1, modified: Self.when, problem: nil)
    }

    func state(_ title: String, pages: Int = 1) -> NoteState {
        T.note(pages: (0..<pages).map { _ in [T.stroke([T.pt(10, 10), T.pt(80, 50), T.pt(120, 20)])] }, meta: T.meta(title: title))
    }

    func scratch() throws -> URL { makeScratch("bulk") }

    func listing(_ dir: URL) -> [String] { FileTree.regularFiles(under: dir, skipHidden: true) }

    let vaultNotes: [NoteSummary] = [
        NoteSummary(id: UUID(uuidString: "00000003-0000-4000-8000-000000000000")!, title: "Week 1", tags: [],
                    notebook: "School/Math", deleted: false, pages: 1, strokes: 1, modified: nil, problem: nil),
        NoteSummary(id: UUID(uuidString: "00000001-0000-4000-8000-000000000000")!, title: "Groceries", tags: [],
                    notebook: nil, deleted: false, pages: 1, strokes: 1, modified: nil, problem: nil),
        NoteSummary(id: UUID(uuidString: "00000002-0000-4000-8000-000000000000")!, title: "Intro", tags: [],
                    notebook: "School", deleted: false, pages: 1, strokes: 1, modified: nil, problem: nil),
        NoteSummary(id: UUID(uuidString: "00000004-0000-4000-8000-000000000000")!, title: "Old", tags: [],
                    notebook: "School/Math", deleted: true, pages: 1, strokes: 1, modified: nil, problem: nil),
        NoteSummary(id: UUID(uuidString: "00000005-0000-4000-8000-000000000000")!, title: "Proofs", tags: [],
                    notebook: " School // Math / Logic ", deleted: false, pages: 1, strokes: 1, modified: nil, problem: nil),
    ]

    // MARK: Selection → job list

    func testVaultScopeMirrorsNotebooksAndSkipsDeleted() {
        let jobs = BulkExportPlan.jobs(for: .vault, from: vaultNotes, format: .pdf, layout: .notebooks)
        XCTAssertEqual(jobs.map { $0.path(.pdf) }, [
            "Groceries-00000001.pdf",
            "School/Intro-00000002.pdf",
            "School/Math/Week-1-00000003.pdf",
            "School/Math/Logic/Proofs-00000005.pdf",
        ])
        let withDeleted = BulkExportPlan.jobs(for: .vault, from: vaultNotes, format: .pdf, layout: .notebooks, includeDeleted: true)
        XCTAssertEqual(withDeleted.count, 5)
        XCTAssertEqual(BulkExportPlan.jobs(for: .vault, from: vaultNotes, format: .png, layout: .flat).map { $0.path(.png) },
                       ["Groceries-00000001", "Intro-00000002", "Week-1-00000003", "Proofs-00000005"])
    }

    func testNotebookScopeStartsAtTheNotebook() {
        let jobs = BulkExportPlan.jobs(for: .notebook("School/Math"), from: vaultNotes, format: .pdf, layout: .notebooks)
        XCTAssertEqual(jobs.map { $0.path(.pdf) }, ["Math/Week-1-00000003.pdf", "Math/Logic/Proofs-00000005.pdf"])
        // A notebook is not a prefix match: School/Mathematics is not inside School/Math.
        var more = vaultNotes
        more.append(NoteSummary(id: UUID(uuidString: "00000006-0000-4000-8000-000000000000")!, title: "X", tags: [],
                                notebook: "School/Mathematics", deleted: false, pages: 1, strokes: 1, modified: nil, problem: nil))
        XCTAssertEqual(BulkExportPlan.jobs(for: .notebook("School/Math"), from: more, format: .pdf, layout: .notebooks).count, 2)
        XCTAssertEqual(BulkExportPlan.jobs(for: .notebook("School"), from: more, format: .pdf, layout: .notebooks).map { $0.path(.pdf) }, [
            "School/Intro-00000002.pdf", "School/Math/Week-1-00000003.pdf", "School/Math/Logic/Proofs-00000005.pdf",
            "School/Mathematics/X-00000006.pdf",
        ])
    }

    func testNotesScopeKeepsOrderDropsUnknownAndRepeats() {
        let ids = [vaultNotes[2].id, UUID(), vaultNotes[0].id, vaultNotes[2].id, vaultNotes[3].id]
        let jobs = BulkExportPlan.jobs(for: .notes(ids), from: vaultNotes, format: .pdf, layout: .flat)
        // A deleted note named explicitly is exported (the list's selection can hold one).
        XCTAssertEqual(jobs.map(\.title), ["Intro", "Week 1", "Old"])
    }

    // MARK: Names and collisions

    func testSameTitlesGetDistinctNames() {
        let a = summary(1, "Lecture"), b = summary(2, "Lecture", prefix: "0d1c6a1f")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [a, b], format: .pdf, layout: .flat)
        XCTAssertEqual(Set(jobs.map(\.stem)), ["Lecture-0d1c6a1e", "Lecture-0d1c6a1f"])
    }

    func testSameTitleAndIdPrefixFallsBackToTheFullId() {
        // Same title, ids that share the first 8 hex digits: the short names would be equal.
        let a = summary(1, "Lecture"), b = summary(2, "lecture")
        for order in [[a, b], [b, a]] {
            let jobs = BulkExportPlan.jobs(for: .notes(order.map(\.id)), from: order, format: .pdf, layout: .flat)
            let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.noteId, $0.stem) })
            // The smaller id keeps the short name whatever the order (stable across re-runs).
            XCTAssertEqual(byID[a.id], "Lecture-0d1c6a1e")
            XCTAssertEqual(byID[b.id], "lecture-" + b.id.uuidString.lowercased())
        }
    }

    func testCollisionWithAFolderAndUnicodeNormalisation() {
        // "Café" in NFC and NFD with the same id prefix collide on macOS; a note named like a sub-folder too.
        let nfc = summary(1, "Caf\u{E9}"), nfd = summary(2, "Cafe\u{301}")
        let folder = NoteSummary(id: id(3), title: "x", tags: [], notebook: "Dir-0d1c6a1e", deleted: false, pages: 1,
                                 strokes: 1, modified: nil, problem: nil)
        let clash = summary(4, "Dir")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [nfc, nfd, folder, clash], format: .png, layout: .notebooks)
        let paths = jobs.map { $0.path(.png).precomposedStringWithCanonicalMapping.lowercased() }
        XCTAssertEqual(Set(paths).count, 4, "\(paths)")
        XCTAssertFalse(paths.contains("dir-0d1c6a1e"), "the PNG folder would merge with the notebook's folder")
    }

    func testIllegalCharactersInTitlesAndNotebooks() {
        let s = NoteSummary(id: id(1), title: "a/b\\c:d*e?f\"g<h>i|j\nk", tags: [], notebook: "CON/x:y", deleted: false,
                            pages: 1, strokes: 1, modified: nil, problem: nil)
        let empty = summary(2, "  ", prefix: "0d1c6a1f")
        let dots = summary(3, "..", prefix: "0d1c6a20")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [s, empty, dots], format: .pdf, layout: .notebooks)
        let paths = Set(jobs.map { $0.path(.pdf) })
        XCTAssertEqual(paths, ["CON_/x-y/a-b-c-d-e-f-g-h-i-j-k-0d1c6a1e.pdf", "untitled-0d1c6a1f.pdf", "untitled-0d1c6a20.pdf"])
        for p in paths { XCTAssertTrue(BulkExportManifest.isSafe(p), p) }
    }

    // MARK: Session: folder

    func testFolderExportWritesTreeAndResumesUnchangedNotes() throws {
        let root = try scratch()
        let notes = [summary(1, "One", notebook: "A"), summary(2, "Two", notebook: "A/B", prefix: "0d1c6a1f")]
        let states = [notes[0].id: state("One"), notes[1].id: state("Two", pages: 2)]
        let options = BulkExportOptions(format: .pdf)
        let jobs = BulkExportPlan.jobs(for: .vault, from: notes, format: .pdf, layout: .notebooks)

        func run(versions: [UUID: String]) throws -> BulkExportResult {
            let session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
            for job in jobs {
                let v = versions[job.noteId]!
                if session.skip(job, version: v) { continue }
                try session.export(job, state: states[job.noteId]!, version: v, blobs: nil)
            }
            return try session.finish(cancelled: false)
        }
        let first = try run(versions: [notes[0].id: "v1", notes[1].id: "v1"])
        XCTAssertEqual(first.exported.count, 2)
        XCTAssertEqual(listing(root), ["A/B/Two-0d1c6a1f.pdf", "A/One-0d1c6a1e.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".sempere-export-bulk.json").path))

        // Same versions: both skipped, nothing rendered.
        let again = try run(versions: [notes[0].id: "v1", notes[1].id: "v1"])
        XCTAssertEqual(again.skipped.count, 2)
        XCTAssertEqual(again.exported.count, 0)
        // One note changed: only it is written.
        let changed = try run(versions: [notes[0].id: "v1", notes[1].id: "v2"])
        XCTAssertEqual(changed.skipped.map(\.job.title), ["One"])
        XCTAssertEqual(changed.exported.map(\.job.title), ["Two"])
        // A file whose size no longer matches (truncated by hand) is written again.
        let one = root.appendingPathComponent("A/One-0d1c6a1e.pdf")
        try Data("%PDF-".utf8).write(to: one)
        let repaired = try run(versions: [notes[0].id: "v1", notes[1].id: "v2"])
        XCTAssertEqual(repaired.exported.map(\.job.title), ["One"])
        XCTAssertGreaterThan(try Data(contentsOf: one).count, 100)
        // Other options (no paper) re-render everything.
        let session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .pdf, paper: false), jobs: jobs)
        XCTAssertFalse(session.skip(jobs[0], version: "v1"))
        _ = try session.finish(cancelled: false)
    }

    func testResumeIgnoresAHostileManifest() throws {
        let root = try scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = summary(1, "One")
        let job = BulkExportPlan.jobs(for: .vault, from: [s], format: .pdf, layout: .flat)[0]
        // A manifest naming the note's file outside the folder, and one that is not JSON.
        let entry = #"{"note":"\#(s.id.uuidString.lowercased())","version":"v1","options":"\#(BulkExportOptions(format: .pdf).fingerprint)","size":3}"#
        try Data(#"{"version":1,"files":{"../One-0d1c6a1e.pdf":\#(entry)}}"#.utf8)
            .write(to: root.appendingPathComponent(".sempere-export-bulk.json"))
        try Data("abc".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("One-0d1c6a1e.pdf"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("One-0d1c6a1e.pdf")) }
        var session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .pdf), jobs: [job])
        XCTAssertFalse(session.skip(job, version: "v1"))
        _ = try session.finish(cancelled: false)
        try Data("not json".utf8).write(to: root.appendingPathComponent(".sempere-export-bulk.json"))
        session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .pdf), jobs: [job])
        XCTAssertFalse(session.skip(job, version: "v1"))
    }

    /// A path the manifest gave one note, written for another, moves to the
    /// other (the per-note index follows the manifest).
    func testManifestPathTakenOverByAnotherNote() throws {
        let root = try scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = summary(1, "One"), b = summary(2, "Two")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [a, b], format: .pdf, layout: .flat)
        let options = BulkExportOptions(format: .pdf)
        let pathB = jobs[1].path(.pdf)
        // An earlier manifest says note One wrote Two's file name.
        let entry = #"{"note":"\#(a.id.uuidString.lowercased())","version":"v1","options":"\#(options.fingerprint)","size":3}"#
        try Data(#"{"version":1,"files":{"\#(pathB)":\#(entry)}}"#.utf8)
            .write(to: root.appendingPathComponent(".sempere-export-bulk.json"))
        var session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        XCTAssertFalse(session.skip(jobs[1], version: "v1"))
        try session.export(jobs[1], state: state("Two"), version: "v1", blobs: nil)
        XCTAssertTrue(session.skip(jobs[1], version: "v1"))
        _ = try session.finish(cancelled: false)
        session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        XCTAssertTrue(session.skip(jobs[1], version: "v1"))
        XCTAssertFalse(session.skip(jobs[0], version: "v1"))
    }

    /// Prints how long resume checks take against a large manifest
    /// (`SEMPERE_BENCH_MANIFEST` files, default 20,000; 2,000 notes checked).
    func testSkipTimingsWithALargeManifest() throws {
        let files = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_MANIFEST"] ?? "") ?? 20_000
        let root = try scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let options = BulkExportOptions(format: .png)
        var json = #"{"version":1,"files":{"#
        for i in 0..<files {
            if i > 0 { json += "," }
            let note = id(100_000 + i / 20, prefix: "0e1c6a1e").uuidString.lowercased()
            json += #""Other-\#(i / 20)/p\#(i % 20).png":{"note":"\#(note)","version":"v1","options":"\#(options.fingerprint)","size":3}"#
        }
        json += "}}"
        try Data(json.utf8).write(to: root.appendingPathComponent(".sempere-export-bulk.json"))
        let jobs = BulkExportPlan.jobs(for: .vault, from: (0..<2_000).map { summary($0, "N\($0)") }, format: .png, layout: .flat)
        let session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        let t = Date()
        for job in jobs { XCTAssertFalse(session.skip(job, version: "v1")) }
        print("bench: 2000 skip checks against \(files) manifest files: "
              + String(format: "%.3f s", Date().timeIntervalSince(t)))
    }

    /// Prints time and peak memory of a PNG bulk export of one long note
    /// (`SEMPERE_BENCH_PNG_PAGES`, default 10, of dense ink at 150 dpi).
    func testPNGExportTimings() throws {
        let pages = Int(ProcessInfo.processInfo.environment["SEMPERE_BENCH_PNG_PAGES"] ?? "") ?? 10
        let root = try scratch()
        let dense = RenderBenchmarkTests.denseNote(strokes: 400, points: 40)
        let note = NoteState(meta: dense.meta, pages: (0..<pages).map { Page(order: "a\($0)", strokes: dense.pages[0].strokes) })
        let jobs = BulkExportPlan.jobs(for: .vault, from: [summary(1, "Long")], format: .png, layout: .flat)
        let session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .png, dpi: 150),
                                            jobs: jobs)
        let t = Date()
        let outcome = try session.export(jobs[0], state: note, version: "v1", blobs: nil)
        _ = try session.finish(cancelled: false)
        XCTAssertEqual(outcome.files.count, pages)
        let bytes = outcome.files.reduce(0) { $0 + ((try? Data(contentsOf: root.appendingPathComponent($1)).count) ?? 0) }
        print("bench: PNG bulk export, \(pages) pages: " + String(format: "%.3f s", Date().timeIntervalSince(t))
              + ", \(bytes / 1024) KiB written, peak \(Int(peakRSSMegabytes())) MB")
    }

    /// A note that fails part way through leaves the earlier version's
    /// pages in place, and no temporary files.
    func testPNGFailureKeepsTheEarlierPages() throws {
        let root = try scratch()
        let s = summary(1, "Pages")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [s], format: .png, layout: .flat)
        let options = BulkExportOptions(format: .png, dpi: 36)
        var session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        try session.export(jobs[0], state: state("Pages", pages: 2), version: "v1", blobs: nil)
        _ = try session.finish(cancelled: false)
        let before = try listing(root).map { try Data(contentsOf: root.appendingPathComponent($0)) }
        // Page 2 has a non-finite point: rendering throws after page 1 was drawn.
        var broken = state("Pages", pages: 3)
        broken.pages[1].strokes = [T.stroke([T.pt(10, 10), T.pt(.nan, 20)])]
        session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        let outcome = try session.export(jobs[0], state: broken, version: "v2", blobs: nil)
        _ = try session.finish(cancelled: false)
        guard case .failed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(listing(root), ["Pages-0d1c6a1e/p001.png", "Pages-0d1c6a1e/p002.png"])
        XCTAssertEqual(try listing(root).map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
    }

    func testPNGPagesAndStalePagesRemoved() throws {
        let root = try scratch()
        let s = summary(1, "Pages")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [s], format: .png, layout: .flat)
        let options = BulkExportOptions(format: .png, dpi: 36)
        var session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        try session.export(jobs[0], state: state("Pages", pages: 3), version: "v1", blobs: nil)
        _ = try session.finish(cancelled: false)
        XCTAssertEqual(listing(root), ["Pages-0d1c6a1e/p001.png", "Pages-0d1c6a1e/p002.png", "Pages-0d1c6a1e/p003.png"])
        session = try BulkExportSession(destination: .folder(root), options: options, jobs: jobs)
        XCTAssertTrue(session.skip(jobs[0], version: "v1"))
        XCTAssertFalse(session.skip(jobs[0], version: "v2"))
        try session.export(jobs[0], state: state("Pages", pages: 1), version: "v2", blobs: nil)
        _ = try session.finish(cancelled: false)
        XCTAssertEqual(listing(root), ["Pages-0d1c6a1e/p001.png"])
    }

    // MARK: Failures and cancel

    func testFailuresAreReportedAndTheBatchGoesOn() throws {
        let root = try scratch()
        let notes = [summary(1, "Good"), summary(2, "Bad", prefix: "0d1c6a1f"), summary(3, "Unread", prefix: "0d1c6a20"),
                     summary(4, "Also good", prefix: "0d1c6a21")]
        let jobs = BulkExportPlan.jobs(for: .notes(notes.map(\.id)), from: notes, format: .pdf, layout: .flat)
        var bad = state("Bad")
        bad.meta.pageSize = PageSize(width: .nan, height: 100)   // cannot be rendered
        let session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .pdf), jobs: jobs)
        try session.export(jobs[0], state: state("Good"), version: "1", blobs: nil)
        let failed = try session.export(jobs[1], state: bad, version: "1", blobs: nil)
        if case .failed = failed.status {} else { XCTFail("\(failed.status)") }
        session.fail(jobs[2], CocoaError(.fileReadCorruptFile), text: { _ in "cannot be read" })
        try session.export(jobs[3], state: state("Also good"), version: "1", blobs: nil)
        let result = try session.finish(cancelled: false)
        XCTAssertEqual(result.exported.map(\.job.title), ["Good", "Also good"])
        XCTAssertEqual(result.failures.map(\.job.title), ["Bad", "Unread"])
        XCTAssertEqual(result.failureLines.last, "Unread (0d1c6a20): cannot be read")
        XCTAssertEqual(listing(root), ["Also-good-0d1c6a21.pdf", "Good-0d1c6a1e.pdf"], "nothing left of the failed note")
        XCTAssertFalse(result.cancelled)
    }

    func testCancelStopsBetweenNotesAndKeepsWhatWasWritten() async throws {
        let root = try scratch()
        let notes = (1...5).map { summary($0, "Note \($0)") }
        let jobs = BulkExportPlan.jobs(for: .notes(notes.map(\.id)), from: notes, format: .pdf, layout: .flat)
        let session = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .pdf), jobs: jobs)
        let states = jobs.map { state($0.title) }
        let task = Task.detached { () -> BulkExportResult in
            for (i, job) in jobs.enumerated() {
                if i == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                do { try session.export(job, state: states[i], version: "1", blobs: nil) } catch is CancellationError {
                    return try session.finish(cancelled: true)
                }
            }
            return try session.finish(cancelled: false)
        }
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.exported.count, 2)
        XCTAssertEqual(result.notReached, 3)
        XCTAssertEqual(listing(root).count, 2)
        // The manifest was saved: a re-run skips the two.
        let again = try BulkExportSession(destination: .folder(root), options: BulkExportOptions(format: .pdf), jobs: jobs)
        XCTAssertTrue(again.skip(jobs[0], version: "1"))
        XCTAssertTrue(again.skip(jobs[1], version: "1"))
        XCTAssertFalse(again.skip(jobs[2], version: "1"))
    }

    func testCancelledZipLeavesNothing() throws {
        let dir = try scratch()
        let archive = dir.appendingPathComponent("out.zip"), staging = dir.appendingPathComponent("staging")
        let s = summary(1, "One")
        let jobs = BulkExportPlan.jobs(for: .vault, from: [s], format: .pdf, layout: .flat)
        let session = try BulkExportSession(destination: .zip(archive: archive, staging: staging),
                                            options: BulkExportOptions(format: .pdf), jobs: jobs)
        try session.export(jobs[0], state: state("One"), version: "1", blobs: nil)
        XCTAssertFalse(session.skip(jobs[0], version: "1"), "a zip is never resumed")
        let result = try session.finish(cancelled: true)
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testInvalidResolutionIsRefused() {
        XCTAssertThrowsError(try BulkExportSession(destination: .folder(URL(fileURLWithPath: "/tmp/x")),
                                                   options: BulkExportOptions(format: .png, dpi: 0), jobs: []))
    }

    func testVersionChangesWithRevisions() throws {
        let a = try XCTUnwrap(RevisionName("17596320000000003-a1b2c3d4-1.delta.age"))
        let b = try XCTUnwrap(RevisionName("17596320000000004-a1b2c3d4-2.delta.age"))
        XCTAssertEqual(BulkExportPlan.version(of: [a, b]), BulkExportPlan.version(of: [b, a]))
        XCTAssertNotEqual(BulkExportPlan.version(of: [a]), BulkExportPlan.version(of: [a, b]))
    }

    func testFingerprintCoversEveryOption() {
        let base = BulkExportOptions(format: .png)
        var variants = [base]
        var o = base; o.paper = false; variants.append(o)
        o = base; o.dpi = 300; variants.append(o)
        o = base; o.breaks = .fixed; variants.append(o)
        o = base; o.keepImageMetadata = true; variants.append(o)
        o = base; o.format = .pdf; variants.append(o)
        o = base; o.format = .pdfAttachments; variants.append(o)
        XCTAssertEqual(Set(variants.map(\.fingerprint)).count, variants.count)
        // The layout moves files but does not change them.
        o = base; o.layout = .flat
        XCTAssertEqual(o.fingerprint, base.fingerprint)
    }
}
