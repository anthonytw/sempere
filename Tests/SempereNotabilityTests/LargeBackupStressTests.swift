import CLITestSupport
import Foundation
import Sempere
import SempereImport
import XCTest
@testable import SempereNotability

/// Device check c23 ("Large Notability import"), automated on a synthetic backup (`SyntheticBackup`): every note
/// imports, copies resolve across the parts, progress is reported in order, a cancel keeps what was written and a
/// second run finishes the job. `SEMPERE_STRESS_NOTES=1500` runs it at the size of a real backup.
final class LargeBackupStressTests: NotabilityTestCase {
    static var noteCount: Int {
        ProcessInfo.processInfo.environment["SEMPERE_STRESS_NOTES"].flatMap(Int.init) ?? 160
    }

    /// Progress reports collected from the importing thread.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ImporterProgress] = []
        var all: [ImporterProgress] { lock.lock(); defer { lock.unlock() }; return list }
        func add(_ p: ImporterProgress) { lock.lock(); list.append(p); lock.unlock() }
        var written: Int { all.filter { $0.phase == .writing }.map(\.done).max() ?? 0 }
    }

    func backup(_ config: SyntheticBackup.Config = .init(notes: noteCount)) throws -> SyntheticBackup {
        try SyntheticBackup(writingTo: tmp.appendingPathComponent("backup-\(UUID().uuidString)"), config)
    }

    func run(_ b: SyntheticBackup, into vault: Vault, paths: [URL]? = nil, recorder: Recorder? = nil,
             stop: (@Sendable () -> Bool)? = nil) throws -> NotabilityImporter.ImportReport {
        var options = NotabilityImporter.Options(tagsFromFolders: true, pdfText: nil)
        if let recorder { options.progress = { recorder.add($0) } }
        options.shouldStop = stop
        var clock = HybridClock()
        return try NotabilityImporter.import(paths: paths ?? b.parts, into: vault, device: DeviceID("0a0b0c0d")!,
                                             clock: &clock, options: options)
    }

    func testEveryNoteOfALargeSplitBackupImportsWithProgress() throws {
        let b = try backup()
        let vault = try makeVault()
        let recorder = Recorder()
        let started = Date()
        let report = try run(b, into: vault, recorder: recorder)
        let seconds = Date().timeIntervalSince(started)
        print("STRESS c23: \(b.expected.sources) sources, \(report.imported) imported in \(String(format: "%.1f", seconds)) s")
        XCTAssertEqual(report.notes.count, b.expected.sources)
        XCTAssertEqual(report.imported, b.expected.imported, failures(report))
        XCTAssertEqual(report.skipped, b.expected.skipped, failures(report))
        XCTAssertEqual(report.failed, b.expected.failed, failures(report))
        XCTAssertFalse(report.cancelled)
        // No note fails on a read budget (the owner's question for c23); only the truncated entries fail.
        for n in report.notes {
            if case .failed(let why) = n.status { XCTAssertTrue(n.source.contains("Broken"), "\(n.source): \(why)") }
        }
        XCTAssertEqual(try vault.noteIDs().count, b.expected.imported)

        // Progress: finding, then reading 0…n, then writing 0…n, each phase in order and complete.
        let all = recorder.all
        XCTAssertEqual(all.first?.phase, .finding)
        let reading = all.filter { $0.phase == .reading }.map(\.done)
        let writing = all.filter { $0.phase == .writing }.map(\.done)
        XCTAssertEqual(reading, Array(0...b.expected.sources))
        XCTAssertEqual(writing, Array(0...b.expected.sources))
        XCTAssertTrue(all.allSatisfy { $0.phase == .finding || $0.total == b.expected.sources })
        XCTAssertEqual(all.map(\.fraction), all.map(\.fraction).sorted(), "the bar never goes back")
        XCTAssertTrue(all.compactMap(\.current).allSatisfy { !$0.contains("/") && !$0.contains("!") }, "file names only")

        // Odd titles and the huge note came through.
        let titles = Set(try vault.noteIDs().compactMap { try? vault.reconstruct(noteId: $0).meta.title })
        for t in Set(b.oddTitles) where !t.isEmpty { XCTAssertTrue(titles.contains(t), "missing \(t.debugDescription)") }
        let huge = try XCTUnwrap(report.notes.first { $0.title == "Note 1" })
        XCTAssertEqual(huge.strokes, b.config.hugeStrokes)

        // Again: every note is already in the vault.
        let again = try run(b, into: vault)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skipped, b.expected.sources - b.expected.failed)
        XCTAssertEqual(again.failed, b.expected.failed)
        XCTAssertEqual(try vault.noteIDs().count, b.expected.imported)
    }

    func testCancelWhileWritingKeepsWhatWasWrittenAndARerunFinishes() throws {
        let b = try backup(.init(notes: 60, hugeStrokes: 0))
        let vault = try makeVault()
        let recorder = Recorder()
        let report = try run(b, into: vault, recorder: recorder, stop: { recorder.written >= 20 })
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.notes.count, b.expected.sources, "every source is in the report")
        let cancelled = report.notes.filter { $0.status == .skipped(NotabilityImporter.cancelledReason) }
        // The stop is asked before each note: the note whose progress reached 20 was still written whole.
        XCTAssertEqual(cancelled.count, b.expected.sources - 21)
        let written = try vault.noteIDs().count
        XCTAssertEqual(written, report.imported, "each written note is whole; none half-written")
        XCTAssertGreaterThan(written, 0)
        for id in try vault.noteIDs() { XCTAssertNoThrow(try vault.reconstruct(noteId: id)) }

        let rest = try run(b, into: vault)
        XCTAssertFalse(rest.cancelled)
        XCTAssertEqual(rest.imported + written, b.expected.imported)
        XCTAssertEqual(try vault.noteIDs().count, b.expected.imported)

        // The CLI's view of a cancelled run: one line, and a failure exit.
        let presentation = NotabilityVaultImporter.result(report, noAttachments: false).presentation(ImporterStyle())
        XCTAssertNotNil(presentation.failure)
        XCTAssertTrue(presentation.lines.contains { $0.text.hasPrefix("Canceled: \(b.expected.sources - 21) note(s)") })
        XCTAssertFalse(presentation.lines.contains { $0.text.contains(NotabilityImporter.cancelledReason) },
                       "no line per cancelled note")
    }

    func testCancelWhileReadingWritesNothing() throws {
        let b = try backup(.init(notes: 30, hugeStrokes: 0))
        let vault = try makeVault()
        let recorder = Recorder()
        let report = try run(b, into: vault, recorder: recorder,
                             stop: { (recorder.all.last { $0.phase == .reading }?.done ?? 0) >= 5 })
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.imported, 0)
        XCTAssertTrue(try vault.noteIDs().isEmpty)
        XCTAssertFalse(recorder.all.contains { $0.phase == .writing })
    }

    func testAnUnzippedFolderCopyImportsLikeTheZips() throws {
        let b = try backup(.init(notes: 40, hugeStrokes: 0, zipVariants: false, folderCopy: true))
        let folders = (1...b.config.parts).map { b.parts[0].deletingLastPathComponent().appendingPathComponent("part \($0)") }
        let report = try run(b, into: try makeVault(), paths: folders)
        XCTAssertEqual(report.imported, b.expected.imported, failures(report))
        XCTAssertEqual(report.skipped, b.expected.skipped)
        XCTAssertEqual(report.failed, b.expected.failed)
    }

    func testTheSameBackupGivenTwiceOrInAnotherOrderImportsTheSame() throws {
        let b = try backup(.init(notes: 40, hugeStrokes: 0))
        let twice = try run(b, into: try makeVault(), paths: b.parts + b.parts.reversed())
        XCTAssertEqual(twice.imported, b.expected.imported, failures(twice))
        XCTAssertEqual(twice.failed, 2 * b.expected.failed)
    }

    /// A part that is not a zip at all (a broken download): the import refuses before writing anything, naming the
    /// part, rather than importing the other parts with copies resolved against an incomplete backup.
    func testACorruptPartStopsTheImportBeforeAnythingIsWritten() throws {
        let b = try backup(.init(notes: 30, hugeStrokes: 0))
        let broken = b.parts[1]
        let data = try Data(contentsOf: broken)
        try data.prefix(data.count / 3).write(to: broken)
        let vault = try makeVault()
        XCTAssertThrowsError(try run(b, into: vault)) { error in
            XCTAssertTrue("\(error)".contains("zip"), "\(error)")
        }
        XCTAssertTrue(try vault.noteIDs().isEmpty)
    }

    private func failures(_ r: NotabilityImporter.ImportReport) -> String {
        r.notes.compactMap { n in
            if case .failed(let why) = n.status { return "\(n.source): \(why)" }
            return nil
        }.prefix(10).joined(separator: "\n")
    }
}

/// The same backup through the binary: progress on stderr (`SEMPERE_PROGRESS=always`), Ctrl-C stops between
/// notes, and `--json` reports what happened.
final class CLILargeBackupTests: CLITestCase {
    func vaultArgs(_ vault: String) -> [String] { ["--vault", vault, "--identity", Self.fixtureKey] }

    func testProgressGoesToStderrAndJSONToStdout() throws {
        let b = try SyntheticBackup(writingTo: tmp.appendingPathComponent("backup"), .init(notes: 40, hugeStrokes: 0))
        let vault = try copyFixtureVault()
        let r = try cli(["import", "notability"] + b.parts.map(\.path) + ["--pdf-text", "none"] + vaultArgs(vault),
                        env: ["SEMPERE_PROGRESS": "always"])
        XCTAssertEqual(r.status, 1, "the truncated entries fail: \(r.err)")
        XCTAssertTrue(r.err.contains("Finding notes"), r.err)   // the reading lines may all fall within one 0.1 s redraw
        XCTAssertTrue(r.err.contains("Importing \(b.expected.sources)/\(b.expected.sources) notes"), r.err)
        XCTAssertTrue(r.out.contains("\(b.expected.imported) imported, \(b.expected.skipped) skipped, \(b.expected.failed) failed"), r.out)

        let json = try cli(["import", "notability"] + b.parts.map(\.path) + ["--pdf-text", "none", "--json"] + vaultArgs(vault),
                           env: ["SEMPERE_PROGRESS": "always"])
        XCTAssertFalse(json.err.contains("Finding notes") || json.err.contains("Importing "), "no progress line with --json")
        let summary = try XCTUnwrap((json.json as? [String: Any])?["summary"] as? [String: Any])
        XCTAssertEqual(summary["imported"] as? Int, 0)
        XCTAssertEqual(summary["cancelled"] as? Bool, false)
        XCTAssertEqual(summary["skipped"] as? Int, b.expected.sources - b.expected.failed)
    }

    func testInterruptStopsBetweenNotesAndTheNextRunFinishes() throws {
        #if os(macOS) || os(Linux)
        let b = try SyntheticBackup(writingTo: tmp.appendingPathComponent("backup"), .init(notes: 400, hugeStrokes: 0))
        let vault = try copyFixtureVault()
        let before = try FileManager.default.contentsOfDirectory(atPath: vault + "/notes").count
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = ["import", "notability"] + b.parts.map(\.path) + ["--pdf-text", "none", "--json"] + vaultArgs(vault)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SEMPERE_") }
        env["XDG_STATE_HOME"] = path("state")
        env["SEMPERE_PROGRESS"] = "never"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Wait until the first notes are written, then Ctrl-C.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, p.isRunning,
              (try? FileManager.default.contentsOfDirectory(atPath: vault + "/notes").count) ?? 0 < before + 3 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        p.interrupt()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let summary = try XCTUnwrap((try JSONSerialization.jsonObject(with: outData) as? [String: Any])?["summary"] as? [String: Any],
                                    String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(p.terminationStatus, 1)
        XCTAssertEqual(summary["cancelled"] as? Bool, true)
        let first = try XCTUnwrap(summary["imported"] as? Int)
        XCTAssertLessThan(first, b.expected.imported)

        let rest = try cli(["import", "notability"] + b.parts.map(\.path) + ["--pdf-text", "none", "--json"] + vaultArgs(vault))
        let s2 = try XCTUnwrap((rest.json as? [String: Any])?["summary"] as? [String: Any], rest.err)
        XCTAssertEqual(first + (s2["imported"] as? Int ?? -1), b.expected.imported)
        let verify = try cli(["vault", "verify", "--json"] + vaultArgs(vault))
        XCTAssertEqual(verify.status, 0, verify.err + verify.out)
        #endif
    }
}
