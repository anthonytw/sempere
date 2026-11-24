import Foundation
import FuzzSupport
import XCTest
@testable import Sempere
@testable import SempereSync

/// Seeded fuzzing of what the CloudKit transport believes (docs/design/1.4-cloudkit.md §3.1; CLAUDE.md "Fuzzing"): the
/// mirror file it reloads, the records of the change feed and what a run then does with them, and record names.
/// Everything must fail with a typed error or be skipped and counted, never trap, hang or allocate without bound.
final class CloudKitFuzzTests: XCTestCase {
    private func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    private static func sampleMirror() -> Data {
        var m = CloudMirror()
        m.zoneExists = true
        m.zoneSchema = 1
        m.token = CloudChangeToken(Data([1, 2, 3, 4]))
        m.declared.insert("notes/n9")
        for i in 0..<6 {
            let path = ["notes", "n1", "rev\(i).delta.age"]
            m.upsert(.init(name: CloudRecordNaming.fileName(path), path: path, tag: "t\(i)", modified: 1_900_000_000_000 + Int64(i),
                           size: Int64(100 * i), sha256: Data(repeating: UInt8(i + 1), count: 32), tomb: i == 5, parts: i == 3 ? 4 : 0, schema: 1))
        }
        let fileName = CloudRecordNaming.fileName(["notes", "n1", "rev3.delta.age"])
        let part = CloudRecordNaming.partName(fileName: fileName, fileSha: Data(repeating: 4, count: 32), index: 2)
        let p = CloudRecordNaming.parsePartName(part)!
        m.upsert(.init(name: part, fileHash: p.fileHash, gen: p.gen, index: p.index, tag: "p1", modified: 5))
        return m.encoded()
    }

    func testFuzzMirrorFile() {
        let sample = Self.sampleMirror()
        assertClean(Fuzz.run("cloud-mirror", seeds: [sample, Data("sempere-cloud-mirror/1\n".utf8), Data()], quick: 2500, long: 250_000,
                             text: true, maxSize: 1 << 16) { input in
            do {
                var m = try CloudMirror.decode(input, maxRecords: 1000)
                // Whatever was accepted can be used and saved again, and comes back the same.
                _ = m.childNames([]); _ = m.childNames(["notes"]); _ = m.collectionExists(["notes", "n1"])
                _ = m.folderTag([]); _ = m.tombstones; _ = m.liveFiles(below: ["notes"])
                let again = try CloudMirror.decode(m.encoded(), maxRecords: 1000)
                if again.files != m.files || again.parts != m.parts || again.token != m.token || again.declared != m.declared {
                    return "a decoded mirror does not survive a save"
                }
            } catch is CloudMirrorError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        })
    }

    func testFuzzRecordNames() {
        let hash = String(repeating: "ab", count: 32)
        let seeds = ["p-\(hash)-0123456789abcdef-3", "f-\(hash)", "zone-info", "p-x", "p-\(hash)-0123456789abcdef-007"].map { Data($0.utf8) }
        assertClean(Fuzz.run("cloud-names", seeds: seeds, quick: 3000, long: 300_000, text: true, maxSize: 256) { input in
            let s = String(decoding: input, as: UTF8.self)
            if let p = CloudRecordNaming.parsePartName(s) {
                if p.index < 0 || "p-\(p.fileHash)-\(p.gen)-\(p.index)" != s { return "a part name that is not canonical was taken: \(s)" }
            }
            if let h = CloudRecordNaming.fileHash(ofName: s), "f-\(h)" != s { return "a file name that is not canonical was taken" }
            _ = CloudRecordNaming.components(ofStoredPath: s)
            _ = CloudRecordNaming.isValidTag(s)
            return nil
        })
    }

    /// A record as one line of tab-separated text: kind, name, tag, schema, path, size, sha (hex), tomb, parts, inline bytes.
    private static func record(_ line: String) -> CloudRecord {
        let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        func col(_ i: Int) -> String? { i < c.count ? c[i] : nil }
        let path = col(4)
        let name = col(1).flatMap { $0.isEmpty ? nil : $0 } ?? CloudRecordNaming.fileName((path ?? "x").split(separator: "/").map(String.init))
        return CloudRecord(name: name, kind: col(0) == "p" ? .part : .file, changeTag: col(2) ?? "t",
                           fields: CloudFields(schema: col(3).flatMap(Int64.init), path: path, sha256: col(6).flatMap { Hex.decode($0) },
                                               size: col(5).flatMap(Int64.init), bytes: col(9).map { Data($0.utf8) },
                                               parts: col(8).flatMap(Int64.init), tomb: col(7).flatMap(Int64.init)))
    }

    func testFuzzFeedRecordsAndTheRunsThatMeetThem() {
        let sha = Hex.encode(Data(repeating: 7, count: 32))
        let seeds = [
            "f\t\tt1\t1\tnotes/n1/a\t3\t\(sha)\t\t\tabc",
            "f\t\tt2\t1\tnotes/n1/big\t5000\t\(sha)\t\t13\t",
            "f\t\tt3\t1\tnotes/n1/gone\t\t\t1\t\t",
            "f\t\tt4\t2\tnotes/n1/future\t3\t\(sha)\t\t\tabc",
            "f\tf-nonsense\tt5\t1\tnotes/../x\t-1\t\t\t99999999999\t",
            "p\tp-bad\tt6\t1\t\t\t\t\t\t"
        ].map { Data($0.utf8) }
        assertClean(Fuzz.run("cloud-feed", seeds: seeds, quick: 700, long: 60_000, text: true, maxSize: 600) { input in
            let lines = String(decoding: input, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).prefix(8)
            let db = MemoryCloudDatabase()
            let records = lines.map { Self.record(String($0)) }
            for r in records {
                switch CloudMirror.ingest(r) {
                case .file(let f): if CloudRecordNaming.fileName(f.path) != f.name { return "ingested a file whose name is not its path's" }
                default: break
                }
                db.putRaw(zone: "z", r, asset: r.fields.bytes.flatMap { $0.count > 3 ? $0 : nil })
            }
            let remote = CloudRecordRemote(store: db, zone: "z")
            do {
                try remote.prepareRun()
                var files: [[String]] = []
                func walk(_ p: [String]) throws {
                    for e in try remote.list(p) ?? [] {
                        if e.isCollection { try walk(p + [e.name]) } else { files.append(p + [e.name]) }
                    }
                }
                try walk([])
                for p in files.prefix(8) {
                    do { _ = try remote.read(p, maxBytes: 1 << 16) } catch is CloudRecordError {}
                    do { _ = try remote.write(p, .data(Data("w".utf8)), condition: .create) } catch is CloudRecordError {}
                    do { _ = try remote.delete(p, ifETag: nil) } catch is CloudRecordError {}
                }
            } catch is CloudRecordError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        })
    }
}
