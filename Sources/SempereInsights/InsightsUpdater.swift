import Foundation
import Sempere

// MARK: - The updater (docs/design/1.2-note-insights.md §3.7, §3.8, §4, D13-D15; `sempere insights update`)
//
// One pass over a vault for this device: delete its own files under an earlier key (written again below) and what
// removed devices left, then per note (in the policy's order) generate and embed what no device has a current result for
// (any capable device, D21), title voice notes, tombstone, then rebuild the map when it is due, write this device's record and the topic summaries due. Every write goes through
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
        for w in InsightsWords.words(text) where w.count >= 4 && !w.contains(where: \.isNumber) && isContentWord(w) {
            out.insert(TermNormalizer.singular(w))
        }
        return out
    }

    /// A note's generated keywords and concepts (`RelatedInput.terms`).
    public static func terms(gen: InsightsNoteFile.Gen?) -> Set<String> {
        Set((gen?.keywords ?? []).map(\.t) + (gen?.concepts ?? []))
    }

    /// A text word that says something about a note's subject (D16: map labels read "maybe, hopefully, going" and
    /// "eeeee"): not a stop word, not one of the words summaries talk about notes with, not filler, not junk.
    static func isContentWord(_ w: String) -> Bool {
        !InsightsStoplist.generic.contains(w) && !InsightsStoplist.filler.contains(w) && !TermNormalizer.isJunk(w)
            && (!InsightsStoplist.summaryLanguage.contains(w) || InsightsStoplist.subjectWords.contains(w))
    }
}

public struct InsightsUpdateOptions: Sendable {
    public var note: UUID?
    /// Regenerate current notes too, past the settle time, open notes and the back-off (`--force`).
    public var force = false
    /// Skip the 10-minute settle time only ("Process Now"): open notes still wait, current ones are not redone.
    public var ignoreSettle = false
    /// Failures in the memo recorded before this moment do not hold notes or topics back ("Process Now": the start of its
    /// pass, so what fails during the pass waits instead of being asked again in its next run).
    public var ignoreBackoffBefore: Date?
    public var limit: Int?
    public var embeddingsOnly = false
    public var dryRun = false
    public var rebuildMap = false
    public var topics = true
    public var titles = true
    public var now = Date()
    public var platform = InsightsPlatform.current
    public var powerWindow = true
    /// This device's memo of failed generations (`InsightsFailureMemo`): read for the policy's back-off and updated
    /// after the run; nil keeps none (tests, a dry run reads it only).
    public var failureMemo: URL?
    /// Notes open in an editor on this device: not eligible while open (design §3.7, `PolicyNote.open`), and never
    /// retitled while open.
    public var openNotes: Set<UUID> = []
    /// This device's settings type (the settings are read as this kind of device reads them): nil reads the top level only.
    public var deviceType: SettingsDeviceType?
    public init() {}
}

/// What a pass did (or would do, `dryRun`).
public struct InsightsUpdateReport: Hashable, Sendable, Codable {
    public var device: String = ""
    public var generated: [String] = []
    public var embedded: [String] = []
    public var tombstoned: [String] = []
    public var dropped: [String] = []
    public var titled: [String] = []
    public var restoredTitles: [String] = []
    public var removed: [String] = []
    public var mapBuilt = false
    public var deviceRecord = false
    public var topics: [String] = []
    public var pinSet: [String: Int] = [:]
    /// Notes whose generation failed, with why (backed off).
    public var failures: [String: String] = [:]
    /// Why nothing was generated or embedded (`model unavailable: …`), when so.
    public var notes: [String] = []
    /// Notes this device would summarize now but for a failure remembered in the memo (`InsightsFailureMemo`), and why the
    /// first of them failed.
    public var backedOff = 0
    public var backedOffReason: String?
    /// Notes this device would summarize but for the 10-minute settle time, or being open in an editor here.
    public var waitingToSettle = 0
    public var waitingOpen = 0
    public var dryRun = false
    /// The run was cancelled (the app's background time ran out): what was made so far is saved, nothing after the
    /// notes ran (titles, the map, the record, topics).
    public var cancelled = false
    public init() {}
}

/// Why a pass made nothing (no summary, no topic), from its reports: what Settings shows under "Process Now" instead of
/// ending silently. Worded by the app.
public enum InsightsPassOutcome: Hashable, Sendable {
    /// This device cannot make summaries (Apple Intelligence off, not ready, not eligible, no model here).
    case modelUnavailable(ModelAvailability?)
    /// Generations failed: how many, and the first one's error.
    case failed(count: Int, reason: String)
    /// Notes wait after failing earlier (the memo's back-off), and why the first of them failed.
    case backedOff(count: Int, reason: String?)
    /// Notes edited in the last 10 minutes wait to settle.
    case waitingToSettle(Int)
    /// Notes wait because they are open in an editor here.
    case noteOpen(Int)
    /// Every note with text is summarized (here or on another device).
    case nothingToDo
    /// The pass could not start (the app's early checks, a forced pass only): the vault is read-only here.
    case readOnly
    /// The pass could not start: this device is not in the vault's device list, so it cannot write.
    case notListed
    /// The pass could not start or stopped with an error: why (the app's words of the error).
    case cannotWrite(String)

    /// The outcome of a pass of `reports` on a device whose model is `availability` (nil: no model provider); nil when the
    /// pass made something, was cut off, or ran no update.
    public static func of(_ reports: [InsightsUpdateReport], availability: ModelAvailability?) -> InsightsPassOutcome? {
        guard let last = reports.last, !last.cancelled else { return nil }
        if reports.contains(where: { !$0.generated.isEmpty || !$0.topics.isEmpty }) { return nil }
        if availability?.isAvailable != true { return .modelUnavailable(availability) }
        // Notes only (failures are keyed by note id or by topic scope name): a topic that failed is no note's failure.
        var failures: [String: String] = [:]
        for r in reports { failures.merge(r.failures.filter { UUID(uuidString: $0.key) != nil }) { a, _ in a } }
        if let first = failures.keys.sorted().first, let why = failures[first] { return .failed(count: failures.count, reason: why) }
        if last.backedOff > 0 { return .backedOff(count: last.backedOff, reason: last.backedOffReason) }
        if last.waitingToSettle > 0 { return .waitingToSettle(last.waitingToSettle) }
        if last.waitingOpen > 0 { return .noteOpen(last.waitingOpen) }
        return .nothingToDo
    }
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

/// Writes one delta to `note` (a voice note's rename, D14) whose ops `build` decides from the note as it is on disk at
/// the moment of writing (nil: nothing to write, a rename in between won), and returns the revision written, or nil.
/// The app's: through its model's `DeviceClock` and edit gate (CLAUDE.md: never open a second clock on a state file a
/// `DeviceClock` holds); without one the updater writes with `Vault.apply` and the machine's `DeviceState` (the CLI).
public typealias InsightsTitleWriter = @Sendable (_ note: UUID, _ build: @escaping @Sendable () throws -> [Op]?, _ now: Date)
    async throws -> RevisionName?

public struct InsightsUpdater: Sendable {
    public var vault: Vault
    public var model: (any ModelProvider)?
    public var embedder: (any EmbeddingProvider)?
    /// The device state file voice-note titles are written with (`Vault.apply`).
    public var deviceState: URL
    public var app: String
    /// Where voice-note titles are written (nil: `Vault.apply` with `deviceState`).
    public var titleWriter: InsightsTitleWriter?
    /// The device id this device's revisions carry, when the caller knows it (the app's clock); nil: read from
    /// `deviceState`.
    public var writerDevice: DeviceID?

    public init(vault: Vault, model: (any ModelProvider)?, embedder: (any EmbeddingProvider)?, deviceState: URL, app: String) {
        self.vault = vault; self.model = model; self.embedder = embedder; self.deviceState = deviceState; self.app = app
    }

    /// The device id this device's revisions carry (its state file's), which a `titleOp` of its own names; nil before
    /// the state file exists (then no `titleOp` is this device's).
    var revisionWriter: DeviceID? {
        if let writerDevice { return writerDevice }
        guard FileManager.default.fileExists(atPath: deviceState.path) else { return nil }
        return (try? DeviceState.loadOrCreate(at: deviceState))?.device
    }

    public func run(_ o: InsightsUpdateOptions, notes inputs: [InsightsNoteInput]) async throws -> InsightsUpdateReport {
        var report = InsightsUpdateReport()
        report.dryRun = o.dryRun
        var settings = InsightsSettings.read(vault, type: o.deviceType)
        guard settings.enabled else {
            // Off (here or by another device): this device's memo of failures goes too.
            if let url = o.failureMemo, !o.dryRun { InsightsFailureMemo.remove(at: url) }
            throw InsightsUpdateError.disabled
        }
        let store = InsightsStore(vault: vault)
        let me = try store.writer()
        report.device = me.rawValue
        if !o.dryRun {
            report.removed = try store.removeOwnEarlierKey() + store.removeRemovedDevices()
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
        let standing = canEmbed == nil ? MapCompatibility.vectorReader
            : mapStanding(snapshot: snapshot, me: me, records: records, settings: settings, language: main, key: pinKey)
        let changedRecord = snapshot.devices[me].map { !Self.sameRecord($0, ownRecord) } ?? true
        let caps = PolicyCapabilities(model: o.embeddingsOnly ? nil : usable?.identity, embedRevision: canEmbed, powerWindow: o.powerWindow)
        let selected = o.note.map { id in inputs.filter { $0.id == id } } ?? inputs
        let policyNotes = selected.map {
            PolicyNote(id: $0.id, hash: $0.hash, modified: $0.modified, deleted: $0.deleted, open: o.openNotes.contains($0.id),
                       hasText: !$0.text.isEmpty)
        }
        var memo = o.failureMemo.map { InsightsFailureMemo.load(from: $0, vault: vault) } ?? InsightsFailureMemo()
        let backoff = usable.map { m in
            memo.backoff(notes: selected.map { ($0.id, $0.hash) }, identity: m.identity, ignoringBefore: o.ignoreBackoffBefore)
        } ?? [:]
        var plan = InsightsPolicy.plan(notes: policyNotes, snapshot: snapshot, me: me, settings: settings, capabilities: caps,
                                       pinKey: pinKey, now: o.now, force: o.force, ignoreSettle: o.ignoreSettle, backoff: backoff,
                                       deviceRecordChanged: changedRecord, standing: standing)
        if o.rebuildMap, pinKey != nil, standing.mayWriteShared, !plan.contains(.rebuildMap) { plan.append(.rebuildMap) }
        // What waits, and why ("Process Now"'s outcome): the notes a plan with no settle time, no open notes and no
        // back-off would summarize that this one does not.
        if usable != nil, !o.force {
            var free = policyNotes
            for i in free.indices { free[i].open = false }
            let unheld = InsightsPolicy.plan(notes: free, snapshot: snapshot, me: me, settings: settings, capabilities: caps, pinKey: pinKey,
                                             now: o.now, ignoreSettle: true, deviceRecordChanged: false, standing: standing)
            let planned = Set(plan.compactMap { if case .generate(let id) = $0 { return id } else { return nil } })
            let open = Set(policyNotes.filter(\.open).map(\.id))
            for case .generate(let id) in unheld where !planned.contains(id) {
                if let until = backoff[id], until > o.now {
                    report.backedOff += 1
                    if report.backedOffReason == nil { report.backedOffReason = memo.reason(note: id) }
                } else if open.contains(id) {
                    report.waitingOpen += 1
                } else {
                    report.waitingToSettle += 1
                }
            }
            if report.backedOff > 0 { report.notes.append("\(report.backedOff) notes backed off (failed earlier; --force to retry)") }
        }
        let byId = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        let merger = InsightsNotes.merger(inputs)
        var generations = 0
        var pending: [UUID: InsightsNoteFile] = [:]
        func own(_ id: UUID) -> InsightsNoteFile {
            pending[id] ?? snapshot.notes[id]?[me] ?? InsightsNoteFile(noteId: id, device: me, written: 0)
        }
        var cancelled = false
        planLoop: for item in plan {
            // Cancelled (background time ran out): stop between notes; what was made so far is saved below.
            if Task.isCancelled { cancelled = true; break planLoop }
            switch item {
            case .generate(let id):
                guard let note = byId[id], let model = usable else { continue }
                if let limit = o.limit, generations >= limit { continue }
                generations += 1
                do {
                    let isVoice = !note.transcript.isEmpty
                    let gen = try await InsightsGenerator.generate(text: note.text, hash: note.hash, language: note.language,
                                                                   model: model, merger: merger,
                                                                   transcript: isVoice ? note.transcript : nil,
                                                                   label: FactCheck.Context(title: note.title, notebook: note.notebook,
                                                                                            tags: note.tags))
                    var f = own(id); f.gen = gen; f.lang = note.language
                    pending[id] = f
                    report.generated.append(id.uuidString.lowercased())
                    memo.clear(note: id)
                } catch {
                    // A cancellation is not the note's failure: no back-off, and the run stops.
                    if error is CancellationError || Task.isCancelled { generations -= 1; cancelled = true; break planLoop }
                    report.failures[id.uuidString.lowercased()] = "\(error)"
                    memo.record(note: id, hash: note.hash, identity: model.identity, error: error, now: o.now)
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
            case .rebuildMap, .writeDeviceRecord:
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
            // Device-local and only a saving of model time: a memo that cannot be written is no reason to fail the run.
            if let url = o.failureMemo { try? memo.save(to: url, vault: vault) }
        }
        if cancelled || Task.isCancelled {
            report.cancelled = true
            return report
        }
        // Voice-note titles (D14): from any device's current `gen` slug, while the title is the capture default.
        // Any device may set a title (D21), once per note: only while the title is still the capture default, from the best
        // `gen`'s slug, so devices that race write the same title (format.md §16.8, D14); `insights title` stays manual.
        if o.titles, !o.embeddingsOnly {
            for note in selected where !note.deleted && !note.transcript.isEmpty && !o.openNotes.contains(note.id) {
                if Task.isCancelled { report.cancelled = true; return report }
                guard let outcome = try await applyTitle(note, snapshot: snapshot, me: me, format: settings.voiceNoteTitle,
                                                   dryRun: o.dryRun, now: o.now) else { continue }
                switch outcome {
                case .apply: report.titled.append(note.id.uuidString.lowercased())
                case .restore: report.restoredTitles.append(note.id.uuidString.lowercased())
                case .keep: break
                }
            }
            if !o.dryRun { snapshot = store.snapshot() }
        }
        if Task.isCancelled { report.cancelled = true; return report }
        // The pin is written by the first map build (D12).
        if plan.contains(.rebuildMap), let r = canEmbed, settings.pins[main] == nil {
            report.pinSet[main] = r
            if !o.dryRun {
                try vault.updateSharedSettingsUnderWriteLock { s in
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
                let map = Self.buildMap(snapshot: snapshot, me: me, key: key, inputs: inputs, previous: snapshot.bestMap(key: key)?.map,
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
                let comp = InsightsReader(vault: vault, snapshot: snapshot, settings: InsightsSettings.read(vault, type: o.deviceType))
                    .compatibility(me: me, embedder: embedder, language: main)
                record.compatibility = comp.rawValue
                record.against = snapshot.bestMap(rev: pin, language: main)?.map.written
                try store.write(.device(record), now: o.now)
            }
        }
        // Topic summaries: on any device with the model (D13), judged against the latest from every device.
        if o.topics, !o.embeddingsOnly, o.powerWindow, let model = usable {
            report.topics = try await updateTopics(store: store, snapshot: snapshot, inputs: inputs, model: model, merger: merger,
                                                   me: me, o: o, limit: o.limit.map { max(0, $0 - generations) }, report: &report)
        }
        return report
    }

    // MARK: Titles

    enum TitleOutcome { case apply, restore, keep }

    /// Applies (or restores) a voice note's title; nil when there is nothing to do.
    func applyTitle(_ note: InsightsNoteInput, snapshot: InsightsSnapshot, me: DeviceID, format: String, dryRun: Bool,
                    now: Date) async throws -> TitleOutcome? {
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
        let writer = revisionWriter
        let decision = titles.decide(applied: ownFile?.titleOp, proposed: proposed, writer: writer,
                                     automatic: snapshot.automaticTitleStamps(for: note.id))
        switch decision {
        case .keep: return nil
        case .apply(let title):
            guard !dryRun else { return .apply }
            guard let stamp = try await rename(note.id, decision: decision, applied: ownFile?.titleOp, proposed: proposed,
                                               writer: writer, automatic: snapshot.automaticTitleStamps(for: note.id),
                                               now: now) else { return nil }
            var f = ownFile ?? InsightsNoteFile(noteId: note.id, device: me, written: 0)
            f.titleOp = .init(stamp: stamp.description, title: title)
            try InsightsStore(vault: vault).write(.note(f), now: now)
            return .apply
        case .restore:
            guard !dryRun else { return .restore }
            guard try await rename(note.id, decision: decision, applied: ownFile?.titleOp, proposed: proposed, writer: writer,
                                   automatic: snapshot.automaticTitleStamps(for: note.id), now: now) != nil else { return nil }
            return .restore
        }
    }

    /// One rename delta through `titleWriter`, else `Vault.apply` with `deviceState`; the stamp of the revision written,
    /// nil when the note as it is on disk at the moment of writing no longer gives `decision` (a rename in between wins).
    func rename(_ id: UUID, decision: VoiceNoteTitleState.Decision, applied: InsightsNoteFile.TitleOp?, proposed: String?,
                writer: DeviceID?, automatic: Set<Stamp> = [], now: Date) async throws -> Stamp? {
        let vault = self.vault
        let build: @Sendable () throws -> [Op]? = {
            let loaded = try vault.loadNote(id)
            let state = try vault.reconstruct(loaded)
            let again = VoiceNoteTitleState(revisions: loaded.revisions, state: state)
                .decide(applied: applied, proposed: proposed, writer: writer, automatic: automatic)
            switch (again, decision) {
            case (.apply(let a), .apply(let b)) where a == b: return NoteOps.rename(to: a, state: state)
            case (.restore(let a), .restore(let b)) where a == b: return NoteOps.rename(to: a, state: state)
            default: return nil
            }
        }
        if let titleWriter {
            guard let r = try await titleWriter(id, build, now) else { return nil }
            return Stamp(hlc: r.hlc, device: r.device)
        }
        guard let ops = try build() else { return nil }
        let rev = try vault.apply(ops, to: id, deviceState: deviceState, app: app, wall: now)
        return Stamp(hlc: rev.hlc, device: rev.device)
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
        return (titles.decide(applied: me.flatMap { snapshot.notes[note.id]?[$0]?.titleOp }, proposed: proposed, writer: revisionWriter,
                              automatic: snapshot.automaticTitleStamps(for: note.id)),
                titles.isVoiceNote)
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
        let decision = titles.decide(applied: ownFile?.titleOp, proposed: proposed, writer: revisionWriter,
                                     automatic: snapshot.automaticTitleStamps(for: note.id))
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

    /// The map of the vault's vectors at `key` (design §3.8; any device's, D21): mean-centered clusters and layout,
    /// warm-started from `previous`. Deterministic: the same vectors, summaries and `previous` give the same clusters,
    /// labels and positions on every device, so devices that rebuild at once write the same map (only `device`,
    /// `written` and the builder's canaries differ).
    public static func buildMap(snapshot: InsightsSnapshot, me: DeviceID, key: EmbeddingKey, inputs: [InsightsNoteInput],
                                previous: InsightsMapFile?, canaries: [[Float]]?) -> InsightsMapFile? {
        let live = inputs.filter { !$0.deleted }
        var rel: [RelatedInput] = []
        var pairs: [(UUID, String)] = []
        var dim: Int?
        for n in live {
            guard let e = snapshot.emb(for: n.id, key: key, hash: n.hash)?.emb, let v = e.vector else { continue }
            dim = dim ?? v.count
            guard v.count == dim else { continue }
            let gen = snapshot.bestGen(for: n.id, hash: n.hash)?.gen
            rel.append(RelatedInput(id: n.id, vector: v, tokens: InsightsNotes.tokens(text: n.text, gen: gen), words: InsightsWords.count(n.text),
                                    terms: InsightsNotes.terms(gen: gen)))
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

    /// This device's standing toward the shared map before it writes anything (D21): `compatible`, `noMap` or
    /// `incompatible`/`vectorReader` (the last two write nothing shared). With no map yet, the canaries in the device
    /// records decide: the capable device with the lowest id that has canaries at `key` is the reference (a device that is
    /// not it writes only when its canaries agree with the reference's), so devices that disagree do not both start a set.
    func mapStanding(snapshot: InsightsSnapshot, me: DeviceID, records: [DeviceID: InsightsDeviceRecord],
                     settings: InsightsSettings, language: String, key: EmbeddingKey?) -> MapCompatibility {
        let reader = InsightsReader(vault: vault, snapshot: snapshot, settings: settings)
        let comp = reader.compatibility(me: me, embedder: embedder, language: language)
        guard comp == .noMap, let key, let embedder else { return comp }
        guard let mine = try? Canaries.vectors(embedder, language: key.lang, revision: key.rev) else { return .incompatible }
        let others = records.filter { $0.key != me }.compactMap { d, r -> (DeviceID, [[Float]], EmbeddingKey)? in
            guard let c = r.canaries.first(where: { $0.key == key && $0.canaries.set == Canaries.set }),
                  let v = c.canaries.vectors(dimension: c.dim) else { return nil }
            return (d, v, c.key)
        }.sorted { $0.0.rawValue < $1.0.rawValue }
        guard let reference = others.first, reference.0.rawValue < me.rawValue else { return .noMap }
        return Canaries.compatible(mine: mine, myKey: key, theirs: reference.1, theirKey: reference.2) ? .noMap : .incompatible
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

    /// The topic summaries due on this device (design §4 step 9, D8): each scope at most once a day, never one backed off
    /// in the failure memo (the model threw or nothing survived the fact check), stopping between scopes when the task
    /// is cancelled. Each made scope is written at once (`updateOwnTopics`), so a cancelled run keeps what it made.
    /// Returns the scopes written (a dry run: the scopes due).
    func updateTopics(store: InsightsStore, snapshot: InsightsSnapshot, inputs: [InsightsNoteInput], model: any ModelProvider,
                      merger: TypoMerger, me: DeviceID, o: InsightsUpdateOptions, limit: Int?,
                      report: inout InsightsUpdateReport) async throws -> [String] {
        let scopes = TopicScopes.members(inputs: inputs, snapshot: snapshot)
        let own = snapshot.topics[me]?.topics ?? []
        var memo = o.failureMemo.map { InsightsFailureMemo.load(from: $0, vault: vault) } ?? InsightsFailureMemo()
        var memoChanged = false
        defer { if memoChanged, !o.dryRun, let url = o.failureMemo { try? memo.save(to: url, vault: vault) } }
        var made: [String] = []
        var attempts = 0
        for (scope, members) in scopes {
            if let limit, attempts >= limit { break }
            if Task.isCancelled { report.cancelled = true; break }
            let name = TopicScopes.name(scope)
            let latest = TopicSummaries.latest(scope, snapshot: snapshot)?.topic
            guard TopicSummaries.isDue(members: members, stored: latest, own: own.first { $0.scope == scope }, reader: model.identity,
                                       now: o.now) else { continue }
            let digest = TopicSummaries.membersHash(members)
            if !o.force, let until = memo.topicBackoff(name, membersHash: digest, identity: model.identity,
                                                       ignoringBefore: o.ignoreBackoffBefore), until > o.now { continue }
            attempts += 1
            if o.dryRun { made.append(name); continue }
            do {
                guard try await writeTopic(scope, members: members, inputs: inputs, model: model, merger: merger, store: store,
                                           now: o.now) else {
                    report.failures[name] = "nothing survived the fact check"
                    memo.recordTopic(name, membersHash: digest, identity: model.identity, error: nil, now: o.now)
                    memoChanged = true
                    continue
                }
                made.append(name)
                if memo.topics[name] != nil { memo.clearTopic(name); memoChanged = true }
            } catch {
                if error is CancellationError || Task.isCancelled { report.cancelled = true; break }
                report.failures[name] = "\(error)"
                memo.recordTopic(name, membersHash: digest, identity: model.identity, error: error, now: o.now)
                memoChanged = true
            }
        }
        return made
    }

    /// Makes `scope`'s summary from `members` and writes it into this device's topics file; false when nothing survived
    /// the fact check (nothing written).
    func writeTopic(_ scope: InsightsTopicsFile.Scope, members: [TopicSummaries.Member], inputs: [InsightsNoteInput],
                    model: any ModelProvider, merger: TypoMerger, store: InsightsStore, now: Date) async throws -> Bool {
        let name = TopicScopes.name(scope)
        guard let text = try await TopicSummaries.generate(name: name, members: members, language: InsightsNotes.languageOf(members, inputs),
                                                           model: model, merger: merger) else { return false }
        try Task.checkCancellation()
        let topic = InsightsTopicsFile.Topic(scope: scope, members: members.count, membersHash: TopicSummaries.membersHash(members),
                                             gen: .init(identity: model.identity, at: InsightsCodec.nextWritten(after: nil, now: now), summary: text))
        try store.updateOwnTopics(now: now) { topics in
            topics.removeAll { $0.scope == scope }
            topics.append(topic)
            topics.sort { TopicScopes.name($0.scope) < TopicScopes.name($1.scope) }
            return true
        }
        return true
    }

    /// Why a topic summary was not made now (`regenerateTopic`).
    public enum TopicError: Error, Hashable, Sendable, CustomStringConvertible {
        /// No usable model on this device.
        case unavailable(String)
        /// Fewer summarized members than `TopicSummaries.minMembers`.
        case tooFewMembers(Int)
        /// Nothing survived the fact check; nothing was written.
        case factCheck
        public var description: String {
            switch self {
            case .unavailable(let why): return "model unavailable: \(why)"
            case .tooFewMembers(let n):
                return "\(n) summarized note(s); a topic needs at least \(TopicSummaries.minMembers)"
            case .factCheck: return "the summary did not survive the fact check; nothing written"
            }
        }
    }

    /// Makes `scope`'s topic summary now on this device and writes it ("Regenerate", `sempere insights topic --generate`),
    /// whatever the once-a-day rule and the failure memo say; a success clears the memo's entry. Returns it as shown.
    public func regenerateTopic(_ scope: InsightsTopicsFile.Scope, inputs: [InsightsNoteInput], failureMemo: URL? = nil,
                                now: Date = Date()) async throws -> TopicSummaries.Shown {
        try vault.requireWritable()
        guard let model, model.availability.isAvailable else {
            throw TopicError.unavailable(model?.availability.reason ?? "no model provider")
        }
        let store = InsightsStore(vault: vault)
        _ = try store.writer()
        let members = TopicScopes.members(inputs: inputs, snapshot: store.snapshot()).first { $0.0 == scope }?.1 ?? []
        guard members.count >= TopicSummaries.minMembers else { throw TopicError.tooFewMembers(members.count) }
        guard try await writeTopic(scope, members: members, inputs: inputs, model: model, merger: InsightsNotes.merger(inputs),
                                   store: store, now: now) else { throw TopicError.factCheck }
        if let failureMemo {
            var memo = InsightsFailureMemo.load(from: failureMemo, vault: vault)
            let name = TopicScopes.name(scope)
            if memo.topics[name] != nil { memo.clearTopic(name); try? memo.save(to: failureMemo, vault: vault) }
        }
        return TopicSummaries.shown(scope, members: members, snapshot: store.snapshot())
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
