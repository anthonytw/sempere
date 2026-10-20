import Foundation

// Fork resolution (docs/design/key-hierarchy.md §5.6; format.md §15.9): over
// the tree of every verified epoch a device has seen, find the kept chain
// from epoch 1 down. Pure function: the caller verified every epoch
// (`EpochChain.verify`) before building the tree.
//
// - Context: epochs authored by a device that this device's pinned chain
//   removed never enter the tree (unless they are on the pinned chain).
// - Pruning: walking down, an epoch whose author the kept prefix removed, or
//   whose author is in the re-application set, is dropped with its subtree.
// - At a branch, two sides are compared over their COUNTED epochs: each
//   child counts; a descendant counts only if its parent counts and no
//   counted epoch of the other side removed its author (computed to a fixed
//   point; undecided epochs do not count). A removed device that appends
//   under an old honest fork therefore supplies neither removals nor
//   descendants to that side (review C1).
// - Stored answers first (a rejected author's side loses), then a pre-pass
//   applies rule 1 to all siblings (only undominated siblings discard), then
//   pairs in `epochId` order: rule 1 a removed author loses; rule 2 mutual
//   removal is the user's question (an author follows one binding resolve
//   epoch, two that disagree are a contradiction and a question); rule 3 a
//   side without counted descendants loses; rule 4 the larger `epochId` loses.
// - The counted removals of every side lost by rule 3 or 4, still listed at
//   the end of the kept chain and never a recovery key, are re-applied in one
//   epoch.

/// One verified epoch, as fork resolution sees it.
public struct ForkNode: Hashable, Sendable {
    public var epochId: Data
    /// The parent's `epochId`; nil for epoch 1.
    public var parent: Data?
    /// The author's fingerprint.
    public var author: Data
    /// The keys it removed, computed (design §4.1).
    public var removals: Set<Data>
    /// Its list: the first list plus the additions admitted during it.
    public var list: Set<Data>
    public var reason: EpochReason
    /// Its recovery fingerprint (the chain entry's `recovery`, covered by `epochSig`).
    public var recovery: Data?
    /// For a `resolve` epoch: the author whose side it rejected (the chain entry's `rejected`,
    /// covered by `epochSig`).
    public var rejected: Data?

    public init(epochId: Data, parent: Data?, author: Data, removals: Set<Data>, list: Set<Data>, reason: EpochReason,
                recovery: Data? = nil, rejected: Data? = nil) {
        self.epochId = epochId; self.parent = parent; self.author = author; self.removals = removals
        self.list = list; self.reason = reason; self.recovery = recovery; self.rejected = rejected
    }
}

/// What the device brings to resolution besides the tree.
public struct ForkContext: Sendable {
    /// This device's fingerprint (nil: a reader that is no device, e.g. the CLI with the recovery key).
    public var me: Data?
    /// The authors this device's user rejected ("Which of these did you make?"), from its trust record.
    public var rejectedAuthors: Set<Data>
    /// The `addedBy` chain of each device that wrote a resolve epoch (`EpochChain.Verified.approverChain`).
    public var approverChains: [Data: [Data]]
    /// The device's pinned chain (epoch ids from epoch 1), from its trust record; empty for a joining device.
    public var pinned: [Data]

    public init(me: Data? = nil, rejectedAuthors: Set<Data> = [], approverChains: [Data: [Data]] = [:],
                pinned: [Data] = []) {
        self.me = me; self.rejectedAuthors = rejectedAuthors; self.approverChains = approverChains; self.pinned = pinned
    }
}

/// How a side was decided at a branch.
public enum ForkRule: String, Hashable, Sendable, Codable {
    /// Rule 1 (also in the pre-pass): its author was removed by the other side, not the reverse.
    case removedAuthor = "rule1"
    /// Rule 2, decided: by the user's stored answer, by a binding resolve epoch (for an author), or
    /// an author keeping its own side until one arrives.
    case mutualAnswered = "rule2"
    /// Rule 3: no counted descendants, against a side with some.
    case stale = "rule3"
    /// Rule 4: the larger `epochId`.
    case epochIdOrder = "rule4"
    /// Dropped walking down: its author was removed on the kept prefix or is in the re-application set.
    case pruned = "pruned"

    /// Sides lost by rules 3 and 4 are re-applied; the others never.
    public var reapplies: Bool { self == .stale || self == .epochIdOrder }
}

/// A side that lost at a branch.
public struct ForkLoss: Hashable, Sendable {
    public var child: Data
    /// The winner (for `.pruned`, the kept epoch it hung from).
    public var to: Data
    public var rule: ForkRule
}

/// The open question of rule 2 (design §5.6): nothing decides without the user.
public struct ForkQuestion: Hashable, Sendable {
    /// The branch point P: names come from its list.
    public var branch: Data
    /// The two children, in `epochId` order.
    public var sides: [Data]
    /// Their authors, in the same order.
    public var authors: [Data]
    /// Each side's counted removals, in the same order.
    public var removals: [Set<Data>]
    /// Who is asked: every device in P's list or in a counted list on either side, except the two
    /// authors and recovery keys.
    public var asked: Set<Data>
    /// Resolve epochs counted on either side (shown as context), with the author they rejected.
    public var resolves: [Data: Data]
}

/// A resolve epoch that differs from this device's stored answer, or from another binding resolve
/// epoch (design §5.6 "Contradictions").
public struct ForkContradiction: Hashable, Sendable {
    public var resolveEpoch: Data
    public var rejected: Data
}

/// The outcome of resolution.
public struct ForkResolution: Hashable, Sendable {
    /// From epoch 1 to the last kept epoch (P when a question is open).
    public var keptChain: [Data]
    /// Every side that lost, at every branch on the way.
    public var losses: [ForkLoss]
    /// Keys to remove in one `reapply` epoch on top of the kept chain; empty: write nothing.
    public var reapply: Set<Data>
    /// An open rule-2 question; the device then treats both sides as unverified-pending.
    public var question: ForkQuestion?
    public var contradictions: [ForkContradiction]
}

/// Why the tree cannot be resolved.
public enum ForkError: Error, Hashable, Sendable {
    /// Not exactly one epoch without a parent.
    case noRoot
    /// A parent that is not in the tree, or a cycle.
    case detached
}

/// Fork resolution (design §5.6).
public enum EpochForks {
    public static func resolve(_ nodes: [ForkNode], context: ForkContext = ForkContext()) throws -> ForkResolution {
        var byId: [Data: ForkNode] = [:]
        for n in nodes { byId[n.epochId] = n }
        let roots = byId.values.filter { $0.parent == nil }
        guard roots.count == 1, let root = roots.first else { throw ForkError.noRoot }
        var children: [Data: [Data]] = [:]
        for n in byId.values {
            guard let p = n.parent else { continue }
            guard byId[p] != nil else { throw ForkError.detached }
            children[p, default: []].append(n.epochId)
        }
        var reached = 0
        var stack = [root.epochId]
        while let x = stack.popLast(), reached <= byId.count { reached += 1; stack += children[x] ?? [] }
        guard reached == byId.count else { throw ForkError.detached }
        let recoveryKeys = Set(byId.values.compactMap(\.recovery))
        func precedes(_ a: Data, _ b: Data) -> Bool { a.lexicographicallyPrecedes(b) }
        func author(_ id: Data) -> Data { byId[id]?.author ?? Data() }

        // Context: what the pinned chain removed never enters the tree (except the pinned chain itself).
        var pinnedIds: Set<Data> = []
        var removedOnPinned: Set<Data> = []
        var expected: Data? = nil
        for id in context.pinned {
            guard let n = byId[id], n.parent == expected else { break }
            pinnedIds.insert(id); removedOnPinned.formUnion(n.removals); expected = id
        }
        var excluded: Set<Data> = []
        func exclude(_ id: Data) { excluded.insert(id); for c in children[id] ?? [] { exclude(c) } }
        for n in byId.values where !pinnedIds.contains(n.epochId) && removedOnPinned.contains(n.author) { exclude(n.epochId) }
        func kids(_ id: Data) -> [Data] { (children[id] ?? []).filter { !excluded.contains($0) }.sorted(by: precedes) }
        func subtree(_ id: Data) -> [Data] { [id] + kids(id).flatMap(subtree) }

        /// The counted epochs of sides `s` and `t` (design §5.6 as amended after review C1).
        var judgments: [[Data]: (Set<Data>, Set<Data>)] = [:]
        func judge(_ s: Data, _ t: Data) -> (s: Set<Data>, t: Set<Data>) {
            if let j = judgments[[s, t]] { return j }
            let sideS = subtree(s), sideT = subtree(t)
            var accepted: Set<Data> = [s, t], rejected: Set<Data> = []
            let inS = Set(sideS)
            var changed = true
            while changed {
                changed = false
                for f in sideS.dropFirst() + sideT.dropFirst() where !accepted.contains(f) && !rejected.contains(f) {
                    let opponent = inS.contains(f) ? sideT : sideS
                    let parent = byId[f]?.parent ?? Data()
                    let attackers = opponent.filter { !rejected.contains($0) && (byId[$0]?.removals.contains(author(f)) ?? false) }
                    if rejected.contains(parent) || attackers.contains(where: accepted.contains) {
                        rejected.insert(f); changed = true
                    } else if attackers.isEmpty && accepted.contains(parent) {
                        accepted.insert(f); changed = true
                    }
                }
            }
            let result = (accepted.intersection(sideS), accepted.intersection(sideT))
            judgments[[s, t]] = result
            judgments[[t, s]] = (result.1, result.0)
            return result
        }
        func removals(_ counted: Set<Data>) -> Set<Data> {
            counted.reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.removals ?? []) }
        }

        var losses: [ForkLoss] = []
        var reapplyFrom: Set<Data> = []
        var contradictions: [ForkContradiction] = []
        var question: ForkQuestion?

        if !context.rejectedAuthors.isEmpty {
            for r in byId.values.sorted(by: { precedes($0.epochId, $1.epochId) })
            where !excluded.contains(r.epochId) && r.reason == .resolve {
                if let rej = r.rejected, !context.rejectedAuthors.contains(rej) {
                    contradictions.append(ForkContradiction(resolveEpoch: r.epochId, rejected: rej))
                }
            }
        }

        /// Rule 2 between `a` and `b`: the winner, or nil when the user must answer.
        func mutual(_ a: Data, _ b: Data, counted: Set<Data>) -> Data? {
            let authors = [author(a), author(b)]
            if context.rejectedAuthors.contains(authors[0]) && !context.rejectedAuthors.contains(authors[1]) { return b }
            if context.rejectedAuthors.contains(authors[1]) && !context.rejectedAuthors.contains(authors[0]) { return a }
            guard let me = context.me, authors.contains(me) else { return nil }
            // An author follows a binding resolve epoch: counted on either side, written by a device that
            // is neither author and whose addedBy chain passes through neither.
            let binding = counted.compactMap { byId[$0] }.filter { r in
                guard r.reason == .resolve, let rej = r.rejected, authors.contains(rej),
                      !authors.contains(r.author) else { return false }
                return !(context.approverChains[r.author] ?? []).contains { authors.contains($0) }
            }.sorted { precedes($0.epochId, $1.epochId) }
            let verdicts = Set(binding.compactMap(\.rejected))
            if verdicts.count > 1 {
                // Two binding resolves disagree: shown, and the author's user is asked (review M4).
                for r in binding { if let rej = r.rejected { contradictions.append(ForkContradiction(resolveEpoch: r.epochId, rejected: rej)) } }
                return nil
            }
            if let rej = verdicts.first { return rej == authors[0] ? b : a }
            // Until then each author keeps its own side.
            return me == authors[0] ? a : b
        }

        var cur = root.epochId
        var kept = [cur]
        var prefixRemoved: Set<Data> = []
        walk: while true {
            // Pruning: what the kept prefix removed, or what is about to be re-applied, never continues it.
            var candidates: [Data] = []
            for c in kids(cur) {
                if prefixRemoved.contains(author(c)) || reapplyFrom.contains(author(c)) {
                    losses.append(ForkLoss(child: c, to: cur, rule: .pruned))
                } else {
                    candidates.append(c)
                }
            }
            if candidates.isEmpty { break }
            if candidates.count == 1 {
                cur = candidates[0]; kept.append(cur); prefixRemoved.formUnion(byId[cur]?.removals ?? []); continue
            }
            var remaining = candidates
            // Stored answers: a rejected author's side loses at every branch (rule 2, answered).
            if !context.rejectedAuthors.isEmpty {
                let keep = remaining.filter { !context.rejectedAuthors.contains(author($0)) }
                if !keep.isEmpty {
                    for c in remaining where !keep.contains(c) {
                        losses.append(ForkLoss(child: c, to: keep[0], rule: .mutualAnswered))
                    }
                    remaining = keep
                }
            }
            // Pre-pass: rule 1 against every sibling, over counted epochs, unless the pair is mutual;
            // only siblings that no one dominates discard others; repeated until nothing changes.
            func dominates(_ d: Data, _ c: Data) -> Bool {
                guard d != c else { return false }
                let j = judge(d, c)
                return removals(j.s).contains(author(c)) && !removals(j.t).contains(author(d))
            }
            while true {
                let undominated = remaining.filter { d in !remaining.contains { dominates($0, d) } }
                var round: [(Data, Data)] = []
                for c in remaining {
                    if let d = undominated.first(where: { dominates($0, c) }) { round.append((c, d)) }
                }
                if round.isEmpty { break }
                for (c, d) in round { losses.append(ForkLoss(child: c, to: d, rule: .removedAuthor)) }
                let gone = Set(round.map(\.0))
                remaining = remaining.filter { !gone.contains($0) }
            }
            // Pairs in epochId order.
            var winner = remaining[0]
            for next in remaining.dropFirst() {
                let j = judge(winner, next)
                let removedByWinner = removals(j.s), removedByNext = removals(j.t)
                let aRemovesB = removedByWinner.contains(author(next))
                let bRemovesA = removedByNext.contains(author(winner))
                var rule: ForkRule
                var newWinner: Data
                if bRemovesA && !aRemovesB {
                    rule = .removedAuthor; newWinner = next
                } else if aRemovesB && !bRemovesA {
                    rule = .removedAuthor; newWinner = winner
                } else if aRemovesB && bRemovesA {
                    guard let w = mutual(winner, next, counted: j.s.union(j.t)) else {
                        let sides = [winner, next]
                        var asked = byId[cur]?.list ?? []
                        for x in j.s.union(j.t) { asked.formUnion(byId[x]?.list ?? []) }
                        asked.subtract(sides.map(author))
                        asked.subtract(recoveryKeys)
                        var seen: [Data: Data] = [:]
                        for x in j.s.union(j.t) {
                            if let r = byId[x], r.reason == .resolve, let rej = r.rejected { seen[x] = rej }
                        }
                        question = ForkQuestion(branch: cur, sides: sides, authors: sides.map(author),
                                                removals: [removedByWinner, removedByNext], asked: asked, resolves: seen)
                        break walk
                    }
                    rule = .mutualAnswered; newWinner = w
                } else if (j.s.count > 1) != (j.t.count > 1) {
                    rule = .stale; newWinner = j.s.count > 1 ? winner : next
                } else {
                    rule = .epochIdOrder; newWinner = precedes(winner, next) ? winner : next
                }
                let loser = newWinner == winner ? next : winner
                losses.append(ForkLoss(child: loser, to: newWinner, rule: rule))
                if rule.reapplies { reapplyFrom.formUnion(loser == winner ? removedByWinner : removedByNext) }
                winner = newWinner
            }
            cur = winner
            kept.append(cur)
            prefixRemoved.formUnion(byId[cur]?.removals ?? [])
        }
        let end = byId[kept[kept.count - 1]]?.list ?? []
        let reapply = reapplyFrom.intersection(end).subtracting(recoveryKeys)
        return ForkResolution(keptChain: kept, losses: losses, reapply: reapply, question: question,
                              contradictions: contradictions)
    }
}
