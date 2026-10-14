import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Handwritten math → LaTeX, the pure parts (docs/attachments.md §14 G1 part 2):
/// the model's image, its vocabulary, beam search, clean-up, model manifests
/// and the verified store. The Core ML recogniser runs on the tiny random
/// fixture model on macOS only.
final class MathRecognitionTests: XCTestCase {
    // MARK: Image

    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, width: Double = 4,
              tool: InkTool = .pen, transform: Transform? = nil) -> Stroke {
        let pts = (0...10).map { i -> StrokePoint in
            let t = Double(i) / 10
            return T.pt(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, w: width)
        }
        return T.stroke(pts, tool: tool, width: width, color: Color(r: 200, g: 0, b: 0), transform: transform)
    }

    let spec = MathImageSpec(width: 200, height: 60, padding: 10, strokeWidth: 3)

    /// Darkest column and row ranges of an image (pixels darker than 128).
    func inkBox(_ img: MathInkImage) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var box: (Int, Int, Int, Int)?
        for y in 0..<img.height {
            for x in 0..<img.width where img.gray[y * img.width + x] < 128 {
                if let b = box { box = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } else { box = (x, x, y, y) }
            }
        }
        return box.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    func testInkIsScaledIntoThePaddedBoxLeftAlignedAndCentredVertically() throws {
        // 100 × 20 points of ink: the padded box is 180 × 40, so the height decides (scale 40 / ~24).
        let img = try XCTUnwrap(MathInkImage.render(strokes: [line(50, 100, 150, 120)], spec: spec))
        XCTAssertEqual(img.width, 200)
        XCTAssertEqual(img.height, 60)
        let box = try XCTUnwrap(inkBox(img))
        XCTAssertGreaterThanOrEqual(box.minX, 9)
        XCTAssertLessThanOrEqual(box.minX, 13)   // left-aligned at the padding
        XCTAssertGreaterThanOrEqual(box.minY, 9)
        XCTAssertLessThanOrEqual(box.maxY, 50)
        XCTAssertEqual(Double(box.minY + box.maxY) / 2, 30, accuracy: 2)   // centred vertically
        // Only white and ink: the colour and pressure are gone.
        XCTAssertEqual(img.gray.first, 255)
        XCTAssertTrue(img.gray.contains(0))
    }

    func testStrokeWidthIsTheSpecsWhateverThePenWas() throws {
        // A thin and a very thick pen draw the same image.
        let thin = try XCTUnwrap(MathInkImage.render(strokes: [line(0, 0, 100, 30, width: 0.5)], spec: spec))
        let thick = try XCTUnwrap(MathInkImage.render(strokes: [line(0, 0, 100, 30, width: 0.5)].map { s in
            var t = s
            t.ink.width = 40
            for i in t.points.indices { t.points[i].w = 40; t.points[i].h = 40 }
            return t
        }, spec: spec))
        // Bounds differ by the padded pen, so compare the drawn line's thickness in one column.
        func thickness(_ img: MathInkImage) -> Int {
            let x = img.width / 3
            return (0..<img.height).filter { img.gray[$0 * img.width + x] < 128 }.count
        }
        XCTAssertEqual(thickness(thin), thickness(thick), accuracy: 1)
        XCTAssertLessThanOrEqual(thickness(thin), 6)
    }

    func testMaxInkHeightKeepsSmallInkSmallAndCentringWorks() throws {
        var s = spec
        s.maxInkHeight = 20
        s.alignLeft = false
        let img = try XCTUnwrap(MathInkImage.render(strokes: [line(0, 0, 10, 10)], spec: s))
        let box = try XCTUnwrap(inkBox(img))
        XCTAssertLessThanOrEqual(box.maxY - box.minY, 24)
        XCTAssertEqual(Double(box.minX + box.maxX) / 2, 100, accuracy: 3)
    }

    func testTransformsMarkersAndEmptyInk() throws {
        // A stroke moved by its transform is drawn where it is on the page: alone, it fills the box the same way.
        let moved = line(0, 0, 100, 20, transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 500, ty: 300))
        let plain = line(500, 300, 600, 320)
        XCTAssertEqual(try MathInkImage.render(strokes: [moved], spec: spec)?.gray,
                       try MathInkImage.render(strokes: [plain], spec: spec)?.gray)
        // Markers and empty strokes are not read.
        XCTAssertNil(try MathInkImage.render(strokes: [line(0, 0, 10, 10, tool: .marker)], spec: spec))
        XCTAssertNil(try MathInkImage.render(strokes: [], spec: spec))
        // A single dot still draws.
        let dot = T.stroke([T.pt(5, 5)])
        XCTAssertNotNil(try MathInkImage.render(strokes: [dot], spec: spec))
    }

    func testBadSpecsAreRefused() {
        for bad in [MathImageSpec(width: 0, height: 10), MathImageSpec(width: 5000, height: 10),
                    MathImageSpec(width: 64, height: 64, channels: 2), MathImageSpec(width: 64, height: 64, padding: 40),
                    MathImageSpec(width: 64, height: 64, strokeWidth: .nan),
                    MathImageSpec(width: 64, height: 64, mean: [0, 0], std: [1]),
                    MathImageSpec(width: 64, height: 64, std: [0])] {
            XCTAssertNotNil(bad.problem, "\(bad)")
            XCTAssertThrowsError(try MathInkImage.render(strokes: [line(0, 0, 1, 1)], spec: bad))
        }
        XCTAssertNil(spec.problem)
    }

    func testTensorNormalisesInvertsAndRepeatsChannels() {
        let img = MathInkImage(width: 2, height: 1, gray: [0, 255], region: Rect(x: 0, y: 0, w: 1, h: 1), scale: 1)
        XCTAssertEqual(img.tensor(MathImageSpec(width: 2, height: 1, padding: 0, strokeWidth: 0.1)), [0, 1])
        let inverted = MathImageSpec(width: 2, height: 1, padding: 0, strokeWidth: 0.1, invert: true, mean: [0.5], std: [0.5])
        XCTAssertEqual(img.tensor(inverted), [1, -1])
        let rgb = MathImageSpec(width: 2, height: 1, channels: 3, padding: 0, strokeWidth: 0.1,
                                mean: [0, 0.5, 1], std: [1, 1, 1])
        XCTAssertEqual(img.tensor(rgb), [0, 1, -0.5, 0.5, -1, 0])
        XCTAssertNoThrow(try img.png())
    }

    // MARK: Vocabulary

    func testByteLevelVocabularyDecodes() throws {
        let json = """
            {"model": {"type": "BPE", "vocab": {"<s>": 0, "</s>": 1, "\\\\frac": 2, "{": 3, "a": 4, "}": 5, "Ġ+": 6, "Ġb": 7, "Ã©": 8}},
             "added_tokens": [{"id": 0, "content": "<s>", "special": true}, {"id": 1, "content": "</s>", "special": true}]}
            """
        let v = try MathVocabulary.parse(Data(json.utf8), joining: .byteLevel)
        XCTAssertEqual(v.tokens.count, 9)
        XCTAssertEqual(v.special, [0, 1])
        XCTAssertEqual(v.text([0, 2, 3, 4, 5, 6, 7, 1]), "\\frac{a} + b")
        XCTAssertEqual(v.text([8]), "é")   // bytes C3 A9
        XCTAssertEqual(v.text([99, -1]), "")   // out of range: left out
    }

    func testWordVocabularyAndBadFiles() throws {
        let v = try MathVocabulary.parse(Data(#"["<sos>", "x", "^", "{", "2", "}"]"#.utf8), joining: .words)
        XCTAssertEqual(v.text([1, 2, 3, 4, 5]), "x ^ { 2 }")
        for bad in [#"{"x": 1}"#, "not json", #"[1, 2]"#,
                    #"{"model": {"vocab": {"a": 0, "b": 2}}}"#,   // a gap
                    #"{"model": {"vocab": {"a": -1}}}"#, #"{"model": {"vocab": {"a": 9999999}}}"#] {
            XCTAssertThrowsError(try MathVocabulary.parse(Data(bad.utf8), joining: .byteLevel), bad)
        }
    }

    // MARK: Beam search

    /// A toy decoder: after the prefix `[0] + p`, prefers `table[p]` (by 2 nats), else the end token 1.
    func toyStep(_ table: [[Int]: [Float]]) -> ([Int]) throws -> [Float] {
        { prefix in table[Array(prefix.dropFirst())] ?? [0, 5, 0, 0, 0] }
    }

    func testBeamSearchFindsTheBestSequenceAndAlternatives() throws {
        // Greedy takes 2 (logit 3) then is unsure; the 3 path is sure of 4 then end.
        let table: [[Int]: [Float]] = [
            []: [0, 0, 3, 2.5, 0],
            [2]: [0, 1, 1, 1, 1],
            [3]: [0, 0, 0, 0, 9],
            [3, 4]: [0, 9, 0, 0, 0],
        ]
        let results = try MathBeamSearch.search(start: 0, end: 1, vocabularySize: 5, width: 3, maxLength: 10,
                                                step: toyStep(table))
        XCTAssertEqual(results.first?.tokens, [3, 4])
        XCTAssertGreaterThan(results.count, 1)
        XCTAssertTrue(results.allSatisfy { $0.meanLogProbability <= 0 })
        // Width 1 is greedy.
        let greedy = try MathBeamSearch.search(start: 0, end: 1, vocabularySize: 5, width: 1, maxLength: 10, step: toyStep(table))
        XCTAssertEqual(greedy.first?.tokens.first, 2)
    }

    func testBeamSearchIsBoundedAndChecksScores() throws {
        var calls = 0
        // Never ends: stops at maxLength with the cut beams.
        let results = try MathBeamSearch.search(start: 0, end: 1, vocabularySize: 3, width: 2, maxLength: 7) { _ in
            calls += 1
            return [0, -9, 4]
        }
        XCTAssertLessThanOrEqual(calls, 2 * 7)
        XCTAssertEqual(results.first?.tokens.count, 7)
        XCTAssertThrowsError(try MathBeamSearch.search(start: 0, end: 1, vocabularySize: 3, width: 2, maxLength: 3) { _ in [0, 1] })
        XCTAssertThrowsError(try MathBeamSearch.search(start: 0, end: 1, vocabularySize: 3, width: 2, maxLength: 3) { _ in [0, .nan, 1] })
    }

    func testLogSoftmaxIsStable() {
        let lp = MathBeamSearch.logSoftmax([1000, 1000])
        XCTAssertEqual(lp[0], -log(2.0), accuracy: 1e-9)
        XCTAssertEqual(MathBeamSearch.top([0.1, 0.5, 0.3, 0.9], 2).map(\.0), [3, 1])
    }

    // MARK: Clean-up

    func testCleanupRemovesDelimitersStyleAndSpaces() {
        XCTAssertEqual(LaTeXCleanup.clean(#"\frac { a } { b } + x ^ { 2 }"#), #"\frac{a}{b}+x^{2}"#)
        XCTAssertEqual(LaTeXCleanup.clean(#"$$\displaystyle \alpha x$$"#), #"\alpha x"#)
        XCTAssertEqual(LaTeXCleanup.clean(#"\[ \sum _ { i = 1 } ^ { n } i \]"#), #"\sum_{i=1}^{n}i"#)
        XCTAssertEqual(LaTeXCleanup.clean(#"\sin \theta"#), #"\sin\theta"#)
        XCTAssertEqual(LaTeXCleanup.clean("\\alpha\u{0}\tb"), #"\alpha b"#)
        XCTAssertEqual(LaTeXCleanup.clean(#"\, x \; y"#), #"\,x\;y"#)
        XCTAssertEqual(LaTeXCleanup.clean("$"), "$")
        XCTAssertEqual(LaTeXCleanup.clean(""), "")
        // What comes out is accepted by the format's check whenever the input was.
        XCTAssertNil(MathSource.check(LaTeXCleanup.clean(#"\frac { 1 } { \sqrt { x } }"#)))
    }

    // MARK: Manifests and the store

    func tinyFolder() throws -> URL { try T.fixtureURL("math-tiny") }

    func testTheTinyFixtureManifestParsesAndVerifies() throws {
        let folder = try tinyFolder()
        let m = try MathModelStore.manifest(in: folder)
        XCTAssertNil(m.problem)
        XCTAssertEqual(m.decoder.vocabularySize, 200)
        XCTAssertNoThrow(try MathModelStore.verify(m, in: folder))
        let vocab = try MathVocabulary.parse(BoundedRead.contents(of: folder.appendingPathComponent(m.vocabulary.file),
                                                                  maxBytes: 1 << 20), joining: m.vocabulary.joining)
        XCTAssertEqual(vocab.tokens.count, m.decoder.vocabularySize)
    }

    func manifest(files: [MathModelManifest.File]) -> MathModelManifest {
        MathModelManifest(id: "m", name: "M", licence: "MIT", source: "test", files: files,
                          image: MathImageSpec(width: 64, height: 32),
                          vocabulary: .init(file: "tokenizer.json", joining: .byteLevel),
                          decoder: .init(start: 0, end: 1, pad: 2, maxLength: 16, vocabularySize: 10),
                          coreml: .init(encoder: "e.mlpackage", decoder: "d.mlpackage"))
    }

    func testManifestChecks() throws {
        let h = String(repeating: "a", count: 64)
        let good: [MathModelManifest.File] = [.init(path: "e.mlpackage/x", sha256: h, size: 1),
                                              .init(path: "d.mlpackage/x", sha256: h, size: 1),
                                              .init(path: "tokenizer.json", sha256: h, size: 1)]
        XCTAssertNil(manifest(files: good).problem)
        for (path, why) in [("../etc/passwd", "parent"), ("/abs", "absolute"), (".hidden", "dot"), ("a//b", "empty part"),
                            ("manifest.json", "the manifest"), ("a b", "space"), ("é", "non-ASCII")] {
            XCTAssertNotNil(manifest(files: good + [.init(path: path, sha256: h, size: 1)]).problem, why)
        }
        XCTAssertNotNil(manifest(files: good + [.init(path: "x", sha256: "AA", size: 1)]).problem)
        XCTAssertNotNil(manifest(files: good + [.init(path: "x", sha256: h, size: -1)]).problem)
        XCTAssertNotNil(manifest(files: good + [good[2]]).problem, "listed twice")
        XCTAssertNotNil(manifest(files: good + [.init(path: "tokenizer.json/y", sha256: h, size: 1)]).problem, "file and folder")
        XCTAssertNotNil(manifest(files: Array(good.dropLast())).problem, "no vocabulary")
        XCTAssertNotNil(manifest(files: [good[0], good[2]]).problem, "no decoder files")
        var m = manifest(files: good)
        m.decoder.lengths = [4, 8, 16]
        XCTAssertNil(m.problem)
        XCTAssertEqual(m.decoder.length(for: 1), 4)
        XCTAssertEqual(m.decoder.length(for: 5), 8)
        XCTAssertEqual(m.decoder.length(for: 16), 16)
        XCTAssertNil(m.decoder.length(for: 17))
        for bad in [[4, 8], [8, 4, 16], [4, 4, 16], [0, 16], []] {
            m.decoder.lengths = bad
            XCTAssertNotNil(m.problem, "\(bad)")
        }
        m = manifest(files: good)
        XCTAssertEqual(m.decoder.length(for: 3), 16, "no lengths: maxLength only")
        m.decoder.end = 10
        XCTAssertNotNil(m.problem)
        m = manifest(files: good)
        m.coreml.computeUnits = "gpuOnly"
        XCTAssertNotNil(m.problem)
        m = manifest(files: good)
        m.format = "sempere-math-model/2"
        XCTAssertNotNil(m.problem)
        XCTAssertThrowsError(try MathModelManifest.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try MathModelManifest.parse(Data(count: MathModelManifest.maxBytes + 1)))
    }

    func copyOfTiny() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("math-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: tinyFolder(), to: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInstallChecksEveryFileAndTheManifestHash() throws {
        let staging = try copyOfTiny()
        let manifestData = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        let sha = FileDigest.sha256(manifestData)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let m = try MathModelStore.manifest(in: staging)
        let entry = MathModelCatalogEntry(id: m.id, name: m.name, manifestURL: "https://example.org/m/manifest.json",
                                          manifestSHA256: sha, downloadBytes: m.totalBytes, licence: m.licence)
        XCTAssertNil(MathModelStore.installed(entry, root: root))

        // A wrong manifest hash, then a changed file: nothing is installed.
        XCTAssertThrowsError(try MathModelStore.install(from: staging, manifestSHA256: String(repeating: "0", count: 64), root: root))
        let tokenizer = staging.appendingPathComponent("tokenizer.json")
        let original = try Data(contentsOf: tokenizer)
        var changed = original
        changed[changed.startIndex] ^= 1
        try changed.write(to: tokenizer)
        XCTAssertThrowsError(try MathModelStore.install(from: staging, manifestSHA256: sha, root: root)) { error in
            XCTAssertEqual(error as? MathModelManifest.Failure, .mismatch("tokenizer.json"))
        }
        try original.write(to: tokenizer)
        try FileManager.default.removeItem(at: tokenizer)
        XCTAssertThrowsError(try MathModelStore.install(from: staging, manifestSHA256: sha, root: root)) { error in
            XCTAssertEqual(error as? MathModelManifest.Failure, .missing("tokenizer.json"))
        }
        try original.write(to: tokenizer)
        XCTAssertNil(MathModelStore.installed(entry, root: root))

        let installed = try MathModelStore.install(from: staging, manifestSHA256: sha, root: root)
        XCTAssertEqual(installed.lastPathComponent, m.id)
        XCTAssertEqual(MathModelStore.installed(entry, root: root)?.manifest, m)
        // Installing again replaces it.
        let again = try copyOfTiny()
        XCTAssertNoThrow(try MathModelStore.install(from: again, manifestSHA256: sha, root: root))
        // A newer catalogue entry (another manifest hash) does not take the old copy; a truncated file is not installed.
        var newer = entry
        newer.manifestSHA256 = String(repeating: "1", count: 64)
        XCTAssertNil(MathModelStore.installed(newer, root: root))
        try Data("x".utf8).write(to: installed.appendingPathComponent("tokenizer.json"))
        XCTAssertNil(MathModelStore.installed(entry, root: root))
        try MathModelStore.remove(id: m.id, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    func testCatalogEntryURLs() {
        let e = MathModelCatalogEntry(id: "m", name: "M", manifestURL: "https://example.org/models/m/manifest.json",
                                      manifestSHA256: "", downloadBytes: 1, licence: "MIT")
        XCTAssertEqual(e.fileURL("encoder.mlpackage/Manifest.json")?.absoluteString,
                       "https://example.org/models/m/encoder.mlpackage/Manifest.json")
        XCTAssertNil(e.fileURL("../x"))
        var http = e
        http.manifestURL = "http://example.org/m/manifest.json"
        XCTAssertNil(http.fileURL("x"))
        XCTAssertTrue(MathModelCatalog.entries.allSatisfy { $0.manifestURL.hasPrefix("https://") })
    }

    // MARK: A fake recogniser through the protocol

    struct Fake: MathRecognizing {
        let imageSpec = MathImageSpec(width: 64, height: 32)
        func recognize(_ image: MathInkImage) throws -> MathRecognition {
            MathRecognition(candidates: [MathCandidate(latex: "x^{\(image.gray.filter { $0 < 128 }.count > 0 ? 2 : 0)}")],
                            engine: "fake", seconds: 0)
        }
    }

    func testRecognizeStrokesDrawsThenReads() throws {
        XCTAssertEqual(try Fake().recognize(strokes: [line(0, 0, 10, 10)])?.best?.latex, "x^{2}")
        XCTAssertNil(try Fake().recognize(strokes: []))
    }

    // MARK: Core ML (macOS)

    #if canImport(CoreML)
    func testCoreMLRunsTheTinyModel() throws {
        let folder = try tinyFolder()
        let m = try MathModelStore.manifest(in: folder)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mlc-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        let recognizer = try CoreMLMathRecognizer(folder: folder, manifest: m, compiledCache: cache)
        let result = try XCTUnwrap(recognizer.recognize(strokes: [line(0, 0, 40, 20), line(0, 20, 40, 0)]))
        // Random weights: any reading, within the bounds, from this engine.
        XCTAssertEqual(result.engine, m.id)
        XCTAssertLessThanOrEqual(result.candidates.count, m.decoder.beamWidth)
        XCTAssertTrue(result.candidates.allSatisfy { ($0.score ?? 0) <= 0 })
        // The compiled models are cached for the next load.
        XCTAssertNoThrow(try CoreMLMathRecognizer(folder: folder, manifest: m, compiledCache: cache))
    }
    #endif
}
