import Foundation
import Sempere

// MARK: - Reading insights (docs/design/1.2-note-insights.md §3.8, §6, §7; `sempere insights show|related|search|status|map`)
//
// What every device shows from the vault's files: a note's best `gen`, the related notes from the compatible vector set
// (the work device's vectors whose key equals its map's, plus notes this device places itself when it is compatible
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
        let emb = settings.workDevice.flatMap { snapshot.emb(for: note.id, from: $0) }
        return Shown(note: note.id.uuidString.lowercased(), title: note.title, state: state, summary: best?.gen.summary,
                     keywords: best?.gen.keywords ?? [], concepts: best?.gen.concepts ?? [], device: best?.device.rawValue,
                     deviceName: best.flatMap { deviceNames[$0.device.rawValue] },
                     written: best.map { Date(timeIntervalSince1970: Double($0.written) / 1000) }, model: best?.gen.model,
                     os: best?.gen.os, prompt: best?.gen.prompt, dropped: best?.gen.dropped, slug: best?.gen.slug,
                     embedded: emb?.hash == note.hash, embeddingKey: emb?.key.description)
    }

    // MARK: Compatibility

    /// How this device stands to the work device's map (design §3.8).
    public func compatibility(me: DeviceID?, embedder: (any EmbeddingProvider)?, language: String) -> MapCompatibility {
        guard let w = settings.workDevice, let map = snapshot.map(of: w), let key = map.key else { return .noMap }
        if me == w { return .workDevice }
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
        /// The note's vector was made on this device (placed), not by the work device.
        public var placed: Bool
    }

    public struct RelatedResult: Hashable, Sendable, Codable {
        /// `vectors` (the shared set, maybe with placed notes), `local` (an incompatible device's own set) or
        /// `keywords` (no vectors).
        public var basis: String
        public var compatibility: String
        public var related: [Related]
    }

    /// The vectors of the compatible set (design §3.8), with the ids embedded on this device.
    public func vectorSet(inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?,
                          language: String) -> (vectors: [UUID: [Float]], placed: Set<UUID>, basis: String, compatibility: MapCompatibility) {
        let comp = compatibility(me: me, embedder: embedder, language: language)
        var vectors: [UUID: [Float]] = [:]
        var placed = Set<UUID>()
        let live = inputs.filter { !$0.deleted && !$0.text.isEmpty }
        switch comp {
        case .noMap:
            // No map yet: the work device's vectors at the pin, if any; nothing placed.
            if let w = settings.workDevice {
                let pinRev = settings.pins[language]
                for n in live {
                    if let e = snapshot.emb(for: n.id, from: w), e.hash == n.hash, pinRev.map({ $0 == e.key.rev }) ?? true,
                       let v = e.vector { vectors[n.id] = v }
                }
            }
        case .workDevice, .compatible, .vectorReader:
            guard let w = settings.workDevice, let key = snapshot.map(of: w)?.key else { break }
            for n in live {
                if let e = snapshot.emb(for: n.id, from: w), e.key == key, let v = e.vector { vectors[n.id] = v }
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
            if let embedder, let w = settings.workDevice, let key = snapshot.map(of: w)?.key {
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

    /// The related notes of `note` (design §4 step 6).
    public func related(_ note: InsightsNoteInput, inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?,
                        limit: Int = RelatedGraph.maxEdges) -> RelatedResult {
        let language = InsightsUpdater.mainLanguage(inputs)
        let set = vectorSet(inputs: inputs, me: me, embedder: embedder, language: language)
        let live = inputs.filter { !$0.deleted && !$0.text.isEmpty }
        // Vectors are used only when every note that can be embedded has one in the set; otherwise keyword overlap
        // alone (never a mix of sets). A note with no embedding input (equations only) has none and joins by keyword
        // overlap (D16: seven such notes turned the vectors off for a whole vault).
        let allHave = !set.vectors.isEmpty
            && live.allSatisfy { set.vectors[$0.id] != nil || EmbeddingInput.clean($0.text).isEmpty }
        let rel = live.map { n in
            let gen = snapshot.bestGen(for: n.id, hash: n.hash)?.gen
            return RelatedInput(id: n.id, vector: allHave ? set.vectors[n.id] : nil, tokens: InsightsNotes.tokens(text: n.text, gen: gen),
                                words: InsightsWords.count(n.text), terms: InsightsNotes.terms(gen: gen))
        }
        let graph = RelatedGraph.build(rel)
        let titles = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.title) })
        let edges = (graph[note.id] ?? []).prefix(max(0, limit)).map { e in
            Related(note: e.note.uuidString.lowercased(), title: titles[e.note] ?? "", score: e.score, csls: e.csls,
                    keywordOverlap: e.keywordOverlap, why: e.why, shared: e.shared, placed: set.placed.contains(e.note))
        }
        return RelatedResult(basis: allHave ? set.basis : "keywords", compatibility: set.compatibility.rawValue, related: Array(edges))
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
        let words = InsightsWords.words(query).map(TermNormalizer.singular)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for n in inputs where !n.deleted {
            guard let best = snapshot.bestGen(for: n.id, hash: n.hash) else { continue }
            func has(_ text: String) -> Bool {
                let ws = Set(InsightsWords.words(text).map(TermNormalizer.singular))
                return words.allSatisfy(ws.contains)
            }
            let id = n.id.uuidString.lowercased()
            if let k = best.gen.keywords.first(where: { has($0.t) }) {
                hits.append(.init(note: id, title: n.title, field: "keyword", matched: k.t, stale: !best.current))
            } else if let c = best.gen.concepts.first(where: has) {
                hits.append(.init(note: id, title: n.title, field: "concept", matched: c, stale: !best.current))
            } else if let s = best.gen.summary, has(s) {
                hits.append(.init(note: id, title: n.title, field: "summary", matched: String(s.prefix(120)), stale: !best.current))
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
        public var isWorkDevice: Bool
    }

    public struct Status: Hashable, Sendable, Codable {
        public var enabled: Bool
        public var notes: Int
        public var processed: Int
        public var stale: Int
        public var missing: Int
        public var workDevice: String?
        public var workDeviceName: String?
        public var workDeviceNotSeen: Bool
        public var workDeviceLastSeen: Date?
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
        let work = WorkDeviceStatus(settings: settings, snapshot: snapshot, listed: listed, language: language, now: now)
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
                                compatibility: d == settings.workDevice ? MapCompatibility.workDevice.rawValue : r?.compatibility,
                                isWorkDevice: d == settings.workDevice)
        }
        let mapStatus = settings.workDevice.flatMap { w in snapshot.map(of: w).map { m in
            MapStatus(device: w.rawValue, written: Date(timeIntervalSince1970: Double(m.written) / 1000), key: m.key?.description ?? "",
                      notes: m.built?.notes ?? m.layout.count, clusters: m.clusters.filter { $0.level == 0 }.count)
        } }
        return Status(enabled: settings.enabled, notes: live.count, processed: processed, stale: stale,
                      missing: live.count - processed - stale, workDevice: settings.workDevice?.rawValue,
                      workDeviceName: settings.workDevice.flatMap { names[$0.rawValue] }, workDeviceNotSeen: work.notSeen,
                      workDeviceLastSeen: work.lastSeen, capableDevices: work.capable.map(\.rawValue), language: language, pin: pin,
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

    /// The map as this device shows it: the work device's clusters and positions, plus notes it places itself
    /// (compatible) or its own local map (incompatible, `local`), or nothing (no map).
    public func mapView(inputs: [InsightsNoteInput], me: DeviceID?, embedder: (any EmbeddingProvider)?) -> MapView {
        let language = InsightsUpdater.mainLanguage(inputs)
        let titles = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.title) })
        let live = Set(inputs.filter { !$0.deleted }.map(\.id))
        guard let w = settings.workDevice, let map = snapshot.map(of: w) else {
            return MapView(device: nil, key: nil, basis: "none", nodes: [], clusters: [])
        }
        let set = vectorSet(inputs: inputs, me: me, embedder: embedder, language: language)
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
            source = InsightsMapFile(device: w, written: map.written, key: key, dim: rel.first?.vector?.count, canaries: nil,
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
        return MapView(device: w.rawValue, key: map.key?.description, basis: basis, nodes: nodes, clusters: clusters)
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
            let color = n.cluster.map { palette[abs($0) % palette.count] } ?? "#888888"
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
