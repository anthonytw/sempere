import Age
import Foundation
import FuzzSupport
import XCTest

@testable import Sempere

/// Seeded mutation fuzzing of everything `Sources/Sempere` parses from a vault
/// folder: body framing and gzip, revision / snapshot / manifest / journal /
/// device-state JSON, file names and the other string encodings, and the
/// reducer, history, snapshot and compaction code fed with adversarial op logs.
/// Every input may fail with a typed error; none may trap, hang or allocate
/// without bound. Knobs: Tests/FuzzSupport (SEMPERE_FUZZ_LONG, ...).
final class SempereFuzzTests: VaultTestCase {
    static let wall = Date(timeIntervalSince1970: 1_800_000_000)
    static let pageA = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a1")!
    static let pageB = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a2")!

    func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    /// Errors the library is allowed to throw for bad input.
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is DecodingError {
        } catch is EncodingError {
        } catch is NoteLogError {
        } catch is HistoryError {
        } catch is VaultError {
        } catch is RevisionReadError {
        } catch is BodyFramingError {
        } catch is GzipError {
        } catch is AgeError {
        } catch is SharedSettingsError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    // MARK: Seeds

    static func richStroke(_ id: UUID, _ n: Int, transform: Transform? = nil, parent: UUID? = nil) -> Stroke {
        Stroke(id: id, ink: Ink(tool: n % 2 == 0 ? .pen : .marker, color: Color(r: 10, g: 20, b: 30, a: 200), width: 2.5),
               points: (0..<n).map { i in
                   StrokePoint(x: Double(i) * 3.5, y: 10 + Double(i % 7), t: Double(i) / 120, w: 2, h: 2.5, o: 0.9,
                               f: 0.5, az: 0.25, al: 1.25)
               }, transform: transform, parent: parent)
    }

    /// A log with every op kind, two devices, a snapshot with extras,
    /// tombstones and clocks, and a later delta.
    static func seedLog() throws -> [Revision] {
        var log = LogBuilder()
        let s = (1...6).map { UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000b\($0)")! }
        let rec = Recognition(engine: "fuzz-1", text: "hello world",
                              words: [.init(text: "hello", box: .init(x: 1, y: 2, w: 30, h: 10))])
        let d1 = log.delta(devA, 0, NoteOps.newNote(title: "Fuzz", notebook: "School/Math", tags: ["a", "b"], pageId: pageA))
        let d2 = log.delta(devA, 10, [.addStroke(page: pageA, stroke: richStroke(s[0], 5)),
                                      .addStroke(page: pageA, stroke: richStroke(s[1], 2, transform: .init(a: 2, b: 0, c: 0, d: 2, tx: 5, ty: 6))),
                                      .addPage(Page(id: pageB, order: "b", parent: pageA)),
                                      .setPageRecognition(pageId: pageA, recognition: rec)])
        var d3 = log.delta(devB, 15, [.removeStroke(page: pageA, strokeId: s[0]), .setPageOrder(pageId: pageB, order: "Z"),
                                      .setMeta(.paper(Paper(kind: .grid, spacing: 18))),
                                      .setMeta(.pageSize(PageSize(width: 612, height: 2000, infinite: true, breakHeight: 700)))])
        d3.session = "5f0c3e8a-2b7d-4c1e-9a3f-6d2b8e4f1a07"   // version history fields (format.md §5.8)
        var snap = try log.snapshot(devB, 20, from: [d1, d2, d3])
        snap.asOf = RevisionKey(d3.name)
        var d4 = log.delta(devA, 30, [.addStroke(page: pageB, stroke: richStroke(s[2], 40, parent: s[1])),
                                      .removePage(pageId: pageA), .deleteNote, .restoreNote,
                                      .setMeta(.favorite(true)), .setMeta(.notebook(nil))])
        d4.checkpoint = Checkpoint(name: "Fuzz version")
        var late = log.delta(devB, 40, [.addStroke(page: pageB, stroke: richStroke(s[3], 1))])
        late.seq = 7   // leaves a gap: a later snapshot lists it in `extra`
        let snap2 = try log.snapshot(devA, 50, from: [d1, d2, d3, snap, d4, late])
        return [d1, d2, d3, snap, d4, late, snap2]
    }

    static func json(_ value: some Encodable) throws -> Data { try InkJSON.encoder().encode(value) }

    // MARK: Exercising the model

    /// Runs everything that consumes a decoded log: reconstruct, history,
    /// restore, snapshot (and its re-encoding), compaction, notebook tree,
    /// page-order keys.
    static func exercise(_ revs: [Revision]) -> String? {
        typed {
            guard !revs.isEmpty else { return }
            _ = NoteHistory.groups(NoteHistory.restorePoints(revs))
            _ = LoadedNote(revisions: revs, failures: [:]).compactionPlan(retention: 0, now: wall, assumingSnapshot: true)
            for mode in [CompactionMode.thin(olderThan: 0), .retention(0)] {
                var clock = HybridClock()
                _ = try? CompactionPlanner.plan(revs, mode: mode, now: wall, device: DeviceID("dddddddd")!, clock: &clock,
                                                wall: wall, app: "fuzz")
            }
            _ = LoadedNote(revisions: revs, failures: [:]).needsSnapshotBeforeCompaction(retention: 0, now: wall)
            let state = try NoteReducer.reconstruct(revs)
            _ = NotebookNode.flatten(NotebookNode.tree([state.meta.notebook, "x/y"]))
            for (a, b) in zip(state.pages.map(\.order), state.pages.dropFirst().map(\.order)) {
                _ = PageOrder.between(a, b); _ = PageOrder.between(b, a)
            }
            _ = PageOrder.between(state.pages.last?.order, nil)
            _ = PageOrder.between(nil, state.pages.first?.order)
            let names = revs.map(\.name).sorted()
            for point in [names[0], names[names.count / 2]] {
                var clock = HybridClock()
                _ = try? NoteHistory.makeRestore(from: revs, to: point, device: devC, clock: &clock, wall: wall,
                                                 app: "fuzz")
            }
            var clock = HybridClock()
            let seq = Vault.nextSeq(from: revs, device: devC)
            guard seq <= RevisionName.maxSeq else { return }
            let snap = try SnapshotBuilder.makeSnapshot(from: revs, device: devC, seq: seq, clock: &clock, wall: wall,
                                                        app: "fuzz")
            let back = try InkJSON.decoder().decode(Revision.self, from: json(snap))
            _ = try NoteReducer.reconstruct(revs + [back])
        }
    }

    /// One revision decoded from `input`, merged with the seed log.
    static func exerciseRevision(_ input: Data, log: [Revision]) -> String? {
        let rev: Revision
        do { rev = try InkJSON.decoder().decode(Revision.self, from: input) } catch is DecodingError { return nil } catch {
            return "untyped decode error \(type(of: error)): \(error)"
        }
        if let p = exercise([rev]) { return p }
        // Same (device, seq) as a seed revision is a typed conflict; keep the rest.
        return exercise(log.filter { $0.device != rev.device || $0.seq != rev.seq } + [rev])
    }

    // MARK: Targets

    func testFuzzRevisionJSON() throws {
        let log = try Self.seedLog()
        let seeds = try log.map(Self.json)
        assertClean(Fuzz.run("revision-json", seeds: seeds, quick: 1500, text: true) { input in
            Self.exerciseRevision(input, log: log)
        })
    }

    /// Newer revisions (format.md §7.4): unknown ops, fields and snapshot
    /// elements, decoded leniently. Whatever the input, decoding gives a typed
    /// error or a revision whose report stays within its bounds.
    static func newerSeeds() throws -> [Data] {
        let note = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000ff")!
        var d = NewerFixture.envelope(note, NewerFixture.devN, 1, 1000, "delta")
        d["features"] = ["tables"]
        d["ops"] = [
            ["op": "addPage", "page": ["id": NewerFixture.id(1), "order": "a0"]],
            ["op": "addStroke", "page": NewerFixture.id(1), "stroke": NewerFixture.stroke(1)],
            ["op": "warp", "page": NewerFixture.id(1), "by": [1, 2]],
            ["op": "setMeta", "field": "color", "value": "#FF0000FF"],
            ["op": "setItem", "page": NewerFixture.id(1), "itemId": NewerFixture.id(2), "field": "id", "value": 1],
        ] as [Any]
        var s = NewerFixture.envelope(note, NewerFixture.devN, 2, 2000, "snapshot")
        s["included"] = [NewerFixture.devN.rawValue: ["upTo": 1, "extra": []]]
        s["state"] = [
            "deleted": false, "tables": [1],
            "meta": ["title": "t", "tags": [], "favorite": false, "created": NewerFixture.wall(0),
                     "paper": ["kind": "ruled"], "pageSize": ["width": 612, "height": 792, "infinite": false]],
            "pages": [["id": NewerFixture.id(1), "order": "a0", "strokes": [NewerFixture.stroke(1), ["id": 3]]],
                      ["order": "b"]],
            "recordings": [["nope": true]],
        ] as [String: Any]
        return try [d, s].map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }

    func testFuzzNewerRevisionJSON() throws {
        let log = try Self.seedLog()
        assertClean(Fuzz.run("newer-revision-json", seeds: try Self.newerSeeds(), quick: 1200, text: true) { input in
            _ = RevisionMarkers.peekNewer(input)
            if let problem = Self.exerciseRevision(input, log: log) { return problem }
            guard let rev = try? InkJSON.decoder().decode(Revision.self, from: input), let n = rev.newer else { return nil }
            for map in [n.skippedOps, n.formats, n.features] {
                if map.count > NewerContent.maxNames + 1 { return "\(map.count) names kept" }
                if map.keys.contains(where: { $0.count > NewerContent.maxNameLength }) { return "long name kept" }
            }
            return n.revisions == 1 ? nil : "revisions \(n.revisions)"
        })
    }

    /// Revisions with attachments (format.md §8): every attachment op, a
    /// snapshot holding items of each kind, recordings and their tombstones,
    /// open fields. Besides the usual merge exercise, anything that decodes
    /// must encode again, and that encoding must be a fixed point.
    static func attachmentSeeds() throws -> [Revision] {
        let page = pageA
        let hash = String(repeating: "ab", count: 32)
        let blob = BlobRef(sha256: hash, size: 1234, type: "image/png", extra: ["x": .array([.number(1), .null])])
        let text = TextContent(family: "SF Pro", size: 12, color: .black, align: .center, dir: .rtl, lang: "ar",
                               runs: [TextRun("سلام ", b: true), TextRun("e\u{301}\nb", size: 18, lang: "es")], breaks: [2])
        let rec = Recording(id: UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000c1")!,
                            blob: BlobRef(sha256: hash, size: 99, type: "audio/mp4"), started: wall, duration: 12.5,
                            codec: "aac", sampleRate: 48000, channels: 1, bitRate: 64000, title: "T",
                            transcript: BlobRef(sha256: hash, size: 5, type: BlobRef.transcriptType), extra: ["k": .bool(true)])
        let items = [
            Item.text(id: UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000d1")!, text,
                      frame: Rect(x: 1, y: 2, w: 300, h: 40), z: "a", rec: RecordingLink(id: rec.id, at: 3.25)),
            Item.image(id: UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000d2")!, blob: blob,
                       pixelSize: Size(w: 30, h: 40), orientation: 6, crop: Rect(x: 0, y: 0, w: 30, h: 40),
                       frame: Rect(x: 5, y: 5, w: 30, h: 40), z: "b"),
            Item.pdfPage(id: UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000d3")!,
                         blob: BlobRef(sha256: hash, size: 7, type: "application/pdf"), pageIndex: 2,
                         pageSize: Size(w: 612, h: 792), frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a"),
            Item(id: UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000d4")!, kind: ItemKind(rawValue: "shape"), layer: ItemLayer(rawValue: 250),
                 frame: Rect(x: 1, y: 1, w: 2, h: 2), rotation: 45, z: "c", extra: ["latex": .string("x^2"), "render": try JSONValue(encoding: blob)]),
            Item.math(id: UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000d5")!,
                      MathContent(latex: "\\int_0^1 x^2\\,dx = \\frac{1}{3}", display: false, size: 18, color: .black,
                                  render: BlobRef(sha256: hash, size: 70, type: "application/pdf"), renderSize: Size(w: 90, h: 30),
                                  engine: "swiftmath-1.7.3", extra: ["future": .bool(true)]),
                      frame: Rect(x: 50, y: 60, w: 90, h: 30), z: "d"),
        ]
        var log = LogBuilder()
        let d1 = log.delta(devA, 0, NoteOps.newNote(title: "Att", pageId: page))
        let d2 = log.delta(devA, 5, items.map { .addItem(page: page, item: $0) } + [
            .addRecording(rec),
            .setItem(page: page, itemId: items[0].id, change: .frame(Rect(x: 0, y: 0, w: 9, h: 9))),
            .setItem(page: page, itemId: items[1].id, change: .crop(nil)),
            .setItem(page: page, itemId: items[1].id, change: .rotation(90)),
            .setItem(page: page, itemId: items[0].id, change: .text(text)),
            .setItem(page: page, itemId: items[3].id, change: .other(field: "latex", value: .string("y"))),
            .setItem(page: page, itemId: items[4].id, change: .math(MathContent(latex: "\\sqrt{2}", size: 12))),
            .setRecording(recordingId: rec.id, change: .title("U")),
            .setRecording(recordingId: rec.id, change: .transcript(nil)),
            .removeItem(page: page, itemId: items[2].id), .removeRecording(recordingId: UUID()),
        ])
        var state = try NoteReducer.reconstruct([d1])
        state.pages[0].items = items
        state.recordings = [rec]
        state.tombstones = Tombstones(items: [UUID()], recordings: [UUID()])
        let snap = Revision(noteId: testNote, device: devB, seq: 1, hlc: HLC(millis: baseMillis + 9, counter: 0)!,
                            wall: wall, app: "fuzz", body: .snapshot(included: Included([devA: .init(upTo: 1)]), state: state))
        return [d1, d2, snap]
    }

    func testFuzzAttachmentJSON() throws {
        let log = try Self.seedLog() + Self.attachmentSeeds()
        let seeds = try Self.attachmentSeeds().map(Self.json)
        assertClean(Fuzz.run("attachment-json", seeds: seeds, quick: 1200, text: true) { input in
            if let problem = Self.exerciseRevision(input, log: log) { return problem }
            guard let rev = try? InkJSON.decoder().decode(Revision.self, from: input) else { return nil }
            do {
                let once = try Self.json(rev)
                let twice = try Self.json(InkJSON.decoder().decode(Revision.self, from: once))
                return once == twice ? nil : "re-encoding is not a fixed point"
            } catch {
                return "a decoded revision does not round-trip: \(error)"
            }
        })
    }

    /// LaTeX sources (format.md §8.2.8): `MathSource.check` must answer every
    /// input quickly (linear, no recursion), and a source it accepts must
    /// stay within the limits it promises.
    func testFuzzMathSource() throws {
        let seeds = ["\\frac{a}{b}", "\\left( \\sum_{i=1}^{n} x_i \\right)^{2}",
                     "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", "\\sqrt\\sqrt{x}", "e^{i\\pi}+1=0",
                     "\\{ x \\} \\left\\{ \\right.", "{{{{x}}}}", "a^^__"].map { Data($0.utf8) }
        assertClean(Fuzz.run("math-source", seeds: seeds, quick: 3000, text: true, maxSize: 3 * MathSource.maxBytes,
                             generate: { rng in
            // Deep or long structures built directly.
            let pieces = ["{", "}", "\\left(", "\\right)", "\\begin{x}", "\\end{x}", "\\sqrt", "^", "_", "x", " ", "\\"]
            return Data((0..<rng.below(9000)).map { _ in rng.pick(pieces) }.joined().utf8)
        }) { input in
            let latex = String(decoding: input, as: UTF8.self)
            let issue = MathSource.check(latex)
            if issue == nil {
                if latex.utf8.count > MathSource.maxBytes { return "accepted a source over the byte limit" }
                if latex.unicodeScalars.filter({ !$0.properties.isWhitespace }).count > 2 * MathSource.maxTokens + latex.utf8.count {
                    return "accepted too many tokens"
                }
            }
            // Item decoding with the source in it fails with a typed error or round-trips.
            let item = ##"{"id":"7e57c0de-0000-4000-8000-0000000000d5","kind":"math","frame":[1,2,3,4],"z":"a","math":"##
                + ##"{"display":true,"size":12,"color":"#000000FF","latex":"##
            var json = Data(item.utf8)
            json.append((try? JSONSerialization.data(withJSONObject: [latex], options: [.fragmentsAllowed]).dropFirst().dropLast()) ?? Data("\"\"".utf8))
            json.append(Data("}}".utf8))
            do {
                let decoded = try InkJSON.decoder().decode(Item.self, from: json)
                let again = try InkJSON.decoder().decode(Item.self, from: try InkJSON.encoder().encode(decoded))
                return again == decoded ? nil : "math item does not round-trip"
            } catch is DecodingError { return nil } catch { return "untyped error \(type(of: error))" }
        })
    }

    /// Markdown text boxes (format.md §8.5.4): any source parses, its plain
    /// text and rendered paragraphs are built, every offset points inside the
    /// source, and the editing helpers keep their selection inside the text.
    func testFuzzMarkdown() throws {
        let seeds = ["# H\n\n- [x] **a** _b_ ~~c~~ `d` [e](f) <g:h>\n> q\n```\ncode\n```\n$$\nx\n$$",
                     "1. a\n   - b\n     > c *d* $e$ $$f$$", "***x** y*", "[a](<b> \"t\") ![i](j)", "\\* \\$ $5 $6",
                     String(repeating: "> - ", count: 30) + "deep"].map { Data($0.utf8) }
        assertClean(Fuzz.run("markdown", seeds: seeds, quick: 2000, text: true, maxSize: 4096, generate: { rng in
            let pieces = ["*", "_", "~~", "`", "$", "$$", "[", "]", "(", ")", "<", ">", "#", "- ", "1. ", "\n", " ", "\\", "x",
                          "[ ] ", "```", "!", "é", "😀"]
            return Data((0..<rng.below(3000)).map { _ in rng.pick(pieces) }.joined().utf8)
        }) { input in
            let source = String(decoding: input, as: UTF8.self)
            let count = source.unicodeScalars.count
            let doc = MarkdownDocument(source)
            _ = doc.plainText
            let content = TextContent(size: 12, color: .black, runs: [TextRun(source)], markup: .markdown)
            for p in MarkdownPlan(content).paragraphs {
                var last = -1
                for a in p.atoms {
                    if a.offset < 0 || a.offset > count { return "offset \(a.offset) outside the source" }
                    if a.offset <= last { return "offsets not increasing" }
                    last = a.offset
                }
            }
            let n = (source as NSString).length
            for action in MarkdownEditing.Action.allCases {
                let r = MarkdownEditing.apply(action, to: source, selection: NSRange(location: n / 3, length: n / 3))
                if r.selection.location + r.selection.length > (r.text as NSString).length { return "\(action): selection outside" }
            }
            return nil
        })
    }

    func testFuzzTranscript() throws {
        let t = Transcript(recording: UUID(), engine: "apple-speechtranscriber-26.4", language: "en-US", created: Self.wall,
                           segments: [.init(start: 0.52, end: 3.1, text: "Today we look at linear maps.", confidence: 0.94,
                                            words: [.init("Today", start: 0.52, end: 0.8, c: 0.97), .init("we", start: 0.8, end: 0.93)]),
                                      .init(start: 3.1, end: 4, text: "Kernels.", language: "en-GB")])
        assertClean(Fuzz.run("transcript", seeds: [try t.encoded()], quick: 1500, text: true) { input in
            let decoded: Transcript
            do { decoded = try Transcript.decode(input) } catch is DecodingError { return nil } catch {
                return "untyped decode error \(type(of: error))"
            }
            do {
                let once = try decoded.encoded()
                return try Transcript.decode(once).encoded() == once ? nil : "re-encoding is not a fixed point"
            } catch {
                return "a decoded transcript does not round-trip: \(error)"
            }
        })
    }

    /// Whole op logs as one JSON array, half of them generated: duplicate
    /// ids, removes of unknown ids, parent cycles, orphans, conflicting
    /// (device, seq), huge `included`, many pages and long strokes.
    func testFuzzOpLogs() throws {
        let log = try Self.seedLog()
        let seeds = [try Self.json(log), try Self.json(Array(log.prefix(3)))]
        assertClean(Fuzz.run("op-log", seeds: seeds, quick: 800, text: true, generate: { rng in
            (try? Self.json(Self.adversarialLog(&rng))) ?? Data()
        }) { input in
            let revs: [Revision]
            do { revs = try InkJSON.decoder().decode([Revision].self, from: input) } catch is DecodingError { return nil } catch {
                return "untyped decode error \(type(of: error))"
            }
            return Self.exercise(revs)
        })
    }

    func testFuzzBodyFramingAndGzip() throws {
        let log = try Self.seedLog()
        let secret = VaultSecret.random()
        let note = testNote.uuidString.lowercased()
        let seeds = try log.map { r in
            try BodyFraming.frame(json: Self.json(r), noteId: note, filename: r.name.filename, secret: secret)
        }
        assertClean(Fuzz.run("body-framing", seeds: seeds, quick: 2500) { input in
            Self.typed {
                for key in [secret, nil] {
                    guard let u = try? BodyFraming.unframe(input, noteId: note, filename: log[0].name.filename,
                                                           secret: key) else { continue }
                    let json = try Gzip.decompress(u.gzip, maxOutput: 32 << 20)
                    if let p = Self.exerciseRevision(json, log: log) { throw Invariant(p) }
                }
            }
        })
        // Raw gzip members, including ones that inflate far past the limit.
        let big = try Gzip.compress(Data(count: 12 << 20))
        let gz = try seeds.map { _ = $0; return try Gzip.compress(Self.json(log)) } + [big]
        assertClean(Fuzz.run("gzip", seeds: gz, quick: 2000, maxSize: 256 << 10) { input in
            Self.typed {
                _ = try Gzip.decompress(input, maxOutput: 8 << 20)
                _ = try Gzip.inflateRaw(input.dropFirst(10), maxOutput: 8 << 20)
            }
        })
    }

    struct Invariant: Error { var text: String; init(_ t: String) { text = t } }

    func testFuzzManifestJournalAndDeviceState() throws {
        let id = pqIdentity(), other = pqIdentity()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient, other.recipient], labels: ["a", "b"],
                                     identities: [id])
        let manifest = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        let journal = try Self.json(Vault.RewrapJournal(format: "sempere/1",
                                                        previousVaultSecret: try Vault.encryptSecret(.random(), to: [id.recipient])))
        let device = try JSONEncoder().encode(DeviceState(device: devA, clock: HybridClock(millis: 5, counter: 3)))
        assertClean(Fuzz.run("manifest", seeds: [manifest, journal, device], quick: 1500, text: true) { input in
            Self.typed {
                if let m = try? Vault.readManifest(input) {
                    _ = try? Vault.decryptSecret(m.vaultSecret, with: [id])
                    _ = try m.encoded()
                }
                _ = try? InkJSON.decoder().decode(Vault.RewrapJournal.self, from: input)
                if let s = try? JSONDecoder().decode(DeviceState.self, from: input) {
                    var clock = s.clock
                    _ = clock.tick(wall: Self.wall)
                    _ = clock.observe(HLC(millis: HLC.maxMillis, counter: HLC.maxCounter)!, wall: .distantFuture)
                }
            }
        })
    }

    /// A broken invariant: untyped, so the fuzzer reports it.
    struct SettingsInvariant: Error { var what: String }

    /// settings.age's JSON (format.md §13): decoding, migration, validation,
    /// resolution, merge, a device pass and re-encoding. A file that decodes
    /// round-trips to the same settings.
    func testFuzzSharedSettings() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/settings")
        let seeds = try ["v1.json", "future-v2.json", "future-v3-breaking.json"].map { try Data(contentsOf: fixtures.appendingPathComponent($0)) }
        let base = try SharedSettings.decode(seeds[0]).settings
        assertClean(Fuzz.run("settings", seeds: seeds, quick: 1500, text: true) { input in
            Self.typed {
                let decoded = try SharedSettings.decode(input)
                let s = SharedSettingsMigrations.migrated(decoded.settings)
                _ = SharedSettingsCatalog.issues(in: decoded)
                for spec in SharedSettingsCatalog.specs {
                    for type in SettingsDeviceType.allCases { _ = s.resolve(spec, for: type) }
                }
                if s.merging(base).slots != base.merging(s).slots { throw SettingsInvariant(what: "merge not commutative") }
                var state = SettingsSyncState()
                var local: [String: JSONValue] = [:]
                for spec in SharedSettingsCatalog.specs(for: .ipad) { local[spec.name] = spec.defaultValue }
                _ = try state.enable(.useVault, local: local, file: s, type: .ipad, now: Self.wall)
                let again = try SharedSettings.decode(try decoded.settings.encoded()).settings
                if again != decoded.settings { throw SettingsInvariant(what: "round trip changed the settings") }
            }
        })
    }

    /// vault.json's `recipientsTag` / `secretLink` (format.md §2.1) and trust
    /// records: a mutated manifest never verifies with keys other than the
    /// real ones under the real secret, is never classified untagged by a
    /// device with a record, and never traps.
    func testFuzzRecipientsTag() throws {
        let id = pqIdentity(), other = pqIdentity()
        let store = MemoryRecipientsTrustStore()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient, other.recipient], labels: ["a", "b"],
                                     identities: [id], trust: store)
        let manifest = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        let secret = try XCTUnwrap(vault.secret)
        let record = try XCTUnwrap(try store.record(for: vault.vaultId))
        let recordJSON = try JSONEncoder().encode(record)
        let keys = vault.recipients.map(\.key)
        // A manifest with a signed `secretLink` (format.md §2.1), when ML-DSA is available.
        var seeds = [manifest, recordJSON]
        if postQuantumAvailable {
            var rotated = try Vault.create(at: vaultURL("Rotated"), recipients: [id.recipient, other.recipient], identities: [id])
            try rotated.removeRecipient(other.recipient)
            seeds.append(try Data(contentsOf: rotated.url.appendingPathComponent("vault.json")))
        }
        assertClean(Fuzz.run("recipients-tag", seeds: seeds, quick: 600, text: true) { input in
            if let r = try? JSONDecoder().decode(RecipientsTrustRecord.self, from: input) {
                switch r.anchor {
                case .legacy(let k) where k.count != 32: return "a legacy trust record with a \(k.count)-byte link key"
                case .signed(let k) where k.ed25519.count != 32 || k.mldsa65.count != 1952:
                    return "a trust record with \(k.ed25519.count) + \(k.mldsa65.count)-byte public keys"
                default: break
                }
            }
            guard let m = try? Vault.readManifest(input) else {
                _ = Vault.incomingManifestProblem(input, local: manifest, vault: vault)
                return nil
            }
            _ = RecipientsAuth.unhex(m.recipientsTag ?? "")
            for rec in [record, nil] as [RecipientsTrustRecord?] {
                let status = RecipientsAuth.evaluate(m, secret: secret, record: rec)
                if case .verified = status, m.vaultId == vault.vaultId, m.recipients.map(\.key) != keys {
                    return "a changed list verified: \(status)"
                }
                if rec != nil, m.vaultId == vault.vaultId, status == .untagged { return "untagged despite a record" }
            }
            _ = Vault.incomingManifestProblem(input, local: manifest, vault: vault)
            _ = try? m.encoded()
            return nil
        })
    }

    /// File names and the other string encodings (origin, stamps, colours,
    /// page-order keys, notebook paths).
    func testFuzzNamesAndStrings() throws {
        let seeds = ["17596320000000003-a1b2c3d4-12.delta.age", "17596320000000003-a1b2c3d4-1.snapshot.age",
                     "17596320000000003-a1b2c3d4-12-0", "17596320000000003-a1b2c3d4", "#1A1A1AFF", "a0V",
                     " Research//Daily log/ "].map { Data($0.utf8) }
        assertClean(Fuzz.run("names", seeds: seeds, quick: 6000, text: true, maxSize: 8192) { input in
            let s = String(decoding: input, as: UTF8.self)
            if let n = RevisionName(s), n.seq > RevisionName.maxSeq { return "seq above maxSeq accepted" }
            _ = Origin(s); _ = Stamp(s); _ = HLC(s); _ = DeviceID(s); _ = Color(hex: s)
            let half = s.index(s.startIndex, offsetBy: s.count / 2)
            let (a, b) = (String(s[..<half]), String(s[half...]))
            for (x, y) in [(a, b), (b, a), (s, s)] {
                let k = PageOrder.between(x, y)
                if PageOrder.strictlyBetween(x, y) != nil, !(x < k && k < y) { return "between(\(x), \(y)) = \(k)" }
            }
            _ = PageOrder.between(s, nil); _ = PageOrder.between(nil, s)
            _ = NotebookNode.tree([s, a, b])
            _ = NotebookPath.renamed(s, from: a, to: b)
            return nil
        })
    }

    /// Mutated revisions, encrypted and written into a real vault, then read
    /// through every vault entry point (load, reconstruct, summary, history,
    /// verify, nextSeq, snapshot, compaction plan).
    func testFuzzVaultFiles() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = try Self.seedLog()
        for r in log { try vault.write(r) }
        let seeds = try log.map(Self.json)
        let dir = vault.url.appendingPathComponent("notes").appendingPathComponent(testNote.uuidString.lowercased())
        let secret = try XCTUnwrap(vault.secret)
        assertClean(Fuzz.run("vault-files", seeds: seeds, quick: 250, text: true) { input in
            // Written under the name it claims (or a fixed one), encrypted for real.
            let claimed = (try? InkJSON.decoder().decode(Revision.self, from: input))?.name
            let name = claimed ?? RevisionName("17596320000500000-cccccccc-9.delta.age")!
            let file = dir.appendingPathComponent(name.filename)
            guard !FileManager.default.fileExists(atPath: file.path) else { return nil }
            defer { try? FileManager.default.removeItem(at: file) }
            return Self.typed {
                let gz = try Gzip.compress(input)
                let body = BodyFraming.frame(gzip: gz, noteId: testNote.uuidString.lowercased(), filename: name.filename,
                                             secret: secret)
                try AgeFile.encrypt(body, to: [id.recipient]).write(to: file)
                let loaded = try vault.loadNote(testNote)
                _ = vault.summary(of: testNote, loaded: loaded)
                _ = loaded.restorePoints
                _ = loaded.history
                _ = try? vault.nextSeq(noteId: testNote, device: devC)
                _ = try? vault.reconstruct(loaded)
                _ = loaded.compactionPlan(retention: 0, now: Self.wall, assumingSnapshot: true)
                _ = vault.verify()
                if let p = Self.exercise(loaded.revisions) { throw Invariant(p) }
            }
        })
    }

    // MARK: Adversarial log generator

    static func adversarialLog(_ rng: inout FuzzRNG) -> [Revision] {
        let pages = (0..<4).map { UUID(uuidString: "7e57c0de-0000-4000-8000-00000000000\($0)")! }
        let strokes = (0..<8).map { UUID(uuidString: "7e57c0de-0000-4000-8000-0000000001\(String(format: "%02d", $0))")! }
        let devices = [devA, devB, devC]
        let orders = ["a", "b", "", "Z", "a0", "zzzz", "\u{0}", "é", "a/b"]
        var seqs: [DeviceID: Int] = [:]
        var out: [Revision] = []
        let count = 1 + rng.below(12)
        for k in 0..<count {
            let dev = rng.pick(devices)
            var seq = (seqs[dev] ?? 0) + 1
            if rng.oneIn(6) { seq = rng.pick([1, 2, RevisionName.maxSeq, RevisionName.maxSeq - 1, seq + 1000]) }
            seqs[dev] = min(seq, RevisionName.maxSeq - 1)
            let hlc = HLC(millis: rng.oneIn(8) ? HLC.maxMillis : baseMillis + Int64(rng.below(1000)),
                          counter: rng.oneIn(8) ? HLC.maxCounter : rng.below(3))!
            var ops: [Op] = []
            let n = rng.oneIn(20) ? 300 + rng.below(700) : rng.below(8)
            for _ in 0..<n {
                let p = rng.pick(pages), s = rng.pick(strokes)
                switch rng.below(10) {
                case 0: ops.append(.addPage(Page(id: p, order: rng.pick(orders), parent: rng.oneIn(2) ? rng.pick(pages) : nil)))
                case 1: ops.append(.removePage(pageId: p))
                case 2, 3:
                    let len = rng.oneIn(200) ? 5000 : 1 + rng.below(6)
                    ops.append(.addStroke(page: p, stroke: richStroke(s, len, parent: rng.oneIn(3) ? rng.pick(strokes) : nil)))
                case 4: ops.append(.removeStroke(page: p, strokeId: s))
                case 5: ops.append(.setPageOrder(pageId: p, order: rng.pick(orders)))
                case 6: ops.append(.setPageRecognition(pageId: p, recognition: rng.oneIn(2) ? nil
                                                       : Recognition(engine: "x", text: "t")))
                case 7: ops.append(.setMeta(rng.pick([.title("t"), .tags(["x", "x"]), .notebook("a//b/"), .favorite(true),
                                                      .paper(Paper(kind: .dot, spacing: 0.001)),
                                                      .pageSize(PageSize(width: 1e300, height: -1, infinite: true))])))
                case 8: ops.append(rng.oneIn(2) ? .deleteNote : .restoreNote)
                default: ops.append(.addPage(Page(id: UUID(), order: "p\(k)")))
                }
            }
            let body: Revision.Body
            if rng.oneIn(3) {
                var included = Included()
                for d in devices where rng.oneIn(2) {
                    let up = rng.pick([0, 1, 3, RevisionName.maxSeq, RevisionName.maxSeq - 1])
                    let extra = (0..<rng.below(4)).map { _ in rng.pick([2, 5, 9, RevisionName.maxSeq, 100_000]) }
                    included = included.union(Included([d: .init(upTo: up, extra: extra)]))
                }
                let pageList = (0..<(rng.oneIn(20) ? 2000 : rng.below(4))).map { i in
                    Page(id: i < pages.count ? pages[i] : UUID(), order: rng.pick(orders),
                         strokes: rng.oneIn(2) ? [richStroke(rng.pick(strokes), 3)] : [],
                         orderClock: rng.oneIn(2) ? "\(hlc)-\(dev)" : rng.pick(["garbage", "99999999999999999-ffffffff"]),
                         origin: rng.pick([nil, "\(hlc)-\(dev)-1-0", "\(hlc)-\(dev)-\(RevisionName.maxSeq)-9223372036854775807",
                                           "x"]),
                         recognitionClock: rng.oneIn(3) ? "00000000000000000-00000000" : nil)
                }
                let state = NoteState(deleted: rng.oneIn(2), meta: NoteMeta(created: wall), pages: pageList,
                                      clocks: rng.oneIn(2) ? ["title": "99999999999999999-ffffffff", "bogus": "x"] : nil,
                                      tombstones: rng.oneIn(2) ? Tombstones(strokes: strokes, pages: [pages[0]]) : nil)
                body = .snapshot(included: included, state: state)
            } else {
                body = .delta(ops: ops)
            }
            out.append(Revision(noteId: testNote, device: dev, seq: seq, hlc: hlc,
                                wall: rng.oneIn(5) ? .distantFuture : wall, app: "fuzz", body: body))
            if rng.oneIn(40), let last = out.last {
                var dup = last
                dup.app = "conflicting copy"
                out.append(dup)
            }
        }
        return out
    }
}
