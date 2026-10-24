import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The invariants of key-hierarchy design §11.2 over sync (phase KH4: J1 to J6 and J8 to J10), on seeded random
/// runs: four or five devices on two targets (each device on one or both), transport faults, writes, two-way
/// runs, removals by home after its best-effort pull, takeovers (one, or two at once), lost epoch records, and
/// adversarial removed devices that keep writing under the keys they held and plant the files on a target, or
/// forge an epoch under one where they were listed and plant it. An oracle records every write (who, when,
/// whether its writer was removed then). At quiescence (faults off, every device synced with its targets a few
/// times) the invariants are checked; J5a, J5b and J6 also after every step.
///
/// Each test-only mutation (`EpochMutation`, `SyncEpochMutation`, `PrecedenceMutation`) must break ITS invariant
/// on a seed whose unmutated run is clean, so none is vacuous. Quick mode: 3 seeds over the memory transport and
/// the WebDAV mock in every `swift test`; `SEMPERE_SYNC_STRESS_LONG=1` runs `SEMPERE_SYNC_STRESS_SEEDS` (60)
/// seeds of 120 steps with five devices, also over wsgidav (`scripts/sync-stress.sh`); `SEMPERE_EPOCH_SEED=N`
/// replays one seed.
final class EpochInterleavingTests: SyncTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        Self.clearMutations()
        super.tearDown()
    }

    static func clearMutations() {
        VaultEpochKey.testRandomSource = nil
        Vault.epochMutations = []
        Vault.precedenceMutations = []
        SyncEngine.epochMutations = []
    }

    struct Mode {
        var seeds: [UInt64]
        var steps: Int
        var devices: Int
    }

    static var mode: Mode {
        let env = ProcessInfo.processInfo.environment
        let long = env["SEMPERE_SYNC_STRESS_LONG"] == "1"
        var seeds: [UInt64] = long ? Array(1...max(env["SEMPERE_SYNC_STRESS_SEEDS"].flatMap(UInt64.init) ?? 60, 1)) : [1, 2, 3]
        if let one = env["SEMPERE_EPOCH_SEED"].flatMap(UInt64.init) { seeds = [one] }
        return long ? Mode(seeds: seeds, steps: 120, devices: 5) : Mode(seeds: seeds, steps: 36, devices: 4)
    }

    enum Transport: String { case memory, mock, wsgidav }

    func transport(_ kind: Transport) throws -> TransportUnderTest {
        switch kind {
        case .memory: return .memory()
        case .mock: return try .mockDAV()
        case .wsgidav: return try .wsgidav()
        }
    }

    func testInvariantsHoldOverMemoryTargets() throws { try runSeeds(.memory) }
    func testInvariantsHoldOverTheWebDAVMock() throws { try runSeeds(.mock) }
    func testInvariantsHoldOverWsgidav() throws {
        _ = try transport(.wsgidav)   // skips without the server (scripts/test-webdav.sh)
        try runSeeds(.wsgidav)
    }

    private func runSeeds(_ kind: Transport) throws {
        let mode = Self.mode
        var all: [String] = []
        for seed in mode.seeds {
            let start = Date()
            let lean = ProcessInfo.processInfo.environment["SEMPERE_EPOCH_EMPHASIS"].flatMap { e in Op.allCases.first { "\($0)" == e } }
            let found = try run(seed: seed, steps: lean == nil ? mode.steps : 26, devices: mode.devices, kind: kind, emphasis: lean)
            print("EPOCH-INTERLEAVING \(kind.rawValue) seed \(seed): \(found.isEmpty ? "clean" : "\(found.count) violations"), "
                  + String(format: "%.1f s", Date().timeIntervalSince(start)))
            all += found.map { "seed \(seed): \($0)" }
        }
        XCTAssertTrue(all.isEmpty, all.prefix(15).joined(separator: "\n"))
    }

    // MARK: - Mutations

    enum Mutation: CaseIterable {
        case acceptUnsealed, skipCatchUp, replaceWithoutSettingAside, corruptReencryption, writeUnderOldKey
        case uploadWhileWaiting, pruneLedgerOnUpload
        case takeoverByArrival, takeoverIgnored, nonHomeSignerAccepted

        /// The invariants design §11.2 names for it.
        var breaks: [String] {
            switch self {
            case .acceptUnsealed: return ["J3"]
            case .skipCatchUp, .pruneLedgerOnUpload: return ["J1"]
            case .replaceWithoutSettingAside: return ["J6"]
            case .corruptReencryption: return ["J8"]
            case .writeUnderOldKey: return ["J2", "J5a"]
            case .uploadWhileWaiting: return ["J5b"]
            case .takeoverByArrival: return ["J4"]
            case .takeoverIgnored: return ["J9", "J4"]
            case .nonHomeSignerAccepted: return ["J10"]
            }
        }

        func activate() {
            switch self {
            case .acceptUnsealed: Vault.epochMutations = [.acceptUnsealed]
            case .skipCatchUp: Vault.epochMutations = [.skipCatchUp]
            case .replaceWithoutSettingAside: Vault.epochMutations = [.replaceWithoutSettingAside]
            case .corruptReencryption: Vault.epochMutations = [.corruptReencryption]
            case .writeUnderOldKey: Vault.epochMutations = [.writeUnderOldKey]
            case .takeoverByArrival: Vault.epochMutations = [.takeoverByArrival]
            case .uploadWhileWaiting: SyncEngine.epochMutations = [.uploadWhileWaiting]
            case .pruneLedgerOnUpload: SyncEngine.epochMutations = [.pruneLedgerOnUpload]
            case .takeoverIgnored: Vault.precedenceMutations = [.takeoverIgnored]
            case .nonHomeSignerAccepted: Vault.precedenceMutations = [.nonHomeSignerAccepted]
            }
        }

        /// Ops the run leans on for this mutation (more of them, so few seeds are needed).
        var emphasis: Op? {
            switch self {
            case .acceptUnsealed, .writeUnderOldKey: return .rogueWrite
            case .nonHomeSignerAccepted: return .forge
            case .takeoverByArrival: return .twoTakeovers
            case .takeoverIgnored: return .takeover
            case .uploadWhileWaiting: return .withhold
            default: return .remove
            }
        }
    }

    /// Each mutation must make a run report its own invariant on a seed whose unmutated run is clean.
    func testEachMutationBreaksItsInvariant() throws {
        var missed: [String] = []
        let only = ProcessInfo.processInfo.environment["SEMPERE_EPOCH_MUTATION"]
        for m in Mutation.allCases where only.map({ "\(m)" == $0 }) ?? true {
            var caught = false
            for seed in UInt64(100)..<UInt64(124) where !caught {
                let mutated = try run(seed: seed, steps: 26, devices: 4, kind: .memory, mutation: m)
                    .filter { v in m.breaks.contains { v.hasPrefix($0 + ":") || v.hasPrefix($0 + " ") } }
                guard !mutated.isEmpty else { continue }
                let clean = try run(seed: seed, steps: 26, devices: 4, kind: .memory, emphasis: m.emphasis)
                XCTAssertTrue(clean.isEmpty, "seed \(seed) fails without \(m): \(clean.prefix(3))")
                caught = true
            }
            if !caught { missed.append("\(m) did not break \(m.breaks.joined(separator: " or "))") }
        }
        XCTAssertTrue(missed.isEmpty, missed.joined(separator: "\n"))
    }

    // MARK: - One run

    enum Op: CaseIterable { case write, sync, remove, takeover, twoTakeovers, withhold, rogueWrite, forge }

    private struct Write {
        var writer: String
        var note: UUID
        var title: String
        /// The writer was not removed when it wrote.
        var listed: Bool
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func run(seed: UInt64, steps: Int, devices count: Int, kind: Transport, mutation: Mutation? = nil,
                     emphasis: Op? = nil) throws -> [String] {
        Self.clearMutations()
        defer { Self.clearMutations() }
        var rng = SeededRNG(seed)
        // Keys, epoch ids and note ids from the seed too, and one transfer at a time: a failing seed replays.
        let ids = Locked(SeededRNG(seed &+ 0x5EED))
        let idLock = NSLock()
        @Sendable func bytes(_ n: Int) -> Data {
            idLock.lock(); defer { idLock.unlock() }
            var g = ids.value
            let out = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
            ids.value = g
            return out
        }
        func noteId() -> UUID { UUID(uuid: bytes(16).withUnsafeBytes { $0.load(as: uuid_t.self) }) }
        VaultEpochKey.testRandomSource = { bytes(32) }
        let faultRate = Locked(0.0)
        let t = [try transport(kind), try transport(kind)]
        let targets = t.enumerated().map { i, x in EpochTarget.over(x, name: "T\(i + 1)", seed: seed &+ UInt64(i), faults: { faultRate.value }) }
        let names = Array(["A", "B", "C", "D", "E"].prefix(count))
        let dir = tmp.appendingPathComponent("il-\(kind.rawValue)-\(seed)-\(mutation.map { "\($0)" } ?? "none")-\(UUID().uuidString.prefix(6))")
        let w = try EpochSyncWorld(in: dir, names: names, made: targets, seed: seed)
        // One transfer at a time, a seeded device id and a step clock: revision names (and so the fault rolls,
        // keyed by path) replay.
        let clock = Locked(Date(timeIntervalSince1970: 1_900_000_000))
        for (i, n) in names.enumerated() {
            w[n].tune = { $0.concurrency = 1 }
            w[n].wall = { clock.value = clock.value.addingTimeInterval(1); return clock.value }
            try? DeviceState(device: DeviceID(String(format: "%08x", 0x1000_0000 + i * 0x1111 + Int(seed % 0x1000)))!)
                .save(to: w[n].deviceState)
        }
        // Who syncs where: A and B bridge both targets, the others one each.
        var reach: [String: [EpochTarget]] = [:]
        for (i, n) in names.enumerated() { reach[n] = i < 2 ? targets : [targets[i % 2]] }
        for n in names { for tg in reach[n] ?? [] { _ = try? w[n].sync(tg) } }
        mutation?.activate()
        let lean = mutation?.emphasis ?? emphasis

        var out: [String] = []
        var trace: [String] = []
        let traceMode = ProcessInfo.processInfo.environment["SEMPERE_EPOCH_TRACE"]
        let tracing = traceMode == "1" || traceMode == "all"
        defer {
            if tracing, !out.isEmpty || traceMode == "all" { print(trace.joined(separator: "\n")) }
        }
        var listed = Set(names)
        var home = "A"
        var removedEpoch: [String: Int] = [:]
        var writes: [Write] = []
        var held: [String: [any AgeIdentity]] = [:]
        var aside: [String: Set<String>] = [:]
        func hold(_ n: String) { if let v = try? w[n].open(), v.canRead { held[n, default: []] += v.identities } }
        for n in names { hold(n) }
        faultRate.value = 0.02

        /// Hashes of the files under `notes/` of `n`'s working copy.
        func hashes(_ n: String) -> [String: String] {
            var h: [String: String] = [:]
            for p in SyncDevice.noteFiles(in: w[n].folder) {
                if let d = try? Data(contentsOf: w[n].folder.appendingPathComponent(p)) { h[p] = FileDigest.sha256(d) }
            }
            return h
        }
        /// J6: the set-aside store only grows, and a file replaced in place was set aside first.
        func checkAside(_ n: String, before: [String: String], step: Int) {
            let now = Set(w[n].setAside.items(vaultId: w.vaultId).map { "\($0.path):\($0.sha256)" })
            if !(aside[n] ?? []).isSubset(of: now) { out.append("J6: step \(step): \(n)'s set-aside store lost an item") }
            aside[n] = now
            let after = hashes(n)
            for (p, old) in before where after[p] != nil && after[p] != old && !now.contains("\(p):\(old)") {
                out.append("J6: step \(step): \(n) replaced \(p) without setting it aside first")
            }
        }
        var bodies: [String: Data] = [:]
        /// J8: no path ever holds two different bodies (as the kit reads them), on any device.
        func checkBodies(_ n: String, before: [String: String], step: Int) {
            guard let observer = try? w.observer(w[n]) else { return }
            let after = hashes(n)
            for (p, h) in after where before[p] != h && !p.contains("/att/") {
                guard let data = try? Data(contentsOf: w[n].folder.appendingPathComponent(p)),
                      let body = observer.plainBody(of: data, path: p) else { continue }
                if let first = bodies[p], first != body { out.append("J8: step \(step): \(p) holds another body at \(n)") }
                bodies[p] = bodies[p] ?? body
            }
        }
        func sync(_ n: String, _ tg: EpochTarget, step: Int) {
            let before = hashes(n)
            guard let r = try? w[n].sync(tg) else { trace.append("\(step) sync \(n)/\(tg.name) threw"); return }
            if tracing {
                let e = r.epoch.map { "taken \($0.taken.map(String.init) ?? "-") wait \($0.waiting != nil) unl \($0.unlisted != nil) cu \($0.caughtUp ?? -1)" } ?? ""
                trace.append("\(step) sync \(n)/\(tg.name): up \(r.uploaded.count) down \(r.downloaded.count) aside \(r.setAside.map(\.path)) "
                    + "pend \(r.pending.count) repl \(r.replaced.map { "\($0.side):\($0.path.suffix(30))" }) err \(r.errors.map(\.message).prefix(2)) "
                    + "q \(r.quarantined.map(\.message).prefix(2)) rej \(r.rejected.map(\.message).prefix(1)) \(e) "
                    + "sk \(r.skipped.filter { $0.path.hasPrefix("notes/") && $0.path.count > 10 }.map { "\($0.path.suffix(30)): \($0.message.prefix(60))" }.prefix(3))")
            }
            hold(n)
            // J5b: a run that met a change it cannot verify (or found this device removed) uploads nothing new.
            if r.epoch?.waiting != nil || r.epoch?.unlisted != nil {
                let up = r.uploaded.filter { !$0.hasPrefix(Vault.epochsName + "/") }
                if !up.isEmpty { out.append("J5b: step \(step): \(n) uploaded \(up.prefix(2)) while a device change waits") }
            }
            checkAside(n, before: before, step: step)
            checkBodies(n, before: before, step: step)
        }

        for step in 0..<steps {
            var op = Op.allCases.randomElement(using: &rng) ?? .write
            let roll = Int.random(in: 0..<100, using: &rng)
            if roll < 30 { op = .write } else if roll < 62 { op = .sync } else if roll < 72, let lean { op = lean }
            if tracing { trace.append("\(step) op \(op) home \(home) listed \(listed.sorted())") }
            switch op {
            case .write:
                let n = listed.sorted().randomElement(using: &rng) ?? "A"
                let title = "\(n)-\(step)"
                let before = hashes(n)
                defer { checkAside(n, before: before, step: step); checkBodies(n, before: before, step: step) }
                guard let note = try? w[n].write(title, id: noteId()) else { trace.append("\(step) write \(n) failed"); break }
                trace.append("\(step) write \(n) \(title) \(note.uuidString.prefix(8)) epoch \((try? w[n].open().manifest.epoch) ?? -1)")
                writes.append(Write(writer: n, note: note, title: title, listed: true))
                // J5a: written under the key of the epoch it verified, none earlier.
                if let v = try? w[n].open() {
                    let dir = w[n].folder.appendingPathComponent("notes/\(note.uuidString.lowercased())")
                    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where RevisionName(f) != nil {
                        guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)) else { continue }
                        if (try? AgeFile.decrypt(data, with: v.identities)) == nil {
                            out.append("J5a: step \(step): \(n) wrote under another key than its epoch's")
                        }
                    }
                }
            case .sync:
                let n = names.randomElement(using: &rng) ?? "A"
                guard let tg = reach[n]?.randomElement(using: &rng) else { break }
                sync(n, tg, step: step)
            case .remove:
                // A bridge stays listed (both targets meet through it), and so do at least two devices.
                let bridges = listed.filter { (reach[$0]?.count ?? 0) > 1 }
                let removable = listed.subtracting([home]).filter { !(bridges.count == 1 && bridges.contains($0)) }
                guard listed.count > 2, let victim = removable.sorted().randomElement(using: &rng) else { break }
                guard var a = try? w[home].open(), a.isHome else { break }
                let before = a.manifest.epochId
                _ = EpochChangePull.run(vault: a, folder: w[home].folder,
                                        targets: (reach[home] ?? []).map { .init(name: $0.name, remote: $0.remote(for: home)) },
                                        scratch: w[home].root.appendingPathComponent("pull"))
                guard let fresh = try? w[home].open(), fresh.isHome else { break }
                a = fresh
                guard (try? a.removeDevices([w[victim].id])) != nil else { break }
                listed.remove(victim)
                removedEpoch[victim] = a.manifest.epoch
                hold(home)
                let tgHome = reach[home]?.randomElement(using: &rng)
                if lean == .forge, let forged = try? forge(w[victim]) {
                    // The removed device strikes at once, on the target home is not about to update.
                    for tg in targets where tg !== tgHome { tg.put(forged.1.path, forged.1.data); tg.put(Vault.manifestName, forged.0) }
                    // A listed device that has not seen the removal meets the forgery first.
                    for tg in targets where tg !== tgHome {
                        let stale = listed.subtracting([home]).sorted().filter {
                            (reach[$0] ?? []).contains { $0 === tg } && (try? w[$0].open().manifest.epochId) == before
                        }
                        if let d = stale.first { sync(d, tg, step: step) }
                    }
                }
                if let tgHome { sync(home, tgHome, step: step) }
            case .takeover, .twoTakeovers:
                let homeId = try? w[home].open().manifest.epochId
                let ready = listed.subtracting([home]).filter { (try? w[$0].open().manifest.epochId) == homeId }.sorted()
                let takers = op == .twoTakeovers ? Array(ready.shuffled(using: &rng).prefix(2)) : Array(ready.shuffled(using: &rng).prefix(1))
                guard !takers.isEmpty, takers.count == (op == .twoTakeovers ? 2 : 1) else { break }
                var made: [(String, Data)] = []
                for taker in takers {
                    let keep = Set(listed.subtracting([taker]).map { w[$0].fingerprint })
                    guard let r = try? Vault.takeover(at: w[taker].folder, device: w[taker].keys, recovery: w.recovery, keep: keep,
                                                      trust: w[taker].trust, root: w.root, ledger: w[taker].ledger,
                                                      setAside: w[taker].setAside) else { continue }
                    made.append((taker, r.report.epochId))
                    hold(taker)
                }
                // Two takeovers that are not ancestors of each other: the smaller id wins (design §5.6).
                if let winner = made.min(by: { $0.1.lexicographicallyPrecedes($1.1) }) { home = winner.0 }
                for (taker, _) in made { if let tg = reach[taker]?.randomElement(using: &rng) { sync(taker, tg, step: step) } }
            case .withhold:
                guard let tg = targets.randomElement(using: &rng),
                      let r = tg.paths.filter({ $0.hasPrefix(Vault.epochsName + "/") && !$0.contains("/1-") }).sorted().randomElement(using: &rng)
                else { break }
                tg.remove(r)
            case .rogueWrite:
                // A removed device keeps writing under the key it holds and plants the files on a target.
                guard let x = Set(names).subtracting(listed).sorted().randomElement(using: &rng), let tg = targets.randomElement(using: &rng),
                      let v = try? Vault.open(at: w[x].folder, identities: [w[x].identity], signing: TestVaults.signing(w[x].identity))
                else { break }
                held[x, default: []] += v.identities
                let note = noteId(), title = "\(x)-rogue-\(step)"
                guard (try? v.apply(NoteOps.newNote(title: title, paper: .ruled, pageId: UUID()), to: note,
                                    deviceState: w[x].deviceState, app: "test/1", wall: w[x].wall?() ?? Date())) != nil else { break }
                writes.append(Write(writer: x, note: note, title: title, listed: false))
                let dir = w[x].folder.appendingPathComponent("notes/\(note.uuidString.lowercased())")
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    if let d = try? Data(contentsOf: dir.appendingPathComponent(f)) { tg.put("notes/\(note.uuidString.lowercased())/\(f)", d) }
                }
            case .forge:
                // A removed device forges an epoch under one where it was listed, names itself home, plants it.
                guard let x = Set(names).subtracting(listed).sorted().randomElement(using: &rng), let tg = targets.randomElement(using: &rng) else { break }
                guard let (manifest, record) = try? forge(w[x]) else { break }
                tg.put(record.path, record.data)
                tg.put(Vault.manifestName, manifest)
            }
        }

        // Quiescence: no faults; every device (removed ones too: they keep pulling) syncs its targets.
        faultRate.value = 0
        for _ in 0..<5 {
            for n in names { for tg in reach[n] ?? [] { sync(n, tg, step: steps) } }
        }
        let readers = listed.sorted()
        var titles: [String: [UUID: String]] = [:]
        for n in readers { titles[n] = (try? w[n].titles()) ?? [:] }
        // J1, J3.
        for wr in writes {
            if wr.listed, listed.contains(wr.writer) {
                for r in readers where titles[r]?[wr.note] != wr.title {
                    out.append("J1: \(r) does not read \(wr.title) (\(wr.writer))")
                    if tracing { trace += diagnose(note: wr.note, reader: r) }
                }
            }
            if !wr.listed {
                for r in readers where titles[r]?[wr.note] != nil {
                    out.append("J3: \(r) took \(wr.title), written by \(wr.writer) after its removal")
                }
            }
        }
        /// Which device's keys (current, and every key it held) open each copy of `note`'s files.
        func diagnose(note: UUID, reader: String) -> [String] {
            var lines = ["DIAG note \(note.uuidString.prefix(8)) reader \(reader) epochs " + names.map { n in
                "\(n):\((try? w[n].open()).map { "\($0.manifest.epoch)/\(Hex.encode($0.manifest.epochId).prefix(6))" } ?? "?")"
            }.joined(separator: " ")]
            let id = note.uuidString.lowercased()
            var copies: [(String, String, Data)] = []
            for n in names {
                let dir = w[n].folder.appendingPathComponent("notes/\(id)")
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where RevisionName(f) != nil {
                    if let d = try? Data(contentsOf: dir.appendingPathComponent(f)) { copies.append((n, f, d)) }
                }
            }
            for tg in targets { for p in tg.paths where p.hasPrefix("notes/\(id)/") { if let d = tg.file(p) { copies.append((tg.name, String(p.split(separator: "/").last ?? ""), d)) } } }
            let items = w[reader].setAside.items(vaultId: w.vaultId).filter { $0.path.contains(id) }
            lines.append("DIAG  \(reader) in place unaccepted: \(((try? w[reader].open().unacceptedInPlace()) ?? [:]).filter { $0.key.contains(id) }.mapValues { $0.prefix(8) })")
            lines.append("DIAG  \(reader) set aside: \(items.map { "\($0.sha256.prefix(8)) \($0.reason)" }) scanned-ledger "
                + "\((try? w[reader].ledger.entries().filter { $0.path.contains(id) }.map { "\($0.epoch):\($0.sha256.prefix(8))" }) ?? [])")
            for (src, f, d) in copies {
                let openers = names.filter { (try? AgeFile.decrypt(d, with: w[$0].open().identities)) != nil }
                let heldBy = names.filter { (try? AgeFile.decrypt(d, with: held[$0] ?? [])) != nil }
                let acc = (try? w[reader].open()).map { "\($0.acceptance(of: d, path: "notes/\(id)/\(f)"))" } ?? "?"
                lines.append("DIAG  \(src) \(f.suffix(24)) sha \(FileDigest.sha256(d).prefix(8)) current-key of \(openers) held-by \(heldBy) at-reader \(acc)")
            }
            return lines
        }

        // J4, J9: one kept chain, list and note set on every listed device and target.
        let epochs = Dictionary(readers.map { ($0, (try? w[$0].open().manifest.epochId).map { Hex.encode($0) } ?? "?") },
                                uniquingKeysWith: { a, _ in a })
        if Set(epochs.values).count > 1 { out.append("J4: listed devices hold different epochs: \(epochs.mapValues { $0.prefix(8) })") }
        if let first = readers.first, readers.contains(where: { titles[$0] != titles[first] }) {
            out.append("J4: listed devices read different notes")
            if tracing, let first = readers.first {
                for n in names.sorted() where !listed.contains(n) {
                    guard let v = try? w[n].open() else { continue }
                    for tg in reach[n] ?? [] {
                        guard let d = tg.file(Vault.manifestName) else { continue }
                        if let m = try? EpochManifest.parse(d), let rec = try? v.trustStore?.record(for: v.vaultId) {
                            trace.append("DIAG  \(n) pinned \(rec.chain.map { "\($0.epoch)/\(Hex.encode($0.epochId).prefix(6))" }) incoming \(m.epoch)/\(Hex.encode(m.epochId).prefix(6)) parent \(m.parent.map { Hex.encode($0).prefix(6) } ?? "-") reason \(m.epochReason)")
                        }
                        trace.append("DIAG judge \(n)@\(tg.name): \(v.judgeIncoming(d)) unlisted=\(v.unlistedNotice != nil) waiting=\(v.waitingNotice ?? "-")")
                    }
                }
                let all = Set(readers.flatMap { titles[$0]?.keys.map { $0 } ?? [] })
                for note in all.sorted(by: { $0.uuidString < $1.uuidString }) where Set(readers.map { titles[$0]?[note] }).count > 1 {
                    trace.append("DIAG J4 \(note.uuidString.prefix(8)): " + readers.map { "\($0)=\(titles[$0]?[note] ?? "-")" }.joined(separator: " "))
                    trace += diagnose(note: note, reader: readers.first { titles[$0]?[note] == nil } ?? first)
                }
            }
        }
        for tg in targets {
            if let d = tg.file(Vault.manifestName), let m = try? EpochManifest.parse(d), let e = epochs[home], Hex.encode(m.epochId) != e {
                out.append("J4: \(tg.name) holds epoch \(m.epoch) (\(Hex.encode(m.epochId).prefix(8))), home \(e.prefix(8))")
            }
        }
        if let e = epochs[home] {
            for (n, x) in epochs where x != e { out.append("J9: \(n) does not follow home \(home) (\(x.prefix(8)) vs \(e.prefix(8)))") }
        }
        // J10: no device a change removed is listed in an epoch a listed device keeps.
        let gone = Set(Set(names).subtracting(listed).map { w[$0].fingerprint })
        for n in readers {
            guard let v = try? w[n].open() else { continue }
            if v.manifest.keys.contains(where: { gone.contains($0.fingerprint) }) {
                out.append("J10: \(n)'s kept epoch \(v.manifest.epoch) lists a removed device")
            }
        }
        // J2: no file of an epoch at or after a removal opens with a key the removed device held; J8: one body
        // per path. Over every listed working copy and target, read with the kit.
        var sources: [(String, [String: Data])] = []
        for n in readers {
            var files: [String: Data] = [:]
            for p in SyncDevice.noteFiles(in: w[n].folder) where !p.contains("/att/") {
                files[p] = try? Data(contentsOf: w[n].folder.appendingPathComponent(p))
            }
            sources.append((n, files))
        }
        for tg in targets {
            var files: [String: Data] = [:]
            for p in tg.paths where p.hasPrefix("notes/") && !p.contains("/att/") { files[p] = tg.file(p) }
            sources.append((tg.name, files))
        }
        if let reference = readers.first, let observer = try? w.observer(w[reference]) {
            for (src, files) in sources {
                for (p, data) in files {
                    guard case .opened(_, _, let older) = observer.openUnderEpochs(data) else { continue }
                    let epoch = older?.epoch ?? observer.manifest.epoch
                    for (x, removed) in removedEpoch where epoch >= removed {
                        if (try? AgeFile.decrypt(data, with: held[x] ?? [])) != nil {
                            out.append("J2: \(x) (removed at epoch \(removed)) opens \(src):\(p), of epoch \(epoch)")
                        }
                    }
                    guard observer.acceptance(of: data, path: p).isAccepted, let body = observer.plainBody(of: data, path: p) else { continue }
                    if let first = bodies[p], first != body { out.append("J8: \(p) holds another body at \(src)") }
                    bodies[p] = bodies[p] ?? body
                }
            }
        }
        return out
    }

    /// Forges, in `x`'s working copy, an epoch under the one it holds, signed by itself and naming itself home,
    /// with a wrap for every listed key (as a removed device with modified software could): the new
    /// `vault.json`'s bytes and the record.
    private func forge(_ x: EpochSyncDevice) throws -> (Data, (path: String, data: Data)) {
        let v = try Vault.open(at: x.folder, identities: [x.identity], signing: TestVaults.signing(x.identity))
        guard let me = v.deviceEntry, let recovery = v.manifest.recoveryEntry else { throw VaultError.locked }
        let plan = Vault.EpochPlan(reason: .remove, parentKey: try v.requireSecret(), parentChain: try v.currentChain(),
                                   parentList: v.manifest.keys.map(\.fingerprint), parentAdditions: v.currentAdditions(),
                                   devices: v.manifest.devices, recovery: recovery, home: me.fingerprint, author: me,
                                   signing: TestVaults.signing(x.identity), recoverySigner: nil, sealed: [:],
                                   parentRecordHash: v.manifest.epochRecordHash, created: Date(),
                                   label: nil, features: v.manifest.features)
        let (m, _) = try v.writeEpoch(plan)
        let manifest = try Data(contentsOf: x.folder.appendingPathComponent(Vault.manifestName))
        let record = try Data(contentsOf: x.folder.appendingPathComponent(m.epochRecord))
        return (manifest, (m.epochRecord, record))
    }
}
