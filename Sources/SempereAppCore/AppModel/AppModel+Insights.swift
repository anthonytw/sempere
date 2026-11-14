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

/// What this device can do (from its providers, read when a vault unlocks).
public struct InsightsCapability: Equatable, Sendable {
    /// Apple's on-device model, or why not (nil: no provider in this build or OS).
    public var model: ModelAvailability?
    /// The sentence embedder exists here.
    public var embedder = false

    public init(model: ModelAvailability? = nil, embedder: Bool = false) { self.model = model; self.embedder = embedder }

    /// Summaries, keywords and titles can be made here.
    public var generates: Bool { model?.isAvailable == true }
    /// The device can hold the work device (D13): embeds, so related notes and the map at least.
    public var canWork: Bool { generates || embedder }
}

/// Why Note Insights could not do something (worded by the app).
public enum InsightsProblem: Equatable, Sendable {
    /// The vault is read-only here.
    case readOnly
    /// A write failed (the error's words).
    case failed(String)
}

/// What Settings and the note views read (observed: `AppModel.insights`).
public struct InsightsModelState: Equatable, Sendable {
    /// The vault's insights settings as this device reads them (its type block for `compute`).
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
    public var problem: InsightsProblem?
    /// The offer card was answered (or dismissed) for this vault on this device.
    public var offerAnswered = false
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
    /// The note's text has changed since its summary was made.
    public var stale: Bool { shown?.state == "stale" }
    /// No summary from any device yet.
    public var missing: Bool { shown == nil || shown?.state == "missing" }
}

/// A cluster of the map, as a grouped list (the map view itself is PR 3).
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
    /// What the index was made from (notes and files), so a refresh with nothing new is skipped.
    var signature = 0
    public init() {}
}

/// The tasks and timers of Note Insights (one per model).
@MainActor
final class InsightsRuntime {
    var refresh: Task<Void, Never>?
    var pass: Task<Void, Never>?
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

    nonisolated static func insightsOfferKey(_ vaultId: UUID) -> String {
        "Sempere.insightsOffer.\(vaultId.uuidString.lowercased())"
    }

    /// This device's memo of failed generations for the open vault (`InsightsFailureMemo`), beside the device state.
    var insightsFailureMemoURL: URL? {
        vault.map {
            deviceStateURL.deletingLastPathComponent().appendingPathComponent("Insights", isDirectory: true)
                .appendingPathComponent("\($0.vaultId.uuidString.lowercased())-failures.json")
        }
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
        insights.capability = InsightsCapability(model: runtime.model?.availability, embedder: runtime.embedder != nil)
        insights.offerAnswered = services.settings.bool(forKey: Self.insightsOfferKey(vault.vaultId))
        let gen = generation
        runtime.refresh?.cancel()
        runtime.refresh = Task { [weak self] in
            try? await self?.notesLoaded()
            guard let self, self.generation == gen else { return }
            await self.refreshInsights()
            self.startInsightsLoop()
        }
    }

    /// The vault closed (or locked): every pass and refresh stops, the index goes.
    func stopInsights() {
        let runtime = insightsRuntime
        runtime.refresh?.cancel(); runtime.refresh = nil
        runtime.pass?.cancel(); runtime.pass = nil
        runtime.loop?.cancel(); runtime.loop = nil
        insightsIndex = InsightsIndex()
        insights = InsightsModelState()
    }

    // MARK: Reading

    /// Something the insights depend on changed (a sync placed or deleted insights files, the settings file arrived,
    /// a pass wrote): the index is read again soon.
    public func insightsFilesChanged() {
        insightsRuntime.filesRevision += 1
        scheduleInsightsRefresh()
    }

    /// Reads the index again after a short pause (coalescing bursts of changes).
    public func scheduleInsightsRefresh(after delay: Duration = .seconds(2)) {
        guard phase == .unlocked else { return }
        let runtime = insightsRuntime
        runtime.refresh?.cancel()
        runtime.refresh = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
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

    /// Reads the settings, the status and the index off the main actor (the vault's sidecars are dropped after).
    public func refreshInsights() async {
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
        let result = try? await offMain(priority: .utility) { () -> (InsightsSettings, Vault.InsightsMode, InsightsReader.Status?, InsightsIndex?) in
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
        guard let result, generation == gen else { return }
        let turnedOn = insights.mode != .on && result.1 == .on
        insights.settings = result.0
        insights.mode = result.1
        insights.status = result.2
        if let index = result.3 {
            insightsIndex = index
            insights.revision += 1
        }
        // Turned on here or on another device (its settings arrived): look for work now, not at the next tick.
        if turnedOn, insightsRuntime.pass == nil, !services.lifecycle.isInBackground { requestInsightsPass(force: false) }
    }

    nonisolated static func buildInsightsIndex(reader: InsightsReader, inputs: [InsightsNoteInput], me: DeviceID?,
                                               embedder: (any EmbeddingProvider)?, maxNotes: Int, signature: Int) -> InsightsIndex {
        var index = InsightsIndex()
        index.signature = signature
        for n in inputs where !n.deleted { index.shown[n.id] = reader.show(n) }
        index.graph = reader.relatedGraph(inputs: inputs, me: me, embedder: embedder, maxNotes: maxNotes)
        let map = reader.mapView(inputs: inputs, me: me, embedder: embedder)
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
        return NoteInsightsPanel(shown: index.shown[id], related: rows, basis: related?.basis ?? "keywords", cluster: cluster)
    }

    /// The clusters of the map as a grouped list.
    public var insightsClusters: [InsightsCluster] { insights.mode == .on ? insightsIndex.clusters : [] }

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
        await writeInsightsSettings { vault in _ = try InsightsSettingsWrite.setEnabled(on, vault: vault) }
        answerInsightsOffer()
        if on { requestInsightsPass(force: false) } else { insightsRuntime.pass?.cancel() }
    }

    /// Designates the work device (D13; nil clears it).
    public func setInsightsWorkDevice(_ device: DeviceID?) async {
        await writeInsightsSettings { vault in try InsightsSettingsWrite.setWorkDevice(device, vault: vault) }
        if device == vault?.writerDevice { requestInsightsPass(force: false) }
    }

    /// "Use This Device" (D13: the user designates; no automatic takeover).
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

    /// `insights.compute` for this kind of device: `auto` lets it process too when it is not the work device.
    public func setInsightsComputeHere(_ on: Bool) async {
        let type = settingsDeviceType
        await writeInsightsSettings { vault in try InsightsSettingsWrite.setCompute(auto: on, type: type, vault: vault) }
        if on { requestInsightsPass(force: false) }
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

    /// This device has work it may do (D13): the work device, a device allowed to compute too, or a capable one that
    /// would claim a role nobody holds.
    public var insightsHasRole: Bool {
        let s = insights.settings
        guard insights.mode == .on, insights.capability.canWork else { return false }
        if s.workDevice == nil || s.computeAuto { return true }
        return s.workDevice == vault?.writerDevice
    }

    /// Starts a pass now unless one runs (`force`: Settings' "Update Now", which does not wait for a power window).
    public func requestInsightsPass(force: Bool) {
        guard insightsRuntime.pass == nil else { return }
        let runtime = insightsRuntime
        runtime.pass = Task { [weak self] in
            await self?.runInsightsPass(batch: Self.insightsForegroundBatch, ignorePower: force)
            runtime.pass = nil
        }
    }

    /// The foreground's look for work: now, then every `insightsLoopInterval`, while the vault stays open.
    func startInsightsLoop() {
        let runtime = insightsRuntime
        runtime.loop?.cancel()
        let gen = generation
        runtime.loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                if !self.services.lifecycle.isInBackground { self.requestInsightsPass(force: false) }
                try? await Task.sleep(for: Self.insightsLoopInterval)
            }
        }
    }

    /// The background processing task (`BackgroundSyncRequest.insights`): passes until done or the system takes the
    /// time back (which cancels this between notes; each note is saved before the next starts).
    public func runInsightsInBackground() async {
        insightsRuntime.pass?.cancel()
        if let running = insightsRuntime.pass { await running.value }
        // The task asked for external power: the system's window is the power window.
        await runInsightsPass(batch: Self.insightsBackgroundBatch, ignorePower: true)
    }

    /// The app leaves the screen (iOS): a running pass stops (background time is short); the processing task, which
    /// asks for external power, continues it.
    func insightsEnteredBackground() {
        insightsRuntime.pass?.cancel()
        if insightsHasRole { syncScheduler.schedule(.insights) }
    }

    /// Runs updater passes of `batch` generations each until nothing is left, the task is cancelled, the power window
    /// closes or the vault changes. Returns the reports.
    @discardableResult
    func runInsightsPass(batch: Int, ignorePower: Bool) async -> [InsightsUpdateReport] {
        guard let vault, phase == .unlocked, insights.mode == .on, !isVaultReadOnly, insightsHasRole, !isChangingKeys else { return [] }
        let gen = generation
        let runtime = insightsRuntime
        // A device of the vault's list, writing with the model's one clock.
        guard vault.writerDevice != nil, let clock = try? deviceClockForWriting() else { return [] }
        insights.isWorking = true
        defer { insights.isWorking = false; insights.lastPass = Date() }
        var reports: [InsightsUpdateReport] = []
        var updater = InsightsUpdater(vault: vault, model: runtime.model, embedder: runtime.embedder, deviceState: deviceStateURL,
                                      app: services.appName)
        updater.titleWriter = { [self] id, ops, now in try await self.writeInsightsTitle(id, ops, wall: now) }
        updater.writerDevice = clock.device
        while !Task.isCancelled {
            guard generation == gen, ignorePower || insightsServices.powerWindow() else { break }
            var o = InsightsUpdateOptions()
            o.limit = batch
            o.openNotes = Set([editor?.noteID].compactMap { $0 } + Array(windowEditors.keys))
            o.failureMemo = insightsFailureMemoURL
            o.platform = insightsServices.platform
            o.powerWindow = true
            // Topic summaries are behind the cut line (D19): no screen shows them yet, so a battery device does not make them.
            o.topics = false
            let summaries = insightsSummaries
            let options = o
            let report: InsightsUpdateReport
            do {
                let inputs = try await offMain(priority: .utility) { InsightsNotes.inputs(vault, summaries: summaries) }
                guard generation == gen, !Task.isCancelled else { break }
                report = try await updater.run(options, notes: inputs)
            } catch InsightsUpdateError.disabled {
                break
            } catch {
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
            // Done when this run generated nothing new (everything current, backed off or not allowed here).
            if report.generated.isEmpty { break }
        }
        if generation == gen { await refreshInsights() }
        return reports
    }

    /// A voice note's automatic title (D14), written through the model's clock like every other edit.
    func writeInsightsTitle(_ id: UUID, _ ops: [Op], wall: Date) async throws -> RevisionName {
        var written: RevisionName?
        try await commit(ids: [id]) { vault, clock, verifier in
            written = try await NoteWriter.append(ops, to: id, vault: vault, clock: clock, wall: wall, verify: verifier(id))
        }
        guard let written else { throw ModelError.noteNotFound }
        return written
    }
}
