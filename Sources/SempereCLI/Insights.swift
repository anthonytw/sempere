import ArgumentParser
import Foundation
import Sempere
import SempereInsights
import SempereInsightsApple

// `sempere insights` (docs/cli.md "Note insights"; docs/design/1.2-note-insights.md §7, §11): summaries, keywords,
// related notes, the map, topic summaries, voice-note titles and the work device. Model work needs Apple's on-device
// model (macOS 26 with Apple Intelligence, D18); everything else reads the vault's files and works on Linux too. Writes
// go through `InsightsStore` (and titles through `Vault.apply`) and obey the read-only rule (format.md §7.3).

struct InsightsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insights",
        abstract: "Note insights: summaries, keywords, related notes, the map, topics and voice-note titles.",
        discussion: """
            Insights are made on the vault's devices only (Apple's on-device model and language framework; never a \
            server) and stored encrypted in the vault's insights/ folder (format.md §16). Turn them on with \
            'sempere settings set insights.enabled true'. One work device (insights.workDevice) makes the summaries, \
            embeds every note and builds the map; 'insights work-device' shows or sets it. update, topic --generate, \
            map --rebuild and work-device --claim need macOS 26 (exit 3 elsewhere, or without Apple Intelligence); \
            show, related, search, status, map and title read what is there on any system.
            """,
        subcommands: [InsightsUpdate.self, InsightsShow.self, InsightsRelated.self, InsightsSearch.self, InsightsStatus.self,
                      InsightsTopic.self, InsightsMap.self, InsightsTitle.self, InsightsWorkDevice.self, InsightsPurge.self]
    )
}

/// The providers this run uses: Apple's (macOS 26+), or with `SEMPERE_INSIGHTS_FAKE=1` in a debug build the fakes
/// (`SEMPERE_INSIGHTS_FAKE_MODEL=off` makes the fake model unavailable, `SEMPERE_INSIGHTS_FAKE_EMBEDDER=off` drops the
/// embedder), for the CLI tests.
enum InsightsCLI {
    static func providers() -> (model: (any ModelProvider)?, embedder: (any EmbeddingProvider)?) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["SEMPERE_INSIGHTS_FAKE"] == "1" {
            var script = FakeModelProvider.Script()
            if env["SEMPERE_INSIGHTS_FAKE_MODEL"] == "off" { script.availability = .disabled }
            let embedder: (any EmbeddingProvider)? = env["SEMPERE_INSIGHTS_FAKE_EMBEDDER"] == "off" ? nil : FakeEmbeddingProvider()
            return (FakeModelProvider(script), embedder)
        }
        #endif
        return (AppleInsightsProviders.model(), AppleInsightsProviders.embedder())
    }

    /// Exit 3 with `reason` (D18): the model work this command needs cannot run here.
    static func unavailable(_ reason: String) -> CLIError { .unhealthy("insights: \(reason)") }

    static func modelReason(_ model: (any ModelProvider)?) -> String {
        guard let model else { return AppleInsightsProviders.unavailableReason }
        return "needs Apple Intelligence: \(model.availability)"
    }

    /// The vault's notes as insight inputs.
    static func inputs(_ vault: Vault, cache: CacheOptions) throws -> [InsightsNoteInput] {
        InsightsNotes.inputs(vault, summaries: try vault.summaries(of: nil, cache: cache.cache(for: vault)))
    }

    static func input(_ query: String, in inputs: [InsightsNoteInput], vault: Vault) throws -> InsightsNoteInput {
        let id = try vault.resolveNote(query)
        guard let n = inputs.first(where: { $0.id == id }) else { throw CLIError.failure("note \(id.uuidString.lowercased()) cannot be read") }
        return n
    }

    static func shortId(_ id: String) -> String { String(id.prefix(8)) }

    static func ms(_ d: Date?) -> String { d.map(Format.local) ?? "-" }
}

// MARK: - update

struct InsightsUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Make this device's insights now: summaries, keywords, vectors, the map, titles, topics.",
        discussion: """
            Does what the scheduling policy gives this device (design §3.7): the work device generates and embeds every \
            eligible note (text unchanged for 10 minutes; --force: now), rebuilds the map when more than 10% changed \
            or weekly, and titles voice notes whose title is still the capture default (insights.voiceNoteTitle). A \
            device that is not the work device generates only with insights.compute auto. The first capable device \
            to run it claims the work device when none is set. Needs Apple Intelligence (macOS 26), else exit 3 and \
            nothing is written; --embeddings-only needs only the embedder.
            """
    )

    @Option(name: .long, help: ArgumentHelp("Only this note (id, id prefix or exact title).", valueName: "note")) var note: String?
    @Flag(name: .long, help: "Process notes even when recently edited or already current.") var force = false
    @Option(name: .long, help: ArgumentHelp("At most this many model generations.", valueName: "n")) var limit: Int?
    @Flag(name: .customLong("embeddings-only"), help: "Only embed and build the map (no model).") var embeddingsOnly = false
    @Flag(name: .customLong("dry-run"), help: "Say what would be done; write nothing.") var dryRun = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        if let limit, limit < 0 { throw CLIError.usage("--limit must be at least 0") }
        let p = InsightsCLI.providers()
        if embeddingsOnly {
            guard p.embedder != nil else { throw InsightsCLI.unavailable("needs macOS 26 (the sentence embedder)") }
        } else {
            guard let model = p.model, model.availability.isAvailable else { throw InsightsCLI.unavailable(InsightsCLI.modelReason(p.model)) }
        }
        let vault = try access.openVault(.required)
        if !dryRun { try vault.requireWritable() }
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        var o = InsightsUpdateOptions()
        if let note { o.note = try vault.resolveNote(note) }
        o.force = force; o.limit = limit; o.embeddingsOnly = embeddingsOnly; o.dryRun = dryRun
        o.failureMemo = InsightsFailureMemo.defaultURL(vaultId: vault.vaultId)
        #if os(macOS)
        o.powerWindow = ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
        #endif
        let updater = InsightsUpdater(vault: vault, model: embeddingsOnly ? nil : p.model, embedder: p.embedder,
                                      deviceState: DeviceState.defaultURL(), app: appName)
        let options = o
        let report: InsightsUpdateReport
        do {
            report = try blockingThrowing { try await updater.run(options, notes: inputs) }
        } catch let e as InsightsUpdateError {
            throw CLIError.failure(e.description)
        }
        if output.json { return try output.emitJSON(report) }
        let verb = dryRun ? "would " : ""
        if report.claimedWorkDevice { output.info("\(verb)claim the work device: \(report.device)") }
        for (label, list) in [("generated", report.generated), ("embedded", report.embedded), ("tombstoned", report.tombstoned),
                              ("dropped stale", report.dropped), ("titled", report.titled), ("restored title", report.restoredTitles)]
        where !list.isEmpty {
            output.info("\(dryRun ? "would be " : "")\(label): \(list.count)  " + list.map(InsightsCLI.shortId).joined(separator: " "))
        }
        if !report.pinSet.isEmpty { output.info("pinned embedding revision: " + report.pinSet.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
        if report.mapBuilt { output.info("\(verb)rebuild the map") }
        if !report.topics.isEmpty { output.info("\(verb)summarize topics: " + report.topics.joined(separator: ", ")) }
        for (id, why) in report.failures.sorted(by: { $0.key < $1.key }) { printStderr("warning: \(InsightsCLI.shortId(id)): \(why)") }
        for n in report.notes { output.info(n) }
        if report.generated.isEmpty && report.embedded.isEmpty && !report.mapBuilt && report.titled.isEmpty {
            output.info("nothing to do")
        }
    }
}

// MARK: - show

struct InsightsShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "A note's summary, keywords and concepts: who made them, and whether they are current.")

    @Argument(help: ArgumentHelp("The note: id, id prefix or exact title.", valueName: "note")) var note: String
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        let n = try InsightsCLI.input(note, in: inputs, vault: vault)
        let reader = InsightsReader(vault: vault)
        let model = InsightsCLI.providers().model
        let shown = reader.show(n, reader: model?.availability.isAvailable == true ? model?.identity : nil)
        if output.json { return try output.emitJSON(shown) }
        print("\(shown.title)  [\(shown.state)]")
        if let s = shown.summary { print("summary:   \(s)") } else if shown.state == "missing" {
            print("summary:   (none yet: it appears after a device with Apple Intelligence has processed this note)")
        } else { print("summary:   (none: keywords only)") }
        if !shown.keywords.isEmpty { print("keywords:  " + shown.keywords.map(\.t).joined(separator: ", ")) }
        if !shown.concepts.isEmpty { print("concepts:  " + shown.concepts.joined(separator: ", ")) }
        if let d = shown.device {
            print("made on:   \(shown.deviceName ?? d) (\(d)), \(InsightsCLI.ms(shown.written)), \(shown.model ?? "") \(shown.os ?? "") prompt \(shown.prompt ?? 0)")
        }
        if let k = shown.embeddingKey { print("vector:    \(shown.embedded ? "current" : "stale") (\(k))") }
    }
}

// MARK: - related

struct InsightsRelated: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "related",
        abstract: "Notes related to a note, with why (shared keywords, or similar wording) and their scores.",
        discussion: """
            From the work device's vectors when they are compatible with this device (canaries, design §3.8), with \
            this device's own vectors for notes not embedded yet (placed); a device that fails the canaries uses a \
            local set; without vectors (no map yet, Linux without one), keyword overlap alone.
            """)

    @Argument(help: ArgumentHelp("The note: id, id prefix or exact title.", valueName: "note")) var note: String
    @Option(name: .long, help: ArgumentHelp("At most this many (default 8).", valueName: "n")) var limit = RelatedGraph.maxEdges
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard limit >= 0 else { throw CLIError.usage("--limit must be at least 0") }
        let vault = try access.openVault(.required)
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        let n = try InsightsCLI.input(note, in: inputs, vault: vault)
        let result = InsightsReader(vault: vault).related(n, inputs: inputs, me: vault.writerDevice, embedder: InsightsCLI.providers().embedder,
                                                          limit: limit)
        if output.json { return try output.emitJSON(result) }
        output.info("basis: \(result.basis) (\(result.compatibility))")
        if result.related.isEmpty { output.info("no related notes") }
        let rows = result.related.map { r in
            [InsightsCLI.shortId(r.note), String(format: "%.3f", r.score), r.title, r.why + (r.placed ? "  (placed here)" : "")]
        }
        if !rows.isEmpty { print(Format.table(rows)) }
    }
}

// MARK: - search

struct InsightsSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Notes whose keywords, concepts or summary hold every word of the query.")

    @Argument(help: ArgumentHelp("The words to find.", valueName: "query")) var query: String
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        let hits = InsightsReader(vault: vault).search(query, inputs: inputs)
        if output.json { return try output.emitJSON(hits) }
        if hits.isEmpty { output.info("no matches") }
        let rows = hits.map { [InsightsCLI.shortId($0.note), $0.title, "matched in \($0.field)" + ($0.stale ? " (stale)" : ""), $0.matched] }
        if !rows.isEmpty { print(Format.table(rows)) }
    }
}

// MARK: - status

struct InsightsStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Processed, stale and missing notes; the work device; the pin; each device's model, revisions and compatibility.")

    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        let s = InsightsReader(vault: vault).status(inputs: inputs, me: vault.writerDevice, embedder: InsightsCLI.providers().embedder)
        if output.json { return try output.emitJSON(s) }
        print("Note Insights: \(s.enabled ? "on" : "off")")
        print("processed \(s.processed) of \(s.notes) notes (\(s.stale) stale, \(s.missing) missing)")
        if let w = s.workDevice {
            print("work device: \(s.workDeviceName ?? w) (\(w)), last seen \(s.workDeviceLastSeen == nil ? "- (nothing written yet)" : InsightsCLI.ms(s.workDeviceLastSeen))"
                  + (s.workDeviceNotSeen ? ": work device not seen for 14 days (sempere insights work-device --claim to use this device)" : ""))
        } else {
            print("work device: none (sempere insights work-device --claim)")
        }
        print("embedding: \(s.language), pinned revision \(s.pin.map(String.init) ?? "not set yet")"
              + (s.upgradeOffer.map { "; a newer revision \($0) is available (sempere insights map --pin \($0))"
                  + (s.leftOutByUpgrade.isEmpty ? "" : ", leaving out \(s.leftOutByUpgrade.joined(separator: ", "))") } ?? ""))
        if let m = s.map {
            print("map: from \(m.device), \(m.notes) notes in \(m.clusters) clusters, \(InsightsCLI.ms(m.written)); this device: \(s.compatibility)")
        } else {
            print("map: none yet; this device: \(s.compatibility)")
        }
        let rows = s.devices.map { d -> [String] in
            [d.device + (d.isWorkDevice ? "*" : ""), d.name ?? (d.listed ? "" : "(not listed)"), "\(d.current) current, \(d.stale) stale",
             d.modelAvailable.map { $0 ? "model" : "no model (\(d.modelReason ?? "?"))" } ?? "no record",
             d.supported.map { $0.map { "\($0.key) r\($0.value.map(String.init).joined(separator: ","))" }.sorted().joined(separator: " ") } ?? "",
             d.compatibility ?? "", InsightsCLI.ms(d.lastSeen)]
        }
        if !rows.isEmpty { print(Format.table(rows)) }
        if s.ignoredFiles > 0 { print("\(s.ignoredFiles) file(s) in insights/ not taken (another key, damaged or a removed device's)") }
    }
}

// MARK: - topic

struct InsightsTopic: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "topic",
        abstract: "A notebook's or tag's generated summary, with the notes it was made from.",
        discussion: "--generate makes it now on this device (needs Apple Intelligence, exit 3 elsewhere).")

    @Option(name: .long, help: ArgumentHelp("A notebook path.", valueName: "path")) var notebook: String?
    @Option(name: .long, help: ArgumentHelp("A tag.", valueName: "tag")) var tag: String?
    @Flag(name: .long, help: "Generate it now.") var generate = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable {
        var scope: String
        var members: [String]
        var summary: String?
        var generated: Bool
        var stale: Bool
        var device: String?
        var at: Date?
    }

    func run() throws {
        guard (notebook == nil) != (tag == nil) else { throw CLIError.usage("give one of --notebook or --tag") }
        let scope: InsightsTopicsFile.Scope
        if let notebook {
            guard let c = NotebookPath.canonical(notebook) else { throw CLIError.usage("--notebook is not a notebook path") }
            scope = .init(notebook: c)
        } else { scope = .init(tag: NoteOps.tagKey(tag ?? "")) }
        let p = InsightsCLI.providers()
        if generate {
            guard let m = p.model, m.availability.isAvailable else { throw InsightsCLI.unavailable(InsightsCLI.modelReason(p.model)) }
        }
        let vault = try access.openVault(.required)
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        var snapshot = InsightsStore(vault: vault).snapshot()
        let members = TopicScopes.members(inputs: inputs, snapshot: snapshot).first { $0.0 == scope }?.1 ?? []
        if generate, let model = p.model {
            try vault.requireWritable()
            guard members.count >= TopicSummaries.minMembers else {
                throw CLIError.failure("\(TopicScopes.name(scope)) has \(members.count) summarized note(s); a topic needs at least \(TopicSummaries.minMembers)")
            }
            let merger = InsightsNotes.merger(inputs)
            let name = TopicScopes.name(scope)
            let text = try blockingThrowing {
                try await TopicSummaries.generate(name: name, members: members, language: nil, model: model, merger: merger)
            }
            guard let text else { throw CLIError.failure("the summary did not survive the fact check; nothing written") }
            let store = InsightsStore(vault: vault)
            let me = try store.writer()
            var topics = snapshot.topics[me]?.topics ?? []
            topics.removeAll { $0.scope == scope }
            topics.append(.init(scope: scope, members: members.count, membersHash: TopicSummaries.membersHash(members),
                                gen: .init(identity: model.identity, at: InsightsCodec.nextWritten(after: nil, now: Date()), summary: text)))
            topics.sort { TopicScopes.name($0.scope) < TopicScopes.name($1.scope) }
            try store.write(.topics(InsightsTopicsFile(device: me, written: 0, topics: topics)))
            snapshot = store.snapshot()
        }
        // The latest stored summary of the scope, from any device.
        let stored = snapshot.topics.compactMap { d, f in f.topics.first { $0.scope == scope }.map { (d, $0) } }
            .sorted { ($0.1.gen.at, $0.0.rawValue) > ($1.1.gen.at, $1.0.rawValue) }.first
        let out = Out(scope: TopicScopes.name(scope), members: members.map { $0.note.uuidString.lowercased() }, summary: stored?.1.gen.summary,
                      generated: stored != nil, stale: stored.map { $0.1.membersHash != TopicSummaries.membersHash(members) } ?? false,
                      device: stored?.0.rawValue, at: stored.map { Date(timeIntervalSince1970: Double($0.1.gen.at) / 1000) })
        if output.json { return try output.emitJSON(out) }
        print("\(out.scope)  (\(members.count) summarized notes)")
        if let s = out.summary { print("Generated\(out.stale ? ", stale" : ""): \(s)") } else { print("no summary yet") }
        let titles = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id.uuidString.lowercased(), $0.title) })
        for m in out.members { print("  \(InsightsCLI.shortId(m))  \(titles[m] ?? "")") }
    }
}

// MARK: - map

struct InsightsMap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "map",
        abstract: "The note map: clusters and positions, as JSON or SVG; rebuild it, or move the pinned embedding revision.",
        discussion: """
            --rebuild (needs the embedder, macOS 26): on the work device, embed what is missing and rebuild the shared \
            map; elsewhere, show a map built here (not written). --pin REV moves the vault's pinned embedding revision \
            (the Settings path, D12): it lists the devices that do not support REV (they become vector readers) and \
            needs --yes; when the work device lacks REV the role moves to a device that has it.
            """)

    @Option(name: .long, help: ArgumentHelp("json (default) or svg.", valueName: "format")) var format = "json"
    @Flag(name: .long, help: "Rebuild the map now.") var rebuild = false
    @Option(name: .long, help: ArgumentHelp("Move the pinned embedding revision.", valueName: "rev")) var pin: Int?
    @Flag(name: .long, help: "Confirm --pin.") var yes = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard ["json", "svg"].contains(format) else { throw CLIError.usage("--format is json or svg") }
        let p = InsightsCLI.providers()
        if rebuild, p.embedder == nil { throw InsightsCLI.unavailable("--rebuild needs macOS 26 (the sentence embedder)") }
        let vault = try access.openVault(.required)
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        if let pin { return try movePin(pin, vault: vault, inputs: inputs) }
        if rebuild {
            let settings = InsightsSettings.read(vault)
            if settings.workDevice == vault.writerDevice, settings.workDevice != nil {
                var o = InsightsUpdateOptions()
                o.embeddingsOnly = true; o.rebuildMap = true; o.titles = false; o.topics = false
                let options = o
                let updater = InsightsUpdater(vault: vault, model: nil, embedder: p.embedder, deviceState: DeviceState.defaultURL(), app: appName)
                _ = try blockingThrowing { try await updater.run(options, notes: inputs) }
            } else {
                printStderr("note: this device is not the work device; the map below is built here and not written")
            }
        }
        let view = InsightsReader(vault: vault).mapView(inputs: inputs, me: vault.writerDevice, embedder: p.embedder)
        if format == "svg" { print(InsightsReader.svg(view), terminator: "") } else { try output.emitJSON(view) }
    }

    func movePin(_ rev: Int, vault: Vault, inputs: [InsightsNoteInput]) throws {
        guard rev >= 1 else { throw CLIError.usage("--pin must be at least 1") }
        let snapshot = InsightsStore(vault: vault).snapshot()
        let settings = InsightsSettings.read(vault)
        let language = InsightsLanguage.of(inputs.first { !$0.deleted }?.language)
        let listed = Set(vault.manifest.devices.compactMap { $0.id.flatMap(DeviceID.init) })
        let recent = EmbeddingPin.recent(snapshot.devices, listed: listed, now: Date())
        let leftOut = EmbeddingPin.leftOut(recent, language: language, revision: rev)
        var newWork = settings.workDevice
        if let w = settings.workDevice, let r = snapshot.devices[w], !(r.supported[language] ?? []).contains(rev) {
            newWork = recent.filter { ($0.value.supported[language] ?? []).contains(rev) }.map(\.key).sorted().first
        }
        if !yes {
            let names = leftOut.map(\.rawValue).joined(separator: ", ")
            throw CLIError.usage("moving the \(language) embedding revision to \(rev) "
                + (leftOut.isEmpty ? "leaves no recently seen device out" : "leaves out \(names): they stop making vectors and cannot place new notes")
                + (newWork != settings.workDevice ? "; the work device moves to \(newWork?.rawValue ?? "none")" : "")
                + "; run again with --yes")
        }
        try vault.updateSharedSettings { s in
            guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.pin) else { return }
            var o: [String: JSONValue] = [:]
            if case .object(let cur) = s.resolve(spec, for: nil).value { o = cur }
            o[language] = .number(Double(rev))
            try s.write(spec, .object(o), block: nil, type: nil, now: Date())
            if newWork != settings.workDevice, let w = SharedSettingsCatalog.spec(named: InsightsSettings.keys.workDevice) {
                try s.write(w, newWork.map { .string($0.rawValue) } ?? .null, block: nil, type: nil, now: Date())
            }
        }
        struct Out: Encodable { var language: String; var revision: Int; var leftOut: [String]; var workDevice: String? }
        let out = Out(language: language, revision: rev, leftOut: leftOut.map(\.rawValue), workDevice: newWork?.rawValue)
        if output.json { return try output.emitJSON(out) }
        output.info("pinned \(language) embedding revision \(rev)" + (leftOut.isEmpty ? "" : "; vector readers now: \(out.leftOut.joined(separator: ", "))"))
    }
}

// MARK: - title

struct InsightsTitle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "title",
        abstract: "Title a voice note from its insights (D14), while its title is still the capture default.",
        discussion: """
            The title follows --format, else the vault's insights.voiceNoteTitle (default {date} {time} {slug}): \
            {date} YYYY-MM-DD and {time} HH.mm in the capture's time zone, {slug} the model's 2-6 word title, \
            fact-checked against the transcript. A title the user set is never replaced; a rename made on another \
            device that lost to this device's title is restored. Uses a stored slug; without one, makes it with \
            Apple's on-device model (exit 3 where there is none).
            """)

    @Argument(help: ArgumentHelp("The note: id, id prefix or exact title.", valueName: "note")) var note: String
    @Option(name: .long, help: ArgumentHelp("A title format with {date}, {time} and {slug}.", valueName: "format")) var format: String?
    @Flag(name: .customLong("dry-run"), help: "Say what the title would be; write nothing.") var dryRun = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable { var note: String; var action: String; var title: String?; var dryRun: Bool }

    func run() throws {
        if let format, let why = VoiceNoteTitleFormat.check(format) { throw CLIError.usage("--format: \(why)") }
        let vault = try access.openVault(.required)
        if !dryRun { try vault.requireWritable() }
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        let n = try InsightsCLI.input(note, in: inputs, vault: vault)
        let fmt = format ?? InsightsSettings.read(vault).voiceNoteTitle
        let snapshot = InsightsStore(vault: vault).snapshot()
        var slug = snapshot.bestGen(for: n.id, hash: n.hash).flatMap { $0.current ? $0.gen.slug : nil }
        if slug == nil, fmt.contains("{slug}"), !n.transcript.isEmpty {
            let p = InsightsCLI.providers()
            guard let model = p.model, model.availability.isAvailable else { throw InsightsCLI.unavailable(InsightsCLI.modelReason(p.model)) }
            let transcript = n.transcript, merger = InsightsNotes.merger(inputs)
            slug = try blockingThrowing { () async throws -> String? in
                let raw = try await model.title(transcript: String(transcript.prefix(4000)), language: n.language)
                return InsightsGenerator.slug(raw, transcript: transcript, merger: merger)
            }
        }
        let updater = InsightsUpdater(vault: vault, model: nil, embedder: nil, deviceState: DeviceState.defaultURL(), app: appName)
        let decision: VoiceNoteTitleState.Decision
        let isVoice: Bool
        if dryRun {
            (decision, isVoice) = try updater.proposedTitle(n, format: fmt, slug: slug)
        } else {
            let p = try updater.proposedTitle(n, format: fmt, slug: slug)
            isVoice = p.isVoice
            decision = isVoice ? try updater.writeTitle(n, format: fmt, slug: slug) : .keep
        }
        let out: Out
        switch decision {
        case .apply(let t): out = Out(note: n.id.uuidString.lowercased(), action: "apply", title: t, dryRun: dryRun)
        case .restore(let t): out = Out(note: n.id.uuidString.lowercased(), action: "restore", title: t, dryRun: dryRun)
        case .keep: out = Out(note: n.id.uuidString.lowercased(), action: isVoice ? "keep" : "notVoiceNote", title: nil, dryRun: dryRun)
        }
        if output.json { return try output.emitJSON(out) }
        switch out.action {
        case "apply": output.info("\(dryRun ? "would title" : "titled") \(InsightsCLI.shortId(out.note)): \(out.title ?? "")")
        case "restore": output.info("\(dryRun ? "would restore" : "restored") the user's title: \(out.title ?? "")")
        case "notVoiceNote": output.info("not a voice note: titles are only for quick voice notes")
        default: output.info("the title stays (\(n.title))")
        }
    }
}

// MARK: - work-device

struct InsightsWorkDevice: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "work-device",
        abstract: "Show or set the work device (D13): the one device that makes summaries, embeds every note and builds the map.",
        discussion: """
            Without arguments it shows the work device, when it was last seen and which devices can hold the role. \
            ID (8 hex digits, sempere devices) sets it; --claim takes it for this device (needs the embedder, macOS 26). \
            The role never moves by itself, even when the work device has not been seen for 14 days.
            """)

    @Argument(help: ArgumentHelp("The device id to make the work device.", valueName: "id")) var id: String?
    @Flag(name: .long, help: "Make this device the work device.") var claim = false
    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    struct Out: Encodable {
        var workDevice: String?
        var name: String?
        var lastSeen: Date?
        var notSeenFor14Days: Bool
        var capable: [String]
        var changed: Bool
    }

    func run() throws {
        if id != nil && claim { throw CLIError.usage("give an ID or --claim, not both") }
        if claim, InsightsCLI.providers().embedder == nil { throw InsightsCLI.unavailable("--claim needs macOS 26 (the sentence embedder)") }
        let vault = try access.openVault(.required)
        var changed = false
        if claim || id != nil {
            let target: DeviceID
            if claim {
                guard let me = vault.writerDevice else { throw CLIError.failure("this machine is not a device of the vault") }
                target = me
            } else {
                guard let d = id.flatMap({ DeviceID($0.lowercased()) }) else { throw CLIError.usage("the id is 8 hex digits (sempere devices)") }
                guard vault.manifest.devices.contains(where: { $0.id == d.rawValue }) else {
                    throw CLIError.failure("no device \(d.rawValue) in the vault's list")
                }
                target = d
            }
            try vault.updateSharedSettings { s in
                guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.workDevice) else { return }
                try s.write(spec, .string(target.rawValue), block: nil, type: nil, now: Date())
            }
            changed = true
        }
        let inputs = try InsightsCLI.inputs(vault, cache: cache)
        let reader = InsightsReader(vault: vault)
        let listed = Set(vault.manifest.devices.compactMap { $0.id.flatMap(DeviceID.init) })
        let w = WorkDeviceStatus(settings: reader.settings, snapshot: reader.snapshot, listed: listed,
                                 language: InsightsUpdater.mainLanguage(inputs), now: Date())
        let out = Out(workDevice: w.workDevice?.rawValue, name: w.workDevice.flatMap { reader.deviceNames[$0.rawValue] },
                      lastSeen: w.lastSeen, notSeenFor14Days: w.notSeen, capable: w.capable.map(\.rawValue), changed: changed)
        if output.json { return try output.emitJSON(out) }
        if let d = out.workDevice {
            print("work device: \(out.name ?? d) (\(d)), last seen \(out.lastSeen == nil ? "- (nothing written yet)" : InsightsCLI.ms(out.lastSeen))"
                  + (out.notSeenFor14Days ? "; not seen for 14 days: summaries pause until it returns or another device is set" : ""))
        } else { print("work device: none") }
        if !out.capable.isEmpty { print("capable: " + out.capable.map { "\(reader.deviceNames[$0] ?? $0) (\($0))" }.joined(separator: ", ")) }
    }
}

// MARK: - purge

struct InsightsPurge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Turn Note Insights off and delete every insights file here; the next sync deletes them on targets.")

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        try vault.requireWritable()
        try vault.updateSharedSettings { s in
            guard let spec = SharedSettingsCatalog.spec(named: InsightsSettings.keys.enabled) else { return }
            try s.write(spec, .bool(false), block: nil, type: nil, now: Date())
        }
        let deleted = try InsightsStore(vault: vault).purge()
        struct Out: Encodable { var deleted: [String] }
        if output.json { return try output.emitJSON(Out(deleted: deleted)) }
        output.info("Note Insights is off; deleted \(deleted.count) file(s)")
    }
}
