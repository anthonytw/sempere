import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The invariants of key-hierarchy design §11.2 that need no sync (phase KH3: J1, J2, J3, J5a, J6, J8), on
/// seeded random runs of in-process devices sharing one folder: writes by listed devices (some offline: a
/// vault value opened before the latest change), writes by removed devices (the value they held), removals
/// by home, catch-ups, and catch-ups cut off at each fault point. An omniscient observer (holding the kit)
/// records every write; at quiescence every listed device catches up. Each `EpochMutation` must make a run
/// fail, so no invariant is vacuous. Engine-level runs over targets (J4, J5b, J7, J9, J10) are KH4's
/// `EpochInterleavingTests`.
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
        for seed in 0..<UInt64(Self.seeds) {
            all += try run(seed: seed, steps: 18).map { "seed \(seed): \($0)" }
        }
        XCTAssertTrue(all.isEmpty, all.prefix(12).joined(separator: "\n"))
    }

    func testEachMutationBreaksAnInvariant() throws {
        for m in EpochMutation.allCases {
            var caught: [String] = []
            for seed in 0..<UInt64(10) where caught.isEmpty {
                caught = try run(seed: seed &+ 500, steps: 22, mutation: m)
            }
            XCTAssertFalse(caught.isEmpty, "the mutation \(m) went unnoticed")
        }
    }

    // MARK: - One run

    private struct Write {
        var writer: String
        var note: UUID
        var title: String
        var epoch: Int
        /// The writer was not removed when it wrote.
        var writerListed: Bool
    }

    private enum Op: CaseIterable { case write, write2, refresh, remove, catchUp, crashedCatchUp }

    private func run(seed: UInt64, steps: Int, mutation: EpochMutation? = nil) throws -> [String] {
        let dir = tmp.appendingPathComponent("inv-\(seed)-\(mutation.map { "\($0)" } ?? "none")")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["A", "B", "C", "X", "Y"]
        let w = try EpochWorld(in: dir, names: names)
        var rng = SplitMix64(seed: seed)
        var out: [String] = []
        var values: [String: Vault] = [:]
        var held: [String: [any AgeIdentity]] = [:]
        var removedAt: [String: Int] = [:]
        var writes: [Write] = []
        var bodies: [String: Data] = [:]
        var aside: [String: Set<String>] = [:]
        Vault.epochMutations = mutation.map { [$0] } ?? []
        defer { Vault.epochMutations = [] }
        for n in names {
            let v = try w.open(n)
            try v.requireWritable()
            values[n] = v
            held[n, default: []] += v.identities
        }

        for step in 0..<steps {
            let op = Op.allCases.randomElement(using: &rng) ?? .write
            let name = names.randomElement(using: &rng) ?? "A"
            let d = w[name]
            switch op {
            case .write, .write2:
                // With the value it holds: an offline listed device, or a removed one writing anyway.
                guard let v = values[name] else { break }
                let title = "\(name)-\(step)"
                guard let note = try? d.newNote(v, title) else { break }
                writes.append(Write(writer: name, note: note, title: title, epoch: v.manifest.epoch,
                                    writerListed: removedAt[name] == nil))
                // J5a: written under the key of the epoch it verified, none earlier.
                for data in try revisionFiles(v, note) {
                    if (try? AgeFile.decrypt(data, with: v.identities)) == nil {
                        out.append("J5a step \(step): \(name) wrote under another key than its epoch's")
                    }
                    for o in v.olderEpochs where (try? AgeFile.decrypt(data, with: [o.identity])) != nil {
                        out.append("J5a step \(step): \(name) wrote under epoch \(o.epoch) after verifying \(v.manifest.epoch)")
                    }
                }
            case .refresh:
                guard removedAt[name] == nil, let v = try? w.open(name), v.listStatus.allowsWriting else { break }
                values[name] = v
                held[name, default: []] += v.identities
            case .remove:
                guard var a = try? w.open("A"), a.isHome else { break }
                let listed = names.filter { $0 != "A" && removedAt[$0] == nil }
                guard listed.count > 2, let target = listed.randomElement(using: &rng) else { break }
                guard (try? a.removeDevices([w[target].id])) != nil else {
                    out.append("step \(step): home could not remove \(target)")
                    break
                }
                removedAt[target] = a.manifest.epoch
                values["A"] = a
                held["A", default: []] += a.identities
            case .catchUp, .crashedCatchUp:
                guard removedAt[name] == nil, var v = try? w.open(name), v.listStatus.allowsWriting else { break }
                values[name] = v
                held[name, default: []] += v.identities
                if op == .crashedCatchUp {
                    let points: [EpochFaults.Point] = [.catchUpWritten(1), .catchUpVerified(1), .catchUpPlaced(1)]
                    v.faults = EpochFaults(stop: points.randomElement(using: &rng))
                }
                let before = try fileHashes(w)
                _ = try? v.catchUp()
                out += try checkSetAside(w, device: d, before: before, seen: &aside).map { "step \(step): \($0)" }
            }
            out += try checkBodies(w, bodies: &bodies).map { "step \(step): \($0)" }
        }

        // Quiescence: every listed device opens the folder and catches up (twice).
        for name in names where removedAt[name] == nil {
            for _ in 0..<2 {
                let v = try w.open(name)
                let before = try fileHashes(w)
                let report = try v.catchUp()
                if !report.problems.isEmpty { out.append("catch-up of \(name) left problems: \(report.problems)") }
                out += try checkSetAside(w, device: w[name], before: before, seen: &aside)
            }
        }
        out += try checkBodies(w, bodies: &bodies)
        let listed = names.filter { removedAt[$0] == nil }
        let readers = try listed.map { (name: $0, titles: try w.titles(try w.open($0))) }
        for wr in writes {
            // J1: every body a listed device wrote is accepted by every listed device.
            if wr.writerListed, removedAt[wr.writer] == nil {
                for r in readers where r.titles[wr.note] != wr.title {
                    out.append("J1: \(r.name) does not read \(wr.title) (\(wr.writer), epoch \(wr.epoch))")
                }
            }
            // J3: nothing a removed device wrote after its removal is accepted.
            if !wr.writerListed {
                for r in readers where r.titles[wr.note] != nil {
                    out.append("J3: \(r.name) took \(wr.title), written by \(wr.writer) after its removal")
                }
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
        return out
    }

    // MARK: - Helpers

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
