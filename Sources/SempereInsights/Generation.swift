import Foundation
import Sempere

// MARK: - Generation of one note and of topic summaries (docs/design/1.2-note-insights.md §4 steps 1-5, 9; D14)

public enum InsightsGenerator {
    /// Sempere's prompt revision (`gen.prompt`): a change makes every generation stale (design §3.4). 2: the D16
    /// tuning (the prompt asks for the subject, not the note's form, and for no LaTeX; the fact check and the chunk
    /// cap changed with it).
    public static let promptRevision = 2

    /// At most this many chunks of a note are read (D16: a PDF of 100,000 words is 220 chunks, minutes of model time
    /// and a merge call that cannot fit): evenly spaced ones, the first and the last always among them.
    public static let maxChunks = 8

    /// The note's `gen` from `text` (its insight text) with `model`: chunked to the context window (at most
    /// `maxChunks`, halved and retried once on an overflow), merged, normalized and fact-checked against the text (the
    /// typo merge applied to both sides), with `label` (the note's title, notebook and tags) and the model's own terms
    /// as context (D16). Keywords and concepts keep the model's spelling: on real notes the typo merge turned more
    /// correct words into other words (`patent` into `parent`) than it repaired misreadings (D16). A voice note (`transcript` given) also gets a fact-checked slug for its title.
    /// With `outputLanguage` (the vault's `insights.language`) the summary and the slug are first made and fact-checked in
    /// the note's own language, then put into that language (`ModelProvider.translate`: a failure fails the generation, so
    /// a note is never left half in one language); the keywords and concepts stay as the note has them, which is what
    /// search matches.
    public static func generate(text: String, hash: String, language: String?, model: any ModelProvider,
                                merger: TypoMerger?, transcript: String? = nil, outputLanguage: String? = nil,
                                label: FactCheck.Context = FactCheck.Context()) async throws -> InsightsNoteFile.Gen {
        let extraction = try await extract(text, language: language, model: model)
        let keywords = TermNormalizer.keywords(extraction.keywords)
        let concepts = TermNormalizer.concepts(extraction.concepts, keywords: keywords)
        var context = label
        context.terms = extraction.keywords + extraction.concepts
        let check = FactCheck(source: text, merger: merger, context: context).check(extraction.summary)
        var slug: String?
        if let transcript, !transcript.isEmpty,
           let raw = try? await model.title(transcript: String(transcript.prefix(4000)), language: language) {
            slug = Self.slug(raw, transcript: transcript, merger: merger)
        }
        var summary = check.summary
        if let outputLanguage {
            // A translation is held to the summary's own length rule (4 sentences, 600 characters), so it never exceeds
            // what a file may hold (`InsightsLimits.maxSummary`), however much longer the model made it.
            if let s = summary, !s.isEmpty { summary = FactCheck.cut(text: try await model.translate(s, to: outputLanguage)) }
            if let g = slug {
                // A title must stay short: a translation that grows past a title is not used (the title then has no slug).
                let t = VoiceNoteTitleFormat.cleaned(try await model.translate(g, to: outputLanguage))
                slug = (1...8).contains(InsightsWords.count(t)) ? t : nil
            }
        }
        return InsightsNoteFile.Gen(hash: hash, identity: model.identity, summary: summary, keywords: keywords,
                                    concepts: concepts, dropped: check.dropped, slug: slug, outLang: outputLanguage)
    }

    /// One extraction of `text`: a single call up to the chunk size, else per chunk plus a merge.
    static func extract(_ text: String, language: String?, model: any ModelProvider) async throws -> ModelExtraction {
        let chunks = spread(InsightsChunker.chunks(text), max: maxChunks)
        guard !chunks.isEmpty else { throw InsightsProviderError.refused("no text") }
        if chunks.count == 1 {
            do { return try await model.extract(chunks[0], language: language) } catch InsightsProviderError.contextOverflow
                where mayOverflow(chunks[0]) {
                // Halve and retry once.
                let halves = InsightsChunker.chunks(chunks[0], words: max(1, InsightsWords.count(chunks[0]) / 2))
                var parts: [ModelExtraction] = []
                for h in halves { parts.append(try await model.extract(h, language: language)) }
                return parts.count == 1 ? parts[0] : try await model.merge(parts, language: language)
            }
        }
        // One chunk the model cannot answer (a refusal, a runaway answer) costs that chunk, not the note (D16: a
        // 5,000-word PDF lost everything to one chunk); with no part left, its error stands.
        var parts: [ModelExtraction] = []
        var lastError: Error?
        for c in chunks {
            do {
                do { parts.append(try await model.extract(c, language: language)) } catch InsightsProviderError.contextOverflow
                    where mayOverflow(c) {
                    for h in InsightsChunker.chunks(c, words: max(1, InsightsChunker.chunkWords / 2)) {
                        parts.append(try await model.extract(h, language: language))
                    }
                }
            } catch InsightsProviderError.unavailable(let a) {
                throw InsightsProviderError.unavailable(a)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A refusal is the answer to keep (the failure memo backs a refused note off longer).
                if case InsightsProviderError.refused? = lastError {} else { lastError = error }
            }
        }
        if parts.isEmpty, let lastError { throw lastError }
        return parts.count == 1 ? parts[0] : try await model.merge(parts, language: language)
    }

    /// The slug of a voice note's title (D14) from the model's `raw` answer: cleaned, 1 to 6 words, fact-checked
    /// against the transcript with every content word required (a title shows each word). A longer answer that lists things is cut after its last comma, semicolon or dash within
    /// the first six words (D16: a list of eight errands in a voice note was refused whole);
    /// nil when nothing usable is left.
    public static func slug(_ raw: String, transcript: String, merger: TypoMerger?) -> String? {
        var cleaned = VoiceNoteTitleFormat.cleaned(raw)
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        if words.count > 6 {
            guard let cut = (1...5).reversed().first(where: { i in
                words[i - 1].last.map { ",;".contains($0) } == true || ["-", "–", "—"].contains(String(words[i]))
            }) else { return nil }
            cleaned = VoiceNoteTitleFormat.cleaned(words.prefix(cut).joined(separator: " "))
        }
        guard (1...6).contains(InsightsWords.count(cleaned)),
              FactCheck(source: transcript, merger: merger, share: 1).supported(cleaned) else {
            return nil
        }
        return cleaned
    }

    /// Below this many estimated tokens an overflow is the model's runaway answer, not the input (D16: a 17-word note
    /// ran for minutes and then overflowed), so halving the input cannot help: the error stands.
    public static let halvingTokens = 250

    static func mayOverflow(_ chunk: String) -> Bool { InsightsChunker.tokens(chunk) >= halvingTokens }

    /// At most `max` of `chunks`, evenly spaced, the first and the last kept, in order.
    public static func spread<T>(_ chunks: [T], max: Int) -> [T] {
        guard chunks.count > max, max >= 2 else { return max == 1 ? Array(chunks.prefix(1)) : chunks }
        let step = Double(chunks.count - 1) / Double(max - 1)
        return (0..<max).map { chunks[Int((Double($0) * step).rounded())] }
    }
}

/// Topic summaries (design §4 step 9, D8, D19): a notebook or tag with at least 3 summarized notes; up to 25 member
/// summaries in one call, above that per-group passes then one over those; at most 6 sentences; fact-checked against
/// the members' summaries and keywords; labeled "generated".
public enum TopicSummaries {
    public static let minMembers = 3
    public static let singleShot = 25
    public static let maxSentences = 6
    /// The most characters a topic summary keeps, translated or not (`InsightsLimits.maxTopicSummary` is 4,000).
    public static let maxCharacters = 1200
    /// A scope is regenerated at most once a day.
    public static let minInterval: TimeInterval = 24 * 3600

    /// One member: its note, insight hash, summary and keywords.
    public struct Member: Hashable, Sendable {
        public var note: UUID
        public var hash: String
        public var summary: String
        public var keywords: [String]
        public init(note: UUID, hash: String, summary: String, keywords: [String]) {
            self.note = note; self.hash = hash; self.summary = summary; self.keywords = keywords
        }
    }

    /// `membersHash`: SHA-256 hex over the sorted `noteId:hash` pairs.
    public static func membersHash(_ members: [Member]) -> String { MapBuilder.digest(members.map { ($0.note, $0.hash) }) }

    /// True when `scope` needs a summary now: enough members, and none stored for these members, or one made with an
    /// older model, and the last one at least a day old. `stored` is the latest from any device (`latest`), since every
    /// device with the model may make topics (D13); `own`, this device's, also counts as current for it, so two devices
    /// on different OS majors do not take turns remaking the same scope every day.
    public static func isDue(members: [Member], stored: InsightsTopicsFile.Topic?, own: InsightsTopicsFile.Topic? = nil,
                             reader: GenerationIdentity, language: String? = nil, now: Date) -> Bool {
        guard members.count >= minMembers else { return false }
        guard let stored else { return true }
        let digest = membersHash(members)
        for t in [stored, own].compactMap({ $0 }) where t.membersHash == digest && t.gen.outLang == language && t.gen.identity.isCurrent(for: reader) {
            return false
        }
        return now.timeIntervalSince1970 - Double(stored.gen.at) / 1000 >= minInterval
    }

    /// A scope's topic summary as every device shows it (design §6 item 4; `sempere insights topic`, the app's Summary).
    public struct Shown: Hashable, Sendable {
        public var scope: InsightsTopicsFile.Scope
        /// The scope's summarized members now (the "Check sources" list), by note id.
        public var members: [UUID]
        /// The latest stored paragraph from any device, nil when none was made yet.
        public var summary: String?
        public var device: DeviceID?
        public var at: Date?
        /// The members changed since the paragraph was made (their digest differs).
        public var stale: Bool
        /// Enough summarized members for a topic summary (`minMembers`).
        public var eligible: Bool { members.count >= TopicSummaries.minMembers }
    }

    /// The latest stored topic of `scope` from any device's topics file (by `gen.at`, then device id), or nil.
    public static func latest(_ scope: InsightsTopicsFile.Scope, snapshot: InsightsSnapshot) -> (device: DeviceID, topic: InsightsTopicsFile.Topic)? {
        snapshot.topics.compactMap { d, f in f.topics.first { $0.scope == scope }.map { (device: d, topic: $0) } }
            .max { ($0.topic.gen.at, $0.device.rawValue) < ($1.topic.gen.at, $1.device.rawValue) }
    }

    /// `scope` as shown, from its current members (`TopicScopes.members`) and the stored files.
    public static func shown(_ scope: InsightsTopicsFile.Scope, members: [Member], snapshot: InsightsSnapshot) -> Shown {
        let stored = latest(scope, snapshot: snapshot)
        return Shown(scope: scope, members: members.map(\.note), summary: stored?.topic.gen.summary, device: stored?.device,
                     at: stored.map { Date(timeIntervalSince1970: Double($0.topic.gen.at) / 1000) },
                     stale: stored.map { $0.topic.membersHash != membersHash(members) } ?? false)
    }

    /// Every scope with enough summarized members, as shown.
    public static func shownAll(inputs: [InsightsNoteInput], snapshot: InsightsSnapshot, language: String? = nil) -> [Shown] {
        TopicScopes.members(inputs: inputs, snapshot: snapshot, language: language).filter { $0.1.count >= minMembers }
            .map { shown($0.0, members: $0.1, snapshot: snapshot) }
    }

    /// The topic's paragraph from `members` with `model`, fact-checked; nil when nothing survives.
    public static func generate(name: String, members: [Member], language: String?, model: any ModelProvider,
                                merger: TypoMerger?, outputLanguage: String? = nil) async throws -> String? {
        let sorted = members.sorted { $0.note.uuidString < $1.note.uuidString }
        let summaries: [String]
        if sorted.count <= singleShot {
            summaries = sorted.map(\.summary)
        } else {
            var groups: [String] = []
            var i = 0
            while i < sorted.count {
                let group = Array(sorted[i..<min(sorted.count, i + singleShot)])
                groups.append(try await model.summarize(topic: name, summaries: group.map(\.summary), language: language))
                i += singleShot
            }
            summaries = groups
        }
        let paragraph = try await model.summarize(topic: name, summaries: summaries, language: language)
        let source = sorted.map { $0.summary + " " + $0.keywords.joined(separator: " ") }.joined(separator: "\n")
        let checked = FactCheck(source: source, merger: merger).check(paragraph, maxSentences: maxSentences,
                                                                      maxCharacters: maxCharacters).summary
        // The insight language (`insights.language`): put into it after the fact check, as a note's summary is, and held
        // to the same length rule, so it never exceeds what a topics file may hold (`InsightsLimits.maxTopicSummary`).
        guard let outputLanguage, let checked, !checked.isEmpty else { return checked }
        return FactCheck.cut(text: try await model.translate(checked, to: outputLanguage), maxSentences: maxSentences,
                             maxCharacters: maxCharacters)
    }
}

// MARK: - Step 10: the scheduling policy

/// What the scheduling policy knows of one note (design §3.7, §4 step 10).
public struct PolicyNote: Hashable, Sendable {
    public var id: UUID
    public var hash: String
    public var modified: Date?
    public var deleted: Bool
    /// Open in an editor on this device.
    public var open: Bool
    public var hasText: Bool

    public init(id: UUID, hash: String, modified: Date?, deleted: Bool, open: Bool = false, hasText: Bool) {
        self.id = id; self.hash = hash; self.modified = modified; self.deleted = deleted; self.open = open; self.hasText = hasText
    }
}

/// What this device can do now.
public struct PolicyCapabilities: Hashable, Sendable {
    public var model: GenerationIdentity?
    /// The pinned revision this device can embed at (nil: it does not support the pin).
    public var embedRevision: Int?
    /// On power (or charging), thermal state below serious, not in Low Power Mode (the platform's window).
    public var powerWindow: Bool
    public init(model: GenerationIdentity?, embedRevision: Int?, powerWindow: Bool) {
        self.model = model; self.embedRevision = embedRevision; self.powerWindow = powerWindow
    }
}

/// One unit of work, and why.
public enum WorkItem: Hashable, Sendable {
    case generate(UUID)
    case embed(UUID)
    /// Replace this device's sidecar with a tombstone: the note was deleted.
    case tombstone(UUID)
    /// This device's `gen` is stale while another device's is current: drop it (keeping any current `emb`).
    case dropStaleGen(UUID)
    case rebuildMap
    case writeDeviceRecord
}

public enum InsightsPolicy {
    /// A note is eligible once its text has been unchanged for 10 minutes (its modified date stands in for that).
    public static let settle: TimeInterval = 600
    public static let recent: TimeInterval = 30 * 24 * 3600
    /// A rebuild runs when more than 10% of the notes changed since `built`, or weekly.
    public static let rebuildFraction = 0.1
    public static let rebuildEvery: TimeInterval = 7 * 24 * 3600
    /// Device records are written at most daily, and when they change.
    public static let recordEvery: TimeInterval = 24 * 3600

    /// Order (design §3.7): notes edited in the last 30 days newest first, then the rest by modified date (newest
    /// first), ties by id.
    public static func order(_ notes: [PolicyNote], now: Date) -> [PolicyNote] {
        notes.sorted { a, b in
            let ra = (a.modified.map { now.timeIntervalSince($0) <= recent } ?? false)
            let rb = (b.modified.map { now.timeIntervalSince($0) <= recent } ?? false)
            if ra != rb { return ra }
            let ma = a.modified ?? .distantPast, mb = b.modified ?? .distantPast
            if ma != mb { return ma > mb }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// The work for this device, in order. `force` ignores the settle time and regenerates stale and current alike;
    /// `ignoreSettle` only skips the settle time ("Process Now": open notes still wait, current ones are not redone).
    /// Any capable device does the work (D21): a note is generated when this device has the model and no device (this one
    /// included) holds a current `gen` for it, embedded when this device supports the pin and no device holds a current
    /// vector, and the map is rebuilt when it is due against the best map of any device. Readers settle a race between
    /// devices by a fixed order (`InsightsSnapshot.bestGen`, `bestMap`). Power only decides when, never who.
    public static func plan(notes: [PolicyNote], snapshot: InsightsSnapshot, me: DeviceID, settings: InsightsSettings,
                            capabilities c: PolicyCapabilities, pinKey: EmbeddingKey?, now: Date, force: Bool = false,
                            ignoreSettle: Bool = false, backoff: [UUID: Date] = [:], deviceRecordChanged: Bool,
                            standing: MapCompatibility = .compatible) -> [WorkItem] {
        guard settings.enabled else { return [] }
        var out: [WorkItem] = []
        let generates = c.powerWindow && c.model != nil
        // An incompatible device keeps its vectors local (D21): it neither writes shared vectors nor the map.
        let embeds = c.embedRevision != nil && pinKey != nil && standing.mayWriteShared
        let record = snapshot.devices[me]
        if record == nil || deviceRecordChanged
            || record.map({ now.timeIntervalSince1970 - Double($0.written) / 1000 >= recordEvery }) == true {
            out.append(.writeDeviceRecord)
        }
        for n in order(notes, now: now) {
            let mine = snapshot.notes[n.id]?[me]
            if n.deleted {
                if let mine, !mine.isTombstone { out.append(.tombstone(n.id)) }
                continue
            }
            guard n.hasText else { continue }
            let eligible = force || (!n.open && (ignoreSettle || (n.modified.map { now.timeIntervalSince($0) >= settle } ?? true)))
            guard eligible else { continue }
            // A back-off (a failed generation, `InsightsFailureMemo`) holds the model back, never the embedding.
            let backedOff = backoff[n.id].map { $0 > now && !force } ?? false
            let others = (snapshot.notes[n.id] ?? [:]).filter { $0.key != me }
            let currentElsewhere = others.values.contains { f in
                f.gen.map { $0.hash == n.hash && $0.outLang == settings.language && (c.model.map($0.identity.isCurrent(for:)) ?? true) } ?? false
            }
            if generates, !backedOff, let model = c.model {
                let ownCurrent = mine?.gen.map { $0.hash == n.hash && $0.outLang == settings.language && $0.identity.isCurrent(for: model) } ?? false
                if force ? true : (!ownCurrent && !currentElsewhere) { out.append(.generate(n.id)) }
            }
            // This device's `gen` is for older text, or for this text in another insight language than the one set, while
            // another device holds a current one: it goes, so a rewrite of this file never brings the old one back.
            if let g = mine?.gen, g.hash != n.hash || g.outLang != settings.language, currentElsewhere {
                out.append(.dropStaleGen(n.id))
            }
            if embeds, let key = pinKey {
                // Skipped when any device holds the vector (its bytes are the same on every device at one key).
                if force || !snapshot.hasCurrentEmb(for: n.id, hash: n.hash, key: key) { out.append(.embed(n.id)) }
            }
        }
        if embeds, let key = pinKey {
            let map = snapshot.bestMap(key: key)?.map
            let embedded = notes.filter { !$0.deleted && snapshot.emb(for: $0.id, key: key, hash: nil) != nil }
            let changed = embedded.filter { e in
                guard let map else { return true }
                let written = snapshot.emb(for: e.id, key: key, hash: nil)?.written ?? 0
                return written > map.written || map.positions[e.id] == nil
            }.count + (map.map { m in m.positions.keys.filter { id in !embedded.contains { $0.id == id } }.count } ?? 0)
            let due: Bool
            if let map {
                let base = max(1, map.built?.notes ?? 1)
                due = Double(changed) > rebuildFraction * Double(base)
                    || (changed > 0 && now.timeIntervalSince1970 - Double(map.written) / 1000 >= rebuildEvery)
            } else {
                due = embedded.count >= 3 || notes.contains { !$0.deleted && $0.hasText }
            }
            if due { out.append(.rebuildMap) }
        }
        return out
    }
}
