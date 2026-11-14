import Foundation
import Sempere

// MARK: - The updater (docs/design/1.2-note-insights.md §3.7, §3.8, §4, D13-D15; `sempere insights update`)
//
// One pass over a vault for this device: re-seal its own files under the current key, delete what removed devices
// left, claim the work device when none is set, then per note (in the policy's order) generate, embed, tombstone and
// title, then rebuild the map, write this device's record and the topic summaries due. Every write goes through
// `InsightsStore` (and voice-note titles through `Vault.apply`), so a read-only vault refuses them all. The app (PR 2)
// and the CLI call it alike.

/// What one note gave the updater.
public struct InsightsNoteInput: Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var hash: String
    public var language: String
    public var modified: Date?
    public var deleted: Bool
    /// Joined transcripts, for a voice note's title (D14).
    public var transcript: String
    public var notebook: String?
    public var tags: [String]

    public init(id: UUID, title: String, text: String, hash: String, language: String, modified: Date?, deleted: Bool,
                transcript: String, notebook: String?, tags: [String]) {
        self.id = id; self.title = title; self.text = text; self.hash = hash; self.language = language; self.modified = modified
        self.deleted = deleted; self.transcript = transcript; self.notebook = notebook; self.tags = tags
    }
}

/// Reading notes for insights.
public enum InsightsNotes {
    /// The insight inputs of `summaries` (transcripts decrypted per recording; one that fails is left out).
    public static func inputs(_ vault: Vault, summaries: [NoteSummary]) -> [InsightsNoteInput] {
        summaries.filter { $0.problem == nil }.map { s in
            var transcripts: [String] = []
            for r in s.transcribed {
                guard let data = try? vault.readBlob(note: s.id, r.blob, maxBytes: Transcript.maxSize),
                      let t = try? Transcript.decode(data), t.recording == r.recording else { continue }
                transcripts.append(t.segments.map(\.text).joined(separator: " "))
            }
            let text = InsightsText.text(pageTexts: s.pageTexts, transcripts: transcripts)
            return InsightsNoteInput(id: s.id, title: s.title, text: text, hash: InsightsText.hash(text),
                                     language: InsightsLanguage.of(s.lang), modified: s.modified, deleted: s.deleted,
                                     transcript: transcripts.joined(separator: "\n\n"), notebook: s.notebook, tags: s.tags)
        }
    }

    /// The vault's recognized-word frequencies (the typo merge's corpus, step 4).
    public static func merger(_ notes: [InsightsNoteInput]) -> TypoMerger { TypoMerger(texts: notes.map(\.text)) }

    /// Normalized content tokens of a note for keyword overlap: its `gen` terms and its text's content words.
    public static func tokens(text: String, gen: InsightsNoteFile.Gen?) -> Set<String> {
        var out = Set<String>()
        for k in gen?.keywords ?? [] { out.insert(k.t) }
        for c in gen?.concepts ?? [] { out.insert(c) }
        for w in InsightsWords.words(text) where w.count >= 4 && !InsightsStoplist.generic.contains(w) && !w.contains(where: \.isNumber) {
            out.insert(TermNormalizer.singular(w))
        }
        return out
    }
}

public struct InsightsUpdateOptions: Sendable {
    public var note: UUID?
    public var force = false
    public var limit: Int?
    public var embeddingsOnly = false
    public var dryRun = false
    public var rebuildMap = false
    public var topics = true
    public var titles = true
    public var now = Date()
    public var platform = InsightsPlatform.current
    public var powerWindow = true
    public init() {}
}

/// What a pass did (or would do, `dryRun`).
public struct InsightsUpdateReport: Hashable, Sendable, Codable {
    public var device: String = ""
    public var claimedWorkDevice = false
    public var generated: [String] = []
    public var embedded: [String] = []
    public var tombstoned: [String] = []
    public var dropped: [String] = []
    public var titled: [String] = []
    public var restoredTitles: [String] = []
    public var resealed: [String] = []
    public var removed: [String] = []
    public var mapBuilt = false
    public var deviceRecord = false
    public var topics: [String] = []
    public var pinSet: [String: Int] = [:]
    /// Notes whose generation failed, with why (backed off).
    public var failures: [String: String] = [:]
    /// Why nothing was generated or embedded (`model unavailable: …`), when so.
    public var notes: [String] = []
    public var dryRun = false
    public init() {}
}

public enum InsightsUpdateError: Error, Hashable, Sendable, CustomStringConvertible {
    case disabled
    case notWritable(String)
    public var description: String {
        switch self {
        case .disabled: return "Note Insights is off for this vault (sempere settings set insights.enabled true)"
        case .notWritable(let why): return why
        }
    }
}

public struct InsightsUpdater: Sendable {
    public var vault: Vault
    public var model: (any ModelProvider)?
    public var embedder: (any EmbeddingProvider)?
    /// The device state file voice-note titles are written with (`Vault.apply`).
    public var deviceState: URL
    public var app: String

    public init(vault: Vault, model: (any ModelProvider)?, embedder: (any EmbeddingProvider)?, deviceState: URL, app: String) {
        self.vault = vault; self.model = model; self.embedder = embedder; self.deviceState = deviceState; self.app = app
    }

    public func run(_ o: InsightsUpdateOptions, notes inputs: [InsightsNoteInput]) async throws -> InsightsUpdateReport {
        var report = InsightsUpdateReport()
        report.dryRun = o.dryRun
        var settings = InsightsSettings.read(vault)
        guard settings.enabled else { throw InsightsUpdateError.disabled }
        let store = InsightsStore(vault: vault)
        let me = try store.writer()
        report.device = me.rawValue
        if !o.dryRun {
            report.resealed = try store.resealOwn(now: o.now)
            report.removed = try store.removeRemovedDevices()
        }
        var snapshot = store.snapshot()
        let usable = model.flatMap { $0.availability.isAvailable ? $0 : nil }
        if usable == nil, let model { report.notes.append("model unavailable: \(model.availability)") }
        let languages = Array(Set(inputs.map(\.language))).sorted()
        let main = Self.mainLanguage(inputs)
        // The pin: unset, the first map build sets it to the lowest revision every recently seen device supports (D12).
        let listed = Set(vault.manifest.devices.compactMap { $0.id.flatMap(DeviceID.init) })
        var supported = embedder?.supported(languages.isEmpty ? [main] : languages) ?? [:]
        if supported.isEmpty, let embedder { supported = embedder.supported([main]) }
        let ownRecord = makeRecord(me: me, supported: supported, settings: settings, snapshot: snapshot, o: o)
        var records = EmbeddingPin.recent(snapshot.devices, listed: listed, now: o.now)
        records[me] = ownRecord
        func pinRevision(_ lang: String) -> Int? { settings.pins[lang] ?? EmbeddingPin.lowestCommon(records, language: lang) }
        let pin = pinRevision(main)
        let canEmbed = pin.flatMap { p in supported[main]?.contains(p) == true ? p : nil }
        let pinKey = canEmbed.flatMap { r in embedder?.key(language: main, revision: r) }
        let changedRecord = snapshot.devices[me].map { !Self.sameRecord($0, ownRecord) } ?? true
        let caps = PolicyCapabilities(model: o.embeddingsOnly ? nil : usable?.identity, embedRevision: canEmbed, powerWindow: o.powerWindow)
        let selected = o.note.map { id in inputs.filter { $0.id == id } } ?? inputs
        let policyNotes = selected.map {
            PolicyNote(id: $0.id, hash: $0.hash, modified: $0.modified, deleted: $0.deleted, hasText: !$0.text.isEmpty)
        }
        var plan = InsightsPolicy.plan(notes: policyNotes, snapshot: snapshot, me: me, settings: settings, capabilities: caps,
                                       pinKey: pinKey, now: o.now, force: o.force, deviceRecordChanged: changedRecord)
        if o.rebuildMap, pinKey != nil, !plan.contains(.rebuildMap) { plan.append(.rebuildMap) }
        // Claim the role (D13: the first capable device to turn insights on), through the settings merge.
        if plan.contains(.claimWorkDevice) {
            report.claimedWorkDevice = true
            if !o.dryRun {
                try vault.updateSharedSettings { s in
                    guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.workDevice) else { return }
                    if case .string = s.resolve(spec, for: nil).value { return }   // claimed meanwhile
                    try s.write(spec, .string(me.rawValue), block: nil, type: nil, now: o.now)
                }
                settings = InsightsSettings.read(vault)
            } else {
                settings.workDevice = me
            }
            if settings.workDevice != me {
                // Another device's claim won the merge: plan again as a device that is not the work device.
                plan = InsightsPolicy.plan(notes: policyNotes, snapshot: snapshot, me: me, settings: settings, capabilities: caps,
                                           pinKey: pinKey, now: o.now, force: o.force, deviceRecordChanged: changedRecord)
            }
        }
        let byId = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        let merger = InsightsNotes.merger(inputs)
        var generations = 0
        var pending: [UUID: InsightsNoteFile] = [:]
        func own(_ id: UUID) -> InsightsNoteFile {
            pending[id] ?? snapshot.notes[id]?[me] ?? InsightsNoteFile(noteId: id, device: me, written: 0)
        }
        for item in plan {
            switch item {
            case .generate(let id):
                guard let note = byId[id], let model = usable else { continue }
                if let limit = o.limit, generations >= limit { continue }
                generations += 1
                do {
                    let isVoice = !note.transcript.isEmpty
                    let gen = try await InsightsGenerator.generate(text: note.text, hash: note.hash, language: note.language,
                                                                   model: model, merger: merger,
                                                                   transcript: isVoice ? note.transcript : nil)
                    var f = own(id); f.gen = gen; f.lang = note.language
                    pending[id] = f
                    report.generated.append(id.uuidString.lowercased())
                } catch {
                    report.failures[id.uuidString.lowercased()] = "\(error)"
                }
            case .embed(let id):
                guard let note = byId[id], let embedder, let r = canEmbed, let key = pinKey else { continue }
                guard let v = try? EmbeddingInput.vector(note.text, language: main, revision: r, provider: embedder) else { continue }
                var f = own(id); f.emb = InsightsNoteFile.Emb(hash: note.hash, key: key, vector: v)
                pending[id] = f
                report.embedded.append(id.uuidString.lowercased())
            case .tombstone(let id):
                pending[id] = InsightsNoteFile(noteId: id, device: me, written: 0)
                report.tombstoned.append(id.uuidString.lowercased())
            case .dropStaleGen(let id):
                var f = own(id); f.gen = nil
                pending[id] = f
                report.dropped.append(id.uuidString.lowercased())
            case .claimWorkDevice, .rebuildMap, .writeDeviceRecord:
                continue
            }
        }
        if !o.dryRun {
            for id in pending.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let f = pending[id] else { continue }
                // A note with nothing left of this device's is a tombstone only if this device had a file for it.
                if f.isTombstone, snapshot.notes[id]?[me] == nil { continue }
                try store.write(.note(f), now: o.now)
            }
            snapshot = store.snapshot()
        }
        // Voice-note titles (D14): from any device's current `gen` slug, while the title is the capture default.
        if o.titles, !o.embeddingsOnly {
            for note in selected where !note.deleted && !note.transcript.isEmpty {
                guard let outcome = try applyTitle(note, snapshot: snapshot, me: me, format: settings.voiceNoteTitle,
                                                   dryRun: o.dryRun, now: o.now) else { continue }
                switch outcome {
                case .apply: report.titled.append(note.id.uuidString.lowercased())
                case .restore: report.restoredTitles.append(note.id.uuidString.lowercased())
                case .keep: break
                }
            }
            if !o.dryRun { snapshot = store.snapshot() }
        }
        // The pin is written by the first map build (D12).
        if plan.contains(.rebuildMap), let r = canEmbed, settings.pins[main] == nil {
            report.pinSet[main] = r
            if !o.dryRun {
                try vault.updateSharedSettings { s in
                    guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.pin) else { return }
                    var o2: [String: JSONValue] = [:]
                    if case .object(let cur) = s.resolve(spec, for: nil).value { o2 = cur }
                    guard o2[main] == nil else { return }
                    o2[main] = .number(Double(r))
                    try s.write(spec, .object(o2), block: nil, type: nil, now: o.now)
                }
            }
        }
        if plan.contains(.rebuildMap), let key = pinKey {
            report.mapBuilt = true
            if !o.dryRun {
                let map = Self.buildMap(snapshot: snapshot, me: me, key: key, inputs: inputs, previous: snapshot.maps[me],
                                        canaries: try? embedder.flatMap { try Canaries.vectors($0, language: main, revision: key.rev) })
                if let map { try store.write(.map(map), now: o.now) }
                snapshot = store.snapshot()
            }
        }
        if plan.contains(.writeDeviceRecord) || changedRecord || report.mapBuilt {
            report.deviceRecord = true
            if !o.dryRun {
                var record = ownRecord
                record.canaries = canaryVectors(supported: supported, pin: pin, language: main)
                let comp = InsightsReader(vault: vault, snapshot: snapshot, settings: InsightsSettings.read(vault))
                    .compatibility(me: me, embedder: embedder, language: main)
                record.compatibility = comp.rawValue
                record.against = settings.workDevice.flatMap { snapshot.map(of: $0)?.written }
                try store.write(.device(record), now: o.now)
            }
        }
        if o.topics, !o.embeddingsOnly, let model = usable, settings.workDevice == me || settings.computeAuto {
            report.topics = try await updateTopics(store: store, snapshot: snapshot, inputs: inputs, model: model, merger: merger,
                                                   me: me, o: o, limit: o.limit.map { max(0, $0 - generations) })
        }
        return report
    }

    // MARK: Titles

    enum TitleOutcome { case apply, restore, keep }

    /// Applies (or restores) a voice note's title; nil when there is nothing to do.
    func applyTitle(_ note: InsightsNoteInput, snapshot: InsightsSnapshot, me: DeviceID, format: String, dryRun: Bool,
                    now: Date) throws -> TitleOutcome? {
        let loaded = try vault.loadNote(note.id)
        let state = try vault.reconstruct(loaded)
        let titles = VoiceNoteTitleState(revisions: loaded.revisions, state: state)
        guard titles.isVoiceNote else { return nil }
        let ownFile = snapshot.notes[note.id]?[me]
        let best = snapshot.bestGen(for: note.id, hash: note.hash)
        let slug = best.flatMap { $0.current ? $0.gen.slug : nil }
        let local = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: titles.defaultTitle?.title,
                                                            started: titles.started ?? note.modified ?? now)
        let proposed = VoiceNoteTitleFormat.render(format, date: local.date, time: local.time, slug: slug)
        switch titles.decide(applied: ownFile?.titleOp, proposed: proposed) {
        case .keep: return nil
        case .apply(let title):
            guard !dryRun else { return .apply }
            let rev = try vault.apply(NoteOps.rename(to: title, state: state), to: note.id, deviceState: deviceState, app: app, wall: now)
            var f = ownFile ?? InsightsNoteFile(noteId: note.id, device: me, written: 0)
            f.titleOp = .init(stamp: Stamp(hlc: rev.hlc, device: rev.device).description, title: title)
            try InsightsStore(vault: vault).write(.note(f), now: now)
            return .apply
        case .restore(let title):
            guard !dryRun else { return .restore }
            _ = try vault.apply(NoteOps.rename(to: title, state: state), to: note.id, deviceState: deviceState, app: app, wall: now)
            return .restore
        }
    }

    /// The title `insights title` would give `note` (no write), nil when it keeps its title.
    public func proposedTitle(_ note: InsightsNoteInput, format: String, slug: String?) throws -> (decision: VoiceNoteTitleState.Decision, isVoice: Bool) {
        let loaded = try vault.loadNote(note.id)
        let state = try vault.reconstruct(loaded)
        let titles = VoiceNoteTitleState(revisions: loaded.revisions, state: state)
        let me = vault.writerDevice
        let snapshot = InsightsStore(vault: vault).snapshot()
        let local = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: titles.defaultTitle?.title,
                                                            started: titles.started ?? note.modified ?? Date())
        let proposed = VoiceNoteTitleFormat.render(format, date: local.date, time: local.time, slug: slug)
        return (titles.decide(applied: me.flatMap { snapshot.notes[note.id]?[$0]?.titleOp }, proposed: proposed), titles.isVoiceNote)
    }

    /// Writes the title of `insights title` (D14) with `format` and `slug`; returns the decision applied.
    public func writeTitle(_ note: InsightsNoteInput, format: String, slug: String?, now: Date = Date()) throws -> VoiceNoteTitleState.Decision {
        let me = try InsightsStore(vault: vault).writer()
        let snapshot = InsightsStore(vault: vault).snapshot()
        let loaded = try vault.loadNote(note.id)
        let state = try vault.reconstruct(loaded)
        let titles = VoiceNoteTitleState(revisions: loaded.revisions, state: state)
        let local = VoiceNoteTitleFormat.captureDateAndTime(defaultTitle: titles.defaultTitle?.title,
                                                            started: titles.started ?? note.modified ?? now)
        let proposed = VoiceNoteTitleFormat.render(format, date: local.date, time: local.time, slug: slug)
        let ownFile = snapshot.notes[note.id]?[me]
        let decision = titles.decide(applied: ownFile?.titleOp, proposed: proposed)
        switch decision {
        case .keep: break
        case .apply(let title):
            let rev = try vault.apply(NoteOps.rename(to: title, state: state), to: note.id, deviceState: deviceState, app: app, wall: now)
            var f = ownFile ?? InsightsNoteFile(noteId: note.id, device: me, written: 0)
            f.titleOp = .init(stamp: Stamp(hlc: rev.hlc, device: rev.device).description, title: title)
            try InsightsStore(vault: vault).write(.note(f), now: now)
        case .restore(let title):
            _ = try vault.apply(NoteOps.rename(to: title, state: state), to: note.id, deviceState: deviceState, app: app, wall: now)
        }
        return decision
    }

    // MARK: Map, records, topics

    /// The map of the work device's vectors at `key` (design §3.8): mean-centered clusters and layout, warm-started.
    public static func buildMap(snapshot: InsightsSnapshot, me: DeviceID, key: EmbeddingKey, inputs: [InsightsNoteInput],
                                previous: InsightsMapFile?, canaries: [[Float]]?) -> InsightsMapFile? {
        let live = inputs.filter { !$0.deleted }
        var rel: [RelatedInput] = []
        var pairs: [(UUID, String)] = []
        var dim: Int?
        for n in live {
            guard let e = snapshot.notes[n.id]?[me]?.emb, e.key == key, let v = e.vector else { continue }
            dim = dim ?? v.count
            guard v.count == dim else { continue }
            let gen = snapshot.bestGen(for: n.id, hash: n.hash)?.gen
            rel.append(RelatedInput(id: n.id, vector: v, tokens: InsightsNotes.tokens(text: n.text, gen: gen), words: InsightsWords.count(n.text)))
            pairs.append((n.id, e.hash))
        }
        guard let dim, !rel.isEmpty else { return nil }
        let corpus = InsightsCorpus(rel.map(\.tokens))
        let built = MapBuilder.build(rel, corpus: corpus, previous: previous.flatMap { $0.key == key ? $0 : nil })
        let clusters = built.clusters.map {
            InsightsMapFile.Cluster(id: $0.id, parent: $0.parent, level: $0.level, label: $0.label, centroid: $0.centroid, members: $0.members)
        }
        return InsightsMapFile(device: me, written: 0, key: key, dim: dim,
                               canaries: canaries.map { InsightsCanaries(set: Canaries.set, vectors: $0) }, mean: built.mean,
                               clusters: clusters, layout: built.positions.mapValues { ($0.x, $0.y) },
                               built: .init(notes: rel.count, hashes: MapBuilder.digest(pairs)))
    }

    /// The language most live notes are in (the embedding's language), the fallback for none.
    public static func mainLanguage(_ inputs: [InsightsNoteInput]) -> String {
        var f: [String: Int] = [:]
        for n in inputs where !n.deleted { f[n.language, default: 0] += 1 }
        return f.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key ?? InsightsLanguage.fallback
    }

    func makeRecord(me: DeviceID, supported: [String: [Int]], settings: InsightsSettings, snapshot: InsightsSnapshot,
                    o: InsightsUpdateOptions) -> InsightsDeviceRecord {
        let availability = model?.availability ?? .unsupported("no model provider")
        let m = InsightsDeviceRecord.Model(available: availability.isAvailable, reason: availability.reason,
                                           identity: availability.isAvailable ? model?.identity : nil)
        return InsightsDeviceRecord(device: me, written: 0, os: o.platform.os, platform: o.platform.platform, model: m,
                                    supported: supported, canaries: [], compatibility: nil, against: nil)
    }

    func canaryVectors(supported: [String: [Int]], pin: Int?, language: String) -> [InsightsDeviceRecord.CanaryVectors] {
        guard let embedder, let revs = supported[language], !revs.isEmpty else { return [] }
        let r = pin.flatMap { revs.contains($0) ? $0 : nil } ?? revs.min() ?? 1
        guard let v = try? Canaries.vectors(embedder, language: language, revision: r) else { return [] }
        return [.init(key: embedder.key(language: language, revision: r), vectors: v, set: Canaries.set)]
    }

    /// Two records equal in what makes one worth writing again (not `written`, canaries or compatibility).
    static func sameRecord(_ a: InsightsDeviceRecord, _ b: InsightsDeviceRecord) -> Bool {
        a.os == b.os && a.platform == b.platform && a.model == b.model && a.supported == b.supported
    }

    func updateTopics(store: InsightsStore, snapshot: InsightsSnapshot, inputs: [InsightsNoteInput], model: any ModelProvider,
                      merger: TypoMerger, me: DeviceID, o: InsightsUpdateOptions, limit: Int?) async throws -> [String] {
        let scopes = TopicScopes.members(inputs: inputs, snapshot: snapshot)
        let stored = snapshot.topics[me]
        var topics = stored?.topics ?? []
        var made: [String] = []
        for (scope, members) in scopes {
            if let limit, made.count >= limit { break }
            let old = topics.first { $0.scope == scope }
            guard TopicSummaries.isDue(members: members, stored: old, reader: model.identity, now: o.now) else { continue }
            made.append(TopicScopes.name(scope))
            if o.dryRun { continue }
            guard let text = try? await TopicSummaries.generate(name: TopicScopes.name(scope), members: members,
                                                                 language: InsightsNotes.languageOf(members, inputs), model: model,
                                                                 merger: merger) else { continue }
            let gen = InsightsTopicsFile.Gen(identity: model.identity, at: InsightsCodec.nextWritten(after: nil, now: o.now), summary: text)
            topics.removeAll { $0.scope == scope }
            topics.append(.init(scope: scope, members: members.count, membersHash: TopicSummaries.membersHash(members), gen: gen))
        }
        if !o.dryRun, !made.isEmpty {
            topics.sort { TopicScopes.name($0.scope) < TopicScopes.name($1.scope) }
            try store.write(.topics(InsightsTopicsFile(device: me, written: 0, topics: topics)), now: o.now)
        }
        return made
    }
}

/// Notebook and tag scopes of topic summaries (D8).
public enum TopicScopes {
    /// Per scope, its summarized members (a current `gen` with a summary), sorted by scope name.
    public static func members(inputs: [InsightsNoteInput], snapshot: InsightsSnapshot) -> [(InsightsTopicsFile.Scope, [TopicSummaries.Member])] {
        var byScope: [InsightsTopicsFile.Scope: [TopicSummaries.Member]] = [:]
        for n in inputs where !n.deleted {
            guard let best = snapshot.bestGen(for: n.id, hash: n.hash), best.current, let summary = best.gen.summary else { continue }
            let m = TopicSummaries.Member(note: n.id, hash: n.hash, summary: summary, keywords: best.gen.keywords.map(\.t))
            if let nb = n.notebook.flatMap(NotebookPath.canonical) { byScope[.init(notebook: nb), default: []].append(m) }
            for t in Set(n.tags.map(NoteOps.tagKey)) { byScope[.init(tag: t), default: []].append(m) }
        }
        return byScope.map { ($0.key, $0.value) }.sorted { name($0.0) < name($1.0) }
    }

    public static func name(_ s: InsightsTopicsFile.Scope) -> String {
        if let nb = s.notebook { return "notebook:\(nb)" }
        return "tag:\(s.tag ?? "")"
    }
}

extension InsightsNotes {
    static func languageOf(_ members: [TopicSummaries.Member], _ inputs: [InsightsNoteInput]) -> String {
        let ids = Set(members.map(\.note))
        return InsightsUpdater.mainLanguage(inputs.filter { ids.contains($0.id) })
    }
}
