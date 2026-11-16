import Foundation
import Sempere
import SempereInsights

// MARK: - Note Insights in the app (docs/design/1.2-note-insights.md §3.7, §6, D13-D16; Insights PR 2)
//
// The model's half: the vault's insights settings and this device's capability, the status Settings shows, a compact
// index of what the note panel shows (each note's summary and keywords, the related graph's edges, the clusters), and
// the passes that make insights on this device (the package's `InsightsUpdater`, as `sempere insights update`), in the
// foreground while the device is on power and from the background processing task. Every write goes through the
// package (`InsightsStore`, `InsightsSettingsWrite`, `updateSharedSettingsUnderWriteLock`), which takes the vault's
// write lock itself: nothing here holds that lock around a store call (`VaultFileLock` is not reentrant; PR 1 notes,
// item 6). Voice-note titles are written through the model's own clock (`writeInsightsTitle`).
//
// Memory (review of #50, L7): the vault's sidecars and vectors are read for a refresh and dropped after it; the model
// keeps only the index (summaries, keywords, at most 8 edges per note, cluster members), and the related graph is built
// once per change over at most `InsightsServices.maxGraphNotes` notes, never per selection.

/// The platform's half of Note Insights (`AppModelServices.insights`): the app's Apple providers and power state;
/// headless, none.
public struct InsightsServices: Sendable {
    /// Apple's on-device model (`SempereInsightsApple`); nil where there is none.
    public var model: @Sendable () -> (any ModelProvider)?
    /// The sentence embedder; nil where there is none.
    public var embedder: @Sendable () -> (any EmbeddingProvider)?
    /// Now is a time to process (design §3.7): on power (charging on iPhone and iPad), not in Low Power Mode, thermal
    /// state below serious.
    public var powerWindow: @MainActor @Sendable () -> Bool
    /// The most notes the related graph takes on this device (its matrices grow with the square of the notes).
    public var maxGraphNotes: Int
    /// This platform (the device record's).
    public var platform: InsightsPlatform

    public init(model: @escaping @Sendable () -> (any ModelProvider)?, embedder: @escaping @Sendable () -> (any EmbeddingProvider)?,
                powerWindow: @escaping @MainActor @Sendable () -> Bool, maxGraphNotes: Int = 4000,
                platform: InsightsPlatform = .current) {
        self.model = model; self.embedder = embedder; self.powerWindow = powerWindow; self.maxGraphNotes = maxGraphNotes
        self.platform = platform
    }

    /// No providers (tests, previews).
    public static let none = InsightsServices(model: { nil }, embedder: { nil }, powerWindow: { true })
}

/// What this device can do (from its providers: read when a vault unlocks, when Settings shows Note Insights and at the
/// start of every pass, since Apple Intelligence can be turned on or finish getting ready at any time).
public struct InsightsCapability: Equatable, Sendable {
    /// Apple's on-device model, or why not (nil: no provider in this build or OS).
    public var model: ModelAvailability?
    /// The sentence embedder exists here.
    public var embedder = false

    public init(model: ModelAvailability? = nil, embedder: Bool = false) { self.model = model; self.embedder = embedder }

    /// Summaries, keywords and titles can be made here.
    public var generates: Bool { model?.isAvailable == true }
    /// The device can hold the work device (D13): it makes summaries, or embeds (related notes and the map at least).
    public var canWork: Bool { generates || embedder }
}

/// Why Note Insights could not do something (worded by the app).
public enum InsightsProblem: Equatable, Sendable {
    /// The vault is read-only here.
    case readOnly
    /// A write failed (the error's words).
    case failed(String)
}

/// Why "Regenerate" made no topic summary (worded by the app).
public enum InsightsTopicProblem: Equatable, Sendable {
    /// Nothing survived the fact check; the stored paragraph (if any) stays.
    case factCheck
    /// Fewer summarized notes than a topic summary needs.
    case tooFewMembers
    /// The model is not available on this device.
    case unavailable
    /// The model or the write failed (the error's words).
    case failed(String)
}

/// What Settings and the note views read (observed: `AppModel.insights`).
public struct InsightsModelState: Equatable, Sendable {
    /// The vault's insights settings as this device reads them.
    public var settings = InsightsSettings()
    /// On, off (explicitly) or unset (format.md §16.6).
    public var mode: Vault.InsightsMode = .unset
    /// This device's capability.
    public var capability = InsightsCapability()
    /// Processed counts, devices, the work device and the map (`InsightsReader.status`); nil until read.
    public var status: InsightsReader.Status?
    /// A pass is running on this device.
    public var isWorking = false
    /// When the last pass on this device ended, and what it did.
    public var lastPass: Date?
    public var lastReport: InsightsUpdateReport?
    /// Why the last pass on this device made nothing (shown under "Process Now"); nil when it made something or none ran.
    public var passOutcome: InsightsPassOutcome?
    public var problem: InsightsProblem?
    /// The offer card was answered (or dismissed) for this vault on this device.
    public var offerAnswered = false
    /// Topic summaries being made now on this device by "Regenerate" (`TopicScopes.name` of each scope).
    public var regeneratingTopics: Set<String> = []
    /// Why the last "Regenerate" made nothing (worded by the app), by scope name.
    public var topicProblems: [String: InsightsTopicProblem] = [:]
    /// Bumped whenever the index changes: views showing insights read again.
    public var revision = 0

    public init() {}
}

/// One note as its panel shows it.
public struct NoteInsightsPanel: Equatable, Sendable {
    public var shown: InsightsReader.Shown?
    /// Related notes (the note's row first in each: id, title, why), best first.
    public var related: [InsightsReader.Related]
    /// `vectors`, `local` or `keywords`.
    public var basis: String
    /// The level-0 cluster the note is in (its label), when there is a map.
    public var cluster: [String]?
    /// The note is not in the related graph here: only this many most recently modified notes are compared on this
    /// device (L7's bound).
    public var outsideGraph: Int?
    /// The note's text has changed since its summary was made.
    public var stale: Bool { shown?.state == "stale" }
    /// No summary from any device yet.
    public var missing: Bool { shown == nil || shown?.state == "missing" }
}

/// A cluster of the map, as a grouped list (the accessible and compact form of the map view).
public struct InsightsCluster: Identifiable, Hashable, Sendable {
    public var id: Int
    public var label: [String]
    /// Its notes, by title.
    public var members: [UUID]
    /// Members placed on this device (not in the work device's map yet).
    public var placed: Set<UUID>
}

/// The compact index of one refresh (not observed; `InsightsModelState.revision` says when it changed).
public struct InsightsIndex: Sendable {
    public var shown: [UUID: InsightsReader.Shown] = [:]
    public var graph: InsightsReader.RelatedGraphResult?
    public var clusters: [InsightsCluster] = []
    /// The cluster of each note.
    public var clusterOf: [UUID: Int] = [:]
    /// Notes left out of the graph by this device's bound (`InsightsServices.maxGraphNotes`).
    public var outsideGraph: Set<UUID> = []
    /// The map as the map view draws it (positions, regions, edges; Insights PR 3).
    public var map = InsightsMapLayout.empty
    /// Notebook and tag scopes with enough summarized notes for a topic summary, as shown (design §6 item 4).
    public var topics: [InsightsTopicsFile.Scope: TopicSummaries.Shown] = [:]
    /// What the index was made from (notes and files), so a refresh with nothing new is skipped.
    var signature = 0
    public init() {}
}

/// The tasks and timers of Note Insights (one per model).
@MainActor
final class InsightsRuntime {
    /// The unlock's wait for the listing, then the first read and the loop.
    var start: Task<Void, Never>?
    /// A scheduled read (`scheduleInsightsRefresh`), waiting out its delay.
    var refresh: Task<Void, Never>?
    /// The read running now (at most one: `refreshInsights`), and the request it answers.
    var refreshing: Task<Void, Never>?
    var refreshRequested = 0
    var refreshDone = 0
    var lastRefreshEnded: ContinuousClock.Instant?
    /// The pass running now, foreground or background, or a topic's regeneration (at most one), and its number.
    var pass: Task<Bool, Never>?
    /// The slot holds a regeneration (`regenerateInsightsTopic` waits for it instead of stopping it).
    var slotIsRegeneration = false
    var passID = 0
    var loop: Task<Void, Never>?
    /// Bumped by every change to the vault's insights files seen here (a pass, a sync arrival).
    var filesRevision = 0
    var model: (any ModelProvider)?
    var embedder: (any EmbeddingProvider)?
    var providersRead = false
    /// The last insights search (`insightsSearchHits`), by what it answered.
    var search: (key: Int, hits: [InsightsReader.SearchHit])?
    nonisolated init() {}
}

extension AppModelCore {
    /// Generations per updater run in the foreground: each run saves what it made, so a run cut off loses at most these.
    static var insightsForegroundBatch: Int { 4 }
    /// In the background each note is saved before the next one starts (design §3.7: stops cleanly on expiration).
    static var insightsBackgroundBatch: Int { 1 }
    /// How often the foreground looks for work while the vault is open and the device on power.
    static var insightsLoopInterval: Duration { .seconds(15 * 60) }
    /// Reads caused by arrivals and note edits come at most this often (each reads every sidecar and builds the graph).
    static var insightsRefreshInterval: Duration { .seconds(30) }

    nonisolated static func insightsOfferKey(_ vaultId: UUID) -> String {
        "Sempere.insightsOffer.\(vaultId.uuidString.lowercased())"
    }

    /// This device's memo of failed generations for the open vault (`InsightsFailureMemo`), beside the device state.
    var insightsFailureMemoURL: URL? { vault.map { insightsFailureMemoURL(for: $0.vaultId) } }

    /// This device's memo of failed generations for the vault `vaultId`, open or not.
    func insightsFailureMemoURL(for vaultId: UUID) -> URL {
        InsightsFailureMemo.fileURL(in: deviceStateURL.deletingLastPathComponent().appendingPathComponent("Insights", isDirectory: true),
                                    vaultId: vaultId)
    }

    /// Deletes this device's memo of failed generations for `vaultId` (Note Insights off, the vault removed).
    func forgetInsightsFailures(vaultId: UUID) {
        InsightsFailureMemo.remove(at: insightsFailureMemoURL(for: vaultId))
    }

    // MARK: Opening and closing

    /// The vault was unlocked: read the settings and this device's capability, then the index once the notes are
    /// listed, and look for work.
    func startInsights() {
        guard let vault else { return }
        let runtime = insightsRuntime
        if !runtime.providersRead {
            runtime.model = insightsServices.model()
            runtime.embedder = insightsServices.embedder()
            runtime.providersRead = true
        }
        insights = InsightsModelState()
        refreshInsightsCapability()
        insights.offerAnswered = services.settings.bool(forKey: Self.insightsOfferKey(vault.vaultId))
        let gen = generation
        runtime.start?.cancel()
        runtime.start = Task { [weak self] in
            try? await self?.notesLoaded()
            guard let self, self.generation == gen else { return }
            await self.refreshInsights()
            self.startInsightsLoop()
        }
    }

    /// Reads this device's capability again from its providers (Settings appearing, each pass's start): Apple
    /// Intelligence turned on, or done getting ready, since the vault was unlocked. A provider missing at unlock is asked
    /// for again.
    public func refreshInsightsCapability() {
        let runtime = insightsRuntime
        if runtime.model == nil { runtime.model = insightsServices.model() }
        if runtime.embedder == nil { runtime.embedder = insightsServices.embedder() }
        let capability = InsightsCapability(model: runtime.model?.availability, embedder: runtime.embedder != nil)
        if insights.capability != capability { insights.capability = capability }
    }

    /// The vault closed (or locked): every pass and refresh stops, the index goes.
    func stopInsights() {
        let runtime = insightsRuntime
        runtime.start?.cancel(); runtime.start = nil
        runtime.refresh?.cancel(); runtime.refresh = nil
        // The pass in either slot, foreground or the background task's (`runInsightsInBackground` waits on it).
        runtime.pass?.cancel(); runtime.pass = nil; runtime.slotIsRegeneration = false
        runtime.loop?.cancel(); runtime.loop = nil
        insightsIndex = InsightsIndex()
        insights = InsightsModelState()
    }

    // MARK: Reading

    /// Something the insights depend on changed (a sync placed or deleted insights files, the settings file arrived,
    /// a pass wrote): the index is read again soon.
    public func insightsFilesChanged() {
        insightsRuntime.filesRevision += 1
        scheduleInsightsRefresh(throttled: true)
    }

    /// The notes changed (an edit here, a listing of what arrived): the index is read again, at most every
    /// `insightsRefreshInterval`, so a stale or new note shows as such.
    func insightsNotesChanged() {
        guard insights.mode == .on else { return }
        scheduleInsightsRefresh(after: .seconds(5), throttled: true)
    }

    /// Reads the index again after `delay` (coalescing bursts of changes: a later request replaces a waiting one);
    /// `throttled` waits until `insightsRefreshInterval` has passed since the last read ended.
    public func scheduleInsightsRefresh(after delay: Duration = .seconds(2), throttled: Bool = false) {
        guard phase == .unlocked else { return }
        let runtime = insightsRuntime
        var wait = delay
        if throttled, let last = runtime.lastRefreshEnded {
            let left = Self.insightsRefreshInterval - (ContinuousClock.now - last)
            if left > wait { wait = left }
        }
        runtime.refresh?.cancel()
        runtime.refresh = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.refreshInsights()
        }
    }

    /// The notes insights are made from: readable, downloaded ones (a partial copy's pending rows are not read).
    var insightsSummaries: [NoteSummary] {
        let pending = pendingNoteIDs
        return notes.filter { $0.problem == nil && !pending.contains($0.id) }
    }

    /// What the index is made from: the notes' ids, titles, dates and texts' sizes, and the files' revision.
    func insightsSignature(_ summaries: [NoteSummary]) -> Int {
        var h = Hasher()
        h.combine(insightsRuntime.filesRevision)
        for s in summaries {
            h.combine(s.id); h.combine(s.title); h.combine(s.modified); h.combine(s.deleted); h.combine(s.pageTexts.count)
            h.combine(s.transcribed.count); h.combine(s.notebook); h.combine(s.tags)
        }
        return h.finalize()
    }

    /// Reads the settings, the status and the index off the main actor (the vault's sidecars are dropped after). One
    /// read runs at a time (each holds every sidecar and the graph's matrices while it runs): a call while one runs waits
    /// for it, and the waiters share one read after it, which answers all of them.
    public func refreshInsights() async {
        let runtime = insightsRuntime
        runtime.refreshRequested += 1
        let wanted = runtime.refreshRequested
        while let running = runtime.refreshing { await running.value }
        guard runtime.refreshDone < wanted else { return }
        let answers = runtime.refreshRequested
        let task = Task { @MainActor [weak self] in
            await self?.readInsights()
            // Cleared by the read itself, so a waiter that wakes sees the next read or none (never this one again).
            runtime.refreshing = nil
            runtime.refreshDone = max(runtime.refreshDone, answers)
            runtime.lastRefreshEnded = .now
        }
        runtime.refreshing = task
        await task.value
    }

    /// Background insights work off the main actor (reads at unlock, after arrivals and edits; a pass's inputs). Not
    /// the model's `offMain`: that one's `afterIO` seam orders the model's own vault I/O for tests, and these reads run
    /// on their own schedule, so passing through it let an unlock's read take the place of an edit's write in a test
    /// that counts arrivals (#52, `closeDuringBrowserEditRefreshDropsTheResult` on CI).
    nonisolated static func insightsOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }

    /// One read (`refreshInsights`); its result is dropped when the vault changed meanwhile.
    func readInsights() async {
        guard let vault, phase == .unlocked else { return }
        let gen = generation
        let type = settingsDeviceType
        let summaries = insightsSummaries
        let signature = insightsSignature(summaries)
        let runtime = insightsRuntime
        let embedder = runtime.embedder
        let me = vault.writerDevice
        let maxNotes = insightsServices.maxGraphNotes
        let unchanged = insightsIndex.signature == signature && insights.status != nil
        let result = await Self.insightsOffMain { () -> (InsightsSettings, Vault.InsightsMode, InsightsReader.Status?, InsightsIndex?) in
            let settings = InsightsSettings.read(vault, type: type)
            let mode = vault.insightsMode()
            guard mode == .on else { return (settings, mode, nil, InsightsIndex()) }
            let inputs = InsightsNotes.inputs(vault, summaries: summaries)
            let reader = InsightsReader(vault: vault, snapshot: InsightsStore(vault: vault).snapshot(), settings: settings)
            let status = reader.status(inputs: inputs, me: me, embedder: embedder)
            guard !unchanged else { return (settings, mode, status, nil) }
            return (settings, mode, status, Self.buildInsightsIndex(reader: reader, inputs: inputs, me: me, embedder: embedder,
                                                                   maxNotes: maxNotes, signature: signature))
        }
        guard generation == gen else { return }
        let turnedOn = insights.mode != .on && result.1 == .on
        insights.settings = result.0
        insights.mode = result.1
        insights.status = result.2
        if let index = result.3 {
            insightsIndex = index
            insights.revision += 1
        }
        // Turned off here or on another device: this device's memo of failed generations goes with it.
        if result.1 == .off { forgetInsightsFailures(vaultId: vault.vaultId) }
        // Turned on here or on another device (its settings arrived): look for work now, not at the next tick.
        if turnedOn, insightsRuntime.pass == nil, !services.lifecycle.isInBackground { requestInsightsPass(force: false) }
    }

    nonisolated static func buildInsightsIndex(reader: InsightsReader, inputs: [InsightsNoteInput], me: DeviceID?,
                                               embedder: (any EmbeddingProvider)?, maxNotes: Int, signature: Int) -> InsightsIndex {
        var index = InsightsIndex()
        index.signature = signature
        for n in inputs where !n.deleted { index.shown[n.id] = reader.show(n) }
        // One vector set for the graph and the map (a compatible device embeds the notes it places only once).
        let bounded = InsightsReader.bounded(inputs, maxNotes: maxNotes)
        let set = reader.vectorSet(inputs: bounded.inputs, me: me, embedder: embedder, language: InsightsUpdater.mainLanguage(inputs))
        index.graph = reader.relatedGraph(inputs: inputs, me: me, embedder: embedder, maxNotes: maxNotes, set: set)
        index.outsideGraph = Set(bounded.leftOut)
        let map = reader.mapView(inputs: inputs, me: me, embedder: embedder, set: set)
        index.map = InsightsMapLayout(view: map, edges: index.graph?.edges)
        for t in TopicSummaries.shownAll(inputs: inputs, snapshot: reader.snapshot) { index.topics[t.scope] = t }
        var members: [Int: [UUID]] = [:], placed: [Int: Set<UUID>] = [:]
        for node in map.nodes {
            guard let c = node.cluster, let id = UUID(uuidString: node.note) else { continue }
            members[c, default: []].append(id)
            if node.placed { placed[c, default: []].insert(id) }
            index.clusterOf[id] = c
        }
        let titles = Dictionary(inputs.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        index.clusters = map.clusters.filter { $0.level == 0 }.compactMap { c in
            guard let m = members[c.id], !m.isEmpty else { return nil }
            return InsightsCluster(id: c.id, label: c.label, members: m.sorted { (titles[$0] ?? "", $0.uuidString) < (titles[$1] ?? "", $1.uuidString) },
                                   placed: placed[c.id] ?? [])
        }.sorted { ($0.members.count, -$0.id) > ($1.members.count, -$1.id) }
        return index
    }

    /// The panel of note `id` from the index (nil when Note Insights is not on).
    public func insightsPanel(for id: UUID) -> NoteInsightsPanel? {
        guard insights.mode == .on else { return nil }
        let index = insightsIndex
        let titles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let deleted = Set(notes.filter(\.deleted).map(\.id))
        var related: InsightsReader.RelatedResult?
        if let graph = index.graph { related = InsightsReader.related(id, in: graph, titles: titles) }
        let rows = (related?.related ?? []).filter { UUID(uuidString: $0.note).map { !deleted.contains($0) && titles[$0] != nil } ?? false }
        let cluster = index.clusterOf[id].flatMap { c in index.clusters.first { $0.id == c }?.label }
        return NoteInsightsPanel(shown: index.shown[id], related: rows, basis: related?.basis ?? "keywords", cluster: cluster,
                                 outsideGraph: index.outsideGraph.contains(id) ? insightsServices.maxGraphNotes : nil)
    }

    /// The clusters of the map as a grouped list.
    public var insightsClusters: [InsightsCluster] { insights.mode == .on ? insightsIndex.clusters : [] }

    /// The map as the map view draws it (empty while Note Insights is off or there is no map).
    public var insightsMap: InsightsMapLayout { insights.mode == .on ? insightsIndex.map : .empty }

    // MARK: Topic summaries (design §6 item 4, D8)

    /// The topic summary of a notebook, as shown; nil when Note Insights is off or the notebook has fewer than 3
    /// summarized notes (its "Summary" is then not offered).
    public func insightsTopic(notebook path: String) -> TopicSummaries.Shown? {
        NotebookPath.canonical(path).flatMap { insightsTopic(.init(notebook: $0)) }
    }

    /// The topic summary of a tag (matched case-insensitively, `NoteOps.tagKey`), as `insightsTopic(notebook:)`.
    public func insightsTopic(tag: String) -> TopicSummaries.Shown? { insightsTopic(.init(tag: NoteOps.tagKey(tag))) }

    public func insightsTopic(_ scope: InsightsTopicsFile.Scope) -> TopicSummaries.Shown? {
        guard insights.mode == .on, let t = insightsIndex.topics[scope], t.eligible else { return nil }
        return t
    }

    /// Every notebook and tag that can have a summary, notebooks first, by name.
    public var insightsTopics: [TopicSummaries.Shown] {
        guard insights.mode == .on else { return [] }
        return insightsIndex.topics.values.filter(\.eligible).sorted { TopicScopes.name($0.scope) < TopicScopes.name($1.scope) }
    }

    /// "Regenerate" is offered: this device can make summaries and the vault is writable here.
    public var canRegenerateInsightsTopics: Bool {
        // Not while the vault's keys change (a re-encryption would seal it under the old key).
        insights.mode == .on && insights.capability.generates && !isVaultReadOnly && phase == .unlocked && !isChangingKeys
    }

    /// "Regenerate": makes the scope's topic summary now on this device (one model call; design §6 item 4), whatever the
    /// once-a-day rule says, then reads the index again. It runs in the model's one insights slot, like a pass (review of
    /// #54, M1): a running pass is stopped first (it saves what it made; the next look for work continues it) and a running
    /// regeneration is waited for, so turning Note Insights off, closing or locking the vault cancel it and wait for it
    /// like any pass, and no two writers make or record the same topic at once. A scope already waiting or running is not
    /// asked again.
    public func regenerateInsightsTopic(_ scope: InsightsTopicsFile.Scope) async {
        let name = TopicScopes.name(scope)
        guard canRegenerateInsightsTopics, !insights.regeneratingTopics.contains(name) else { return }
        let gen = generation
        insights.regeneratingTopics.insert(name)
        insights.topicProblems[name] = nil
        defer { if generation == gen { insights.regeneratingTopics.remove(name) } }
        let runtime = insightsRuntime
        // Take the slot: wait out another regeneration, stop a pass. Re-checked after every wait (the loop may start one).
        while let running = runtime.pass {
            if !runtime.slotIsRegeneration { running.cancel() }
            _ = await running.value
            guard generation == gen else { return }
        }
        guard canRegenerateInsightsTopics else { return }
        let task = occupyInsightsSlot(regeneration: true) { [weak self] in
            await self?.runTopicRegeneration(scope, generation: gen)
            return false
        }
        _ = await task.value
        guard generation == gen else { return }
        // Continue the pass this one may have stopped (in the power window only, as every look for work).
        if !services.lifecycle.isInBackground { requestInsightsPass(force: false) }
    }

    /// The regeneration itself, inside the slot's task (so its cancellation reaches the model call and the write).
    func runTopicRegeneration(_ scope: InsightsTopicsFile.Scope, generation gen: Int) async {
        let name = TopicScopes.name(scope)
        guard let vault, generation == gen, !Task.isCancelled, canRegenerateInsightsTopics else { return }
        let summaries = insightsSummaries
        let updater = InsightsUpdater(vault: vault, model: insightsRuntime.model, embedder: nil, deviceState: deviceStateURL,
                                      app: services.appName)
        let memo = insightsFailureMemoURL
        do {
            let inputs = await Self.insightsOffMain { InsightsNotes.inputs(vault, summaries: summaries) }
            guard generation == gen, !Task.isCancelled else { return }
            _ = try await updater.regenerateTopic(scope, inputs: inputs, failureMemo: memo)
        } catch let e as InsightsUpdater.TopicError {
            guard generation == gen else { return }
            switch e {
            case .factCheck: insights.topicProblems[name] = .factCheck
            case .tooFewMembers: insights.topicProblems[name] = .tooFewMembers
            case .unavailable: insights.topicProblems[name] = .unavailable
            }
        } catch {
            // Cancelled (turned off, closed, locked): nothing to say.
            guard generation == gen, !(error is CancellationError), !Task.isCancelled else { return }
            insights.topicProblems[name] = .failed(services.describeError(error))
        }
        guard generation == gen, !Task.isCancelled else { return }
        insightsRuntime.filesRevision += 1
        await refreshInsights()
    }

    /// The search field's insights hits (design §6 item 2): notes in the search's scope whose keywords, concepts or
    /// summary hold every word of the query, best field first ("matched in summary"), without the notes the page-text
    /// search found already. From the index, so typing reads nothing.
    public var insightsSearchHits: [InsightsReader.SearchHit] {
        guard insights.mode == .on else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let found = Set(searchResults.map(\.note))
        var h = Hasher()
        h.combine(insights.revision); h.combine(query); h.combine(searchScope); h.combine(sidebarSelection); h.combine(found)
        let key = h.finalize()
        if let memo = insightsRuntime.search, memo.key == key { return memo.hits }
        let ids = Set(searchCandidates.map(\.id)).subtracting(found)
        let shown = insightsIndex.shown.filter { ids.contains($0.key) }.map(\.value)
        let hits = InsightsReader.search(query, shown: shown)
        insightsRuntime.search = (key, hits)
        return hits
    }

    // MARK: Settings

    /// Settings' switch (D4): on writes `insights.enabled` true (the first capable device then claims the work device
    /// in its first pass); off writes the explicit false that deletes `insights/` everywhere, and deletes this copy's.
    public func setInsightsEnabled(_ on: Bool) async {
        // Off: every pass (foreground or the background task's) stops and has ended before the false is written and the
        // files are deleted, so none writes a sidecar after the purge.
        if !on { await cancelInsightsPass() }
        await writeInsightsSettings { vault in _ = try InsightsSettingsWrite.setEnabled(on, vault: vault) }
        if !on, let id = vault?.vaultId { forgetInsightsFailures(vaultId: id) }
        answerInsightsOffer()
        if on { requestInsightsPass(force: false) }
    }

    /// Designates the work device (D13; nil clears it).
    public func setInsightsWorkDevice(_ device: DeviceID?) async {
        await writeInsightsSettings { vault in try InsightsSettingsWrite.setWorkDevice(device, vault: vault) }
        if device == vault?.writerDevice { requestInsightsPass(force: false) }
    }

    /// "Use This Device" (D13: the user designates; a device also takes the role by itself once the work device has not
    /// been seen for 14 days, in its next pass).
    public func claimInsightsWorkDevice() async {
        guard let me = vault?.writerDevice else { return }
        await setInsightsWorkDevice(me)
    }

    /// The voice-note title format (D14); nil resets it. Returns false when the format is refused.
    @discardableResult
    public func setInsightsVoiceNoteTitle(_ format: String?) async -> Bool {
        if let format, VoiceNoteTitleFormat.check(format) != nil { return false }
        await writeInsightsSettings { vault in try InsightsSettingsWrite.setVoiceNoteTitle(format, vault: vault) }
        return true
    }

    /// What "Use the newer embedding model" would do (D12), for its confirmation; nil without an offer.
    public func insightsPinMove() async -> InsightsSettingsWrite.PinMove? {
        guard let vault, let status = insights.status, let rev = status.upgradeOffer else { return nil }
        let settings = insights.settings, language = status.language
        return try? await offMain(priority: .userInitiated) {
            InsightsSettingsWrite.planPinMove(to: rev, language: language, vault: vault, snapshot: InsightsStore(vault: vault).snapshot(),
                                              settings: settings)
        }
    }

    /// Moves the pin as confirmed.
    public func applyInsightsPinMove(_ move: InsightsSettingsWrite.PinMove) async {
        await writeInsightsSettings { vault in try InsightsSettingsWrite.apply(move, vault: vault) }
        requestInsightsPass(force: false)
    }

    /// The offer card was answered: not shown again for this vault on this device.
    public func answerInsightsOffer() {
        guard let vault else { return }
        services.settings.set(true, forKey: Self.insightsOfferKey(vault.vaultId))
        insights.offerAnswered = true
    }

    /// The one-time offer card shows: a device that can make summaries, a writable vault where the feature was never
    /// set (never after an explicit off, D4), not answered here.
    public var showsInsightsOffer: Bool {
        phase == .unlocked && !isVaultReadOnly && insights.mode == .unset && insights.capability.generates && !insights.offerAnswered
            && listLoaded
    }

    func writeInsightsSettings(_ write: @escaping @Sendable (Vault) throws -> Void) async {
        guard let vault else { return }
        if isVaultReadOnly { insights.problem = .readOnly; return }
        do {
            try await offMain { try write(vault) }
            insights.problem = nil
        } catch VaultError.readOnly {
            insights.problem = .readOnly
        } catch {
            insights.problem = .failed(services.describeError(error))
        }
        insightsRuntime.filesRevision += 1
        await refreshInsights()
    }

    // MARK: Passes

    /// This device has work it may do (D13): it can make summaries (every such device does), or it embeds and holds the
    /// work device, would claim a role nobody holds, or would take over a work device not seen for 14 days.
    public var insightsHasRole: Bool {
        let s = insights.settings
        guard insights.mode == .on, insights.capability.canWork else { return false }
        if insights.capability.generates { return true }
        guard insights.capability.embedder else { return false }
        return s.workDevice == nil || s.workDevice == vault?.writerDevice || insights.status?.workDeviceNotSeen == true
    }

    /// The one insights slot is taken (a pass, or a topic's "Regenerate"): "Process Now" would start nothing.
    public var insightsBusy: Bool { insights.isWorking || !insights.regeneratingTopics.isEmpty }

    /// Starts a pass now unless one runs (`force`: Settings' "Process Now", which does not wait for a power window or the
    /// settle time, and asks again for notes that failed before; open notes still wait).
    public func requestInsightsPass(force: Bool) {
        guard insightsRuntime.pass == nil else { return }
        startInsightsPass(batch: Self.insightsForegroundBatch, ignorePower: force, forced: force)
    }

    /// Puts a pass in the one slot; it clears the slot when it ends, only while the slot is still its own.
    @discardableResult
    func startInsightsPass(batch: Int, ignorePower: Bool, forced: Bool = false) -> Task<Bool, Never> {
        occupyInsightsSlot(regeneration: false) { [weak self] in
            await self?.runInsightsPass(batch: batch, ignorePower: ignorePower, forced: forced).remains ?? false
        }
    }

    /// Puts `work` (a pass or a topic's regeneration) in the one insights slot; it clears the slot when it ends, only
    /// while the slot is still its own.
    func occupyInsightsSlot(regeneration: Bool, _ work: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let runtime = insightsRuntime
        runtime.passID += 1
        let id = runtime.passID
        let task = Task { @MainActor () -> Bool in
            let remains = await work()
            if runtime.passID == id { runtime.pass = nil; runtime.slotIsRegeneration = false }
            return remains
        }
        runtime.pass = task
        runtime.slotIsRegeneration = regeneration
        return task
    }

    /// Stops the running pass, if any, and waits until it has ended.
    func cancelInsightsPass() async {
        guard let running = insightsRuntime.pass else { return }
        running.cancel()
        _ = await running.value
    }

    /// The foreground's look for work: now, then every `insightsLoopInterval`, while the vault stays open.
    func startInsightsLoop() {
        let runtime = insightsRuntime
        runtime.loop?.cancel()
        let gen = generation
        runtime.loop = Task { [weak self] in
            // The model is held only for each look, never across the wait: a `guard let self` in this loop kept it
            // strongly through the sleep, so a model let go with its vault open lived on for the interval (and its
            // scratch folder with it).
            while !Task.isCancelled, self?.insightsLoopLook(generation: gen) == true {
                try? await Task.sleep(for: Self.insightsLoopInterval)
            }
        }
    }

    /// One look of the foreground loop (`startInsightsLoop`); false once the vault changed (the loop ends).
    private func insightsLoopLook(generation gen: Int) -> Bool {
        guard generation == gen else { return false }
        if !services.lifecycle.isInBackground { requestInsightsPass(force: false) }
        return true
    }

    /// The background processing task (`BackgroundSyncRequest.insights`): a pass in the model's one slot (a foreground
    /// pass is stopped first; `stopInsights` cancels this one too) until done or the system takes the time back, which
    /// cancels it between notes (each note is saved before the next starts). Returns whether work remains.
    @discardableResult
    public func runInsightsInBackground() async -> Bool {
        await cancelInsightsPass()
        // The task asked for external power: the system's window is the power window.
        let task = startInsightsPass(batch: Self.insightsBackgroundBatch, ignorePower: true)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The app leaves the screen (iOS): a running pass stops (background time is short); the processing task, which
    /// asks for external power, continues it.
    func insightsEnteredBackground() {
        insightsRuntime.pass?.cancel()
        if insightsHasRole { syncScheduler.schedule(.insights) }
    }

    /// Runs updater passes of `batch` generations each until nothing is left, the task is cancelled, the power window
    /// closes or the vault changes. Returns the reports, and publishes why the pass made nothing (`passOutcome`).
    /// `remains`: the pass stopped with work left (cancelled, the power window closed, or a run still generating).
    /// `forced` ("Process Now"): no settle time, and failures remembered before the pass do not hold notes back (what
    /// fails during it waits, so its next run does not ask again).
    @discardableResult
    func runInsightsPass(batch: Int, ignorePower: Bool, forced: Bool = false) async -> (reports: [InsightsUpdateReport], remains: Bool) {
        refreshInsightsCapability()
        guard let vault, phase == .unlocked, insights.mode == .on, !isVaultReadOnly, insightsHasRole, !isChangingKeys else { return ([], false) }
        let gen = generation
        let runtime = insightsRuntime
        // A device of the vault's list, writing with the model's one clock.
        guard vault.writerDevice != nil, let clock = try? deviceClockForWriting() else { return ([], false) }
        insights.isWorking = true
        defer { insights.isWorking = false; insights.lastPass = Date() }
        var reports: [InsightsUpdateReport] = []
        var remains = false
        let started = insightsNow()
        var updater = InsightsUpdater(vault: vault, model: runtime.model, embedder: runtime.embedder, deviceState: deviceStateURL,
                                      app: services.appName)
        updater.titleWriter = { [self] id, build, now in try await self.writeInsightsTitle(id, build, wall: now) }
        updater.writerDevice = clock.device
        while true {
            guard !Task.isCancelled else { remains = true; break }
            guard generation == gen else { break }
            guard ignorePower || insightsServices.powerWindow() else { remains = true; break }
            var o = InsightsUpdateOptions()
            o.now = insightsNow()
            o.limit = batch
            o.openNotes = Set([editor?.noteID].compactMap { $0 } + Array(windowEditors.keys))
            o.failureMemo = insightsFailureMemoURL
            o.platform = insightsServices.platform
            o.powerWindow = true
            o.deviceType = settingsDeviceType
            if forced { o.ignoreSettle = true; o.ignoreBackoffBefore = started }
            // Topic summaries (design §6 item 4, D8; Insights PR 3): due scopes at most once a day each, in the same power
            // window and batch as the notes, backed off in the failure memo when they fail.
            o.topics = true
            let summaries = insightsSummaries
            let options = o
            let report: InsightsUpdateReport
            do {
                let inputs = await Self.insightsOffMain { InsightsNotes.inputs(vault, summaries: summaries) }
                guard generation == gen else { break }
                guard !Task.isCancelled else { remains = true; break }
                report = try await updater.run(options, notes: inputs)
            } catch InsightsUpdateError.disabled {
                break
            } catch {
                if error is CancellationError || Task.isCancelled { remains = true; break }
                insights.problem = .failed(services.describeError(error))
                break
            }
            guard generation == gen else { break }
            reports.append(report)
            insights.lastReport = report
            insights.problem = nil
            // Read again once the pass pauses (each refresh reads every sidecar; not after every run of a long pass).
            insightsRuntime.filesRevision += 1
            scheduleInsightsRefresh(after: .seconds(10))
            if report.cancelled { remains = true; break }
            // Done when this run made nothing new (everything current, backed off or not allowed here). A topic that
            // failed is in the memo, so it is not asked again in the next run.
            if report.generated.isEmpty && report.topics.isEmpty { break }
        }
        if generation == gen {
            if !reports.isEmpty, !remains {
                insights.passOutcome = InsightsPassOutcome.of(reports, availability: insights.capability.model)
            } else if reports.contains(where: { !$0.generated.isEmpty || !$0.topics.isEmpty }) {
                insights.passOutcome = nil
            }
            await refreshInsights()
        }
        return (reports, remains)
    }

    /// A voice note's automatic title (D14), written through the model's clock like every other edit, inside the edit
    /// gate: `build` decides from the note as it is on disk then, so a rename made here in between wins (it gives no
    /// ops). Nothing is written to a note open in an editor. Nil when nothing was written.
    func writeInsightsTitle(_ id: UUID, _ build: @escaping @Sendable () throws -> [Op]?, wall: Date) async throws -> RevisionName? {
        guard !isNoteOpen(id) else { return nil }
        var written: RevisionName?
        try await commit(ids: [id]) { vault, clock, verifier in
            guard let ops = try build(), !ops.isEmpty else { return }
            written = try await NoteWriter.append(ops, to: id, vault: vault, clock: clock, wall: wall, verify: verifier(id))
        }
        return written
    }
}
