import Age
import Foundation
@testable import Sempere

/// Deterministic generator (SplitMix64), so synthetic vaults are the same on every run.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Synthetic vaults for the summary benchmark and property tests. Content is
/// made up (titles like "Note 12"), never personal data.
enum SyntheticVault {
    static let devices = [DeviceID("5e5e0001")!, DeviceID("5e5e0002")!, DeviceID("5e5e0003")!]

    /// A wavy stroke of `n` points: a random walk, so gzip sees realistic numbers.
    static func stroke(_ rng: inout SeededRNG, points n: Int) -> Stroke {
        var x = Double.random(in: 20...580, using: &rng), y = Double.random(in: 20...760, using: &rng)
        var pts: [StrokePoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            x += Double.random(in: -3...3, using: &rng); y += Double.random(in: -3...3, using: &rng)
            pts.append(StrokePoint(x: InkJSON.round3(x), y: InkJSON.round3(y), t: InkJSON.round3(Double(i) * 0.008),
                                   w: InkJSON.round3(Double.random(in: 1.5...3, using: &rng)),
                                   h: InkJSON.round3(Double.random(in: 1.5...3, using: &rng)), o: 1,
                                   f: InkJSON.round3(Double.random(in: 0...1, using: &rng)),
                                   az: InkJSON.round3(Double.random(in: 0...6, using: &rng)),
                                   al: InkJSON.round3(Double.random(in: 0.5...1.5, using: &rng))))
        }
        let tools: [InkTool] = [.pen, .pencil, .marker, .monoline]
        return Stroke(id: UUID.random(&rng), ink: Ink(tool: tools[Int(rng.next() % 4)], color: .black, width: 2),
                      points: pts)
    }

    /// One note as a single delta, the way the importer writes them: pages,
    /// title, notebook, tags, `strokes` strokes of `points` points, and
    /// recognized text on the first page of every third note.
    static func importedNote(index: Int, strokes: Int, points: Int, rng: inout SeededRNG, baseMillis: Int64)
        -> Revision {
        let note = UUID.random(&rng)
        let pageCount = 1 + index % 3
        var ops: [Op] = [.setMeta(.title("Note \(index)")), .setMeta(.notebook("Course \(index % 7)/Unit \(index % 3)"))]
        var pages: [UUID] = []
        for p in 0..<pageCount {
            let id = UUID.random(&rng)
            pages.append(id)
            ops.append(.addPage(Page(id: id, order: "a\(p)")))
        }
        ops.append(.addTag("tag\(index % 5)"))
        if index % 4 == 0 { ops.append(.addTag("Tag\(index % 5 + 1)")) }
        for s in 0..<strokes { ops.append(.addStroke(page: pages[s % pageCount], stroke: stroke(&rng, points: points))) }
        if index % 3 == 0 {
            ops.append(.setPageRecognition(pageId: pages[0], recognition: Recognition(
                engine: "synthetic-1", text: "words of note \(index)",
                words: [.init(text: "words", box: .init(x: 1, y: 2, w: 30, h: 10))])))
        }
        let ms = baseMillis + Int64(index) * 60_000
        return Revision(noteId: note, device: devices[index % devices.count], seq: 1,
                        hlc: HLC(millis: ms, counter: 0)!, wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                        app: "synthetic/1", body: .delta(ops: ops))
    }

    /// Writes `notes` imported-style notes into `vault`.
    static func populate(_ vault: Vault, notes: Int, strokes: Int, points: Int, seed: UInt64 = 1) throws {
        var rng = SeededRNG(seed)
        for i in 0..<notes {
            try vault.write(importedNote(index: i, strokes: strokes, points: points, rng: &rng,
                                         baseMillis: 1_780_000_000_000))
        }
    }

    /// A random edit history for one note: several devices, deltas with every
    /// op kind (adds, removes, page order, recognition, paper, title, notebook,
    /// tags added and removed, delete/restore), concurrent
    /// stamps, sometimes a snapshot in the middle, sometimes an orphan.
    static func randomHistory(note: UUID, rng: inout SeededRNG) throws -> [Revision] {
        var revs: [Revision] = []
        var seqs: [DeviceID: Int] = [:]
        var pages: [UUID] = []
        var strokes: [(page: UUID, id: UUID)] = []
        var tagOrigins: [String: [Origin]] = [:]
        let count = 1 + Int(rng.next() % 9)
        var ms: Int64 = 1_780_000_000_000
        for r in 0..<count {
            let dev = devices[Int(rng.next() % UInt64(devices.count))]
            let seq = (seqs[dev] ?? 0) + 1
            seqs[dev] = seq
            // Some revisions share a millisecond: concurrent writers.
            if rng.next() % 3 != 0 { ms += Int64(rng.next() % 5_000) }
            let hlc = HLC(millis: ms, counter: Int(rng.next() % 2))!
            let name = RevisionName(hlc: hlc, device: dev, seq: seq, kind: .delta)
            if r > 1, rng.next() % 5 == 0 {
                var clock = HybridClock()
                let snap = try SnapshotBuilder.makeSnapshot(from: revs, device: dev, seq: seq, clock: &clock,
                                                            wall: Date(timeIntervalSince1970: Double(ms) / 1000),
                                                            app: "synthetic/1")
                revs.append(snap)
                continue
            }
            var ops: [Op] = []
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                switch rng.next() % 16 {
                case 0, 1:
                    let id = UUID.random(&rng)
                    pages.append(id)
                    ops.append(.addPage(Page(id: id, order: "a\(rng.next() % 10)")))
                case 2, 3, 4, 5:
                    // Sometimes a page nobody has seen: an orphan.
                    let page = pages.isEmpty || rng.next() % 10 == 0 ? UUID.random(&rng)
                        : pages[Int(rng.next() % UInt64(pages.count))]
                    let s = stroke(&rng, points: 2 + Int(rng.next() % 6))
                    strokes.append((page, s.id))
                    ops.append(.addStroke(page: page, stroke: s))
                case 6:
                    if let s = strokes.randomElement(using: &rng) { ops.append(.removeStroke(page: s.page, strokeId: s.id)) }
                case 7:
                    if let p = pages.randomElement(using: &rng), rng.next() % 3 == 0 { ops.append(.removePage(pageId: p)) }
                case 8:
                    if let p = pages.randomElement(using: &rng) { ops.append(.setPageOrder(pageId: p, order: "b\(rng.next() % 10)")) }
                case 9:
                    if let p = pages.randomElement(using: &rng) {
                        let text = rng.next() % 4 == 0 ? "" : "text \(rng.next() % 100)"
                        ops.append(.setPageRecognition(pageId: p, recognition: rng.next() % 5 == 0 ? nil
                                                       : Recognition(engine: "e", text: text)))
                    }
                case 10: ops.append(.setMeta(.title("Title \(rng.next() % 50)")))
                case 11: ops.append(.setMeta(.notebook(rng.next() % 4 == 0 ? nil : "NB \(rng.next() % 3)/Sub")))
                case 12:
                    let tag = ["math", "Math", "physics", "todo"][Int(rng.next() % 4)]
                    tagOrigins[NoteOps.tagKey(tag), default: []].append(Origin(name, op: ops.count))
                    ops.append(.addTag(tag))
                case 13:
                    if let (key, origins) = tagOrigins.randomElement(using: &rng) {
                        ops.append(.removeTag(key, observed: origins))
                    }
                case 14:
                    if rng.next() % 4 == 0 { ops.append(.setMeta(.notebook(["A", "B", nil][Int(rng.next() % 3)]))) }
                default:
                    ops.append(rng.next() % 2 == 0 ? .deleteNote : .restoreNote)
                }
            }
            if ops.isEmpty { ops = [.setMeta(.favorite(true))] }
            revs.append(Revision(noteId: note, device: dev, seq: seq, hlc: hlc,
                                 wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "synthetic/1",
                                 body: .delta(ops: ops)))
        }
        return revs
    }
}

extension UUID {
    static func random(_ rng: inout SeededRNG) -> UUID {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8(truncatingIfNeeded: rng.next()) }
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension SyntheticVault {
    /// A note as a mass re-import leaves it (`import notability --overwrite`):
    /// the first import, then a second delta from the same device that removes
    /// every page and adds the note again. With `withoutCheckpoints` both are
    /// plain autosaves dated by the note's creation date (valid revisions
    /// with no session or checkpoint); otherwise both are checkpoints and the
    /// second has its own `wall`.
    static func reimportedNote(index: Int, strokes: Int, points: Int, rng: inout SeededRNG, baseMillis: Int64,
                               reimportMillis: Int64, withoutCheckpoints: Bool) -> [Revision] {
        var first = importedNote(index: index, strokes: strokes, points: points, rng: &rng, baseMillis: baseMillis)
        var again = importedNote(index: index, strokes: strokes, points: points, rng: &rng, baseMillis: baseMillis)
        guard case .delta(let firstOps) = first.body, case .delta(let againOps) = again.body else { return [first] }
        var ops: [Op] = []
        for case .addPage(let p) in firstOps { ops.append(.removePage(pageId: p.id)) }
        ops += againOps
        again.noteId = first.noteId
        again.device = first.device
        again.seq = 2
        again.hlc = HLC(millis: reimportMillis + Int64(index), counter: 0)!
        again.body = .delta(ops: ops)
        if !withoutCheckpoints {
            first.checkpoint = Checkpoint(name: "Imported from Notability")
            again.checkpoint = Checkpoint(name: "Imported from Notability")
            again.wall = Date(timeIntervalSince1970: Double(reimportMillis) / 1000)
        }
        return [first, again]
    }
}
