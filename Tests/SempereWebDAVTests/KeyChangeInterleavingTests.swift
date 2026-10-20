import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The key-change property test (docs/design/device-first-sync.md §6.4 `KeyChangeInterleavingTests`):
/// 3 devices and 2 targets (in memory; the second one the WebDAV mock in every other seed), random
/// edits and attachments; adds, removals and replaces of keys on random devices in both modes,
/// stopped at random fault points (after the claims, after K1, K2, file n of K3, before K4, after
/// any step C5(a) to (d) on a target); targets going offline and coming back, with the routine
/// override; random clock jumps; a target that serves an older copy of a file it holds (a hostile
/// downgrade); a device removed for good that keeps writing; transport faults (cut bodies, lost
/// answers). Invariants after every step and at quiescence:
///
/// - I1 no loss: every revision a listed device wrote is readable with its body somewhere (a working
///   copy, a target, or a quarantine);
/// - I2 convergence: with faults off and every device synced, all working copies and targets hold
///   the same vault.json and the same bytes for every note file;
/// - I3 body integrity: no copy of a path ever holds another body;
/// - I4 revocation: after convergence no note file opens with a removed key, and each has one stanza
///   per listed key;
/// - I5 liveness: no journal and no change in progress is left at quiescence;
/// - I6 policy: no late file is taken in after its device's window, and nothing ever leaves a quarantine.
///
/// Seeded (`SEMPERE_KEYCHANGE_SEED=N` replays one). Quick mode (3 seeds of 40 steps) runs in every
/// `swift test`; `SEMPERE_SYNC_STRESS_LONG=1` runs `SEMPERE_SYNC_STRESS_SEEDS` (60) seeds of 120 steps
/// (`scripts/sync-stress.sh`).
final class KeyChangeInterleavingTests: TempDirTestCase {
    struct Mode {
        var seeds: [UInt64]
        var steps: Int
    }

    static var mode: Mode {
        let env = ProcessInfo.processInfo.environment
        let long = env["SEMPERE_SYNC_STRESS_LONG"] == "1"
        var seeds: [UInt64] = long ? Array(1...max(env["SEMPERE_SYNC_STRESS_SEEDS"].flatMap(UInt64.init) ?? 60, 1)) : [1, 2, 3]
        if let one = env["SEMPERE_KEYCHANGE_SEED"].flatMap(UInt64.init) { seeds = [one] }
        return Mode(seeds: seeds, steps: long ? 120 : 40)
    }

    func testKeyChangesUnderFaultsLoseNothingAndConverge() throws {
        let mode = Self.mode
        for seed in mode.seeds {
            let start = Date()
            let run = try KeyChangeRun(seed: seed, root: tmp.appendingPathComponent("seed-\(seed)"))
            try run.run(steps: mode.steps)
            print("KEYCHANGE seed \(seed): \(run.summary), \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
    }
}

/// A deterministic random source (SplitMix64).
struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        let hex = String(format: "%016llx%016llx", a, b)
        let c = Array(hex)
        return UUID(uuidString: "\(String(c[0..<8]))-\(String(c[8..<12]))-4\(String(c[13..<16]))-8\(String(c[17..<20]))-\(String(c[20..<32]))")!
    }
}

/// One seed of the property test.
final class KeyChangeRun: @unchecked Sendable {
    let seed: UInt64
    var rng: SeededRandom
    let w: KCWorld
    /// Keys no longer listed (spares removed, keys replaced, the removed device's).
    var revoked: [NativeIdentity] = []
    /// Paths the removed device wrote after its removal (they stay on targets, outside the vault).
    var afterRemoval = Set<String>()
    /// Every quarantined file seen so far (I6: nothing ever leaves).
    var quarantined: [String: Data] = [:]
    /// Older copies of note files seen on each target, by `<target>|<path>` (for the hostile downgrade).
    var history: [String: [Data]] = [:]
    var notes: [UUID] = []
    var counts: [String: Int] = [:]

    init(seed: UInt64, root: URL) throws {
        self.seed = seed
        rng = SeededRandom(state: seed &* 0x2545_F491_4F6C_DD1D)
        var r = rng
        let uses = [[0, 1], r.chance(0.5) ? [0] : [0, 1], r.chance(0.5) ? [1] : [0, 1]]
        rng = r
        w = try KCWorld(root: root, deviceCount: 3, targetCount: 2, webdav: seed % 2 == 0 ? [1] : [], uses: uses)
    }

    var summary: String { counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }

    /// What each step did, printed with the first failure.
    var trace: [String] = []
    var printedTrace = false

    func count(_ k: String) {
        counts[k, default: 0] += 1
        trace.append("\(w.now.timeIntervalSince1970 - 1_790_000_000): \(k)")
    }

    func note(_ s: String) { trace.append("   \(s)") }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        dumpTrace()
        XCTFail("seed \(seed): \(message)", file: file, line: line)
    }

    func dumpTrace() {
        guard !printedTrace else { return }
        printedTrace = true
        print("KEYCHANGE TRACE seed \(seed):\n" + trace.joined(separator: "\n"))
    }

    func run(steps: Int) throws {
        for step in 0..<steps {
            try oneStep()
            checkQuarantine()
            if step % 8 == 7 { checkBodies() }
        }
        try quiesce()
    }

    var listed: [KCDevice] { w.devices.filter { !$0.removed } }

    func oneStep() throws {
        let roll = rng.int(100)
        switch roll {
        case 0..<22: try write()
        case 22..<27: try attach()
        case 27..<60: sync()
        case 60..<72: try keyChange()
        case 72..<78:
            let t = rng.pick(w.targets)
            t.offline.value.toggle()
            count(t.offline.value ? "offline" : "online")
        case 78..<84:
            w.tick(Double(rng.int(4)) * 86_400 + Double(rng.int(3600)))
            count("time")
        case 84..<88: downgrade()
        case 88..<91: try removeDevice()
        case 91..<95:
            // Transport faults on one device's way to one target, for a while.
            let d = rng.pick(w.devices), t = rng.pick(d.targets)
            if t.store != nil {
                d.faults[t.name] = d.faults[t.name] == nil
                    ? MemoryFaults(seed: rng.next(), rates: MemoryFaults.Rates([.cutBody: 0.2, .loseAnswer: 0.1, .dropBefore: 0.1]))
                    : nil
                count("faults")
            }
        default:
            // A relaunch: the coordinator recovers what a crash left.
            let d = rng.pick(listed)
            if var v = try? d.vault(), v.canRead { _ = try? d.coordinator.recover(&v) }
            count("relaunch")
        }
    }

    func write() throws {
        let d = rng.pick(w.devices)
        guard d.hasVault, (try? d.vault())?.canRead == true else { return }
        let note = notes.isEmpty || rng.chance(0.3) ? rng.uuid() : rng.pick(notes)
        if !notes.contains(note) { notes.append(note) }
        w.tick()
        guard let n = try? d.write(note, "t\(rng.int(1000))", now: w.now) else { return }
        w.oracle.wrote(d, note: note, name: n)
        if d.removed { afterRemoval.insert("notes/\(note.uuidString.lowercased())/\(n.filename)") }
        count("write")
    }

    func attach() throws {
        let d = rng.pick(listed)
        guard !notes.isEmpty, (try? d.vault())?.canRead == true else { return }
        w.tick()
        _ = try? d.attach(rng.pick(notes), Data("blob \(rng.next())".utf8), now: w.now)
        count("attach")
    }

    func sync() {
        let d = rng.pick(w.devices), t = rng.pick(d.targets)
        guard !t.offline.value else { return }
        w.tick()
        var faults = KeyChangeFaults()
        if rng.chance(0.08) { faults.afterStep[t.name] = rng.pick(KeyChangeStep.allCases) }
        do {
            let r = try d.sync(t.name, now: w.now, faults: faults)
            note("\(d.name)/\(t.name)\(faults.afterStep.isEmpty ? "" : " stop \(faults.afterStep)"): \(KCWorld.brief(r))")
            for late in r.keyChange?.lateAccepted ?? [] where late.deadline <= w.now {
                fail("I6: \(d.name) took in \(late.path) after its window (\(late.deadline))")
            }
            count("sync")
        } catch {
            count("sync threw")
            note("\(d.name)/\(t.name): \(error)")
        }
        for (p, data) in t.noteFiles() where !(history[t.name + "|" + p]?.contains(data) ?? false) {
            history[t.name + "|" + p, default: []].append(data)
        }
        w.oracle.learn(d)
    }

    /// Every spare key ever added.
    var spares: [NativeIdentity] = []

    func keyChange() throws {
        let d = rng.pick(listed)
        guard let v = try? d.vault(), v.canRead else { return }
        let keys = Set(v.recipients.map(\.key))
        let spare = spares.first { keys.contains($0.recipient.string) }
        let policy: KeyChangePolicy = rng.chance(0.3) ? .compromised : ((try? .routine(days: rng.int(8))) ?? .routine)
        var faults = KeyChangeFaults()
        switch rng.int(10) {
        case 0: faults.afterClaims = true
        case 1: faults.rewrap = RewrapFaults(stop: .afterJournal)
        case 2: faults.rewrap = RewrapFaults(stop: .afterManifest)
        case 3: faults.rewrap = RewrapFaults(stop: .afterFiles(rng.int(6)))
        case 4: faults.rewrap = RewrapFaults(stop: .beforeFinish)
        default: break
        }
        let offline = Set(d.targets.filter { $0.offline.value }.map(\.name))
        let overriding = rng.chance(0.6) ? offline : []
        note("change on \(d.name): \(policy.mode) \(policy.lateFileWindowDays)d, faults \(faults), overriding \(overriding)")
        do {
            switch (rng.int(3), spare) {
            case (0, nil), (1, nil):
                let s = pqIdentity()
                spares.append(s)
                w.oracle.identities.append(s)
                try w.change(d, overriding: overriding, faults: faults) {
                    try $0.prepareAddRecipient(s.recipient, label: "paper", keyChange: policy)
                }
                count("add")
            case (0, let s?), (1, let s?):
                revoked.append(s)
                try w.change(d, overriding: overriding, faults: faults) { try $0.prepareRemoveRecipient(s.recipient, keyChange: policy) }
                count("remove")
            default:
                let old = d.identity, new = pqIdentity()
                d.identities.insert(new, at: 0)
                w.oracle.learn(d)
                revoked.append(old)
                try w.change(d, overriding: overriding, faults: faults) {
                    try $0.prepareReplaceRecipient(old.recipient, with: new.recipient, keyChange: policy)
                }
                count("replace")
            }
        } catch {
            // Refused (another change in flight, a target unreachable or not synced lately, a list that
            // moved) or stopped by a fault: whatever was written is finished or abandoned by later runs.
            count("change stopped")
            note("\(d.name): \(error)")
        }
    }

    /// A target serves an older copy of a file it holds (the same body under an older wrap).
    func downgrade() {
        // A copy this target itself held before (a server rolled back), never one from elsewhere.
        let t = rng.pick(w.targets)
        let prefix = t.name + "|"
        let candidates = history.filter { $0.key.hasPrefix(prefix) && $0.value.count > 1 && $0.key.split(separator: "/").count == 3 }
        guard !candidates.isEmpty, !t.offline.value else { return }
        let (key, copies) = rng.pick(candidates.sorted { $0.key < $1.key })
        t.put(key.dropFirst(prefix.count).split(separator: "/").map(String.init), rng.pick(copies))
        count("downgrade")
    }

    /// Removes device C for good (once), when no change is in flight anywhere.
    func removeDevice() throws {
        let c = w.c
        guard !c.removed, w.devices.allSatisfy({ !$0.coordinator.inProgress }),
              w.targets.allSatisfy({ $0.file([Vault.journalName]) == nil }) else { return }
        let d = rng.pick([w.a, w.b])
        do {
            try w.change(d, overriding: Set(w.targets.filter { $0.offline.value }.map(\.name))) {
                try $0.prepareRemoveRecipient(c.identity.recipient, keyChange: try .routine(days: 1))
            }
            c.removed = true
            revoked.append(contentsOf: c.identities)
            count("device removed by \(d.name)")
        } catch {
            count("change stopped")
        }
    }

    // MARK: Invariants as it goes

    func checkQuarantine() {
        for d in w.devices {
            let now = d.quarantined()
            for (p, data) in quarantined where now[p] == nil && p.hasPrefix(d.root.path) {
                // Only an Adopt or Export takes a file out; this run does neither.
                fail("I6: \(p) left the quarantine")
                _ = data
            }
            for (p, data) in now {
                if let was = quarantined[p], was != data { fail("I6: \(p) changed in the quarantine") }
                quarantined[p] = data
            }
        }
    }

    func checkBodies() {
        for d in w.devices { w.oracle.learn(d) }
        for (loc, path, data) in w.everyCopy() {
            guard let want = w.oracle.written[path], let body = w.oracle.body(data, path: path) else { continue }
            if body != want { fail("I3: \(loc) \(path) holds another body") }
        }
    }

    /// After keeping another change: this device's own change is redone (spare keys it had added are
    /// added again; a dropped key of its own is simply not used).
    func redo(_ d: KCDevice, _ dropped: [String]) throws {
        for key in dropped {
            guard let spare = spares.first(where: { $0.recipient.string == key }) else { continue }
            for _ in 0..<3 {
                for t in d.targets { w.tick(); _ = try? d.sync(t.name, now: w.now) }
                if (try? w.change(d) { try $0.prepareAddRecipient(spare.recipient, label: "paper") }) != nil { break }
            }
            count("redone")
        }
    }

    // MARK: Quiescence

    func quiesce() throws {
        for t in w.targets { t.offline.value = false }
        for d in w.devices { d.faults = [:] }
        // Changes that met (F7): the user keeps the other change where they did.
        for _ in 0..<3 {
            for d in listed {
                guard var v = try? d.vault(), v.canRead else { continue }
                _ = try? d.coordinator.recover(&v)
                if let (target, _) = d.coordinator.conflicts.sorted(by: { $0.key < $1.key }).first {
                    do {
                        var dropped: [String]
                        do { dropped = try d.coordinator.adoptOtherChange(from: target, vault: &v, now: w.now) } catch VaultError.untrustedRecipients {
                            // It missed a rotation in between: the user checks the list and confirms it.
                            dropped = try d.coordinator.adoptOtherChange(from: target, vault: &v, now: w.now, confirmed: true)
                        }
                        count("adopted")
                        try redo(d, dropped)
                    } catch VaultError.recipientsNotRepairable {
                        // The target holds an older list again: nothing to keep; propagation goes on.
                        count("nothing to adopt")
                    } catch {
                        fail("adopting the other change failed on \(d.name): \(error)")
                    }
                }
            }
            for _ in 0..<2 {
                for d in listed {
                    for (t, r) in zip(d.targets, d.syncAll(now: w.now)) {
                        guard let why = r.rejected.first(where: { $0.path == Vault.manifestName })?.message,
                              why.contains("cannot confirm") || why.contains("fewer devices under the same secret") else { continue }
                        // Missed two rotations (format.md §2.1): the user checks the list and confirms it.
                        // Two additions met (F7): the user keeps the other one and redoes this one.
                        guard var v = try? d.vault(), v.canRead else { continue }
                        do {
                            try redo(d, try d.coordinator.adoptOtherChange(from: t.name, vault: &v, now: w.now,
                                                                          confirmed: why.contains("cannot confirm")))
                            count("confirmed")
                        } catch {
                            note("confirm on \(d.name) failed: \(error)")
                        }
                    }
                    w.tick()
                }
            }
        }
        let before = Date()
        if ProcessInfo.processInfo.environment["SEMPERE_KEYCHANGE_TRACE"] == "1" { dumpTrace() }
        try w.converge(rounds: 16)
        _ = before
        for d in listed {
            if d.coordinator.inProgress, let l = d.coordinator.load().change {
                func fp(_ x: Data?) -> String { x.flatMap { Vault.listFingerprint($0) }.map { String($0.prefix(6)) } ?? "-" }
                func h(_ x: Data?) -> String { x.map { String(FileDigest.sha256($0).prefix(6)) } ?? "-" }
                print("LEDGER \(d.name): conflicts \(l.conflicts) journal \(h(l.journal)) base \(fp(l.base)) step2 \(fp(l.step2)) "
                      + "step4 \(fp(l.step4)) local \(fp(d.manifest())) "
                      + w.targets.map { "\($0.name): \(fp($0.file([Vault.manifestName]))) j \(h($0.file([Vault.journalName])))" }.joined(separator: " "))
            }
            if d.coordinator.inProgress { fail("I5: \(d.name) still has a change in progress (\(d.coordinator.steps))") }
        }
        if ProcessInfo.processInfo.environment["SEMPERE_KEYCHANGE_TRACE"] == "1" {
            for d in listed {
                guard let v = try? d.vault() else { continue }
                let vo = v.withOlderSecrets(from: try? d.keyring.load(vaultId: v.vaultId))
                for (p, data) in d.noteFiles() where p.contains("/att/") && revoked.contains(where: { (try? AgeFile.decrypt(data, with: [$0])) != nil }) {
                    let parts = p.split(separator: "/").map(String.init)
                    print("DEBUG \(d.name) \(p): \(vo.classifyBlob(at: d.folder.appendingPathComponent(p), fileName: parts[3])) older \(vo.olderSecretCount)")
                    if let st = try? SyncState.load(d.stateURL("T0")) { print("  state T0 lateRewrapFor \(st.lateRewrapFor ?? "-") rec \(st.files["\(parts[1])/att/\(parts[3])"].map { "\($0)" } ?? "-")") }
                }
            }
        }
        // What the removed device wrote and the vault never took in (late files, quarantined by the
        // others) stays on the targets, never deleted, outside every working copy.
        let removedNames = Set(w.devices.filter(\.removed).map(\.name))
        let held = Set(listed[0].noteFiles().keys)
        let ignored = afterRemoval.union(w.oracle.written.keys.filter { removedNames.contains(w.oracle.writer[$0] ?? "") && !held.contains($0) })
        w.assertConverged(ignoring: ignored)
        let stillListed = Set((try? VaultManifest.decode(listed[0].manifest() ?? Data()))?.recipients.map(\.key) ?? [])
        w.assertRevoked(revoked.filter { !stillListed.contains($0.recipient.string) }, ignoring: ignored)
        w.assertNoLoss()
        checkQuarantine()
        checkBodies()
    }
}
