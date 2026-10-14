import Age
import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// `revision` with every stroke's points dropped: what `.withoutStrokePoints` must decode to.
func withoutPoints(_ revision: Revision) -> Revision {
    func strip(_ s: Stroke) -> Stroke { var s = s; s.points = []; return s }
    func strip(_ p: Page) -> Page { var p = p; p.strokes = p.strokes.map(strip); return p }
    var r = revision
    switch r.body {
    case .delta(let ops):
        r.body = .delta(ops: ops.map { op in
            switch op {
            case .addStroke(let page, let s): return .addStroke(page: page, stroke: strip(s))
            case .addPage(let p): return .addPage(strip(p))
            default: return op
            }
        })
    case .snapshot(let included, var state):
        state.pages = state.pages.map(strip)
        r.body = .snapshot(included: included, state: state)
    }
    return r
}

/// Every stroke of a revision, in file order.
func allStrokes(_ revision: Revision) -> [Stroke] {
    switch revision.body {
    case .delta(let ops):
        return ops.flatMap { op -> [Stroke] in
            switch op {
            case .addStroke(_, let s): return [s]
            case .addPage(let p): return p.strokes
            default: return []
            }
        }
    case .snapshot(_, let state): return state.pages.flatMap(\.strokes)
    }
}

/// Whether `lite` is `full` with some strokes' points dropped (the filter
/// keeps the ones it is not sure of).
func isFiltered(_ lite: Revision, from full: Revision) -> Bool {
    guard withoutPoints(lite) == withoutPoints(full) else { return false }
    return zip(allStrokes(lite), allStrokes(full)).allSatisfy { $0.points.isEmpty || $0.points == $1.points }
}

final class StrokePointsFilterTests: XCTestCase {
    func strip(_ s: String) -> String { String(decoding: StrokePointsFilter.strip(Data(s.utf8)), as: UTF8.self) }

    func testReplacesWellFormedPointArrays() {
        let p = "[1,2,3,4,5,6,7,8,9]"
        XCTAssertEqual(strip(#"{"points":[\#(p),\#(p)],"id":1}"#), #"{"points":[],"id":1}"#)
        XCTAssertEqual(strip(#"{"points" : [ [ -0.5 , 2.25,3,4,5,6,7,8 ,9 ] ] }"#), #"{"points" : [] }"#)
        XCTAssertEqual(strip(#"{"points":[]}"#), #"{"points":[]}"#)
        XCTAssertEqual(strip("{\"points\":\n[\(p)]}"), "{\"points\":\n[]}")
        // Every occurrence, at any depth.
        XCTAssertEqual(strip(#"[{"a":{"points":[\#(p)]}},{"points":[\#(p)]}]"#), #"[{"a":{"points":[]}},{"points":[]}]"#)
    }

    func testLeavesAnythingUncertainToTheDecoder() {
        let cases = [
            #"{"points":[[1,2,3,4,5,6,7,8]]}"#,           // eight numbers
            #"{"points":[[1,2,3,4,5,6,7,8,9,10]]}"#,      // ten
            #"{"points":[[1e2,2,3,4,5,6,7,8,9]]}"#,       // exponent
            #"{"points":[[01,2,3,4,5,6,7,8,9]]}"#,        // leading zero (invalid JSON)
            #"{"points":[[1.,2,3,4,5,6,7,8,9]]}"#,        // bare dot
            #"{"points":[[-,2,3,4,5,6,7,8,9]]}"#,
            #"{"points":[["1",2,3,4,5,6,7,8,9]]}"#,       // a string
            #"{"points":[[null,2,3,4,5,6,7,8,9]]}"#,
            #"{"points":[[1,2,3,4,5,6,7,8,9],]}"#,        // trailing comma
            #"{"points":[[1,2,3,4,5,6,7,8,9]"#,           // truncated
            #"{"points":null}"#,
            #"{"points":5}"#,
            #"{"points":"[[1,2,3,4,5,6,7,8,9]]"}"#,
            #"{"x":"points","y":[[1,2,3,4,5,6,7,8,9]]}"#,  // "points" as a value
            #"{"x":"a\"points","y":1}"#,
            "{\"p" + "\\" + "u006fints\":[[1,2,3,4,5,6,7,8,9]]}",   // escaped key: decoded in full
            #"{"points":[[1,2,3,4,5,6,7,8,\#(String(repeating: "1", count: 301))]]}"#,
        ]
        for c in cases { XCTAssertEqual(strip(c), c, c) }
        XCTAssertEqual(strip(#"{"x":"points\\","points":[[1,2,3,4,5,6,7,8,9]]}"#), #"{"x":"points\\","points":[]}"#)
    }

    func testUnchangedInputIsReturnedAsIs() {
        let data = Data(#"{"a":[1,2]}"#.utf8)
        XCTAssertEqual(StrokePointsFilter.strip(data), data)
        XCTAssertEqual(StrokePointsFilter.strip(Data()), Data())
    }

    /// Every revision of the fuzz seed log, and random histories: the filtered
    /// JSON decodes to the revision without points.
    func testDecodesToTheRevisionWithoutPoints() throws {
        var rng = SeededRNG(7)
        var revs = try SempereFuzzTests.seedLog()
        for _ in 0..<40 { revs += try SyntheticVault.randomHistory(note: UUID.random(&rng), rng: &rng) }
        for r in revs {
            let json = try InkJSON.encoder().encode(r)
            let lite = try InkJSON.decoder().decode(Revision.self, from: StrokePointsFilter.strip(json))
            XCTAssertEqual(lite, withoutPoints(r))
        }
    }

    /// Mutated revision JSON: the filtered bytes decode exactly when the
    /// original does, and then to the original without points.
    /// Stripping removes nesting levels: a document near the decoder's limit
    /// must not decode only once stripped (the listing would call a note
    /// healthy that cannot be opened).
    func testDeeplyNestedInputIsLeftAsItIs() throws {
        func doc(_ k: Int) -> Data {
            Data((String(repeating: "[", count: k) + #"{"points":[[0,0,0,0,0,0,0,0,0]]}"# + String(repeating: "]", count: k)).utf8)
        }
        for k in 495...515 {
            let json = doc(k), stripped = StrokePointsFilter.strip(json)
            let full = (try? InkJSON.decoder().decode(JSONAny.self, from: json)) != nil
            let lite = (try? InkJSON.decoder().decode(JSONAny.self, from: stripped)) != nil
            XCTAssertEqual(full, lite, "depth \(k)")
        }
        XCTAssertNotEqual(StrokePointsFilter.strip(doc(400)), doc(400), "well below the limit it still strips")
        XCTAssertEqual(StrokePointsFilter.strip(doc(StrokePointsFilter.maxDepth)), doc(StrokePointsFilter.maxDepth))
        let shallow = Data(#"[{"points":[[0,0,0,0,0,0,0,0,0]]}]"#.utf8)
        XCTAssertEqual(String(decoding: StrokePointsFilter.strip(shallow), as: UTF8.self), #"[{"points":[]}]"#)
    }

    /// A UTF-16 body (the decoder accepts it) is not scanned as bytes: its
    /// bytes are not its characters, and a string could be cut.
    func testNonUTF8BodiesAreLeftAsTheyAre() throws {
        let text = #"{"title":"x","points":[[0,0,0,0,0,0,0,0,0]]}"#
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16, .utf32] {
            let data = try XCTUnwrap(text.data(using: encoding))
            XCTAssertEqual(StrokePointsFilter.strip(data), data, "\(encoding)")
        }
        XCTAssertNotEqual(StrokePointsFilter.strip(Data(text.utf8)), Data(text.utf8))
    }

    func testFuzzFilterAgreesWithTheDecoder() throws {
        let seeds = try SempereFuzzTests.seedLog().map(SempereFuzzTests.json)
        let report = Fuzz.run("strip-points", seeds: seeds, quick: 1200, text: true) { input in
            let full = Result { try InkJSON.decoder().decode(Revision.self, from: input) }
            let lite = Result { try InkJSON.decoder().decode(Revision.self, from: StrokePointsFilter.strip(input)) }
            switch (full, lite) {
            case (.success(let f), .success(let l)):
                return isFiltered(l, from: f) ? nil : "filtered revision differs"
            case (.failure, .failure): return nil
            case (.success, .failure(let e)): return "only the filtered input fails: \(e)"
            case (.failure(let e), .success): return "only the original fails: \(e)"
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}

final class SummaryTests: VaultTestCase {
    /// The summary from full reconstruction, the reference.
    func fullSummary(_ vault: Vault, _ id: UUID) throws -> NoteSummary {
        vault.summary(of: id, loaded: try vault.loadNote(id, detail: .full))
    }

    func testFixtureSummariesEqualFullReconstruction() throws {
        let id = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
        let vault = try Vault.open(at: FixtureTests.bundled("sample.sempere"), identities: [id])
        let ids = try vault.noteIDs()
        XCTAssertFalse(ids.isEmpty)
        let fast = try vault.summaries()
        XCTAssertEqual(fast.count, ids.count)
        for s in fast { XCTAssertEqual(s, try fullSummary(vault, s.id)) }
    }

    /// Random multi-device histories with every op kind, snapshots, orphans and
    /// concurrent stamps, written to a vault: the parallel, point-free
    /// summaries equal those of full reconstruction, with and without a cache.
    func testRandomHistoriesSummariesEqualFullReconstruction() throws {
        let identity = pqIdentity()
        let vault = try makeVault(identity)
        var rng = SeededRNG(42)
        for _ in 0..<60 {
            for r in try SyntheticVault.randomHistory(note: UUID.random(&rng), rng: &rng) { try vault.write(r) }
        }
        let ids = try vault.noteIDs()
        let reference = try ids.map { try fullSummary(vault, $0) }
        for width in [1, 3] {
            XCTAssertEqual(Set(try vault.summaries(of: ids, maxConcurrency: width)), Set(reference))
        }
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        XCTAssertEqual(Set(try vault.summaries(of: nil, cache: cache)), Set(reference))
        let reopened = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        XCTAssertNil(reopened.loadProblem)
        XCTAssertEqual(Set(try vault.summaries(of: nil, cache: reopened)), Set(reference))
        for s in reference { XCTAssertEqual(try vault.summary(of: s.id), s) }
    }

    func testProgressReportsEveryNoteOnce() throws {
        let identity = pqIdentity()
        let vault = try makeVault(identity)
        try SyntheticVault.populate(vault, notes: 9, strokes: 3, points: 4)
        let seen = Locked<[SummaryProgress]>([])
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        _ = try vault.summaries(of: nil, cache: cache, maxConcurrency: 4) { p in seen.mutate { $0.append(p) } }
        XCTAssertEqual(seen.value.count, 9)
        XCTAssertEqual(Set(seen.value.map(\.completed)), Set(1...9))
        XCTAssertTrue(seen.value.allSatisfy { $0.total == 9 && !$0.cached })
        seen.mutate { $0 = [] }
        _ = try vault.summaries(of: nil, cache: cache) { p in seen.mutate { $0.append(p) } }
        XCTAssertTrue(seen.value.allSatisfy(\.cached))
        XCTAssertEqual(seen.value.count, 9)
    }

    func testParallelMapKeepsOrder() {
        let calls = Locked(0)
        let out = Parallel.map(Array(0..<100), width: 6) { $0 * 2 } done: { _, _ in calls.mutate { $0 += 1 } }
        XCTAssertEqual(out, (0..<100).map { $0 * 2 })
        XCTAssertEqual(calls.value, 100)
        XCTAssertEqual(Parallel.map([Int](), width: 4) { $0 }, [])
        XCTAssertEqual(Parallel.map([1, 2], width: 0) { Optional($0) }, [1, 2])
    }

    /// A note without files (an iCloud folder not listed yet) has a problem
    /// summary, which is never cached.
    func testNoteWithoutRevisionsIsAProblemNotAnError() throws {
        let vault = try makeVault(pqIdentity())
        let cache = try SummaryCache(directory: tmp.appendingPathComponent("cache"), vault: vault)
        let id = UUID()
        let out = try vault.summaries(of: [id], cache: cache)
        XCTAssertEqual(out.count, 1)
        XCTAssertNotNil(out[0].problem)
        XCTAssertNil(cache.summary(for: id, revisions: []))
        XCTAssertFalse(cache.hasChanges)
    }

    // MARK: Cache

    func makeCachedVault(notes: Int = 4) throws -> (Vault, URL, NativeIdentity) {
        let identity = pqIdentity()
        let vault = try makeVault(identity)
        try SyntheticVault.populate(vault, notes: notes, strokes: 2, points: 3)
        return (vault, tmp.appendingPathComponent("cache"), identity)
    }

    func testCacheHitsUntilARevisionIsAdded() throws {
        let (vault, dir, _) = try makeCachedVault()
        let first = try vault.summaries(of: nil, cache: try SummaryCache(directory: dir, vault: vault))
        let id = first[0].id
        // A new delta for one note: only that note is read again.
        let names = try vault.revisionNames(of: id)
        _ = try vault.apply([.setMeta(.title("Renamed"))], to: id, deviceState: tmp.appendingPathComponent("device.json"),
                            app: "test/0")
        XCTAssertNotEqual(try vault.revisionNames(of: id), names)
        let cache = try SummaryCache(directory: dir, vault: vault)
        let seen = Locked<[UUID: Bool]>([:])
        let second = try vault.summaries(of: nil, cache: cache) { p in seen.mutate { $0[p.summary.id] = p.cached } }
        XCTAssertEqual(seen.value[id], false)
        XCTAssertEqual(seen.value.values.filter { $0 }.count, first.count - 1)
        XCTAssertEqual(second.first { $0.id == id }?.title, "Renamed")
        XCTAssertEqual(Set(second), Set(try vault.noteIDs().map { try fullSummary(vault, $0) }))
    }

    /// The names each entry was made from are what a listing compares with.
    func testStoredNamesAreTheRevisionFileNames() throws {
        let (vault, dir, _) = try makeCachedVault()
        let cache = try SummaryCache(directory: dir, vault: vault)
        let all = try vault.summaries(of: nil, cache: cache)
        for s in all {
            let names = try vault.revisionNames(of: s.id).map(\.filename).sorted()
            XCTAssertEqual(cache.storedRevisionNames[s.id], names)
            XCTAssertEqual(cache.storedRevisionNames(of: s.id), names)
            XCTAssertEqual(cache.storedSummary(of: s.id), s)
            XCTAssertEqual(cache.summary(for: s.id, names: names), s)
            XCTAssertNil(cache.summary(for: s.id, names: names + ["x"]))
        }
        XCTAssertNil(cache.storedSummary(of: UUID()))
    }

    /// A caller reading in batches defers the save (every save rewrites the
    /// whole file) and saves once at the end.
    func testBatchedReadsSaveOnlyWhenAsked() throws {
        let (vault, dir, _) = try makeCachedVault()
        let ids = try vault.noteIDs()
        let cache = try SummaryCache(directory: dir, vault: vault)
        _ = try vault.summaries(of: Array(ids.prefix(2)), cache: cache, saveCache: false)
        _ = try vault.summaries(of: Array(ids.dropFirst(2)), cache: cache, saveCache: false)
        XCTAssertTrue(cache.hasChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
        try cache.save()
        XCTAssertFalse(cache.hasChanges)
        XCTAssertEqual(Set(try SummaryCache(directory: dir, vault: vault).storedSummaries.map(\.id)), Set(ids))
        // The default still saves.
        let other = try SummaryCache(directory: tmp.appendingPathComponent("cache2"), vault: vault)
        _ = try vault.summaries(of: ids, cache: other)
        XCTAssertFalse(other.hasChanges)
    }

    func testCacheDropsDeletedNotesAndKeepsNoProblems() throws {
        let (vault, dir, _) = try makeCachedVault()
        let ids = try vault.noteIDs()
        // A broken revision: summarised with a problem, never cached.
        let broken = ids[1]
        let file = vault.noteURL(broken).appendingPathComponent(try vault.revisionNames(of: broken)[0].filename)
        try flipByte(file, at: 20)
        let first = try vault.summaries(of: nil, cache: try SummaryCache(directory: dir, vault: vault))
        XCTAssertNotNil(first.first { $0.id == broken }?.problem)
        XCTAssertEqual(Set(try SummaryCache(directory: dir, vault: vault).storedSummaries.map(\.id)),
                       Set(ids).subtracting([broken]))
        // A note deleted from the folder leaves the cache with the next full listing.
        try FileManager.default.removeItem(at: vault.noteURL(ids[0]))
        let second = try vault.summaries(of: nil, cache: try SummaryCache(directory: dir, vault: vault))
        XCTAssertEqual(second.count, ids.count - 1)
        XCTAssertEqual(Set(try SummaryCache(directory: dir, vault: vault).storedSummaries.map(\.id)),
                       Set(ids).subtracting([broken, ids[0]]))
    }

    func testCacheIsEncryptedAndOutsideTheVault() throws {
        let (vault, dir, _) = try makeCachedVault()
        _ = try vault.summaries(of: nil, cache: try SummaryCache(directory: dir, vault: vault))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let bytes = try Data(contentsOf: files[0])
        XCTAssertEqual(Array(bytes.prefix(5)), SummaryCache.magic)
        for needle in ["Note 0", "tag0", "Course", vault.vaultId.uuidString.lowercased()] {
            XCTAssertNil(bytes.range(of: Data(needle.utf8)), needle)
        }
        XCTAssertFalse(files[0].lastPathComponent.contains(vault.vaultId.uuidString.lowercased()))
        // The vault folder gained nothing.
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: vault.url.path).contains { $0.hasSuffix(".summaries") })
    }

    func testDamagedCacheIsIgnoredAndRebuilt() throws {
        let (vault, dir, _) = try makeCachedVault()
        let reference = try vault.summaries()
        _ = try vault.summaries(of: nil, cache: try SummaryCache(directory: dir, vault: vault))
        let file = try SummaryCache(directory: dir, vault: vault).fileURL
        let good = try Data(contentsOf: file)
        var damaged: [String: Data] = [
            "empty": Data(),
            "truncated": good.prefix(good.count / 2),
            "magic only": Data(SummaryCache.magic),
            "garbage": Data((0..<500).map { UInt8(truncatingIfNeeded: $0 &* 31) }),
        ]
        var flipped = good
        flipped[good.count - 3] ^= 0x10
        damaged["flipped"] = flipped
        var header = good
        header[2] ^= 0x01
        damaged["bad magic"] = header
        for (what, bytes) in damaged {
            try bytes.write(to: file)
            let cache = try SummaryCache(directory: dir, vault: vault)
            XCTAssertNotNil(cache.loadProblem, what)
            XCTAssertTrue(cache.storedSummaries.isEmpty, what)
            XCTAssertEqual(try vault.summaries(of: nil, cache: cache), reference, what)
            let rebuilt = try SummaryCache(directory: dir, vault: vault)
            XCTAssertNil(rebuilt.loadProblem, what)
            XCTAssertEqual(rebuilt.storedSummaries.count, reference.count, what)
        }
        // A directory where the file should be: listing still works, the save problem is kept.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let blocked = try SummaryCache(directory: dir, vault: vault)
        XCTAssertNotNil(blocked.loadProblem)
        XCTAssertEqual(try vault.summaries(of: nil, cache: blocked), reference)
        XCTAssertNotNil(blocked.saveProblem)
    }

    func testOtherSchemaOrSecretIsIgnored() throws {
        let (vault, dir, _) = try makeCachedVault()
        _ = try vault.summaries(of: nil, cache: try SummaryCache(directory: dir, vault: vault))
        // Same file under another secret: neither its name nor its key match.
        let otherSecret = VaultSecret.random()
        let other = SummaryCache(directory: dir, secret: otherSecret)
        XCTAssertNil(other.loadProblem)
        XCTAssertTrue(other.storedSummaries.isEmpty)
        let mine = try SummaryCache(directory: dir, vault: vault)
        try FileManager.default.copyItem(at: mine.fileURL, to: other.fileURL.appendingPathExtension("x"))
        try FileManager.default.moveItem(at: other.fileURL.appendingPathExtension("x"), to: other.fileURL)
        // The copied file is read under the other secret's name and fails to authenticate.
        let swapped = SummaryCache(directory: dir, secret: otherSecret)
        XCTAssertNotNil(swapped.loadProblem)
        XCTAssertTrue(swapped.storedSummaries.isEmpty)
        // An authentic file of another schema version.
        let secret = try vault.requireSecret()
        let key = SummaryCache.derive(secret, info: SummaryCache.keyInfo, bytes: 32)
        let json = Data(#"{"schema":999,"notes":[]}"#.utf8)
        let aad = Data(SummaryCache.magic) + Data(mine.fileURL.lastPathComponent.utf8)
        try SummaryCache.seal(try Gzip.compress(json), key: key, aad: aad).write(to: mine.fileURL)
        let old = try SummaryCache(directory: dir, vault: vault)
        XCTAssertEqual(old.loadProblem, "schema 999, expected \(SummaryCache.schemaVersion)")
        XCTAssertTrue(old.storedSummaries.isEmpty)
    }

    func testCLIDirectory() {
        XCTAssertEqual(SummaryCache.cliDirectory(environment: ["XDG_CACHE_HOME": "/x/cache"]).path, "/x/cache/sempere")
        XCTAssertTrue(SummaryCache.cliDirectory(environment: ["XDG_CACHE_HOME": "relative"]).path.hasSuffix("/.cache/sempere"))
        XCTAssertTrue(SummaryCache.cliDirectory(environment: [:]).path.hasSuffix("/.cache/sempere"))
    }

    func testLockedVaultHasNoCache() throws {
        let (vault, dir, _) = try makeCachedVault()
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try SummaryCache(directory: dir, vault: locked))
    }
}

/// A value behind a lock, for counting from concurrent callbacks.
/// Any JSON value, decoded only to see whether the decoder accepts it.
private enum JSONAny: Decodable {
    case value
    init(from decoder: Decoder) throws {
        if var a = try? decoder.unkeyedContainer() {
            while !a.isAtEnd { _ = try a.decode(JSONAny.self) }
        } else if let o = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for k in o.allKeys { _ = try o.decode(JSONAny.self, forKey: k) }
        }
        self = .value
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}


/// `LocalCacheKey` (format.md §10.1): names and sealed files of per-device caches.
final class LocalCacheKeyTests: XCTestCase {
    func secret(_ byte: UInt8) throws -> VaultSecret { try VaultSecret(bytes: Data(repeating: byte, count: 32)) }

    func testNamesDependOnTheSecretAndPurposeOnly() throws {
        let a = LocalCacheKey(secret: try secret(1), purpose: "drawing-cache", magic: Array("SMPD\u{1}".utf8))
        let again = LocalCacheKey(secret: try secret(1), purpose: "drawing-cache", magic: Array("SMPD\u{1}".utf8))
        let other = LocalCacheKey(secret: try secret(2), purpose: "drawing-cache", magic: Array("SMPD\u{1}".utf8))
        let purpose = LocalCacheKey(secret: try secret(1), purpose: "other", magic: Array("SMPD\u{1}".utf8))
        XCTAssertEqual(a.name, again.name)
        XCTAssertEqual(a.name.count, 32)
        XCTAssertNotEqual(a.name, other.name)
        XCTAssertNotEqual(a.name, purpose.name)
        XCTAssertEqual(a.entryName("note|r1"), again.entryName("note|r1"))
        XCTAssertNotEqual(a.entryName("note|r1"), a.entryName("note|r2"))
        XCTAssertNotEqual(a.entryName("note|r1"), other.entryName("note|r1"))
        XCTAssertFalse(a.entryName("note|r1").contains("note"))
    }

    /// Domain separation: no cache purpose can derive a vault-wide key
    /// (format.md §10.1). Every HKDF info string the format uses over the
    /// vault secret, other than §10.1's own, is listed here.
    func testNoPurposeDerivesAVaultWideKey() throws {
        let vaultWide = [SummaryCache.keyInfo, SummaryCache.nameInfo, RecipientsAuth.recipientsInfo,
                         RecipientsAuth.linkEd25519Info,
                         RecipientsAuth.linkMLDSA65Info, RecipientsAuth.secretIdInfo]
        for info in vaultWide {
            XCTAssertTrue(info.hasPrefix("sempere/1 "), info)
            let rest = info.dropFirst("sempere/1 ".count)
            for suffix in [" key", " entry", " name"] where rest.hasSuffix(suffix) {
                let word = String(rest.dropLast(suffix.count))
                XCTAssertFalse(LocalCacheKey.isUsablePurpose(word), "\(word) would derive \(info)")
            }
        }
        for used in ["drawing-cache", "blob-cache", "render-cache", "activity", "other"] {
            XCTAssertTrue(LocalCacheKey.isUsablePurpose(used), used)
        }
        for bad in ["", "-", "a-", "-a", "a--b", "Recipients", "secret link", "a b", "capture", "é",
                    String(repeating: "a", count: 65)] {
            XCTAssertFalse(LocalCacheKey.isUsablePurpose(bad), bad)
        }
    }

    func testSealedFilesOpenOnlyUnderTheirNameAndKey() throws {
        let magic = Array("SMPD\u{1}".utf8)
        let k = LocalCacheKey(secret: try secret(1), purpose: "drawing-cache", magic: magic)
        let plain = Data("ink".utf8)
        let sealed = try k.seal(plain, fileName: "a.page")
        XCTAssertTrue(sealed.starts(with: magic))
        XCTAssertEqual(try k.open(sealed, fileName: "a.page"), plain)
        XCTAssertThrowsError(try k.open(sealed, fileName: "b.page"), "bound to its name")
        let other = LocalCacheKey(secret: try secret(2), purpose: "drawing-cache", magic: magic)
        XCTAssertThrowsError(try other.open(sealed, fileName: "a.page"), "bound to the vault secret")
        var flipped = sealed
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try k.open(flipped, fileName: "a.page"))
        XCTAssertThrowsError(try k.open(Data(sealed.prefix(10)), fileName: "a.page"))
        XCTAssertThrowsError(try k.open(Data(), fileName: "a.page"))
    }
}
