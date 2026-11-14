import Age
import Foundation
import FuzzSupport
import XCTest
import VaultTestSupport
@testable import Sempere

/// Seeded mutation fuzzing of the insights readers (format.md §9, §16): file names, the JSON decoder of every kind,
/// Float16 vectors, and whole files encrypted for real and opened through the vault. Every input may fail with a typed
/// error (`InsightsFileError`); none may trap, hang or allocate without bound.
final class InsightsFuzzTests: VaultTestCase {
    static let device = DeviceID("a1b2c3d4")!
    static let note = UUID(uuidString: "6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10")!

    static func seeds() -> [Data] {
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let gen = InsightsNoteFile.Gen(hash: String(repeating: "a", count: 32), identity: .init(model: "m", os: "27.2", prompt: 1),
                                       summary: "A summary.", keywords: [.init(t: "damping", w: 1)], concepts: ["vibration"], dropped: 1)
        let contents: [InsightsFileContent] = [
            .note(InsightsNoteFile(noteId: note, device: device, written: 1, lang: "en", gen: gen,
                                   emb: .init(hash: String(repeating: "b", count: 32), key: key, vector: [0.1, 0.2, 0.3]),
                                   titleOp: .init(stamp: "00017900000000000-a1b2c3d4", title: "2026-10-07 14.32 Spring lab"))),
            .map(InsightsMapFile(device: device, written: 2, key: key, dim: 2, canaries: InsightsCanaries(set: 1, vectors: [[1, 0]]),
                                 mean: [0, 0], clusters: [.init(id: 1, parent: nil, level: 0, label: ["a"], centroid: [1, 0], members: [note])],
                                 layout: [note: (0.1, 0.2)], built: .init(notes: 1, hashes: "x"))),
            .device(InsightsDeviceRecord(device: device, written: 3, os: "macOS 27.2", platform: "mac",
                                         model: .init(available: true, reason: nil, identity: .init(model: "m", os: "27.2", prompt: 1)),
                                         supported: ["en": [1]], canaries: [.init(key: key, vectors: [[1, 0]], set: 1)],
                                         compatibility: "compatible", against: 2)),
            .topics(InsightsTopicsFile(device: device, written: 4, topics: [
                .init(scope: .init(tag: "physics"), members: 3, membersHash: "h", gen: .init(identity: .init(model: "m", os: "27.2", prompt: 1), at: 1, summary: "S.")),
            ])),
        ]
        return contents.compactMap { try? InsightsCodec.encode($0) }
    }

    static let names: [InsightsFileName] = [InsightsFileName(note: note, device: device), InsightsFileName(.map, device: device),
                                            InsightsFileName(.device, device: device), InsightsFileName(.topics, device: device)]

    func testFuzzInsightsJSON() {
        let report = Fuzz.run("insights-json", seeds: Self.seeds(), quick: 3000, maxSize: 64 << 10) { input in
            for name in Self.names {
                do { _ = try InsightsCodec.decode(input, name: name) } catch is InsightsFileError {} catch {
                    return "untyped error \(type(of: error)): \(error)"
                }
            }
            let text = String(decoding: input.prefix(128), as: UTF8.self)
            if let n = InsightsFileName(text), n.fileName != text { return "file name \(text) does not round-trip" }
            _ = Float16Codec.decode(text, count: Int(input.first ?? 0))
            _ = VoiceNoteTitleFormat.check(text)
            _ = VoiceNoteTitleFormat.render(text, date: "2026-01-01", time: "10.00", slug: text)
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }

    /// Mutated plaintexts sealed for real, opened through the vault and its store.
    func testFuzzSealedInsightsFiles() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing needs Apple OS 26 (always on Linux)")
        let id = pqIdentity()
        let created = try TestVaults.create(at: vaultURL(), identities: [id], names: ["mac"])
        let vault = try TestVaults.open(at: created.url, identity: id)
        let secret = try vault.requireSecret()
        let report = Fuzz.run("insights-sealed", seeds: Self.seeds(), quick: 200, maxSize: 64 << 10) { input in
            let name = Self.names[Int(input.last ?? 0) % Self.names.count]
            let body = (try? BodyFraming.frame(json: input, noteId: "insights", filename: name.fileName, secret: secret))
                ?? BodyFraming.frame(gzip: input, noteId: "insights", filename: name.fileName, secret: secret)
            guard let sealed = try? vault.encrypt(body) else { return nil }
            do { _ = try vault.openInsights(sealed, name: name) } catch is InsightsFileError {} catch {
                return "untyped error \(type(of: error)): \(error)"
            }
            _ = vault.openInsightsUnderEarlierKey(sealed, name: name)
            _ = vault.insightsUnderEpoch(below: 5, sealed, name: name)
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}

/// Regressions for hostile insights files (format.md §9): each found problem stays here.
final class UntrustedInsightsTests: VaultTestCase {
    let noteFile = InsightsFileName(note: InsightsFuzzTests.note, device: InsightsFuzzTests.device)

    func testClaimsBeyondTheBytesAreRefused() {
        // A vector claiming more values than its base64 holds, or a dimension beyond the bound.
        let json = #"{"format":"sempere-insights/1","noteId":"6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10","device":"a1b2c3d4","written":1,"#
            + #""hashBasis":"text/1","emb":{"hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","key":{"model":"m","lang":"en","rev":1,"input":1},"#
            + #""dim":100000000,"enc":"f16le-base64","v":"AAAA"}}"#
        XCTAssertThrowsError(try InsightsCodec.decode(Data(json.utf8), name: noteFile))
    }

    func testOutOfRangeNumbersAndHugeStrings() {
        let big = String(repeating: "x", count: 70_000)
        for json in [
            #"{"format":"sempere-insights/1","device":"a1b2c3d4","written":1e300}"#,
            #"{"format":"sempere-insights/1","device":"a1b2c3d4","written":-5}"#,
            #"{"format":"sempere-insights/1","noteId":"6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10","device":"a1b2c3d4","written":1,"hashBasis":"\#(big)"}"#,
            #"{"format":"sempere-insights/1","noteId":"6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10","device":"a1b2c3d4","written":1,"hashBasis":"text/1","gen":{"hash":"zz","model":"m","os":"1","prompt":1,"keywords":[],"concepts":[],"dropped":0}}"#,
            String(repeating: "[", count: 10_000),
        ] {
            XCTAssertThrowsError(try InsightsCodec.decode(Data(json.utf8), name: noteFile)) { e in
                XCTAssertTrue(e is InsightsFileError, "\(e)")
            }
        }
    }

    func testAMapWithNonFinitePositionsIsRefused() {
        let map = InsightsFileName(.map, device: InsightsFuzzTests.device)
        let json = #"{"format":"sempere-insights-map/1","device":"a1b2c3d4","written":1,"key":{"model":"m","lang":"en","rev":1,"input":1},"#
            + #""dim":1,"clusters":[],"layout":{"6f1c2b9e-0a43-4f6e-9a51-2c8d7e3b4a10":[1e400,0]}}"#
        XCTAssertThrowsError(try InsightsCodec.decode(Data(json.utf8), name: map))
    }
}
