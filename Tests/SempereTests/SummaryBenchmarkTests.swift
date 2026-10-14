import Age
import Foundation
import XCTest
@testable import Sempere

/// Prints how long listing a vault takes, stage by stage. Quick mode (every
/// `swift test`) uses a small vault; `SEMPERE_BENCH_NOTES=600` makes one the
/// size of a real 640-note vault (about 120 MB), best run with
/// `swift test -c release -Xswiftc -enable-testing --filter SummaryBenchmark`.
/// `SEMPERE_BENCH_KEEP=<dir>` keeps the vault and its key there (for timing
/// the CLI on it).
final class SummaryBenchmarkTests: VaultTestCase {
    func testListingTimings() throws {
        let env = ProcessInfo.processInfo.environment
        let notes = Int(env["SEMPERE_BENCH_NOTES"] ?? "") ?? 12
        let strokes = Int(env["SEMPERE_BENCH_STROKES"] ?? "") ?? (notes > 100 ? 350 : 40)
        let points = Int(env["SEMPERE_BENCH_POINTS"] ?? "") ?? 40
        let root = env["SEMPERE_BENCH_KEEP"].map { URL(fileURLWithPath: $0) } ?? tmp!
        let url = root.appendingPathComponent("Bench.sempere")
        let keyURL = root.appendingPathComponent("bench.key")
        let identity: NativeIdentity
        if FileManager.default.fileExists(atPath: url.path) {
            identity = try IdentityFile.parse(String(contentsOf: keyURL, encoding: .utf8))
        } else {
            identity = pqIdentity()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try identity.string.write(to: keyURL, atomically: true, encoding: .utf8)
            let v = try Vault.create(at: url, recipients: [identity.recipient], labels: ["bench"], identities: [identity])
            let t = Date()
            try SyntheticVault.populate(v, notes: notes, strokes: strokes, points: points)
            print("bench: generated \(notes) notes × \(strokes) strokes × \(points) points in \(secs(t))")
        }
        let vault = try Vault.open(at: url, identities: [identity])

        // Stage by stage, one thread.
        let secret = try vault.requireReadable()
        var files: [(UUID, RevisionName, Data)] = []
        var t = Date()
        for id in try vault.noteIDs() {
            for n in try vault.revisionNames(of: id) {
                files.append((id, n, try FileIO.read(vault.noteURL(id).appendingPathComponent(n.filename),
                                                     maxBytes: BoundedRead.maxRevisionBytes)))
            }
        }
        let bytes = files.reduce(0) { $0 + $1.2.count }
        print("bench: \(files.count) files, \(bytes >> 20) MiB; read \(secs(t))")
        t = Date()
        let plains = try files.map { try AgeFile.decrypt($0.2, with: [identity]) }
        print("bench: decrypt \(secs(t))")
        t = Date()
        var gz: [Data] = []
        for (f, p) in zip(files, plains) {
            gz.append(try Vault.unframe(p, note: f.0.uuidString.lowercased(), filename: f.1.filename,
                                        secret: secret, previous: nil).gzip)
        }
        print("bench: unframe (HMAC) \(secs(t))")
        t = Date()
        let jsons = try gz.map { try Gzip.decompress($0) }
        print("bench: gunzip \(secs(t)) → \(jsons.reduce(0) { $0 + $1.count } >> 20) MiB JSON")
        t = Date()
        let revs = try jsons.map { try InkJSON.decoder().decode(Revision.self, from: $0) }
        print("bench: JSON decode (full, Codable) \(secs(t))")
        t = Date()
        let fastRevs = try jsons.map { try FastRevisionDecoder.decode($0) }
        print("bench: JSON decode (full, fast points) \(secs(t))")
        XCTAssertEqual(fastRevs, revs)
        t = Date()
        var byNote: [UUID: [Revision]] = [:]
        for r in revs { byNote[r.noteId, default: []].append(r) }
        for (_, rs) in byNote { _ = try NoteReducer.reconstruct(rs) }
        print("bench: reconstruct \(secs(t))")

        t = Date()
        let stripped = jsons.map(StrokePointsFilter.strip)
        print("bench: strip points \(secs(t)) → \(stripped.reduce(0) { $0 + $1.count } >> 10) KiB JSON")
        t = Date()
        let lite = try stripped.map { try InkJSON.decoder().decode(Revision.self, from: $0) }
        print("bench: JSON decode (no points) \(secs(t))")
        t = Date()
        var liteByNote: [UUID: [Revision]] = [:]
        for r in lite { liteByNote[r.noteId, default: []].append(r) }
        for (_, rs) in liteByNote { _ = try NoteReducer.reconstruct(rs) }
        print("bench: reconstruct (no points) \(secs(t))")

        // The old path: full decode, one thread.
        t = Date()
        let ids = try vault.noteIDs()
        let old = ids.map { vault.summary(of: $0, loaded: try! vault.loadNote($0)) }
        print("bench: BEFORE full decode, 1 thread: \(secs(t))")
        for width in [1, Parallel.defaultWidth] {
            t = Date()
            let new = try vault.summaries(of: ids, maxConcurrency: width)
            print("bench: summaries, no points, \(width) thread(s): \(secs(t))")
            XCTAssertEqual(Set(new), Set(old))
        }
        let cacheDir = tmp.appendingPathComponent("cache")
        t = Date()
        _ = try vault.summaries(of: nil, cache: try SummaryCache(directory: cacheDir, vault: vault))
        print("bench: first listing with an empty cache: \(secs(t))")
        t = Date()
        let cache = try SummaryCache(directory: cacheDir, vault: vault)
        print("bench: cache load (\(cache.storedSummaries.count) entries): \(secs(t))")
        t = Date()
        let again = try vault.summaries(of: nil, cache: cache)
        print("bench: reopen listing from cache: \(secs(t))")
        XCTAssertEqual(Set(again), Set(old))
    }
}

func secs(_ since: Date) -> String { String(format: "%.3f s", Date().timeIntervalSince(since)) }
