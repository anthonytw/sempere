import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// The single writer's property test at the vault level (key-hierarchy design §5.6, §16.6; phase KH3): seeded
/// random runs of real devices sharing a folder (removals and handoffs by home, takeovers with the kit from
/// each device's pinned frontier, epochs forged by devices that are not home, and by a home from before a
/// takeover), each device opening the folder after every step. Against an independent oracle:
///
/// - (a) every epoch of a chain a device follows is signed by the home of its parent, or is a takeover by the
///   kit;
/// - (b) takeover precedence: a device follows the folder's chain exactly when the precedence rule over its
///   pinned chain and that chain keeps it (a takeover beats home epochs that are not its ancestors, the
///   smaller `epochId` between two takeovers, a home conflict stays on the pinned chain);
/// - (c) order independence: what a device decides does not depend on the order devices open the folder;
/// - (d) after a takeover, no device it left out signs or is home on a chain a device follows.
///
/// (e) Three test-only mutations (a non-home signer accepted, takeovers ignored, the home from before a
/// takeover still accepted) must each make it fail. KH1's `EpochPrecedenceTests` checks the pure function
/// over random trees; this one checks what `Vault.open` decides from the files.
final class EpochVaultPropertyTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        Vault.precedenceMutations = []
        super.tearDown()
    }

    static var seeds: Int { Int(ProcessInfo.processInfo.environment["SEMPERE_EPOCH_PROPERTY_SEEDS"] ?? "") ?? 6 }

    func testTheSingleWriterHoldsOnRealVaults() throws {
        var all: [String] = []
        var seen: [String: Int] = [:]
        for seed in 0..<UInt64(Self.seeds) {
            let (violations, stats) = try run(seed: seed, steps: 10)
            all += violations.map { "seed \(seed): \($0)" }
            seen.merge(stats, uniquingKeysWith: +)
        }
        XCTAssertTrue(all.isEmpty, all.prefix(10).joined(separator: "\n"))
        // Not vacuous: every kind of step happened, and devices followed and refused takeovers.
        for key in ["remove", "handoff", "takeover", "forgeByNonHome", "followedTakeover", "refusedForged", "dropped"] {
            XCTAssertGreaterThan(seen[key, default: 0], 0, "no \(key) in \(Self.seeds) seeds: \(seen)")
        }
    }

    /// The invariant each mutation breaks: a non-home signer is followed (a), takeovers lose to home epochs
    /// (b), and the home from before a takeover (which the takeover kept listed) signs again (a).
    static let expected: [PrecedenceMutation: String] = [.nonHomeSignerAccepted: "(a)", .takeoverIgnored: "(b)", .olderHomeKept: "(a)"]

    /// (e): each mutation must break ITS invariant on a seed whose unmutated run is clean.
    func testEachMutationIsCaught() throws {
        for (m, label) in Self.expected.sorted(by: { $0.value < $1.value }) {
            var caught: [String] = []
            for seed in 0..<UInt64(16) where caught.isEmpty {
                let mutated = try run(seed: seed &+ 1000, steps: 12, mutation: m).violations.filter { $0.contains(label) }
                guard !mutated.isEmpty else { continue }
                let clean = try run(seed: seed &+ 1000, steps: 12).violations
                XCTAssertTrue(clean.isEmpty, "seed \(seed &+ 1000) fails without \(m): \(clean.prefix(3))")
                caught = mutated
            }
            XCTAssertFalse(caught.isEmpty, "the mutation \(m) did not break \(label)")
        }
    }

    // MARK: - One run

    private enum Op: CaseIterable { case pin, write, remove, handoff, takeover, forgeByNonHome, forgeByOldHome }

    private func run(seed: UInt64, steps: Int, mutation: PrecedenceMutation? = nil) throws
        -> (violations: [String], stats: [String: Int]) {
        let dir = tmp.appendingPathComponent("run-\(seed)-\(mutation.map { "\($0)" } ?? "none")-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = try EpochWorld(in: dir, names: ["A", "B", "C", "D"])
        var rng = SplitMix64(seed: seed)
        var violations: [String] = []
        var stats: [String: Int] = [:]
        /// A home from before a takeover that the takeover kept listed (what `olderHomeKept` needs).
        var oldHome: EpochDevice?
        Vault.precedenceMutations = mutation.map { [$0] } ?? []
        defer { Vault.precedenceMutations = [] }

        for step in 0..<steps {
            let state = try observe(w)
            let listed = w.devices.filter { state.listed.contains($0.fingerprint) }
            let home = w.devices.first { $0.fingerprint == state.home }
            var forged = false
            let manifestBefore = try Data(contentsOf: w.url.appendingPathComponent("vault.json"))
            let op = Op.allCases.randomElement(using: &rng) ?? .pin
            switch op {
            case .pin:
                if let d = listed.randomElement(using: &rng), let v = try? d.open(w.url), v.listStatus.allowsWriting {
                    try? v.requireWritable()
                }
            case .write:
                if let d = listed.randomElement(using: &rng), let v = try? d.open(w.url), v.listStatus.allowsWriting {
                    _ = try? d.newNote(v, "step \(step)")
                }
            case .remove:
                let others = listed.filter { $0.fingerprint != state.home }
                if others.count >= 2, let h = home, var v = try? h.open(w.url), v.isHome, let target = others.randomElement(using: &rng),
                   (try? v.removeDevices([target.id])) != nil {
                    stats["remove", default: 0] += 1
                }
            case .handoff:
                if let h = home, var v = try? h.open(w.url), v.isHome,
                   let target = listed.filter({ $0.fingerprint != state.home }).randomElement(using: &rng),
                   (try? v.handOff(to: target.id)) != nil {
                    stats["handoff", default: 0] += 1
                }
            case .takeover:
                guard let d = w.devices.randomElement(using: &rng),
                      let plan = try? Vault.takeoverPlan(at: w.url, device: d.keys, recovery: w.recovery, trust: d.trust, root: nil)
                else { break }
                var keep = Set<Data>()
                for c in plan.candidates where Double.random(in: 0..<1, using: &rng) < (c.listed ? 0.8 : 0.3) {
                    keep.insert(c.fingerprint)
                }
                if let h = home, h !== d, Bool.random(using: &rng), plan.candidates.contains(where: { $0.fingerprint == h.fingerprint }) {
                    keep.insert(h.fingerprint)
                }
                if (try? Vault.takeover(at: w.url, device: d.keys, recovery: w.recovery, keep: keep, trust: d.trust, root: nil,
                                        ledger: d.ledger, setAside: d.setAside)) != nil {
                    oldHome = home.flatMap { keep.contains($0.fingerprint) ? $0 : nil }
                    stats["takeover", default: 0] += 1
                }
            case .forgeByNonHome:
                if let d = listed.filter({ $0.fingerprint != state.home }).randomElement(using: &rng) {
                    forged = (try? forge(w, author: d)) != nil
                    if forged { stats["forgeByNonHome", default: 0] += 1 }
                }
            case .forgeByOldHome:
                if let d = oldHome, listed.contains(where: { $0 === d }), d.fingerprint != state.home {
                    forged = (try? forge(w, author: d)) != nil
                    if forged { stats["forgeByOldHome", default: 0] += 1 }
                }
            }
            violations += try check(w, rng: &rng, forged: forged, stats: &stats).map { "step \(step) (\(op)): \($0)" }
            // A forged vault.json is put back by its home afterwards (a shared folder keeps one vault.json).
            if forged { try manifestBefore.write(to: w.url.appendingPathComponent("vault.json")) }
        }
        return (violations, stats)
    }

    /// The folder's current epoch as an observer holding the kit sees it, with the un-mutated rules.
    private struct Observed {
        var chain: [ChainEntry]
        var valid: Bool
        var listed: Set<Data>
        var home: Data
    }

    private func observe(_ w: EpochWorld) throws -> Observed {
        let saved = Vault.precedenceMutations
        Vault.precedenceMutations = []
        defer { Vault.precedenceMutations = saved }
        let v = try Vault.open(at: w.url, identities: [NativeIdentity.mlkem768x25519(w.recovery)], root: w.root)
        let valid = v.listStatus.allowsWriting
        let chain = (try? v.currentChain()) ?? v.verifiedChain?.entries ?? []
        return Observed(chain: chain, valid: valid, listed: Set(v.manifest.devices.map(\.fingerprint)), home: v.manifest.home)
    }

    /// Writes an epoch over `vault.json` signed by `author`, naming itself home (a removal of nobody).
    private func forge(_ w: EpochWorld, author: EpochDevice) throws {
        let saved = Vault.precedenceMutations
        Vault.precedenceMutations = []
        defer { Vault.precedenceMutations = saved }
        let v = try author.open(w.url)
        guard v.listStatus.allowsWriting, let entry = v.deviceEntry, let recovery = v.manifest.recoveryEntry else {
            throw VaultError.locked
        }
        let plan = Vault.EpochPlan(
            reason: .remove, parentKey: try v.requireSecret(), parentChain: try v.currentChain(),
            parentList: v.manifest.keys.map(\.fingerprint), parentAdditions: v.currentAdditions(), devices: v.manifest.devices,
            recovery: recovery, home: author.fingerprint, author: entry, signing: author.keys.signing, recoverySigner: nil,
            sealed: [:], created: Date(), label: nil, features: [])
        _ = try v.writeEpoch(plan)
    }

    /// Opens the folder as every device, twice in random orders, and checks (a) to (d).
    private func check(_ w: EpochWorld, rng: inout SplitMix64, forged: Bool, stats: inout [String: Int]) throws -> [String] {
        let truth = try observe(w)
        var out: [String] = []
        func decide(_ d: EpochDevice) -> (follows: Bool, chain: [ChainEntry], dropped: Int)? {
            guard let v = try? d.open(w.url) else { return nil }
            return (v.listStatus.allowsWriting, v.verifiedChain?.entries ?? ((try? v.currentChain()) ?? []), v.droppedEpochs.count)
        }
        let first = w.devices.shuffled(using: &rng).map { ($0.name, decide($0)) }
        let second = Dictionary(w.devices.shuffled(using: &rng).map { ($0.name, decide($0)) }, uniquingKeysWith: { a, _ in a })
        for (name, result) in first {
            // (c)
            if result?.follows != second[name]??.follows { out.append("(c) \(name) decides differently in another order") }
            guard let result else { continue }
            let d = w[name]
            if result.follows {
                out += chainProblems(result.chain).map { "\(name) follows a chain where \($0)" }
                if result.chain.contains(where: { $0.reason == EpochReason.takeover.rawValue }) { stats["followedTakeover", default: 0] += 1 }
                if result.dropped > 0 { stats["dropped", default: 0] += 1 }
            } else if forged {
                stats["refusedForged", default: 0] += 1
            }
            // (b)
            guard let record = try d.trust.record(for: try Vault.open(at: w.url).vaultId) else { continue }
            let expected = Self.expectedFollow(pinned: record.chain, chain: truth.chain, valid: truth.valid)
            if expected != result.follows {
                out.append("(b) \(name) \(result.follows ? "follows" : "refuses") the folder's chain; the rule "
                    + "\(expected ? "follows" : "refuses") it")
            }
        }
        return out
    }

    /// (a) and (d) on a chain a device follows.
    private func chainProblems(_ chain: [ChainEntry]) -> [String] {
        var out: [String] = []
        for i in chain.indices.dropFirst() {
            let e = chain[i], prev = chain[i - 1]
            if e.reason == EpochReason.takeover.rawValue {
                if e.author.fingerprint != e.home || e.recoveryAuthor?.recoveryFingerprint != prev.recovery {
                    out.append("(a) the takeover of epoch \(e.epoch) is not by its home and the kit")
                }
            } else if e.author.fingerprint != prev.home {
                out.append("(a) epoch \(e.epoch) is not signed by its parent's home")
            }
        }
        for t in chain.indices where chain[t].reason == EpochReason.takeover.rawValue {
            // The takeover's list: its first list and the devices its new home approved in it (re-admitted).
            let kept = Set(chain[t].list).union(chain[t].additions.map(\.fingerprint))
            for later in chain[(t + 1)...] where !kept.contains(later.author.fingerprint) || !kept.contains(later.home) {
                out.append("(d) a device the takeover of epoch \(chain[t].epoch) left out signs or is home at epoch \(later.epoch)")
            }
        }
        return out
    }

    /// The oracle of (b), written apart from `EpochPrecedence`: at the last epoch the pinned chain and the
    /// folder's chain share, the branch whose first takeover has the smaller `epochId` wins; a branch with a
    /// takeover beats one without; without takeovers on either side the pinned branch stays (a home conflict).
    static func expectedFollow(pinned: [EpochTrustRecord.ChainEpoch], chain: [ChainEntry], valid: Bool) -> Bool {
        guard valid else { return false }
        var f = 0
        while f < pinned.count, f < chain.count, pinned[f].epochId == chain[f].epochId { f += 1 }
        let mine = pinned[f...], theirs = chain[f...]
        if theirs.isEmpty { return mine.isEmpty }
        if mine.isEmpty { return true }
        let takeover = EpochReason.takeover.rawValue
        switch (mine.first { $0.reason == takeover }?.epochId, theirs.first { $0.reason == takeover }?.epochId) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case (.some(let a), .some(let b)): return b.lexicographicallyPrecedes(a)
        }
    }
}
