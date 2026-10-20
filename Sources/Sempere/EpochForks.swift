import Foundation

// Fork resolution (docs/design/key-hierarchy.md §5.6; format.md §15.9): over
// the tree of every verified epoch a device has seen, find the kept chain
// from epoch 1 down. At each branch: a pre-pass applies rule 1 to all
// siblings, then the rest are compared in pairs in `epochId` order, over
// SUBTREES (each child with all its descendants). Rule 1: a side whose author
// the other side removed, when the reverse does not hold, loses. Rule 2:
// mutual removal is the user's question (stored answers and binding resolve
// epochs are inputs). Rule 3: a side with no descendants loses to one with
// descendants. Rule 4: the smaller `epochId` wins. The removals of every side
// lost by rule 3 or 4 (its whole subtree) still listed on the kept chain, and
// never a recovery key, are re-applied in one epoch. Pure function: the
// caller verified every epoch (`EpochChain.verify`) before building the tree.

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
    /// For a `resolve` epoch: the author whose side it rejected (the record's `rejected`).
    public var rejected: Data?

    public init(epochId: Data, parent: Data?, author: Data, removals: Set<Data>, list: Set<Data>, reason: EpochReason,
                rejected: Data? = nil) {
        self.epochId = epochId; self.parent = parent; self.author = author; self.removals = removals
        self.list = list; self.reason = reason; self.rejected = rejected
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
    /// Recovery keys: never re-applied.
    public var recoveryKeys: Set<Data>

    public init(me: Data? = nil, rejectedAuthors: Set<Data> = [], approverChains: [Data: [Data]] = [:],
                recoveryKeys: Set<Data> = []) {
        self.me = me; self.rejectedAuthors = rejectedAuthors; self.approverChains = approverChains
        self.recoveryKeys = recoveryKeys
    }
}

/// How a side was decided at a branch.
public enum ForkRule: String, Hashable, Sendable, Codable {
    /// Rule 1 (also in the pre-pass): its author was removed by the other side, not the reverse.
    case removedAuthor = "rule1"
    /// Rule 2, decided: by the user's stored answer, by a binding resolve epoch (for an author), or
    /// an author keeping its own side until one arrives.
    case mutualAnswered = "rule2"
    /// Rule 3: no descendants, against a side with descendants.
    case stale = "rule3"
    /// Rule 4: the larger `epochId`.
    case epochIdOrder = "rule4"

    /// Sides lost by rules 3 and 4 are re-applied; 1 and 2 never.
    public var reapplies: Bool { self == .stale || self == .epochIdOrder }
}

/// A side that lost at a branch.
public struct ForkLoss: Hashable, Sendable {
    public var child: Data
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
    /// Each side's removals (whole subtree), in the same order.
    public var removals: [Set<Data>]
    /// Who is asked: every device in P's list or added on either side, except the two authors.
    public var asked: Set<Data>
    /// Resolve epochs seen on either side (shown as context), with the author they rejected.
    public var resolves: [Data: Data]
}

/// A resolve epoch that differs from this device's stored answer (design §5.6 "Contradictions").
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
        // Every node reachable once from the root (no cycle).
        var reached = 0
        var stack = [root.epochId]
        while let x = stack.popLast() { reached += 1; stack += children[x] ?? [] ; if reached > byId.count { break } }
        guard reached == byId.count else { throw ForkError.detached }

        var subtreeCache: [Data: [Data]] = [:]
        func subtree(_ id: Data) -> [Data] {
            if let s = subtreeCache[id] { return s }
            var out = [id]
            for c in children[id] ?? [] { out += subtree(c) }
            subtreeCache[id] = out
            return out
        }
        func removed(_ id: Data) -> Set<Data> {
            subtree(id).reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.removals ?? []) }
        }
        func author(_ id: Data) -> Data { byId[id]?.author ?? Data() }
        func hasDescendants(_ id: Data) -> Bool { !(children[id] ?? []).isEmpty }
        func precedes(_ a: Data, _ b: Data) -> Bool { a.lexicographicallyPrecedes(b) }

        var losses: [ForkLoss] = []
        var reapplyFrom: Set<Data> = []
        var contradictions: [ForkContradiction] = []
        var question: ForkQuestion?

        // Resolve epochs anywhere in the tree, for context and contradictions.
        let resolves = byId.values.filter { $0.reason == .resolve && $0.rejected != nil }
        for r in resolves {
            guard let rej = r.rejected, !context.rejectedAuthors.isEmpty else { continue }
            if !context.rejectedAuthors.contains(rej) {
                contradictions.append(ForkContradiction(resolveEpoch: r.epochId, rejected: rej))
            }
        }

        /// Rule 2 between `a` and `b` (both authors removed by the other side): the winner, or nil
        /// when the user must answer.
        func mutual(_ a: Data, _ b: Data) -> Data? {
            let authors = [author(a), author(b)]
            if context.rejectedAuthors.contains(authors[0]) && !context.rejectedAuthors.contains(authors[1]) { return b }
            if context.rejectedAuthors.contains(authors[1]) && !context.rejectedAuthors.contains(authors[0]) { return a }
            guard let me = context.me, authors.contains(me) else { return nil }
            // An author follows a binding resolve epoch: written on either side by a device that is
            // neither author and whose addedBy chain passes through neither.
            let binding = (subtree(a) + subtree(b)).compactMap { byId[$0] }.filter { r in
                guard r.reason == .resolve, let rej = r.rejected, authors.contains(rej),
                      !authors.contains(r.author) else { return false }
                return !(context.approverChains[r.author] ?? []).contains { authors.contains($0) }
            }.sorted { precedes($0.epochId, $1.epochId) }
            if let r = binding.first, let rej = r.rejected { return rej == authors[0] ? b : a }
            // Until then each author keeps its own side.
            return me == authors[0] ? a : b
        }

        var cur = root.epochId
        var kept = [cur]
        walk: while true {
            let kids = (children[cur] ?? []).sorted(by: precedes)
            if kids.isEmpty { break }
            if kids.count == 1 { cur = kids[0]; kept.append(cur); continue }
            let removedBy = Dictionary(uniqueKeysWithValues: kids.map { ($0, removed($0)) })
            // Stored answers: a rejected author's side loses at every branch (rule 2, answered).
            var remaining = kids
            if !context.rejectedAuthors.isEmpty {
                let keep = remaining.filter { !context.rejectedAuthors.contains(author($0)) }
                if !keep.isEmpty {
                    for c in remaining where !keep.contains(c) {
                        losses.append(ForkLoss(child: c, to: keep[0], rule: .mutualAnswered))
                    }
                    remaining = keep
                }
            }
            // Pre-pass: rule 1 against every sibling, unless the pair is mutual. A sibling that is
            // itself removed one-sidedly by another does not discard anyone in that round (three
            // children: X's fork removes B, the real side removes X; X's fork goes first, and B's
            // side then stays to be compared and re-applied). Repeated until nothing changes.
            func dominates(_ d: Data, _ c: Data) -> Bool {
                d != c && removedBy[d, default: []].contains(author(c)) && !removedBy[c, default: []].contains(author(d))
            }
            while true {
                let undominated = remaining.filter { d in !remaining.contains { dominates($0, d) } }
                var round: [(Data, Data)] = []
                for c in remaining {
                    if let d = undominated.first(where: { dominates($0, c) }) { round.append((c, d)) }
                }
                if round.isEmpty || round.count == remaining.count { break }
                for (c, d) in round { losses.append(ForkLoss(child: c, to: d, rule: .removedAuthor)) }
                let gone = Set(round.map(\.0))
                remaining = remaining.filter { !gone.contains($0) }
            }
            // Pairs in epochId order.
            var winner = remaining[0]
            for next in remaining.dropFirst() {
                let aRemovesB = removedBy[winner, default: []].contains(author(next))
                let bRemovesA = removedBy[next, default: []].contains(author(winner))
                var rule: ForkRule
                var newWinner: Data
                if bRemovesA && !aRemovesB {
                    rule = .removedAuthor; newWinner = next
                } else if aRemovesB && !bRemovesA {
                    rule = .removedAuthor; newWinner = winner
                } else if aRemovesB && bRemovesA {
                    guard let w = mutual(winner, next) else {
                        let sides = [winner, next]
                        var asked = byId[cur]?.list ?? []
                        for s in sides { for x in subtree(s) { asked.formUnion(byId[x]?.list ?? []) } }
                        asked.subtract(sides.map(author))
                        asked.subtract(context.recoveryKeys)
                        var seen: [Data: Data] = [:]
                        for s in sides {
                            for x in subtree(s) {
                                if let r = byId[x], r.reason == .resolve, let rej = r.rejected { seen[x] = rej }
                            }
                        }
                        question = ForkQuestion(branch: cur, sides: sides, authors: sides.map(author),
                                                removals: sides.map { removedBy[$0, default: []] }, asked: asked,
                                                resolves: seen)
                        break walk
                    }
                    rule = .mutualAnswered; newWinner = w
                } else if hasDescendants(winner) != hasDescendants(next) {
                    rule = .stale; newWinner = hasDescendants(winner) ? winner : next
                } else {
                    rule = .epochIdOrder; newWinner = precedes(winner, next) ? winner : next
                }
                let loser = newWinner == winner ? next : winner
                losses.append(ForkLoss(child: loser, to: newWinner, rule: rule))
                if rule.reapplies { reapplyFrom.formUnion(removedBy[loser, default: []]) }
                winner = newWinner
            }
            cur = winner
            kept.append(cur)
        }
        let end = byId[kept[kept.count - 1]]?.list ?? []
        let reapply = reapplyFrom.intersection(end).subtracting(context.recoveryKeys)
        return ForkResolution(keptChain: kept, losses: losses, reapply: reapply, question: question,
                              contradictions: contradictions)
    }
}
