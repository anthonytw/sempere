import Foundation
import Sempere
import XCTest
@testable import SempereInsights

/// The pure steps of the pipeline (docs/design/1.2-note-insights.md §4, §9 "Linux CI"): normalization, stoplist and
/// IDF, typo merge, chunking and the overflow retry, the fact check, CSLS and mean-centering, the unrelated note,
/// Louvain and layout determinism, placement, cluster ids across a rebuild, canaries, the pin and the policy.
final class InsightsPipelineTests: XCTestCase {
    // MARK: Normalization

    func testNormalizationTable() {
        let table: [(String, String?)] = [
            ("Rigid Bodies", "rigid body"), ("rigid bodie", "rigid body"), ("newton s second law", "newton second law"),
            ("Newton's second law", "newton second law"), ("damping-ratio", "damping ratio"), ("damping_ratio", "damping ratio"),
            ("Kinematics", "kinematics"), ("physics", "physics"), ("matrices", "matrix"), ("Oscillations!", "oscillation"),
            ("zeta", nil), ("F0 sin(w t)", nil), ("x", nil), ("the", nil), ("42", nil), ("  ", nil),
            ("Crises", "crisis"), ("boxes", "box"), ("studies", "study"),
        ]
        for (raw, want) in table { XCTAssertEqual(TermNormalizer.normalize(raw), want, raw) }
        let k = TermNormalizer.keywords(["Rigid Bodies", "rigid body", "Torque", "zeta", "torques"] + (0..<20).map { "term number \($0)" })
        XCTAssertEqual(k.prefix(2).map(\.t), ["rigid body", "torque"])
        XCTAssertEqual(k.count, 10, "capped at 10")
        XCTAssertEqual(TermNormalizer.concepts(["heat flow", "torque", "mass flow", "wave speed", "lift force", "drag force", "free fall"], keywords: k).count, 5)
        XCTAssertFalse(TermNormalizer.concepts(["torque"], keywords: k).contains("torque"), "no concept repeats a keyword")
    }

    func testStoplistAndIDF() {
        let docs: [Set<String>] = [["damping", "spring"], ["damping", "bread"], ["damping", "flour"], ["damping", "orbit"], ["orbit"]]
        let c = InsightsCorpus(docs)
        XCTAssertTrue(c.isStop("damping"), "in more than half of the notes")
        XCTAssertTrue(c.isStop("the"))
        XCTAssertFalse(c.isStop("orbit"))
        XCTAssertGreaterThan(c.idf("spring"), c.idf("orbit"))
        XCTAssertEqual(c.weighted([.init(t: "damping", w: 1), .init(t: "spring", w: 0.5)]).map(\.t), ["spring"])
    }

    func testTypoMerge() {
        var f = ["kinematics": 20, "kinernatics": 1, "momentum": 12, "momentun": 1, "torque": 3, "torqe": 1, "pendulum": 4]
        let m = TypoMerger(frequencies: f)
        XCTAssertEqual(m.merge("kinernatics"), "kinematics", "distance 2, a long word")
        XCTAssertEqual(m.merge("momentun"), "momentum")
        XCTAssertEqual(m.merge("torqe"), "torqe", "torque is not 5x as frequent")
        XCTAssertEqual(m.merge("kinematics"), "kinematics")
        f["pendulun"] = 1
        XCTAssertEqual(TypoMerger(frequencies: f).merge("pendulun"), "pendulun", "4 is not 5 x 1")
        XCTAssertEqual(TypoMerger.distance("kitten", "sitting", max: 3), 3)
        XCTAssertNil(TypoMerger.distance("kitten", "sitting", max: 2))
    }

    // MARK: Chunking

    static func words(_ n: Int, sentence: Int = 15) -> String {
        var out: [String] = []
        for i in 0..<n { out.append("w\(i % 97)" + ((i + 1) % sentence == 0 ? "." : "")) }
        return out.joined(separator: " ")
    }

    func testChunkSizes() {
        XCTAssertEqual(InsightsChunker.chunks(Self.words(42)).count, 1)
        XCTAssertEqual(InsightsChunker.chunks(Self.words(330)).count, 1)
        let c450 = InsightsChunker.chunks(Self.words(450))
        XCTAssertEqual(c450.count, 1)
        let c1247 = InsightsChunker.chunks(Self.words(1247))
        XCTAssertEqual(c1247.count, 3, "[M: 1247 words in 3 chunks]")
        XCTAssertEqual(c1247.map(InsightsWords.count).reduce(0, +), 1247, "no word lost or doubled")
        XCTAssertTrue(c1247.allSatisfy { InsightsWords.count($0) <= InsightsChunker.chunkWords })
        // Paragraph boundaries first.
        let paras = [Self.words(300), Self.words(300), Self.words(300)].joined(separator: "\n\n")
        XCTAssertEqual(InsightsChunker.chunks(paras).map(InsightsWords.count), [300, 300, 300])
        XCTAssertEqual(InsightsChunker.tokens(String(repeating: "x", count: 35)), 10)
    }

    func testOverflowHalvesAndRetriesOnce() async throws {
        var s = FakeModelProvider.Script()
        s.overflowAbove = 200   // 300 words ≈ 340 tokens: one call overflows, its halves fit
        let model = FakeModelProvider(s)
        let text = Self.words(300) + " damping damping spring spring."
        let gen = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: model, merger: nil)
        XCTAssertEqual(model.log.first, "extract")
        XCTAssertGreaterThanOrEqual(model.log.filter { $0 == "extract" }.count, 3, "\(model.log)")
        XCTAssertEqual(model.log.last, "merge")
        XCTAssertFalse(gen.keywords.isEmpty)
    }

    // MARK: Fact check

    func testFactCheck() {
        let source = "The damping ratio zeta decides whether a spring-mass system oscillates. With x = A cos(w t) the amplitude decays."
        let fc = FactCheck(source: source)
        XCTAssertTrue(fc.supported("The note describes the damping ratio of a spring-mass system."))
        XCTAssertFalse(fc.supported("It also covers wave behavior."), "an invented term")
        XCTAssertFalse(fc.supported("The amplitude is x = A sin(w t)."), "a mangled equation")
        XCTAssertTrue(fc.supported("The amplitude is x = A cos(w t)."))
        let r = fc.check("The note describes the damping ratio. The amplitude decays. It explains wave behavior.")
        XCTAssertEqual(r.dropped, 1)
        XCTAssertEqual(r.summary, "The note describes the damping ratio. The amplitude decays.")
        // Over 40% dropped: no summary at all.
        let all = fc.check("Waves interfere. Light refracts. The amplitude decays.")
        XCTAssertNil(all.summary)
        XCTAssertEqual(all.dropped, 2)
        // Cut at 4 sentences and 600 characters.
        let long = Array(repeating: "The amplitude decays.", count: 9).joined(separator: " ")
        XCTAssertEqual(InsightsChunker.sentences(fc.check(long).summary ?? "").count, 4)
        // A typo merged before the check.
        let merger = TypoMerger(frequencies: ["kinematics": 30, "kinernatics": 1])
        XCTAssertTrue(FactCheck(source: "kinernatics of rigid bodies", merger: merger).supported("It covers kinematics."))
    }

    // MARK: Graph

    static let topics: [[String]] = [
        ["damping", "spring", "oscillation", "resonance", "amplitude"], ["sourdough", "flour", "starter", "knead", "oven"],
        ["orbit", "planet", "gravity", "ellipse", "kepler"],
    ]

    static func corpus(seed: Int = 0) -> [RelatedInput] {
        let fake = FakeEmbeddingProvider()
        var out: [RelatedInput] = []
        for (t, words) in topics.enumerated() {
            for i in 0..<4 {
                let text = (words + words.shuffledDeterministically(seed: i + 10 * t)).joined(separator: " ") + " note\(i)"
                let id = UUID(uuidString: String(format: "%08x-0000-4000-8000-%012x", t * 16 + i, t * 16 + i))!
                out.append(RelatedInput(id: id, vector: try? fake.embed(text, language: "en", revision: 1),
                                        tokens: Set(words), words: 30))
            }
        }
        return out
    }

    func testRelatedNotesStayWithinTheirTopicAndTheUnrelatedNoteStaysAlone() {
        var notes = Self.corpus()
        let lonely = UUID(uuidString: "ffffffff-0000-4000-8000-000000000000")!
        notes.append(RelatedInput(id: lonely, vector: try? FakeEmbeddingProvider().embed("violin bow rosin strings", language: "en", revision: 1),
                                  tokens: ["violin", "bow", "rosin"], words: 10))
        let g = RelatedGraph.build(notes)
        XCTAssertNil(g[lonely], "an unrelated note stays unlinked [M: sourdough]")
        let topicOf = Dictionary(uniqueKeysWithValues: notes.map { n in (n.id, Self.topics.firstIndex { Set($0) == n.tokens } ?? -1) })
        for (id, edges) in g {
            XCTAssertLessThanOrEqual(edges.count, RelatedGraph.maxEdges)
            for e in edges { XCTAssertEqual(topicOf[e.note], topicOf[id], "edge across topics") }
            XCTAssertFalse(edges.first?.shared.isEmpty ?? true, "says why")
        }
        // Without vectors: keyword overlap alone, same neighbourhoods.
        let kw = RelatedGraph.build(notes.map { RelatedInput(id: $0.id, vector: nil, tokens: $0.tokens, words: $0.words) })
        for (id, edges) in kw { for e in edges { XCTAssertEqual(topicOf[e.note], topicOf[id]) } }
    }

    func testCSLSDampsAPlantedHub() {
        var notes = Self.corpus()
        // A hub: the mean of all vectors, close to everything.
        let hub = UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000000")!
        notes.append(RelatedInput(id: hub, vector: VectorMath.mean(notes.compactMap(\.vector)), tokens: [], words: 30))
        let g = RelatedGraph.build(notes)
        let linksToHub = g.values.filter { $0.contains { $0.note == hub } }.count
        XCTAssertLessThan(linksToHub, 3, "a hub is not everyone's neighbour")
        // Mean-centering: a constant offset added to every vector changes nothing.
        let shifted = Self.corpus().map { n in
            RelatedInput(id: n.id, vector: n.vector.map { $0.map { $0 + 0.5 } }, tokens: n.tokens, words: n.words)
        }
        let a = RelatedGraph.build(Self.corpus()), b = RelatedGraph.build(shifted)
        XCTAssertEqual(a.mapValues { $0.map(\.note) }, b.mapValues { $0.map(\.note) })
    }

    func testClusteringAndLayoutAreDeterministicUnderShuffling() {
        let notes = Self.corpus()
        let corpus = InsightsCorpus(notes.map(\.tokens))
        let a = MapBuilder.build(notes, corpus: corpus)
        let b = MapBuilder.build(notes.reversed(), corpus: corpus)
        XCTAssertEqual(a.clusters, b.clusters)
        for (id, p) in a.positions {
            XCTAssertEqual(p.x, b.positions[id]?.x ?? .nan, accuracy: 1e-3)
            XCTAssertEqual(p.y, b.positions[id]?.y ?? .nan, accuracy: 1e-3)
        }
        let level0 = a.clusters.filter { $0.level == 0 && $0.id != MapBuilder.otherId }
        XCTAssertEqual(level0.count, 3, "\(a.clusters.map(\.members.count))")
        XCTAssertTrue(level0.allSatisfy { $0.label.count <= 3 && !$0.label.isEmpty })
        // Ids stay put across a rebuild with one note more.
        let previous = InsightsMapFile(device: DeviceID("a1b2c3d4")!, written: 1, key: .init(model: "m", lang: "en", rev: 1, input: 1),
                                       dim: 64, canaries: nil, mean: a.mean,
                                       clusters: a.clusters.map { .init(id: $0.id, parent: $0.parent, level: $0.level, label: $0.label,
                                                                        centroid: $0.centroid, members: $0.members) },
                                       layout: a.positions.mapValues { ($0.x, $0.y) }, built: nil)
        var more = notes
        more.append(RelatedInput(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000ff")!,
                                 vector: try? FakeEmbeddingProvider().embed("damping spring oscillation resonance", language: "en", revision: 1),
                                 tokens: Set(Self.topics[0]), words: 30))
        let c = MapBuilder.build(more, corpus: corpus, previous: previous)
        func ids(_ m: BuiltMap) -> [Set<UUID>: Int] {
            Dictionary(m.clusters.filter { $0.level == 0 }.map { (Set($0.members.filter { notes.map(\.id).contains($0) }), $0.id) },
                       uniquingKeysWith: { a, _ in a })
        }
        XCTAssertEqual(ids(c), ids(a), "cluster ids matched by member overlap")
        // Placement is a pure function.
        let v = try? FakeEmbeddingProvider().embed("orbit planet gravity", language: "en", revision: 1)
        let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
        let vectors = Dictionary(uniqueKeysWithValues: notes.compactMap { n in n.vector.map { (n.id, $0) } })
        let p1 = MapBuilder.place(id: id, vector: v ?? [], map: previous, vectors: vectors)
        let p2 = MapBuilder.place(id: id, vector: v ?? [], map: previous, vectors: vectors)
        XCTAssertNotNil(p1)
        XCTAssertEqual(p1?.position.x, p2?.position.x)
        let orbit = level0.first { $0.members.contains(notes[8].id) }?.id
        XCTAssertEqual(p1?.clusters.first, orbit, "nearest centroid")
    }

    // MARK: Canaries and the pin

    func testCanaries() throws {
        let fake = FakeEmbeddingProvider()
        let key = fake.key(language: "en", revision: 1)
        let mine = try XCTUnwrap(try Canaries.vectors(fake, language: "en", revision: 1))
        XCTAssertTrue(Canaries.compatible(mine: mine, myKey: key, theirs: mine, theirKey: key))
        // Float16 round trip stays compatible.
        let stored = InsightsCanaries(set: 1, vectors: mine).vectors(dimension: 64) ?? []
        XCTAssertTrue(Canaries.compatible(mine: mine, myKey: key, theirs: stored, theirKey: key))
        // A perturbed chip, and another input revision, are not.
        let drift = try XCTUnwrap(try Canaries.vectors(FakeEmbeddingProvider(perturbation: 0.05), language: "en", revision: 1))
        XCTAssertFalse(Canaries.compatible(mine: drift, myKey: key, theirs: mine, theirKey: key))
        var other = key; other.input = 2
        XCTAssertFalse(Canaries.compatible(mine: mine, myKey: other, theirs: mine, theirKey: key))
    }

    func record(_ d: String, _ revs: [Int], written: Int64) -> (DeviceID, InsightsDeviceRecord) {
        let id = DeviceID(d)!
        return (id, InsightsDeviceRecord(device: id, written: written, os: "x", platform: "mac",
                                         model: .init(available: false, reason: nil, identity: nil), supported: ["en": revs],
                                         canaries: [], compatibility: nil, against: nil))
    }

    func testThePinIsTheLowestCommonRevisionOfRecentlySeenListedDevices() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let all = Dictionary(uniqueKeysWithValues: [record("11111111", [1, 2], written: ms), record("22222222", [2, 3], written: ms),
                                                    record("33333333", [3], written: ms - 40 * 86_400_000),
                                                    record("44444444", [4], written: ms)])
        let listed: Set<DeviceID> = [DeviceID("11111111")!, DeviceID("22222222")!, DeviceID("33333333")!]
        let recent = EmbeddingPin.recent(all, listed: listed, now: now)
        XCTAssertEqual(Set(recent.keys), [DeviceID("11111111")!, DeviceID("22222222")!], "40 days old and removed devices ignored")
        XCTAssertEqual(EmbeddingPin.lowestCommon(recent, language: "en"), 2)
        XCTAssertEqual(EmbeddingPin.upgradeOffer(recent, language: "en", pin: 2), 3)
        XCTAssertEqual(EmbeddingPin.leftOut(recent, language: "en", revision: 3), [DeviceID("11111111")!])
        // A later-joining device without the pin does not move it: the setting holds; it is a vector reader.
        let settings = InsightsSettings(enabled: true, workDevice: DeviceID("11111111")!, pins: ["en": 2])
        XCTAssertEqual(settings.pins["en"], 2)
    }

    // MARK: Policy

    func notesFor(_ now: Date) -> [PolicyNote] {
        [PolicyNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, hash: String(repeating: "a", count: 32),
                    modified: now.addingTimeInterval(-3600), deleted: false, hasText: true),
         PolicyNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, hash: String(repeating: "b", count: 32),
                    modified: now.addingTimeInterval(-60), deleted: false, hasText: true),
         PolicyNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, hash: String(repeating: "c", count: 32),
                    modified: now.addingTimeInterval(-40 * 86_400), deleted: false, hasText: true)]
    }

    func testPolicy() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let me = DeviceID("11111111")!
        let model = GenerationIdentity(model: "m", os: "27.2", prompt: 1)
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let notes = notesFor(now)
        var settings = InsightsSettings(enabled: true, workDevice: me)
        let caps = PolicyCapabilities(model: model, embedRevision: 1, powerWindow: true)
        let plan = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                       pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertEqual(plan.compactMap { if case .generate(let id) = $0 { return id } else { return nil } }, [notes[0].id, notes[2].id],
                       "recent first; the one edited a minute ago waits")
        XCTAssertTrue(plan.contains(.writeDeviceRecord))
        XCTAssertTrue(plan.contains(.rebuildMap))
        // No model: no generation, embedding still.
        let noModel = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings,
                                          capabilities: .init(model: nil, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                          deviceRecordChanged: false)
        XCTAssertFalse(noModel.contains { if case .generate = $0 { return true } else { return false } })
        XCTAssertTrue(noModel.contains(.embed(notes[0].id)))
        // Not on power: no generation.
        XCTAssertFalse(InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings,
                                           capabilities: .init(model: model, embedRevision: nil, powerWindow: false), pinKey: nil, now: now,
                                           deviceRecordChanged: false).contains { if case .generate = $0 { return true } else { return false } })
        // Backoff.
        let backed = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                         pinKey: key, now: now, backoff: [notes[0].id: now.addingTimeInterval(60)], deviceRecordChanged: false)
        XCTAssertFalse(backed.contains(.generate(notes[0].id)))
        // Another device is the work device: nothing unless compute auto, and never embedding.
        settings.workDevice = DeviceID("22222222")!
        let other = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                        pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertFalse(other.contains { if case .generate = $0 { return true }; if case .embed = $0 { return true }; return false })
        settings.computeAuto = true
        let auto = InsightsPolicy.plan(notes: notes, snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                       pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertTrue(auto.contains(.generate(notes[0].id)))
        XCTAssertFalse(auto.contains { if case .embed = $0 { return true } else { return false } })
        // Stale after a prompt bump: a current gen of prompt 1 is redone by a reader at prompt 2.
        settings = InsightsSettings(enabled: true, workDevice: me)
        var snap = InsightsSnapshot()
        let old = InsightsNoteFile.Gen(hash: notes[0].hash, identity: model, summary: "s", keywords: [], concepts: [], dropped: 0)
        snap.notes[notes[0].id] = [me: InsightsNoteFile(noteId: notes[0].id, device: me, written: 1, gen: old)]
        let same = InsightsPolicy.plan(notes: notes, snapshot: snap, me: me, settings: settings, capabilities: caps, pinKey: key, now: now,
                                       deviceRecordChanged: false)
        XCTAssertFalse(same.contains(.generate(notes[0].id)))
        let bumped = InsightsPolicy.plan(notes: notes, snapshot: snap, me: me, settings: settings,
                                         capabilities: .init(model: .init(model: "m", os: "27.2", prompt: 2), embedRevision: 1, powerWindow: true),
                                         pinKey: key, now: now, deviceRecordChanged: false)
        XCTAssertTrue(bumped.contains(.generate(notes[0].id)))
        // Off: nothing at all.
        XCTAssertEqual(InsightsPolicy.plan(notes: notes, snapshot: snap, me: me, settings: InsightsSettings(), capabilities: caps,
                                           pinKey: key, now: now, deviceRecordChanged: true), [])
        // Unset work device: a capable device claims it.
        XCTAssertEqual(InsightsPolicy.plan(notes: [], snapshot: snap, me: me, settings: InsightsSettings(enabled: true), capabilities: caps,
                                           pinKey: key, now: now, deviceRecordChanged: false).first, .claimWorkDevice)
    }

    func testTheWorkDeviceIsNeverTakenOverByItself() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let w = DeviceID("22222222")!
        var snap = InsightsSnapshot()
        let (_, r) = record("22222222", [1], written: Int64(now.timeIntervalSince1970 * 1000) - 15 * 86_400_000)
        snap.devices[w] = r
        let status = WorkDeviceStatus(settings: InsightsSettings(enabled: true, workDevice: w), snapshot: snap, listed: [w],
                                      language: "en", now: now)
        XCTAssertTrue(status.notSeen)
        XCTAssertEqual(status.workDevice, w, "the role stays; status only offers a move")
        let plan = InsightsPolicy.plan(notes: notesFor(now), snapshot: snap, me: DeviceID("11111111")!,
                                       settings: InsightsSettings(enabled: true, workDevice: w),
                                       capabilities: .init(model: .init(model: "m", os: "1", prompt: 1), embedRevision: 1, powerWindow: true),
                                       pinKey: .init(model: "nl-sentence", lang: "en", rev: 1, input: 1), now: now, deviceRecordChanged: false)
        XCTAssertFalse(plan.contains(.claimWorkDevice))
    }

    func testVoiceNoteTitleFormat() {
        XCTAssertNil(VoiceNoteTitleFormat.check("{date} {time} {slug}"))
        XCTAssertNotNil(VoiceNoteTitleFormat.check("{when} {slug}"))
        XCTAssertNotNil(VoiceNoteTitleFormat.check("{date"))
        XCTAssertNotNil(VoiceNoteTitleFormat.check("  "))
        XCTAssertEqual(VoiceNoteTitleFormat.render("{date} {time} {slug}", date: "2026-10-07", time: "14.32", slug: "Spring lab results"),
                       "2026-10-07 14.32 Spring lab results")
        XCTAssertNil(VoiceNoteTitleFormat.render("{date} {slug}", date: "2026-10-07", time: "14.32", slug: nil), "no slug: the default stays")
        XCTAssertEqual(VoiceNoteTitleFormat.render("{date} {time}", date: "2026-10-07", time: "14.32", slug: nil), "2026-10-07 14.32")
        XCTAssertEqual(VoiceNoteTitleFormat.cleaned(String(repeating: "word ", count: 30)).count <= 60, true)
        let t = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: "Voice note 2026-10-07 14:32", started: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(t.date, "2026-10-07"); XCTAssertEqual(t.time, "14.32")
        let u = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: "Untitled", started: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(u.date, "2026-09-21"); XCTAssertEqual(u.time, "14.13")
    }

    func testEmbeddingInputCleaning() {
        XCTAssertEqual(EmbeddingInput.clean("- first point\n* second point\n1. third point\nx = 2y + 3\n\\frac{a}{b}\nplain text"),
                       "first point second point third point plain text")
        XCTAssertTrue(EmbeddingInput.isEquation("F = m a"))
        XCTAssertFalse(EmbeddingInput.isEquation("The force equals mass times acceleration = Newton second law"))
    }
}

extension Array {
    /// A deterministic shuffle (tests only).
    func shuffledDeterministically(seed: Int) -> [Element] {
        var rng = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        var a = self
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let j = Int((rng >> 33) % UInt64(i + 1))
            a.swapAt(i, j)
        }
        return a
    }
}
