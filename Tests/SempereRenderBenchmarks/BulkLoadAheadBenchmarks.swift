import TempDirSupport
import XCTest
import Foundation
import Age
import Sempere
@testable import SempereRender

/// Wall time of a real vault's bulk PDF export, one note at a time against reading ahead while
/// rendering (the app's pipeline). Skipped unless `SEMPERE_BENCH_VAULT` and `SEMPERE_BENCH_KEY`
/// name a vault and its identity file; prints both times.
final class BulkLoadAheadBenchmarks: XCTestCase {
    func testSerialAgainstReadAhead() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let vaultPath = env["SEMPERE_BENCH_VAULT"], let keyPath = env["SEMPERE_BENCH_KEY"] else {
            throw XCTSkip("set SEMPERE_BENCH_VAULT and SEMPERE_BENCH_KEY")
        }
        let identity = try IdentityFile.parse(String(contentsOfFile: keyPath, encoding: .utf8))
        let vault = try Vault.open(at: URL(fileURLWithPath: vaultPath), identities: [identity])
        let jobs = BulkExportPlan.jobs(for: .vault, from: try vault.summaries(), format: .pdf, layout: .flat)
        let options = BulkExportOptions(format: .pdf, layout: .flat)
        @Sendable func load(_ id: UUID) throws -> NoteState { try vault.reconstruct(try vault.loadNote(id)) }

        func scratch(_ name: String) throws -> URL {
            let dir = TestTemp.root.appendingPathComponent("bulk-bench-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let a = try scratch("serial"), b = try scratch("ahead")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let t0 = Date()
        let serial = try BulkExportSession(destination: .folder(a), options: options, jobs: jobs)
        for job in jobs {
            let state = try load(job.noteId)
            try serial.export(job, state: state, version: "v", blobs: vault.blobSource(note: job.noteId))
        }
        _ = try serial.finish(cancelled: false)
        let serialTime = Date().timeIntervalSince(t0)

        let t1 = Date()
        let session = try BulkExportSession(destination: .folder(b), options: options, jobs: jobs)
        let ahead = LoadAhead<NoteState>(count: jobs.count, depth: 2) { i in
            let state = try? await Task.detached { try load(jobs[i].noteId) }.value
            return state.map { .ready($0, bytes: 0) } ?? .declined
        }
        ahead.schedule(after: -1)
        for (i, job) in jobs.enumerated() {
            var state: NoteState?
            if case .ready(let s, _)? = await ahead.take(i) { state = s }
            let note = try state ?? load(job.noteId)
            ahead.schedule(after: i)
            try await Task.detached { try session.export(job, state: note, version: "v", blobs: vault.blobSource(note: job.noteId)) }.value
        }
        _ = try session.finish(cancelled: false)
        await ahead.cancelAndWait()
        let aheadTime = Date().timeIntervalSince(t1)
        print("BULK-BENCH notes=\(jobs.count) serial=\(String(format: "%.2f", serialTime))s readAhead=\(String(format: "%.2f", aheadTime))s")
    }
}
