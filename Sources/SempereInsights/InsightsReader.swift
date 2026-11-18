import Foundation
import Sempere

// MARK: - Reading insights (docs/design/1.2-note-insights.md §3.8, §6, §7; `sempere insights show|related|search|status|map`)
//
// What every device shows from the vault's files: a note's best `gen`, the related notes from the compatible vector set
// (the vectors whose key equals the best map's, from any device, plus notes this device places itself when it is compatible
// and has an embedder; keyword overlap alone without vectors), insights search, the per-device status and the map.

public struct InsightsReader: Sendable {
    public let vault: Vault
    public let snapshot: InsightsSnapshot
    public let settings: InsightsSettings

    public init(vault: Vault, snapshot: InsightsSnapshot, settings: InsightsSettings) {
        self.vault = vault; self.snapshot = snapshot; self.settings = settings
    }

    public init(vault: Vault) {
        self.init(vault: vault, snapshot: InsightsStore(vault: vault).snapshot(), settings: InsightsSettings.read(vault))
    }

    /// Display names of the vault's devices by id.
    public var deviceNames: [String: String] {
        var out: [String: String] = [:]
        for d in vault.manifest.devices { if let id = d.id { out[id] = d.name } }
        return out
    }

    // MARK: show

    public struct Shown: Hashable, Sendable, Codable {
        public var note: String
        public var title: String
        public var state: String
        public var summary: String?
        public var keywords: [InsightsKeyword]
        public var concepts: [String]
        public var device: String?
        public var deviceName: String?
        public var written: Date?
        public var model: String?
        public var os: String?
        public var prompt: Int?
        public var dropped: Int?
        public var slug: String?
        public var embedded: Bool
        public var embeddingKey: String?
    }

    /// The note's insights: `current` (its text's hash), `stale` (an older text or model), `missing` or `deleted`.
    public func show(_ note: InsightsNoteInput, reader: GenerationIdentity? = nil) -> Shown {
        let best = snapshot.bestGen(for: note.id, hash: note.hash)
        let staleModel = best.map { b in reader.map { !b.gen.identity.isCurrent(for: $0) } ?? false } ?? false
        let state = note.deleted ? "deleted" : best == nil ? "missing" : (best?.current == true && !staleModel ? "current" : "stale")
        let emb = snapshot.emb(for: note.id, key: snapshot.bestMap(rev: nil)?.map.key, hash: note.hash)?.emb
        return Shown(note: note.id.uuidString.lowercased(), title: note.title, state: state, summary: best?.gen.summary,
                     keywords: best?.gen.keywords ?? [], concepts: best?.gen.concepts ?? [], device: best?.device.rawValue,
                     deviceName: best.flatMap { deviceNames[$0.device.rawValue] },
                     written: best.map { Date(timeIntervalSince1970: Double($0.written) / 1000) }, model: best?.gen.model,
                     os: best?.gen.os, prompt: best?.gen.prompt, dropped: best?.gen.dropped, slug: best?.gen.slug,
                     embedded: emb?.hash == note.hash, embeddingKey: emb?.key.description)
    }

    // MARK: Compatibility

    /// The map this device shows (D21: the best of any device's, `InsightsSnapshot.bestMap`), at the pinned revision of
    /// `language` when one is.
    func sharedMap(language: String) -> (map: InsightsMapFile, device: DeviceID)? { snapshot.bestMap(rev: settings.pins[language], language: language) }

    /// How this device stands to the shared map (design §3.8).
    public func compatibility(me: DeviceID?, embedder: (any EmbeddingProvider)?, language: String) -> MapCompatibility {
        guard let (map, builder) = sharedMap(language: language), let key = map.key else { return .noMap }
        // The device that built the map holds the vectors it was built from.
        if let me, me == builder { return .compatible }
        guard let embedder, embedder.supportedRevisions(language: key.lang).contains(key.rev) else { return .vectorReader }
        let mine = embedder.key(language: key.lang, revision: key.rev)
        guard let dim = map.dim, let theirs = map.canaries?.vectors(dimension: dim),
              let own = try? Canaries.vectors(embedder, language: key.lang, revision: key.rev) else { return .incompatible }
        return Canaries.compatible(mine: own, myKey: mine, theirs: theirs, theirKey: key) ? .compatible : .incompatible
    }

    // MARK: related

    public struct Related: Hashable, Sendable, Codable {
        public var note: String
        public var title: String
        public var score: Double
        public var csls: Double?
        public var keywordOverlap: Double
        public var why: String
        public var shared: [String]
        /// The note's vector was made on this device (placed), not taken from the vault.
        public var placed: Bool
    }

    public struct RelatedResult: Hashable, Sendable, Codable {
        /// `vectors` (the shared set, maybe with placed notes), `local` (an incompatible device's own set) or
        /// `keywords` (no vectors).
        public var basis: String
        public var compatibility: String
        public var related: [Related]
    }

    /// A compatible vector set as `vectorSet` gives it.
    public typealias VectorSet = (vectors: [UUID: [Float]], placed: Set<UUID>, basis: String, compatibility: MapCompatibility)

    /// The vectors of the compatible set (design §3.8), with the ids embedded on this device.
    public func vectorSet(inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?,
                          language: String) -> (vectors: [UUID: [Float]], placed: Set<UUID>, basis: String, compatibility: MapCompatibility) {
        let comp = compatibility(me: me, embedder: embedder, language: language)
        var vectors: [UUID: [Float]] = [:]
        var placed = Set<UUID>()
        let live = inputs.filter { !$0.deleted && !$0.text.isEmpty }
        switch comp {
        case .noMap:
            // No map yet: any device's vectors at the pin, if any; nothing placed.
            let pinRev = settings.pins[language]
            for n in live {
                if let hit = snapshot.emb(for: n.id, key: nil, hash: n.hash), hit.emb.hash == n.hash,
                   pinRev.map({ $0 == hit.emb.key.rev }) ?? true, let v = hit.emb.vector { vectors[n.id] = v }
            }
        case .compatible, .vectorReader:
            guard let key = sharedMap(language: language)?.map.key else { break }
            for n in live {
                if let e = snapshot.emb(for: n.id, key: key, hash: n.hash)?.emb, let v = e.vector { vectors[n.id] = v }
            }
            if comp == .compatible, let embedder {
                for n in live where vectors[n.id] == nil {
                    if let v = try? EmbeddingInput.vector(n.text, language: key.lang, revision: key.rev, provider: embedder) {
                        vectors[n.id] = v; placed.insert(n.id)
                    }
                }
            }
        case .incompatible:
            // One local set, never mixed with the shared one.
            if let embedder, let key = sharedMap(language: language)?.map.key {
                for n in live {
                    if let v = try? EmbeddingInput.vector(n.text, language: key.lang, revision: key.rev, provider: embedder) {
                        vectors[n.id] = v; placed.insert(n.id)
                    }
                }
            }
        }
        let basis = vectors.isEmpty ? "keywords" : comp == .incompatible ? "local" : "vectors"
        return (vectors, placed, basis, comp)
    }

    /// Every note's related notes at once (design §4 step 6), what the app keeps between changes instead of building
    /// the graph per selection (review of #50, L7). `maxNotes` bounds the graph's memory (its matrices grow with the
    /// square of the notes): above it, only the `maxNotes` most recently modified notes take part.
    public struct RelatedGraphResult: Sendable {
        /// As `RelatedResult.basis`.
        public var basis: String
        public var compatibility: MapCompatibility
        public var edges: [UUID: [RelatedEdge]]
        /// Notes whose vector was made on this device.
        public var placed: Set<UUID>
        /// Notes left out by `maxNotes`.
        public var leftOut: Int
    }

    /// The live notes with text that take part in a graph of at most `maxNotes` (the most recently modified first, ties
    /// by id), and how many are left out.
    public static func bounded(_ all: [InsightsNoteInput], maxNotes: Int?) -> (inputs: [InsightsNoteInput], leftOut: [UUID]) {
        let inputs = all.filter { !$0.deleted && !$0.text.isEmpty }
        guard let maxNotes, inputs.count > maxNotes else { return (inputs, []) }
        let sorted = inputs.sorted { ($0.modified ?? .distantPast, $0.id.uuidString) > ($1.modified ?? .distantPast, $1.id.uuidString) }
        let cut = max(0, maxNotes)
        return (Array(sorted.prefix(cut)), sorted.dropFirst(cut).map(\.id))
    }

    /// `set`: the vector set of `bounded(all, maxNotes)` when the caller computed it already (the app builds the graph
    /// and the map from one set per refresh).
    public func relatedGraph(inputs all: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?,
                             maxNotes: Int? = nil, set given: VectorSet? = nil) -> RelatedGraphResult {
        let (inputs, out) = Self.bounded(all, maxNotes: maxNotes)
        let leftOut = out.count
        let language = InsightsUpdater.mainLanguage(all)
        let set = given ?? vectorSet(inputs: inputs, me: me, embedder: embedder, language: language)
        // Vectors are used only when every note that can be embedded has one in the set; otherwise keyword overlap
        // alone (never a mix of sets). A note with no embedding input (equations only) has none and joins by keyword
        // overlap (D16: seven such notes turned the vectors off for a whole vault).
        let allHave = !set.vectors.isEmpty
            && inputs.allSatisfy { set.vectors[$0.id] != nil || EmbeddingInput.clean($0.text).isEmpty }
        let rel = inputs.map { n in
            let gen = snapshot.bestGen(for: n.id, hash: n.hash)?.gen
            return RelatedInput(id: n.id, vector: allHave ? set.vectors[n.id] : nil, tokens: InsightsNotes.tokens(text: n.text, gen: gen),
                                words: InsightsWords.count(n.text), terms: InsightsNotes.terms(gen: gen))
        }
        return RelatedGraphResult(basis: allHave ? set.basis : "keywords", compatibility: set.compatibility,
                                  edges: RelatedGraph.build(rel), placed: set.placed, leftOut: leftOut)
    }

    /// The related notes of `note` (design §4 step 6).
    public func related(_ note: InsightsNoteInput, inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?,
                        limit: Int = RelatedGraph.maxEdges) -> RelatedResult {
        let graph = relatedGraph(inputs: inputs, me: me, embedder: embedder)
        return Self.related(note.id, in: graph, titles: Dictionary(inputs.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }),
                            limit: limit)
    }

    /// The rows of `note` in a graph built by `relatedGraph`.
    public static func related(_ note: UUID, in graph: RelatedGraphResult, titles: [UUID: String],
                               limit: Int = RelatedGraph.maxEdges) -> RelatedResult {
        let edges = (graph.edges[note] ?? []).prefix(max(0, limit)).map { e in
            Related(note: e.note.uuidString.lowercased(), title: titles[e.note] ?? "", score: e.score, csls: e.csls,
                    keywordOverlap: e.keywordOverlap, why: e.why, shared: e.shared, placed: graph.placed.contains(e.note))
        }
        return RelatedResult(basis: graph.basis, compatibility: graph.compatibility.rawValue, related: Array(edges))
    }

    // MARK: search

    public struct SearchHit: Hashable, Sendable, Codable {
        public var note: String
        public var title: String
        /// `keyword`, `concept` or `summary` ("matched in summary").
        public var field: String
        public var matched: String
        public var stale: Bool
    }

    /// Notes whose keywords, concepts or summary hold every word of `query` (normalized: lowercased, singular), best
    /// field first. Deleted notes are left out (they show only in Recently Deleted, design §6).
    public func search(_ query: String, inputs: [InsightsNoteInput]) -> [SearchHit] {
        Self.search(query, shown: inputs.filter { !$0.deleted }.map { show($0) })
    }

    /// `search` over notes as `show` gave them (the app keeps these, not the vault's files).
    public static func search(_ query: String, shown: [Shown]) -> [SearchHit] {
        let words = InsightsWords.words(query).map(TermNormalizer.singular)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for n in shown where n.state == "current" || n.state == "stale" {
            func has(_ text: String) -> Bool {
                let ws = Set(InsightsWords.words(text).map(TermNormalizer.singular))
                return words.allSatisfy(ws.contains)
            }
            let stale = n.state == "stale"
            if let k = n.keywords.first(where: { has($0.t) }) {
                hits.append(.init(note: n.note, title: n.title, field: "keyword", matched: k.t, stale: stale))
            } else if let c = n.concepts.first(where: has) {
                hits.append(.init(note: n.note, title: n.title, field: "concept", matched: c, stale: stale))
            } else if let s = n.summary, has(s) {
                hits.append(.init(note: n.note, title: n.title, field: "summary", matched: String(s.prefix(120)), stale: stale))
            }
        }
        let rank = ["keyword": 0, "concept": 1, "summary": 2]
        return hits.sorted { (rank[$0.field] ?? 3, $0.title, $0.note) < (rank[$1.field] ?? 3, $1.title, $1.note) }
    }

    // MARK: status

    public struct DeviceStatus: Hashable, Sendable, Codable {
        public var device: String
        public var name: String?
        public var listed: Bool
        public var current: Int
        public var stale: Int
        public var tombstones: Int
        public var lastSeen: Date?
        public var os: String?
        public var platform: String?
        public var modelAvailable: Bool?
        public var modelReason: String?
        public var model: String?
        public var supported: [String: [Int]]?
        public var supportsPin: Bool?
        public var compatibility: String?
    }

    public struct Status: Hashable, Sendable, Codable {
        public var enabled: Bool
        public var notes: Int
        public var processed: Int
        public var stale: Int
        public var missing: Int
        /// Devices that can embed and build the map (they support the pin), sorted.
        public var capableDevices: [String]
        public var language: String
        public var pin: Int?
        public var upgradeOffer: Int?
        public var leftOutByUpgrade: [String]
        public var map: MapStatus?
        public var thisDevice: String?
        public var compatibility: String
        public var devices: [DeviceStatus]
        public var ignoredFiles: Int
    }

    public struct MapStatus: Hashable, Sendable, Codable {
        public var device: String
        public var written: Date
        public var key: String
        public var notes: Int
        public var clusters: Int
    }

    public func status(inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?, now: Date = Date()) -> Status {
        let language = InsightsUpdater.mainLanguage(inputs)
        let live = inputs.filter { !$0.deleted && !$0.text.isEmpty }
        var processed = 0, stale = 0
        for n in live {
            guard let b = snapshot.bestGen(for: n.id, hash: n.hash) else { continue }
            if b.current { processed += 1 } else { stale += 1 }
        }
        let listed = Set(vault.manifest.devices.compactMap { $0.id.flatMap(DeviceID.init) })
        let recent = EmbeddingPin.recent(snapshot.devices, listed: listed, now: now)
        let pin = settings.pins[language]
        let offer = pin.flatMap { EmbeddingPin.upgradeOffer(recent, language: language, pin: $0) }
        let hashes = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.hash) })
        var ids = Set(snapshot.devices.keys).union(listed)
        for files in snapshot.notes.values { ids.formUnion(files.keys) }
        let names = deviceNames
        let devices: [DeviceStatus] = ids.sorted().map { d in
            var cur = 0, st = 0, tomb = 0
            var latest: Int64 = 0
            for (note, files) in snapshot.notes {
                guard let f = files[d] else { continue }
                latest = max(latest, f.written)
                if f.isTombstone { tomb += 1 } else if f.gen?.hash == hashes[note] || f.emb?.hash == hashes[note] { cur += 1 } else { st += 1 }
            }
            for w in [snapshot.maps[d]?.written, snapshot.devices[d]?.written, snapshot.topics[d]?.written].compactMap({ $0 }) {
                latest = max(latest, w)
            }
            let r = snapshot.devices[d]
            return DeviceStatus(device: d.rawValue, name: names[d.rawValue], listed: listed.contains(d), current: cur, stale: st,
                                tombstones: tomb, lastSeen: latest > 0 ? Date(timeIntervalSince1970: Double(latest) / 1000) : nil,
                                os: r?.os, platform: r?.platform, modelAvailable: r?.model.available, modelReason: r?.model.reason,
                                model: r?.model.identity.map { "\($0.model) \($0.os) p\($0.prompt)" }, supported: r?.supported,
                                supportsPin: pin.map { p in r.map { ($0.supported[language] ?? []).contains(p) } ?? false },
                                compatibility: r?.compatibility == "workDevice" ? MapCompatibility.compatible.rawValue : r?.compatibility)
        }
        let mapStatus = sharedMap(language: language).map { best in
            let m = best.map
            return MapStatus(device: best.device.rawValue, written: Date(timeIntervalSince1970: Double(m.written) / 1000), key: m.key?.description ?? "",
                      notes: m.built?.notes ?? m.layout.count, clusters: m.clusters.filter { $0.level == 0 }.count)
        }
        return Status(enabled: settings.enabled, notes: live.count, processed: processed, stale: stale,
                      missing: live.count - processed - stale,
                      capableDevices: CapableDevices.list(snapshot: snapshot, listed: listed, language: language, pin: pin).map(\.rawValue),
                      language: language, pin: pin,
                      upgradeOffer: offer, leftOutByUpgrade: offer.map { EmbeddingPin.leftOut(recent, language: language, revision: $0).map(\.rawValue) } ?? [],
                      map: mapStatus, thisDevice: me?.rawValue,
                      compatibility: compatibility(me: me, embedder: embedder, language: language).rawValue, devices: devices,
                      ignoredFiles: snapshot.ignored.count)
    }

    // MARK: map

    public struct MapView: Hashable, Sendable, Codable {
        public struct Node: Hashable, Sendable, Codable {
            public var note: String
            public var title: String
            public var x: Double
            public var y: Double
            public var cluster: Int?
            public var placed: Bool
        }
        public struct Cluster: Hashable, Sendable, Codable {
            public var id: Int
            public var parent: Int?
            public var level: Int
            public var label: [String]
            public var members: Int
        }
        public var device: String?
        public var key: String?
        public var basis: String
        public var nodes: [Node]
        public var clusters: [Cluster]
    }

    /// The map as this device shows it: the best map's clusters and positions, plus notes it places itself
    /// (compatible) or its own local map (incompatible, `local`), or nothing (no map).
    public func mapView(inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?,
                        set given: VectorSet? = nil) -> MapView {
        let language = InsightsUpdater.mainLanguage(inputs)
        let titles = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.title) })
        let live = Set(inputs.filter { !$0.deleted }.map(\.id))
        guard let (map, builder) = sharedMap(language: language) else {
            return MapView(device: nil, key: nil, basis: "none", nodes: [], clusters: [])
        }
        let set = given ?? vectorSet(inputs: inputs, me: me, embedder: embedder, language: language)
        var source = map
        var basis = "shared"
        if set.compatibility == .incompatible, let key = map.key {
            // A local map of this device's own vectors (never written; design §3.8).
            let rel = inputs.filter { live.contains($0.id) }.compactMap { n -> RelatedInput? in
                let gen = snapshot.bestGen(for: n.id, hash: n.hash)?.gen
                return set.vectors[n.id].map {
                    RelatedInput(id: n.id, vector: $0, tokens: InsightsNotes.tokens(text: n.text, gen: gen), words: 0,
                                 terms: InsightsNotes.terms(gen: gen))
                }
            }
            let built = MapBuilder.build(rel, corpus: InsightsCorpus(rel.map(\.tokens)))
            source = InsightsMapFile(device: builder, written: map.written, key: key, dim: rel.first?.vector?.count, canaries: nil,
                                     mean: built.mean, clusters: built.clusters.map {
                                         .init(id: $0.id, parent: $0.parent, level: $0.level, label: $0.label, centroid: $0.centroid,
                                               members: $0.members)
                                     }, layout: built.positions.mapValues { ($0.x, $0.y) }, built: nil)
            basis = "local"
        }
        var clusterOf: [UUID: Int] = [:]
        for c in source.clusters where c.level == 0 { for m in c.members { if let id = UUID(uuidString: m) { clusterOf[id] = c.id } } }
        var nodes: [MapView.Node] = []
        for (id, p) in source.positions where live.contains(id) {
            nodes.append(.init(note: id.uuidString.lowercased(), title: titles[id] ?? "", x: p.x, y: p.y, cluster: clusterOf[id], placed: basis == "local"))
        }
        if basis == "shared", set.compatibility == .compatible {
            for id in set.placed where source.positions[id] == nil {
                guard let v = set.vectors[id], let p = MapBuilder.place(id: id, vector: v, map: source, vectors: set.vectors) else { continue }
                nodes.append(.init(note: id.uuidString.lowercased(), title: titles[id] ?? "", x: p.position.x, y: p.position.y,
                                   cluster: p.clusters.first, placed: true))
            }
        }
        nodes.sort { $0.note < $1.note }
        let clusters = source.clusters.map {
            MapView.Cluster(id: $0.id, parent: $0.parent, level: $0.level, label: $0.label,
                            members: $0.members.filter { UUID(uuidString: $0).map(live.contains) ?? false }.count)
        }
        return MapView(device: builder.rawValue, key: map.key?.description, basis: basis, nodes: nodes, clusters: clusters)
    }

    /// The map as SVG: one circle per note (dashed when placed on this device), colored by cluster, cluster labels at
    /// their members' mean. Titles and labels are escaped.
    public static func svg(_ view: MapView, size: Double = 800) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func px(_ v: Double) -> String { String(format: "%.1f", (v + 1.6) / 3.2 * size) }
        let palette = ["#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f", "#edc948", "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac"]
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(size))\" height=\"\(Int(size))\" viewBox=\"0 0 \(Int(size)) \(Int(size))\">\n"
        out += "<rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/>\n"
        for n in view.nodes {
            let color = n.cluster.map { palette[Int($0.magnitude % UInt(palette.count))] } ?? "#888888"
            out += "<circle cx=\"\(px(n.x))\" cy=\"\(px(n.y))\" r=\"6\" fill=\"\(color)\"" + (n.placed ? " stroke=\"#000\" stroke-dasharray=\"2 2\"" : "")
                + "><title>\(esc(n.title))</title></circle>\n"
        }
        for c in view.clusters where c.level == 0 {
            let members = view.nodes.filter { $0.cluster == c.id }
            guard !members.isEmpty else { continue }
            let x = members.map(\.x).reduce(0, +) / Double(members.count), y = members.map(\.y).reduce(0, +) / Double(members.count)
            out += "<text x=\"\(px(x))\" y=\"\(px(y))\" font-family=\"sans-serif\" font-size=\"12\" text-anchor=\"middle\">\(esc(c.label.joined(separator: ", ")))</text>\n"
        }
        return out + "</svg>\n"
    }
}
