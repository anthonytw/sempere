import Age
import ArgumentParser
import Foundation
import Sempere
import SempereCapture

/// `sempere inbox watch`: the Apple Watch's voice notes, each step as the watch and the iPhone do it, from the same code
/// (docs/design/1.1-watch.md §4, docs/cli.md "Watch"). `keygen` makes a throwaway watch provisioning identity; `provision`
/// builds the vault's capture profile as a payload age-encrypted to that watch (needs the key once, like `enable`);
/// `seal` acts as the watch (opens the payload, remuxes ADTS to MPEG-4, seals, writes the outbox); `receive` acts as the
/// phone (checks, dedupes, delivers by vault, ledger first, and writes the acknowledgement).
struct InboxWatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Apple Watch voice notes: provision a watch, seal as the watch, receive as the phone.",
        subcommands: [InboxWatchKeygen.self, InboxWatchProvision.self, InboxWatchSeal.self, InboxWatchReceive.self,
                      InboxWatchHeld.self]
    )
}

struct InboxWatchKeygen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keygen",
        abstract: "Make a watch provisioning identity (for testing without a watch).",
        discussion: "Writes the identity (mode 0600, never over an existing file) and prints its public recipient (age1pq1…)."
    )

    @Option(name: .long, help: ArgumentHelp("Where to write the identity file.", valueName: "file"))
    var out: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        let identity: NativeIdentity
        do { identity = try NativeIdentity.generate(.postQuantum) } catch { throw CLIError.failure("\(error)") }
        try writeNewSecretFile(IdentityFile.render(identity, created: Date()), to: out)
        let recipient = identity.recipient.string
        if output.json {
            struct Out: Encodable { var identity: String; var recipient: String }
            try output.emitJSON(Out(identity: out, recipient: recipient))
        } else if output.quiet {
            print(recipient)
        } else {
            output.info("Wrote \(out)")
            output.info("Recipient: \(recipient)")
        }
    }
}

struct InboxWatchProvision: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision",
        abstract: "Encrypt the vault's capture profile to a watch's provisioning key (needs the key once).",
        discussion: """
            The payload holds this device's capture profile (the vault identity's public key and this device's capture \
            key, which can only put captures in the inbox), the vault's name and a counter, age-encrypted to the watch's \
            recipient so the capture key is never plaintext on the way. The watch (or `inbox watch seal`) opens it with \
            its provisioning identity.
            """
    )

    @Option(name: .long, help: ArgumentHelp("The watch's provisioning recipient (age1pq1…).", valueName: "recipient"))
    var to: String

    @Option(name: .long, help: ArgumentHelp("Where to write the payload.", valueName: "file"))
    var out: String

    @Option(name: .long, help: ArgumentHelp("The notebook captures are adopted into.", valueName: "name"))
    var notebook: String = CaptureProfile.defaultNotebook

    @Option(name: .long, help: ArgumentHelp("The payload's counter (default: the time in seconds, which fits until 2038); a watch takes only a larger one.",
                                            valueName: "n"))
    var seq: Int?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let seq, !(0...Int(Int32.max)).contains(seq) { throw ValidationError("--seq must be 0 to \(Int32.max)") }
    }

    func run() throws {
        let recipient: NativeRecipient
        do { recipient = try NativeRecipient(string: to) } catch { throw CLIError.usage("not a watch recipient: \(to)") }
        guard recipient.isPostQuantum else { throw CLIError.usage("the watch's key must be a post-quantum (age1pq1…) recipient") }
        let vault = try access.openVault(.required)
        let device = try vault.writerDevice ?? DeviceState.loadOrCreate(at: DeviceState.defaultURL()).device
        let profile = try vault.captureProfile(device: device, notebook: notebook)
        let now = Date()
        let number = seq ?? Int(now.timeIntervalSince1970)
        let name = VaultStore.displayName(of: vault.url)
        let message: WatchProvisioning.Message
        do {
            message = try WatchProvisioning.provision(profile: profile, vaultName: name, seq: number, issued: now, to: recipient)
        } catch { throw CLIError.failure("\(error)") }
        guard case .profile(let data) = message else { throw CLIError.failure("no payload") }
        try writePrivateFile(data, to: URL(fileURLWithPath: out))
        if output.json {
            struct Out: Encodable { var payload: String; var vault: String; var seq: Int; var bytes: Int }
            try output.emitJSON(Out(payload: out, vault: vault.vaultId.uuidString.lowercased(), seq: number, bytes: data.count))
        } else {
            output.info("Wrote the provisioning payload to \(out) (vault \(name), seq \(number))")
        }
    }
}

struct InboxWatchSeal: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seal",
        abstract: "Act as the watch: seal an audio file into an outbox folder.",
        discussion: """
            Opens the payload with the watch's identity, remuxes ADTS (.aac) to MPEG-4 (an .m4a is used as it is), seals \
            it with the provisioned profile and writes <id>.capture.age and its transfer metadata (<id>.meta.json) into \
            the outbox folder, as the watch does. `inbox watch receive` is the phone's half.
            """
    )

    @Argument(help: ArgumentHelp("An audio file: ADTS (.aac) or MPEG-4 (.m4a).", valueName: "audio"))
    var audio: String

    @Option(name: .long, help: ArgumentHelp("The provisioning payload (`inbox watch provision`).", valueName: "file"))
    var payload: String

    @Option(name: .long, help: ArgumentHelp("The watch's provisioning identity (`inbox watch keygen`).", valueName: "file"))
    var identity: String

    @Option(name: .long, help: ArgumentHelp("The outbox folder (created).", valueName: "dir"))
    var outbox: String

    @Option(name: .long, help: ArgumentHelp("The note's title (default: Watch voice note <date> <time>).", valueName: "title"))
    var title: String?

    @Option(name: .long, help: ArgumentHelp("When the first sample was recorded (RFC 3339).", valueName: "time"))
    var started: String?

    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let started, RFC3339.parse(started) == nil { throw ValidationError("--started is not an RFC 3339 time: \(started)") }
    }

    func run() throws {
        let key = try readIdentityFile(identity)
        let sealedPayload: Data
        do { sealedPayload = try BoundedRead.contents(of: URL(fileURLWithPath: payload), maxBytes: WatchProfilePayload.maxBytes) } catch {
            throw CLIError.failure("cannot read \(payload): \(CLIError.from(error).message)")
        }
        let opened: WatchProfilePayload
        do { opened = try WatchProfilePayload.open(sealedPayload, with: key) } catch { throw CLIError.failure("\(error)") }

        let url = URL(fileURLWithPath: audio)
        let bytes: Data
        do { bytes = try BoundedRead.contents(of: url, maxBytes: ADTSToMP4.maxInputBytes) } catch {
            throw CLIError.failure("cannot read \(audio): \(CLIError.from(error).message)")
        }
        let mp4: Data
        let info: AudioInfo?
        if bytes.first == 0xFF {
            // ADTS: remuxed to MPEG-4, a cut-off last frame dropped as a crash leaves it.
            do {
                let r = try ADTSToMP4.remux(bytes, tail: .dropPartial)
                mp4 = r.data
                info = r.info.audioInfo
            } catch { throw CLIError.failure("\(audio): \(error)") }
        } else {
            do { info = try AudioProbe.probe(bytes) } catch {
                throw CLIError.failure("\(audio) is neither ADTS (.aac) nor MPEG-4 (.m4a) audio: \(error)")
            }
            mp4 = bytes
        }
        let when: Date
        if let started, let t = RFC3339.parse(started) {
            when = t
        } else {
            let end = (try? FileManager.default.attributesOfItem(atPath: audio)[.modificationDate] as? Date) ?? Date()
            when = end.addingTimeInterval(-(info?.duration ?? 0))
        }
        let id = UUID()
        let sealed = try CaptureWriter(profile: opened.profile)
            .seal(audio: mp4, type: "audio/mp4", started: when, info: info, title: title ?? WatchRecorder.title(when), id: id)
        let box: WatchOutbox
        do { box = try WatchOutbox(directory: URL(fileURLWithPath: outbox, isDirectory: true)) } catch {
            throw CLIError.failure("\(error)")
        }
        let meta: WatchTransferMeta
        do { meta = try box.add(sealed, vault: opened.profile.vaultId) } catch { throw CLIError.failure("\(error)") }
        if output.json {
            struct Out: Encodable { var capture: String; var vault: String; var file: String; var meta: String; var bytes: Int }
            try output.emitJSON(Out(capture: id.uuidString.lowercased(), vault: meta.vault.uuidString.lowercased(),
                                    file: box.fileURL(id).path, meta: "\(outbox)/\(id.uuidString.lowercased()).meta.json",
                                    bytes: meta.size))
        } else {
            print(id.uuidString.lowercased())
            if !output.quiet { printStderr("Sealed \(meta.name) into \(outbox) (\(meta.size) bytes, vault \(opened.vaultName))") }
        }
    }
}

/// The CLI's half of `WatchDelivery`: this machine's ledger (ledger first), the vault folder named by `--vault`, the
/// store's vaults by id, and a queue folder.
struct CLIWatchDelivery: WatchDelivery {
    var current: (id: UUID, url: URL)?
    var store: VaultStore
    var queueRoot: URL

    var currentVault: UUID? { current?.id }

    private func inbox(of url: URL) -> URL { url.appendingPathComponent(CaptureFile.folderName, isDirectory: true) }

    private func url(of vault: UUID) -> URL? {
        if let current, current.id == vault { return current.url }
        return store.entry(id: vault)?.url
    }

    func inboxHolds(id: UUID, vault: UUID) -> Bool {
        guard let url = url(of: vault) else { return false }
        return FileManager.default.fileExists(atPath: inbox(of: url).appendingPathComponent(CaptureFile.name(id, .capture)).path)
    }

    /// A vault this version may write into: it is that vault, and not marked as written by a newer version (format.md §7.3).
    private func accepts(_ url: URL, vault: UUID) -> Bool {
        guard let v = try? Vault.open(at: url) else { return false }
        return v.vaultId == vault && !v.isReadOnly
    }

    func deliverToCurrent(_ sealed: SealedCapture) throws -> WatchPlacement {
        guard let current else { throw CLIError.failure("no current vault") }
        if accepts(current.url, vault: current.id) {
            // Intent first (design §5.4): never placed unrecorded.
            try WatchLedger.record(sealed, in: captureLedger(vaultId: current.id))
            try CaptureWriter.store(sealed, in: inbox(of: current.url))
            return .vault
        }
        try WatchQueue.store(sealed, in: WatchQueue.folder(queueRoot, vault: current.id))
        return .queued
    }

    func holds(vault: UUID) -> Bool { store.entry(id: vault) != nil }

    func hasLedger(for vault: UUID) -> Bool { captureLedger(vaultId: vault) != nil }

    /// `receive` is an explicit command, so the link counts as on.
    var linkEnabled: Bool { true }

    /// The newest epoch whose key this machine's ledger remembers for `vault` (`inbox watch provision` remembers the
    /// profile's); nil without a ledger.
    func knownEpoch(of vault: UUID) throws -> (epoch: Int, id: Data)? {
        guard let keys = try captureLedger(vaultId: vault)?.epochKeys(), let newest = keys.max(by: { $0.epoch < $1.epoch }) else { return nil }
        return (newest.epoch, newest.key.epochId)
    }

    func holdsKey(of epochId: Data, vault: UUID) throws -> Bool {
        try (captureLedger(vaultId: vault)?.epochKeys() ?? []).contains { $0.key.epochId == epochId }
    }

    func folderEpoch(of vault: UUID) -> Int? {
        guard let url = url(of: vault), let v = try? Vault.open(at: url), v.vaultId == vault else { return nil }
        return v.manifest.epoch
    }

    func recordAndPlace(_ sealed: SealedCapture, in vault: UUID) throws -> Bool {
        guard let url = store.entry(id: vault)?.url, accepts(url, vault: vault) else { return false }
        try WatchLedger.record(sealed, in: captureLedger(vaultId: vault))
        try CaptureWriter.store(sealed, in: inbox(of: url))
        return true
    }

    func queue(_ sealed: SealedCapture, for vault: UUID) throws {
        try WatchQueue.store(sealed, in: WatchQueue.folder(queueRoot, vault: vault))
    }
}

struct InboxWatchReceive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "receive",
        abstract: "Act as the phone: take what a watch's outbox holds into the vault's inbox.",
        discussion: """
            For each <id>.capture.age with its <id>.meta.json: checks the metadata against the file (name, size, SHA-256, \
            epoch), skips an id already received or already in the inbox, and delivers it by the vault the metadata names: \
            the --vault's inbox when it is that vault (recorded in this machine's write ledger first), another vault of \
            the store by its own ledger, else this machine's queue for that vault (recorded when it is placed). Then \
            writes the acknowledgement the phone would send (acked ids, and the ids it holds) to --ack. Run it twice: the \
            second run places nothing. `inbox import` then adopts the captures. A file whose checks fail is reported and \
            never acknowledged.
            """
    )

    @Argument(help: ArgumentHelp("The watch's outbox folder.", valueName: "outbox"))
    var outbox: String

    @Option(name: .long, help: ArgumentHelp("The received-set file (default: $XDG_STATE_HOME/sempere/capture/watch-received.json).",
                                            valueName: "file"))
    var received: String?

    @Option(name: .long, help: ArgumentHelp("Where captures for a vault this machine does not hold wait (default: "
                                            + "$XDG_STATE_HOME/sempere/capture/watch-queue).", valueName: "dir"))
    var queue: String?

    @Option(name: .long, help: ArgumentHelp("Where to write the acknowledgement (default: <outbox>/ack.json).", valueName: "file"))
    var ack: String?

    @Option(name: .long, help: ArgumentHelp("Where files that are not admitted are held (default: "
                                            + "$XDG_STATE_HOME/sempere/capture/watch-held).", valueName: "dir"))
    var held: String?

    @OptionGroup var store: StoreOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct FileResult: Encodable {
        var capture: String
        /// `placed`, `held`, `duplicate` or `refused`.
        var outcome: String
        /// Where a placed capture went: `vault`, `queued`, `otherVault`, `otherVaultQueued`.
        var placement: String?
        /// Why a held capture is held: `linkOff`, `oldEpoch`, `newerEpoch`, `unknownEpoch`, `unknownVault`.
        var reason: String?
        var problem: String?
    }

    static func name(_ p: WatchPlacement) -> String {
        switch p {
        case .vault: return "vault"
        case .queued: return "queued"
        case .otherVault: return "otherVault"
        case .otherVaultQueued: return "otherVaultQueued"
        }
    }

    func run() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: outbox, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { throw CLIError.failure("no outbox folder at \(outbox)") }
        let stateDir = DeviceState.defaultURL().deletingLastPathComponent().appendingPathComponent("capture", isDirectory: true)
        // The vault the machine's capture profile serves: the one `--vault` names, when it is given.
        var current: (id: UUID, url: URL)?
        if access.vault != nil || Env.vars["SEMPERE_VAULT"] != nil {
            let url = try access.vaultURL()
            current = (try Vault.open(at: url).vaultId, url)
        }
        let delivery = CLIWatchDelivery(current: current, store: store.open(),
                                        queueRoot: queue.map { URL(fileURLWithPath: $0, isDirectory: true) }
                                            ?? stateDir.appendingPathComponent("watch-queue", isDirectory: true))
        let set = WatchReceivedSet(url: received.map { URL(fileURLWithPath: $0) } ?? stateDir.appendingPathComponent("watch-received.json"))
        let intake = WatchIntake(received: set, delivery: delivery, held: WatchHeldFolder.store(held))

        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".\(WatchOutbox.sidecarExtension)") }.sorted()
        var results: [FileResult] = []
        var acked: [UUID] = []
        var failures = 0
        for name in names {
            let metaURL = dir.appendingPathComponent(name)
            let meta: WatchTransferMeta
            do {
                meta = try JSONDecoder().decode(WatchTransferMeta.self, from: try BoundedRead.contents(of: metaURL, maxBytes: 4096))
            } catch {
                printStderr("skipped \(name): not transfer metadata")
                failures += 1
                continue
            }
            let file = dir.appendingPathComponent(meta.name)
            do {
                let r = try intake.receive(file: file, meta: meta)
                if r.acknowledged { acked.append(r.id) }
                switch r.outcome {
                case .placed(let p): results.append(FileResult(capture: meta.id.uuidString.lowercased(), outcome: "placed",
                                                               placement: Self.name(p), reason: nil, problem: nil))
                case .held(let why): results.append(FileResult(capture: meta.id.uuidString.lowercased(), outcome: "held",
                                                               placement: nil, reason: why.rawValue, problem: nil))
                case .duplicate: results.append(FileResult(capture: meta.id.uuidString.lowercased(), outcome: "duplicate",
                                                           placement: nil, reason: nil, problem: nil))
                case .refused(let problem):
                    failures += 1
                    results.append(FileResult(capture: meta.id.uuidString.lowercased(), outcome: "refused", placement: nil,
                                              problem: problem.description))
                }
            } catch {
                failures += 1
                results.append(FileResult(capture: meta.id.uuidString.lowercased(), outcome: "refused", placement: nil, reason: nil,
                                          problem: CLIError.from(error).message))
            }
        }
        let ackFile = WatchAck(acked: acked, have: intake.have().have)
        let ackURL = ack.map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("ack.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        struct AckFile: Encodable { var acked: [String]; var have: [String] }
        try writePrivateFile(try enc.encode(AckFile(acked: ackFile.acked.map { $0.uuidString.lowercased() },
                                                    have: ackFile.have.map { $0.uuidString.lowercased() })), to: ackURL)
        if output.json {
            struct Out: Encodable { var files: [FileResult]; var acked: [String]; var ack: String }
            try output.emitJSON(Out(files: results, acked: acked.map { $0.uuidString.lowercased() }, ack: ackURL.path))
        } else {
            for r in results {
                output.info("\(r.capture.prefix(8)) \(r.outcome)\(r.placement.map { " (\($0))" } ?? "")\(r.reason.map { " (\($0))" } ?? "")\(r.problem.map { ": \($0)" } ?? "")")
            }
            let placed = results.filter { $0.outcome == "placed" }.count
            output.info("\(placed) placed, \(results.filter { $0.outcome == "held" }.count) held, "
                        + "\(results.filter { $0.outcome == "duplicate" }.count) already there, "
                        + "\(failures) refused; acknowledgement in \(ackURL.path)")
        }
        if failures > 0 { throw CLIError.failure("\(failures) file(s) could not be received") }
    }
}

/// Where the CLI keeps held files: `--held`, else beside the received set.
enum WatchHeldFolder {
    static func store(_ path: String?) -> WatchHeldStore {
        let stateDir = DeviceState.defaultURL().deletingLastPathComponent().appendingPathComponent("capture", isDirectory: true)
        return WatchHeldStore(root: path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                              ?? stateDir.appendingPathComponent("watch-held", isDirectory: true))
    }
}

/// `sempere inbox watch held`: the files `receive` did not admit (the toggle was off, or the epoch is not the one this machine
/// holds), kept here until they are added to the inbox or deleted.
struct InboxWatchHeld: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "held",
        abstract: "Watch notes that were not admitted: list, add to the inbox, or delete.",
        discussion: """
            `receive` admits a file only while the link is on and its epoch is the one this machine holds for its vault. Any \
            other file is acknowledged but kept here, never in a vault folder, the ledger or a sync, until you decide: `add` \
            takes it into the inbox as `receive` would (catch-up then re-seals it under the current key), `delete` removes it. \
            A file sealed under an epoch this machine never held cannot be added. At most 200 files or 500 MB are held, of \
            which at most 20 files or 50 MB may be notes that can only be deleted; past either a file is refused, \
            unacknowledged, and the watch keeps it. `list` also removes leftover files that have no record and are over a day old.
            """,
        subcommands: [InboxWatchHeldList.self, InboxWatchHeldAdd.self, InboxWatchHeldDelete.self]
    )
}

struct HeldOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The held folder (default: $XDG_STATE_HOME/sempere/capture/watch-held).", valueName: "dir"))
    var held: String?
}

struct HeldRow: Encodable {
    var capture: String
    var vault: String
    var epoch: Int
    var reason: String
    var canAdd: Bool
    /// Arrived after the toggle went off or under an earlier key (`WatchHeldReason.needsCheck`): check before adding.
    var needsCheck: Bool
    var bytes: Int
    var receivedAt: String

    init(_ h: HeldCapture) {
        capture = h.id.uuidString.lowercased()
        vault = h.vault.uuidString.lowercased()
        epoch = h.epoch
        reason = h.reason.rawValue
        canAdd = h.canAdd
        needsCheck = h.needsCheck
        bytes = h.bytes
        receivedAt = RFC3339.string(from: h.receivedAt) ?? ""
    }
}

struct InboxWatchHeldList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the held Watch notes.")

    @OptionGroup var options: HeldOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let store = WatchHeldFolder.store(options.held)
        let rows = store.list().map(HeldRow.init)
        let removed = store.takeOrphansRemoved()
        var counts: [String: Int] = [:]
        for r in rows { counts[r.reason, default: 0] += 1 }
        if output.json {
            struct Out: Encodable {
                var notes: [HeldRow]
                /// Held notes per reason.
                var counts: [String: Int]
                /// Files without their record (and records without their file) older than 24 hours, removed by this listing.
                var orphansRemoved: Int
                var limits: Limits
            }
            struct Limits: Encodable {
                var files: Int
                var bytes: Int
                var unplaceableFiles: Int
                var unplaceableBytes: Int
            }
            try output.emitJSON(Out(notes: rows, counts: counts, orphansRemoved: removed,
                                    limits: Limits(files: WatchHeldStore.maxFiles, bytes: WatchHeldStore.maxTotalBytes,
                                                   unplaceableFiles: WatchHeldStore.maxUnplaceableFiles,
                                                   unplaceableBytes: WatchHeldStore.maxUnplaceableBytes)))
        } else if rows.isEmpty {
            output.info("No Watch notes are held.")
        } else {
            for r in rows {
                let note = !r.canAdd ? " (delete only)" : r.needsCheck ? " (check before adding: add by id)" : ""
                print("\(r.capture)  \(r.reason)\(note)  vault \(r.vault.prefix(8))  \(r.bytes) bytes  \(r.receivedAt)")
            }
            output.info("Held: " + counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        }
        if removed > 0 && !output.json { output.info("Removed \(removed) leftover file(s) older than 24 hours.") }
    }
}

struct InboxWatchHeldAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add held Watch notes to the inbox (ledger first, as `receive` does).",
        discussion: "Names are ids or unique id prefixes (4 or more characters). `--all` takes every held note that can be added, "
            + "except those that arrived after Use on Apple Watch went off or under an earlier key: check those and add them by id."
    )

    @Argument(help: ArgumentHelp("Held capture ids or prefixes.", valueName: "id"))
    var ids: [String] = []

    @Flag(name: .long, help: "Every held note that can be added.")
    var all = false

    @OptionGroup var options: HeldOptions

    @Option(name: .long, help: ArgumentHelp("Where captures for a vault this machine cannot write now wait (default: "
                                            + "$XDG_STATE_HOME/sempere/capture/watch-queue).", valueName: "dir"))
    var queue: String?

    @OptionGroup var store: StoreOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if ids.isEmpty == !all { throw ValidationError("give held ids, or --all") }
    }

    func run() throws {
        let stateDir = DeviceState.defaultURL().deletingLastPathComponent().appendingPathComponent("capture", isDirectory: true)
        var current: (id: UUID, url: URL)?
        if access.vault != nil || Env.vars["SEMPERE_VAULT"] != nil {
            let url = try access.vaultURL()
            current = (try Vault.open(at: url).vaultId, url)
        }
        let delivery = CLIWatchDelivery(current: current, store: store.open(),
                                        queueRoot: queue.map { URL(fileURLWithPath: $0, isDirectory: true) }
                                            ?? stateDir.appendingPathComponent("watch-queue", isDirectory: true))
        let held = WatchHeldFolder.store(options.held)
        let intake = WatchIntake(received: WatchReceivedSet(url: nil), delivery: delivery, held: held)
        let targets: [HeldCapture]
        do {
            if all {
                let everything = held.list()
                let addable = everything.filter(intake.canAddNow)
                targets = addable.filter { !$0.needsCheck }
                if addable.count < everything.count {
                    printStderr("\(everything.count - addable.count) held note(s) cannot be added now (see `held list`); skipped")
                }
                if targets.count < addable.count {
                    printStderr("\(addable.count - targets.count) held note(s) arrived after Use on Apple Watch went off or under an "
                        + "earlier key; skipped: check them (`held list`) and add them by id")
                }
            } else {
                targets = try ids.map { try held.find($0) }
            }
        } catch {
            throw CLIError.failure("\(error)")
        }
        struct Out: Encodable { var capture: String; var outcome: String; var placement: String?; var problem: String? }
        var out: [Out] = []
        var failures = 0
        for t in targets {
            let id = t.id.uuidString.lowercased()
            do {
                let p = try intake.addHeld(t)
                // nil: no longer held (an earlier add took it), a no-op rather than a failure.
                out.append(Out(capture: id, outcome: p == nil ? "notHeld" : "added", placement: p.map(InboxWatchReceive.name),
                               problem: p == nil ? "no longer held (added already)" : nil))
            } catch {
                failures += 1
                out.append(Out(capture: id, outcome: "failed", placement: nil, problem: CLIError.from(error).message))
            }
        }
        if output.json {
            try output.emitJSON(out)
        } else {
            for o in out {
                output.info("\(o.capture.prefix(8)) \(o.outcome)\(o.placement.map { " (\($0))" } ?? "")\(o.problem.map { ": \($0)" } ?? "")")
            }
        }
        if failures > 0 { throw CLIError.failure("\(failures) note(s) could not be added") }
    }
}

struct InboxWatchHeldDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete held Watch notes.",
        discussion: "Names are ids or unique id prefixes (4 or more characters). `--all` deletes every held note."
    )

    @Argument(help: ArgumentHelp("Held capture ids or prefixes.", valueName: "id"))
    var ids: [String] = []

    @Flag(name: .long, help: "Every held note.")
    var all = false

    @OptionGroup var options: HeldOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if ids.isEmpty == !all { throw ValidationError("give held ids, or --all") }
    }

    func run() throws {
        let held = WatchHeldFolder.store(options.held)
        let targets: [HeldCapture]
        do { targets = all ? held.list() : try ids.map { try held.find($0) } } catch { throw CLIError.failure("\(error)") }
        for t in targets { held.delete(t) }
        let names = targets.map { $0.id.uuidString.lowercased() }
        if output.json {
            struct Out: Encodable { var deleted: [String] }
            try output.emitJSON(Out(deleted: names))
        } else {
            output.info("Deleted \(names.count) held Watch note(s).")
        }
    }
}
