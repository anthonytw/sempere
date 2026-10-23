import Age
import Crypto
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The invariants of key-hierarchy design §11.2 that need no sync (phase KH3: J1, J2, J3, J5a, J6, J8), on
/// seeded random runs of in-process devices sharing one folder. Steps:
///
/// - writes by listed devices (some offline: a vault value opened before the latest change) of every kind:
///   revisions, blobs, notebook records, captures (with the profile the device held), and settings;
/// - removals by home (some crashed after the record or after `vault.json`), handoffs, and a stolen home that a
///   takeover from a stale frontier drops, after which the thief keeps writing under the dropped key;
/// - the adversary of §11.2: removed devices keep writing every kind under the keys they hold, plant revisions
///   named with a listed device's id, and rewrite an earlier epoch record's sealed set to cover what they wrote
///   after their removal (review M1, S8);
/// - catch-ups, also cut off at each fault point.
///
/// An omniscient observer (holding the kit) records every write; at quiescence every listed device catches up.
/// Each `EpochMutation` must break ITS invariant on a seed whose unmutated run is clean, so none is vacuous.
/// Engine-level runs over targets (J4, J5b, J7, J9, J10) are KH4's `EpochInterleavingTests`.
final class EpochInvariantTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        Vault.epochMutations = []
        super.tearDown()
    }

    static var seeds: Int { Int(ProcessInfo.processInfo.environment["SEMPERE_EPOCH_INVARIANT_SEEDS"] ?? "") ?? 5 }

    func testInvariantsHoldOnRandomRuns() throws {
        var all: [String] = []
        var seen: [String: Int] = [:]
        for seed in 0..<UInt64(Self.seeds) {
            let (violations, stats) = try run(seed: seed, steps: 24)
            all += violations.map { "seed \(seed): \($0)" }
            seen.merge(stats, uniquingKeysWith: +)
        }
        XCTAssertTrue(all.isEmpty, all.prefix(12).joined(separator: "\n"))
        // Not vacuous: every kind of step happened.
        for key in ["remove", "handoff", "stolenHome", "forgeRecord", "plantNamed", "blob", "capture", "notebook", "settings",
                    "removedWrite"] {
            XCTAssertGreaterThan(seen[key, default: 0], 0, "no \(key) in \(Self.seeds) seeds: \(seen)")
        }
    }

    /// The invariant each mutation breaks (design §11.2's table): a run must report THAT invariant, on a seed
    /// whose unmutated run is clean, so the failure comes from the broken rule and not from something else.
    static let expected: [EpochMutation: [String]] = [
        .acceptUnsealed: ["J3"], .skipCatchUp: ["J1"], .replaceWithoutSettingAside: ["J6"],
        .corruptReencryption: ["J8"], .writeUnderOldKey: ["J2", "J5a"], .olderRecordNotHashChecked: ["J3"],
        .catchUpByDeviceId: ["J3"], .ledgerPrunedOnWrite: ["J1"], .droppedEpochAccepted: ["J3"],
    ]

    /// Mutations of rules only a sync applies, checked by `EpochInterleavingTests` (SempereWebDAVTests, KH4).
    static let overSync: Set<EpochMutation> = [.takeoverByArrival]

    func testEachMutationBreaksItsInvariant() throws {
        for m in EpochMutation.allCases where !Self.overSync.contains(m) {
            let labels = try XCTUnwrap(Self.expected[m], "no invariant named for \(m)")
            var caught: [String] = []
            for seed in 0..<UInt64(12) where caught.isEmpty {
                let mutated = try run(seed: seed &+ 500, steps: 24, mutation: m).violations
                    .filter { v in labels.contains { v.hasPrefix($0) || v.contains(": \($0)") } }
                guard !mutated.isEmpty else { continue }
                let clean = try run(seed: seed &+ 500, steps: 24).violations
                XCTAssertTrue(clean.isEmpty, "seed \(seed &+ 500) fails without \(m): \(clean.prefix(3))")
                caught = mutated
            }
            XCTAssertFalse(caught.isEmpty, "the mutation \(m) did not break \(labels.joined(separator: " or "))")
        }
    }

    // MARK: - One run

    private enum What: Equatable {
        case note(UUID, String)
        case blob(UUID, BlobRef, Data)
        case capture(UUID)
        case notebook(String)
    }

    private struct Write {
        var writer: String
        var what: What
        var epoch: Int
        /// The writer was not removed (on the kept chain) when it wrote.
        var writerListed: Bool
        /// Neither checked by J1 nor by J3: a write by a device whose removal a takeover then dropped, between
        /// that removal and the takeover (the takeover may seal it).
        var ambiguous = false
    }

    private enum Op: CaseIterable {
        case write, writeBlob, writeNotebook, capture, settings, refresh, remove, crashedRemove, handoff, catchUp,
             crashedCatchUp, removedWrite, forgeRecord, plantNamed, stolenHome
    }

    private func run(seed: UInt64, steps: Int, mutation: EpochMutation? = nil) throws -> (violations: [String], stats: [String: Int]) {
        let dir = tmp.appendingPathComponent("inv-\(seed)-\(mutation.map { "\($0)" } ?? "none")-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["A", "B", "C", "D", "X", "Y"]
        let w = try EpochWorld(in: dir, names: names)
        var rng = SplitMix64(seed: seed)
        var out: [String] = []
        var stats: [String: Int] = [:]
        var values: [String: Vault] = [:]
        /// Every vault value a device held (by epoch), for the adversary.
        var history: [String: [Int: Vault]] = [:]
        var held: [String: [any AgeIdentity]] = [:]
        var removedAt: [String: Int] = [:]
        var home = "A"
        var writes: [Write] = []
        var settingsBy: [String: (writer: String, listed: Bool)] = [:]
        var bodies: [String: Data] = [:]
        var aside: [String: Set<String>] = [:]
        var stolen = false
        /// Records the adversary rewrote, with their honest bytes (KH4's write-once union brings those back).
        var forged: [(URL, Data)] = []
        let shared = try w["A"].newNote(try w.open("A"), "attachments")
        let audio = Data((0..<1500).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ Int(seed)) })
        Vault.epochMutations = mutation.map { [$0] } ?? []
        defer { Vault.epochMutations = [] }
        func keep(_ name: String, _ v: Vault) {
            values[name] = v
            history[name, default: [:]][v.manifest.epoch] = v
            held[name, default: []] += v.identities
        }
        for n in names {
            let v = try w.open(n)
            try v.requireWritable()
            keep(n, v)
        }
        func listed() -> [String] { names.filter { removedAt[$0] == nil } }

        for step in 0..<steps {
            let op = Op.allCases.randomElement(using: &rng) ?? .write
            let name = names.randomElement(using: &rng) ?? "A"
            let d = w[name]
            let isListed = removedAt[name] == nil
            switch op {
            case .write, .removedWrite:
                // With the value it holds: an offline listed device, or a removed one writing anyway.
                if op == .removedWrite, isListed { break }
                guard let v = values[name] else { break }
                let title = "\(name)-\(step)"
                guard let note = try? d.newNote(v, title) else { break }
                if !isListed { stats["removedWrite", default: 0] += 1 }
                writes.append(Write(writer: name, what: .note(note, title), epoch: v.manifest.epoch, writerListed: isListed))
                // J5a: written under the key of the epoch it verified, none earlier.
                for data in try revisionFiles(v, note) {
                    if (try? AgeFile.decrypt(data, with: v.identities)) == nil {
                        out.append("J5a step \(step): \(name) wrote under another key than its epoch's")
                    }
                    for o in v.olderEpochs where (try? AgeFile.decrypt(data, with: [o.identity])) != nil {
                        out.append("J5a step \(step): \(name) wrote under epoch \(o.epoch) after verifying \(v.manifest.epoch)")
                    }
                }
            case .writeBlob:
                guard let v = values[name] else { break }
                let content = Data("blob \(name) \(step) \(seed)".utf8)
                guard let ref = try? v.writeBlob(note: shared, content, type: "application/octet-stream") else { break }
                stats["blob", default: 0] += 1
                writes.append(Write(writer: name, what: .blob(shared, ref, content), epoch: v.manifest.epoch, writerListed: isListed))
            case .writeNotebook:
                guard let v = values[name], (try? v.createNotebook("nb-\(name)-\(step)")) != nil else { break }
                stats["notebook", default: 0] += 1
                writes.append(Write(writer: name, what: .notebook("nb-\(name)-\(step)"), epoch: v.manifest.epoch, writerListed: isListed))
            case .capture:
                // The profile the device made from the value it holds (a locked widget keeps an old one).
                guard let v = values[name], let profile = try? v.captureProfile(device: DeviceID("0c0c0c0c")!) else { break }
                let writer = try CaptureWriter(profile: profile)
                let id = UUID()
                let sealed = try writer.seal(audio: audio, started: Date(), id: id)
                if isListed { try writer.record(sealed, in: d.ledger) }
                try CaptureWriter.store(sealed, in: v.inboxURL)
                stats["capture", default: 0] += 1
                writes.append(Write(writer: name, what: .capture(id), epoch: v.manifest.epoch, writerListed: isListed))
            case .settings:
                guard let v = values[name] else { break }
                var s = SharedSettings()
                try s.set(SettingSlotKey("photos.removeMetadata"), to: .bool(step % 2 == 0), type: .mac, now: Date())
                guard (try? v.writeSharedSettings(s)) != nil,
                      let data = try? Data(contentsOf: w.url.appendingPathComponent(SharedSettings.fileName)) else { break }
                stats["settings", default: 0] += 1
                settingsBy[FileDigest.sha256(data)] = (name, isListed)
            case .refresh:
                guard isListed, let v = try? w.open(name), v.listStatus.allowsWriting else { break }
                keep(name, v)
            case .remove, .crashedRemove:
                guard var a = try? w.open(home), a.isHome else { break }
                let others = listed().filter { $0 != home }
                guard others.count > 3, let target = others.randomElement(using: &rng) else { break }
                if op == .crashedRemove {
                    a.faults = EpochFaults(stop: Bool.random(using: &rng) ? .afterRecord : .afterManifest)
                }
                _ = try? a.removeDevices([w[target].id])
                // Whether it took: the folder's list says (a crash after the record leaves an orphan only).
                guard let now = try? Vault.open(at: w.url),
                      !now.manifest.devices.contains(where: { $0.fingerprint == w[target].fingerprint }) else { break }
                stats["remove", default: 0] += 1
                removedAt[target] = now.manifest.epoch
                if let fresh = try? w.open(home) { keep(home, fresh) }
                // Every listed device sees the new epoch at some point (its key is in its history), whatever
                // value it writes with.
                for n in listed() where n != home {
                    if let v = try? w.open(n) { history[n, default: [:]][v.manifest.epoch] = v; held[n, default: []] += v.identities }
                }
            case .handoff:
                guard var a = try? w.open(home), a.isHome,
                      let to = listed().filter({ $0 != home }).randomElement(using: &rng),
                      (try? a.handOff(to: w[to].id)) != nil else { break }
                stats["handoff", default: 0] += 1
                keep(home, a)
                home = to
            case .catchUp, .crashedCatchUp:
                guard isListed, var v = try? w.open(name), v.listStatus.allowsWriting else { break }
                keep(name, v)
                if op == .crashedCatchUp {
                    let points: [EpochFaults.Point] = [.catchUpWritten(1), .catchUpVerified(1), .catchUpRecorded(1), .catchUpPlaced(1)]
                    v.faults = EpochFaults(stop: points.randomElement(using: &rng))
                }
                let before = try fileHashes(w)
                _ = try? v.catchUp()
                out += try checkSetAside(w, device: d, before: before, seen: &aside).map { "step \(step): \($0)" }
            case .forgeRecord:
                if let (title, note, epoch, who) = try forge(w, history: history, removedAt: removedAt, names: names, step: step,
                                                            rng: &rng, forged: &forged) {
                    stats["forgeRecord", default: 0] += 1
                    writes.append(Write(writer: who, what: .note(note, title), epoch: epoch, writerListed: false))
                }
            case .plantNamed:
                // A removed device writes a revision named with a listed device's id (ids decide nothing).
                guard !isListed, let v = values[name], let victim = listed().randomElement(using: &rng),
                      let id = DeviceID(w[victim].id) else { break }
                let note = UUID(), title = "planted-\(name)-\(step)"
                let rev = Revision(noteId: note, device: id, seq: 1, hlc: HLC(millis: 1_791_130_800_000 + Int64(step), counter: 0)!,
                                   wall: Date(), app: "adversary/1",
                                   body: .delta(ops: NoteOps.newNote(title: title, paper: .ruled, pageId: UUID())))
                guard (try? v.write(rev)) != nil else { break }
                stats["plantNamed", default: 0] += 1
                writes.append(Write(writer: name, what: .note(note, title), epoch: v.manifest.epoch, writerListed: false))
            case .stolenHome:
                // Home is stolen: it removes a device; a listed device pins that epoch and writes under it; a
                // device still pinned before it takes over without the thief; the thief writes under its dropped key.
                guard !stolen else { break }
                let candidates = listed().filter { $0 != home }
                guard candidates.count >= 4 else { break }
                var pool = candidates.shuffled(using: &rng)
                let b = pool.removeFirst(), dd = pool.removeFirst(), victim = pool.removeFirst()
                guard let vb = try? w.open(b), (try? vb.requireWritable()) != nil else { break }
                keep(b, vb)
                guard var thief = try? w.open(home), thief.isHome, (try? thief.removeDevices([w[victim].id])) != nil else { break }
                let droppedEpoch = thief.manifest.epoch
                removedAt[victim] = droppedEpoch
                keep(home, thief)
                guard let vd = try? w.open(dd), vd.listStatus.allowsWriting else { break }
                keep(dd, vd)
                let title = "\(dd)-under-thief-\(step)"
                if let note = try? w[dd].newNote(vd, title) {
                    writes.append(Write(writer: dd, what: .note(note, title), epoch: droppedEpoch, writerListed: true))
                }
                guard let plan = try? Vault.takeoverPlan(at: w.url, device: w[b].keys, recovery: w.recovery, trust: w[b].trust, root: nil)
                else { break }
                let keepSet = Set(plan.candidates.filter { $0.checkedByDefault && $0.fingerprint != w[home].fingerprint }.map(\.fingerprint))
                guard let (vt, _) = try? Vault.takeover(at: w.url, device: w[b].keys, recovery: w.recovery, keep: keepSet,
                                                        trust: w[b].trust, root: nil, ledger: w[b].ledger, setAside: w[b].setAside)
                else { break }
                stats["stolenHome", default: 0] += 1
                stolen = true
                keep(b, vt)
                // The victim's removal was dropped: its writes since are the takeover's to seal or not.
                for i in writes.indices where writes[i].writer == victim && writes[i].epoch < droppedEpoch && !writes[i].writerListed {
                    writes[i].ambiguous = true
                }
                removedAt[victim] = vt.manifest.epoch
                removedAt[home] = vt.manifest.epoch
                let thiefName = home
                home = b
                // The thief writes on under the key of its dropped epoch.
                let t2 = "thief-\(thiefName)-\(step)"
                if let note = try? w[thiefName].newNote(thief, t2) {
                    writes.append(Write(writer: thiefName, what: .note(note, t2), epoch: droppedEpoch, writerListed: false))
                }
            }
            out += try checkBodies(w, bodies: &bodies).map { "step \(step): \($0)" }
        }

        // The adversary's last move: every removed device that can forges a record once more.
        for _ in 0..<2 {
            if let (title, note, epoch, who) = try forge(w, history: history, removedAt: removedAt, names: names, step: steps,
                                                        rng: &rng, forged: &forged) {
                stats["forgeRecord", default: 0] += 1
                writes.append(Write(writer: who, what: .note(note, title), epoch: epoch, writerListed: false))
            }
        }
        // J3 while the forged records are in place: no listed device takes what a forged sealed set names.
        for name in listed() {
            guard let v = try? w.open(name) else { continue }
            let t = (try? w.titles(v)) ?? [:]
            for wr in writes where !wr.writerListed && !wr.ambiguous {
                if case .note(let id, let title) = wr.what, t[id] == title {
                    out.append("J3: \(name) took \(title), written by \(wr.writer) after its removal (forged record in place)")
                }
            }
        }
        // A rewritten record is a withheld one for every honest device: the honest bytes come back (KH4 syncs
        // records as a write-once union), and only then does J1 hold.
        for (url, original) in forged { try original.write(to: url) }
        // Quiescence: every listed device opens the folder and catches up (twice).
        for name in listed() {
            for _ in 0..<2 {
                guard let v = try? w.open(name) else { out.append("J1: \(name) cannot open the vault at quiescence"); continue }
                let before = try fileHashes(w)
                let report = try v.catchUp()
                if !report.problems.isEmpty { out.append("catch-up of \(name) left problems: \(report.problems)") }
                out += try checkSetAside(w, device: w[name], before: before, seen: &aside)
            }
        }
        out += try checkBodies(w, bodies: &bodies)
        let readers = try listed().map { (name: $0, vault: try w.open($0)) }
        let titles = try readers.map { (name: $0.name, titles: try w.titles($0.vault), vault: $0.vault) }
        for wr in writes where !wr.ambiguous {
            let mustRead = wr.writerListed && removedAt[wr.writer] == nil
            let mustNot = !wr.writerListed
            guard mustRead || mustNot else { continue }
            for r in titles {
                let reads: Bool
                switch wr.what {
                case .note(let id, let title): reads = r.titles[id] == title
                case .blob(let note, let ref, let content): reads = (try? r.vault.readBlob(note: note, ref)) == content
                case .capture(let id): reads = (try? r.vault.readCapture(id).audio) == audio
                case .notebook(let path):
                    reads = (try? r.vault.readNotebookRecords().records.contains { $0.add.contains(path) }) == true
                }
                // J1: every body a listed device wrote is accepted by every listed device.
                if mustRead, !reads { out.append("J1: \(r.name) does not read \(wr.what) (\(wr.writer), epoch \(wr.epoch))") }
                // J3: nothing a removed device wrote after its removal is accepted.
                if mustNot, reads { out.append("J3: \(r.name) took \(wr.what), written by \(wr.writer) after its removal") }
            }
        }
        // J3 for settings: a removed device's settings.age is never read.
        if let data = try? Data(contentsOf: w.url.appendingPathComponent(SharedSettings.fileName)),
           let by = settingsBy[FileDigest.sha256(data)], !by.listed {
            for r in readers where (try? r.vault.readSharedSettingsFile()) != nil {
                out.append("J3: \(r.name) reads the settings \(by.writer) wrote after its removal")
            }
        }
        // J2: no file under a key of an epoch that no longer listed a removed device opens with a key it held.
        let observer = try Vault.open(at: w.url, identities: [NativeIdentity.mlkem768x25519(w.recovery)], root: w.root)
        for (x, removed) in removedAt {
            for (path, url) in try revisionURLs(w) {
                let data = try Data(contentsOf: url)
                guard case .opened(_, _, let older) = observer.openUnderEpochs(data) else { continue }
                let epoch = older?.epoch ?? observer.manifest.epoch
                if epoch >= removed, (try? AgeFile.decrypt(data, with: held[x] ?? [])) != nil {
                    out.append("J2: \(x) (removed at epoch \(removed)) opens \(path), of epoch \(epoch)")
                }
            }
        }
        return (out, stats)
    }

    // MARK: - Helpers

    /// A removed device holding K_k and K_{k-1} (k ≥ 2) writes under K_{k-1} after its removal, then rewrites
    /// record k's sealed set to cover it (review M1). Returns the write, or nil when no removed device can.
    private func forge(_ w: EpochWorld, history: [String: [Int: Vault]], removedAt: [String: Int], names: [String], step: Int,
                       rng: inout SplitMix64, forged: inout [(URL, Data)]) throws -> (String, UUID, Int, String)? {
        let able = names.filter { n in
            guard removedAt[n] != nil, let e = history[n]?.keys.sorted(), let k = e.last else { return false }
            return k >= 2 && e.contains(k - 1)
        }
        guard let name = able.randomElement(using: &rng), let hist = history[name], let k = hist.keys.max(),
              let vk = hist[k], let vk1 = hist[k - 1] else { return nil }
        let title = "forged-\(name)-\(step)-\(UUID().uuidString.prefix(4))"
        guard let note = try? w[name].newNote(vk1, title), let key = try? vk.requireSecret() else { return nil }
        let recURL = w.url.appendingPathComponent("epochs").appendingPathComponent(EpochRecord.fileName(epoch: k, epochId: key.epochId))
        guard let original = try? Data(contentsOf: recURL),
              var rec = try? EpochRecord.open(original, key: key, vaultId: vk.vaultId, epoch: k),
              var parent = rec.parent else { return nil }
        for n in try vk1.revisionNames(of: note) {
            parent.sealed[Vault.notePath(note, n.filename)] = FileDigest.sha256(try Data(contentsOf: fileURL(vk1, note, n)))
        }
        rec.parent = parent
        try rec.seal(key: key).write(to: recURL)
        if !forged.contains(where: { $0.0 == recURL }) { forged.append((recURL, original)) }
        return (title, note, k - 1, name)
    }

    private func revisionFiles(_ v: Vault, _ note: UUID) throws -> [Data] {
        try v.revisionNames(of: note).map { try Data(contentsOf: fileURL(v, note, $0)) }
    }

    /// Every revision file of the folder, by vault path.
    private func revisionURLs(_ w: EpochWorld) throws -> [(String, URL)] {
        let notes = w.url.appendingPathComponent("notes")
        var out: [(String, URL)] = []
        for id in try FileManager.default.contentsOfDirectory(atPath: notes.path) where UUID(uuidString: id) != nil {
            for f in try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(id).path)
            where RevisionName(f) != nil {
                out.append(("notes/\(id)/\(f)", notes.appendingPathComponent(id).appendingPathComponent(f)))
            }
        }
        return out
    }

    private func fileHashes(_ w: EpochWorld) throws -> [String: String] {
        Dictionary(try revisionURLs(w).map { ($0.0, FileDigest.sha256(try Data(contentsOf: $0.1))) }, uniquingKeysWith: { a, _ in a })
    }

    /// J6: the device's set-aside store only grows, and every file a catch-up replaced is in it first.
    private func checkSetAside(_ w: EpochWorld, device: EpochDevice, before: [String: String],
                               seen: inout [String: Set<String>]) throws -> [String] {
        var out: [String] = []
        let vaultId = try Vault.open(at: w.url).vaultId
        let now = Set(device.setAside.items(vaultId: vaultId).map { "\($0.path):\($0.sha256)" })
        if !(seen[device.name] ?? []).isSubset(of: now) { out.append("J6: \(device.name)'s set-aside store lost an item") }
        seen[device.name] = now
        let after = try fileHashes(w)
        for (path, old) in before where after[path] != nil && after[path] != old && !now.contains("\(path):\(old)") {
            out.append("J6: \(device.name) replaced \(path) without setting it aside first")
        }
        return out
    }

    /// J8: no path ever holds two different bodies (as the observer holding the kit reads them).
    private func checkBodies(_ w: EpochWorld, bodies: inout [String: Data]) throws -> [String] {
        let observer = try Vault.open(at: w.url, identities: [NativeIdentity.mlkem768x25519(w.recovery)], root: w.root)
        var out: [String] = []
        for (path, url) in try revisionURLs(w) {
            guard let body = observer.plainBody(of: try Data(contentsOf: url), path: path) else { continue }
            if let first = bodies[path] {
                if first != body { out.append("J8: \(path) holds another body") }
            } else {
                bodies[path] = body
            }
        }
        return out
    }
}
