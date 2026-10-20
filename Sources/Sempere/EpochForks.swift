import Foundation

// Fork resolution (docs/design/key-hierarchy.md §5.6; format.md §15.9): over
// the tree of every verified epoch a device has seen, find the kept chain
// from epoch 1 down. Pure function: the caller verified every epoch
// (`EpochChain.verify`) before building the tree. Where the structure alone
// cannot tell who is right, the result is a question, never a guess.
//
// 1. Exclusion. Epochs authored by a device that the pinned chain removed,
//    that the user rejected (stored answers), or that a binding resolve epoch
//    rejected, leave the tree with their subtrees, except the pinned chain
//    and the ancestors of an epoch that removes their author (a device's
//    legitimate epochs from before its removal).
// 2. Two sides S and T of a branch are labelled with the grounded semantics
//    of "epoch e removes the author of epoch f on the other side": an epoch
//    is accepted when its parent is accepted (a child's parent, the branch
//    point, is) and every epoch of the other side that removes its author is
//    rejected; rejected when its parent is rejected or an accepted epoch of
//    the other side removes its author; the least fixed point leaves the rest
//    undecided. A child is labelled like any other epoch.
// 3. Undecided epochs are a dispute (rule 2) between their authors: a device
//    among them keeps its own side (it treats the other side's disputed
//    authors as rejected) unless binding resolve epochs disagree; every other
//    device gets a question. Never rule 3 or 4.
// 4. Otherwise: a side whose child is rejected loses (rule 1); then a side
//    without accepted descendants loses (rule 3); then the larger epochId
//    (rule 4). More than two children: a pre-pass discards children that an
//    undominated sibling rejects; the rest go in pairs in epochId order.
// 5. Pruning on the kept prefix, and one re-application of the accepted
//    removals of every side lost by rule 3 or 4 (never a recovery key).

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
    /// For a `resolve` epoch: the author whose side it rejected (covered by `epochSig`).
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
    /// Test-only mutations (`EpochForkPropertyTests`): the property test must fail with each.
    var mutations: Set<ForkMutation> = []

    public init(me: Data? = nil, rejectedAuthors: Set<Data> = [], approverChains: [Data: [Data]] = [:],
                pinned: [Data] = []) {
        self.me = me; self.rejectedAuthors = rejectedAuthors; self.approverChains = approverChains; self.pinned = pinned
    }
}

/// Test-only switches that break one safeguard each.
enum ForkMutation: Hashable, Sendable {
    /// Undecided epochs simply do not count, and the branch goes on by rules 1, 3 and 4.
    case deadlockAsUncounted
    /// Children always count (the first round's fix).
    case childrenAlwaysCount
    /// No exclusion of rejected authors beyond the branch's direct children.
    case noWholesaleExclusion
}

/// How a side was decided at a branch.
public enum ForkRule: String, Hashable, Sendable, Codable {
    /// Rule 1 (also the pre-pass, and exclusion by the pinned chain): an accepted epoch of the other
    /// side removed its author.
    case removedAuthor = "rule1"
    /// Rule 2, decided: its author was rejected (stored answer, binding resolve epoch, or this
    /// device being the other side's disputed author).
    case mutualAnswered = "rule2"
    /// Rule 3: no accepted descendants, against a side with some.
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
    /// The authors of each side's disputed epochs (undecided, and removing or removed by an undecided
    /// epoch of the other side), in the same order: the changes the user is asked about.
    public var disputed: [Set<Data>]
    /// Each side's removals by disputed epochs, in the same order.
    public var removals: [Set<Data>]
    /// Who is asked: every device in P's list or in a list on either side, except the disputed
    /// authors and recovery keys.
    public var asked: Set<Data>
    /// Resolve epochs on either side (shown as context), with the author they rejected.
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
        let tree = try Tree(nodes)
        var contradictions: [ForkContradiction] = []
        var rejected = context.rejectedAuthors
        var askAnyway = false

        // Stored answers against resolve epochs seen.
        if !context.rejectedAuthors.isEmpty {
            for r in tree.sorted where r.reason == .resolve {
                if let rej = r.rejected, !context.rejectedAuthors.contains(rej) {
                    contradictions.append(ForkContradiction(resolveEpoch: r.epochId, rejected: rej))
                }
            }
        }
        // Binding resolve epochs: only for a device in dispute with the rejected author (or rejected
        // itself), written by a device that no epoch removes and whose addedBy chain passes through
        // neither them nor any removed device (so neither party nor a puppet can write one).
        if let me = context.me, context.rejectedAuthors.isEmpty {
            let removedAnywhere = tree.sorted.reduce(into: Set<Data>()) { $0.formUnion($1.removals) }
            func inDispute(_ z: Data) -> Bool {
                tree.sorted.contains { ($0.author == z && $0.removals.contains(me)) || ($0.author == me && $0.removals.contains(z)) }
            }
            let binding = tree.sorted.filter { r in
                guard r.reason == .resolve, let z = r.rejected, r.author != me, r.author != z,
                      !removedAnywhere.contains(r.author), z == me || inDispute(z) else { return false }
                let chain = context.approverChains[r.author] ?? []
                return !chain.contains { $0 == me || $0 == z || removedAnywhere.contains($0) }
            }
            let verdicts = Set(binding.compactMap(\.rejected))
            if verdicts.count > 1 {
                for r in binding { if let z = r.rejected { contradictions.append(ForkContradiction(resolveEpoch: r.epochId, rejected: z)) } }
                askAnyway = true
            } else if let z = verdicts.first {
                rejected.insert(z)
            }
        }
        // Resolve; a device that is itself a disputed author rejects the other side's and starts again.
        for _ in 0...tree.byId.count {
            switch walk(tree, context: context, rejected: rejected, askAnyway: askAnyway) {
            case .done(var result):
                result.contradictions = contradictions
                return result
            case .reject(let authors):
                rejected.formUnion(authors)
            }
        }
        preconditionFailure("each restart rejects at least one more author")
    }

    struct Tree {
        var byId: [Data: ForkNode] = [:]
        var children: [Data: [Data]] = [:]
        var root: Data
        var sorted: [ForkNode]

        init(_ nodes: [ForkNode]) throws {
            for n in nodes { byId[n.epochId] = n }
            let roots = byId.values.filter { $0.parent == nil }
            guard roots.count == 1, let root = roots.first else { throw ForkError.noRoot }
            self.root = root.epochId
            for n in byId.values {
                guard let p = n.parent else { continue }
                guard byId[p] != nil else { throw ForkError.detached }
                children[p, default: []].append(n.epochId)
            }
            for k in children.keys { children[k]?.sort { $0.lexicographicallyPrecedes($1) } }
            var reached = 0
            var stack = [root.epochId]
            while let x = stack.popLast(), reached <= byId.count { reached += 1; stack += children[x] ?? [] }
            guard reached == byId.count else { throw ForkError.detached }
            sorted = byId.values.sorted { $0.epochId.lexicographicallyPrecedes($1.epochId) }
        }

        func ancestors(_ id: Data) -> [Data] {
            var out: [Data] = []
            var cur = byId[id]?.parent
            while let c = cur { out.append(c); cur = byId[c]?.parent }
            return out
        }
    }

    enum Step { case done(ForkResolution), reject(Set<Data>) }

    static func walk(_ tree: Tree, context: ForkContext, rejected: Set<Data>, askAnyway: Bool) -> Step {
        let byId = tree.byId
        func author(_ id: Data) -> Data { byId[id]?.author ?? Data() }
        func precedes(_ a: Data, _ b: Data) -> Bool { a.lexicographicallyPrecedes(b) }
        let recoveryKeys = Set(byId.values.compactMap(\.recovery))

        // 1. Exclusion.
        var pinnedIds: Set<Data> = []
        var removedOnPinned: Set<Data> = []
        var expected: Data? = nil
        for id in context.pinned {
            guard let n = byId[id], n.parent == expected else { break }
            pinnedIds.insert(id); removedOnPinned.formUnion(n.removals); expected = id
        }
        let rejectedNow = context.mutations.contains(.noWholesaleExclusion) ? Set<Data>() : rejected
        let outcast = removedOnPinned.union(rejectedNow)
        // Epochs that are ancestors of an epoch removing their own author stay (legitimate history).
        // Only a removal by a device that is not itself outcast vouches for its ancestors.
        var keep = pinnedIds.union([tree.root])
        for n in tree.sorted where !n.removals.isEmpty && !outcast.contains(n.author) {
            for a in tree.ancestors(n.epochId) where n.removals.contains(author(a)) { keep.insert(a) }
        }
        var excluded: [Data: ForkRule] = [:]
        func exclude(_ id: Data, _ rule: ForkRule) {
            if excluded[id] == nil { excluded[id] = rule }
            for c in tree.children[id] ?? [] { exclude(c, rule) }
        }
        for n in tree.sorted where !keep.contains(n.epochId) && outcast.contains(n.author) {
            exclude(n.epochId, removedOnPinned.contains(n.author) ? .removedAuthor : .mutualAnswered)
        }
        func kids(_ id: Data) -> [Data] { (tree.children[id] ?? []).filter { excluded[$0] == nil } }
        func subtree(_ id: Data) -> [Data] { [id] + kids(id).flatMap(subtree) }

        // 2. Labels of all the siblings of a branch at once: an epoch is attacked by every epoch of
        // another sibling's subtree that removes its author (so a third sibling that removed X
        // discounts X's epochs under the other two).
        struct Labels {
            var sideOf: [Data: Data] = [:]
            var accepted: Set<Data> = []
            var undecided: Set<Data> = []
            /// Undecided epochs that remove the author of, or are removed by, an undecided epoch of another sibling.
            var disputed: Set<Data> = []
        }
        func attacks(_ e: Data, _ f: Data) -> Bool { byId[e]?.removals.contains(author(f)) ?? false }
        func judge(_ siblings: [Data]) -> Labels {
            var l = Labels()
            var all: [Data] = []
            for c in siblings { for x in subtree(c) { l.sideOf[x] = c; all.append(x) } }
            let isChild = Set(siblings)
            var rejectedEpochs: Set<Data> = []
            if context.mutations.contains(.childrenAlwaysCount) { l.accepted = isChild }
            var changed = true
            while changed {
                changed = false
                for f in all where !l.accepted.contains(f) && !rejectedEpochs.contains(f) {
                    let parent = byId[f]?.parent ?? Data()
                    let attackers = all.filter { l.sideOf[$0] != l.sideOf[f] && !rejectedEpochs.contains($0) && attacks($0, f) }
                    if (!isChild.contains(f) && rejectedEpochs.contains(parent)) || attackers.contains(where: l.accepted.contains) {
                        rejectedEpochs.insert(f); changed = true
                    } else if (isChild.contains(f) || l.accepted.contains(parent)) && attackers.isEmpty {
                        l.accepted.insert(f); changed = true
                    }
                }
            }
            l.undecided = Set(all).subtracting(l.accepted).subtracting(rejectedEpochs)
            l.disputed = l.undecided.filter { e in
                l.undecided.contains { l.sideOf[$0] != l.sideOf[e] && (attacks(e, $0) || attacks($0, e)) }
            }
            if context.mutations.contains(.deadlockAsUncounted) { l.undecided = []; l.disputed = [] }
            return l
        }
        func removals(_ ids: Set<Data>) -> Set<Data> { ids.reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.removals ?? []) } }
        func authors(_ ids: Set<Data>) -> Set<Data> { Set(ids.map(author)) }

        var losses: [ForkLoss] = []
        var reapplyFrom: Set<Data> = []
        var cur = tree.root
        var kept = [cur]
        var prefixRemoved: Set<Data> = []
        var question: ForkQuestion?
        walk: while true {
            var candidates: [Data] = []
            var outcastKids: [(Data, ForkRule)] = []
            for c in tree.children[cur] ?? [] {
                if let rule = excluded[c] {
                    outcastKids.append((c, rule))
                } else if prefixRemoved.contains(author(c)) || reapplyFrom.contains(author(c)) {
                    losses.append(ForkLoss(child: c, to: cur, rule: .pruned))
                } else {
                    candidates.append(c)
                }
            }
            if candidates.isEmpty {
                for (c, rule) in outcastKids { losses.append(ForkLoss(child: c, to: cur, rule: rule)) }
                break
            }
            let l = judge(candidates)
            if !l.undecided.isEmpty {
                // A dispute (rule 2). A device among the disputed authors keeps its own side: it rejects
                // the authors of the epochs that dispute its own, and starts again. Everyone else is asked.
                if let me = context.me, !askAnyway {
                    let mine = l.disputed.filter { author($0) == me }
                    let opponents = Set(l.disputed.filter { e in
                        mine.contains { l.sideOf[$0] != l.sideOf[e] && (attacks($0, e) || attacks(e, $0)) }
                    }.map(author)).subtracting([me]).subtracting(rejected)
                    if !opponents.isEmpty { return .reject(opponents) }
                }
                let sides = candidates.filter { c in l.disputed.contains { l.sideOf[$0] == c } }
                let disputedBySide = sides.map { c in l.disputed.filter { l.sideOf[$0] == c } }
                var asked = byId[cur]?.list ?? []
                for c in sides { for x in subtree(c) { asked.formUnion(byId[x]?.list ?? []) } }
                asked.subtract(authors(l.disputed)); asked.subtract(recoveryKeys)
                var seen: [Data: Data] = [:]
                for c in sides {
                    for x in subtree(c) { if let r = byId[x], r.reason == .resolve, let rej = r.rejected { seen[x] = rej } }
                }
                question = ForkQuestion(branch: cur, sides: sides, authors: sides.map(author),
                                        disputed: disputedBySide.map(authors), removals: disputedBySide.map(removals),
                                        asked: asked, resolves: seen)
                break walk
            }
            // Rule 1: a child that an accepted epoch of another sibling removed loses.
            var remaining: [Data] = []
            for c in candidates {
                if l.accepted.contains(c) {
                    remaining.append(c)
                } else {
                    let by = candidates.first { d in l.accepted.contains(d) && subtree(d).contains { l.accepted.contains($0) && attacks($0, c) } }
                    losses.append(ForkLoss(child: c, to: by ?? cur, rule: .removedAuthor))
                }
            }
            guard !remaining.isEmpty else { break walk }
            // Rules 3 and 4, in pairs in epochId order. A sibling whose author is about to be
            // re-applied (removed by a side that lost by rule 3 or 4) goes too.
            func accepted(_ c: Data) -> Set<Data> { Set(subtree(c)).intersection(l.accepted) }
            var winner = remaining[0]
            for next in remaining.dropFirst() {
                if reapplyFrom.contains(author(next)) {
                    losses.append(ForkLoss(child: next, to: winner, rule: .pruned)); continue
                }
                let (a, b) = (accepted(winner), accepted(next))
                let rule: ForkRule
                let newWinner: Data
                if (a.count > 1) != (b.count > 1) {
                    rule = .stale; newWinner = a.count > 1 ? winner : next
                } else {
                    rule = .epochIdOrder; newWinner = precedes(winner, next) ? winner : next
                }
                let loser = newWinner == winner ? next : winner
                losses.append(ForkLoss(child: loser, to: newWinner, rule: rule))
                reapplyFrom.formUnion(removals(loser == winner ? a : b))
                winner = newWinner
            }
            if reapplyFrom.contains(author(winner)) {
                losses.append(ForkLoss(child: winner, to: cur, rule: .pruned))
                break walk
            }
            for (c, rule) in outcastKids { losses.append(ForkLoss(child: c, to: winner, rule: rule)) }
            cur = winner
            kept.append(cur)
            prefixRemoved.formUnion(byId[cur]?.removals ?? [])
        }
        let end = byId[kept[kept.count - 1]]?.list ?? []
        let reapply = question == nil ? reapplyFrom.intersection(end).subtracting(recoveryKeys) : []
        return .done(ForkResolution(keptChain: kept, losses: losses, reapply: reapply, question: question, contradictions: []))
    }
}
