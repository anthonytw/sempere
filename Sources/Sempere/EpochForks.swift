import Foundation

// Fork resolution: the simple rule (docs/design/key-hierarchy.md §5.6; format.md
// §15.9), adopted after five review rounds of automatic rules. A device never
// decides between two changes by itself:
//
// 1. It follows only epochs that extend its chain linearly: the one child of
//    its chain's end whose author is listed there and is neither removed on
//    its chain nor rejected.
// 2. At a branch (more than one such child of an epoch on or after its pin) it
//    asks, per side, "Did you make this change?" about each author of the
//    side's continuation. Yes: the author's removals there are re-applied in
//    the device's resolve epoch. No: the author is rejected everywhere.
// 3. The answer is stored, and the device writes a resolve epoch on the chosen
//    side (amendment 2: the re-applied removals and the rejected authors prune
//    the chosen side's continuation, except an author's epochs from before its
//    removal further down that side).
// 4. It follows another device's resolve epoch only when the resolve's path
//    leaves its chain at a branch on its chain, below the branch's child (a
//    resolve that is itself a child of the branch answered nothing there); the
//    resolver is not rejected, not removed on the device's own side, not removed
//    by an epoch that counts (one on the device's chain, or by an author that
//    chain does not remove and the user did not reject), and was not added by a
//    removed or rejected device; every author of an epoch on that path not
//    already on the device's chain is not rejected and is removed only further
//    down the path; and no other such resolve leaves for another side. A resolve
//    that passes the first checks but not the path check makes its side part of
//    a question, also after an answer (the user may change the choice).
// 5. An unpinned device (a kit joiner) starts at epoch 1 and asks at every
//    branch it meets that no resolve settles.
// 6. Epochs by devices its chain removed, or that its user rejected, are
//    ignored entirely.
// 7. Questions about a branch on its pinned chain do not stop it from following
//    its pin's linear extensions (amendment 4).
//
// There is no fixed point, no labelling and no tie-break: only linear following,
// answers and resolve epochs.

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
    /// For a `resolve` epoch: an author its writer rejected, if any (covered by `epochSig`).
    public var rejected: Data?

    public init(epochId: Data, parent: Data?, author: Data, removals: Set<Data>, list: Set<Data>, reason: EpochReason,
                recovery: Data? = nil, rejected: Data? = nil) {
        self.epochId = epochId; self.parent = parent; self.author = author; self.removals = removals
        self.list = list; self.reason = reason; self.recovery = recovery; self.rejected = rejected
    }
}

/// The user's answer at one branch (stored in the trust record, design §5.6).
public struct ForkAnswer: Hashable, Sendable {
    /// The epoch with several children.
    public var branch: Data
    /// The child the device continues on.
    public var chosen: Data
    /// Authors the user said "yes" to: their removals on the other sides are re-applied.
    public var confirmed: Set<Data>
    /// Authors the user said "no" to: rejected everywhere.
    public var rejected: Set<Data>

    public init(branch: Data, chosen: Data, confirmed: Set<Data> = [], rejected: Set<Data> = []) {
        self.branch = branch; self.chosen = chosen; self.confirmed = confirmed; self.rejected = rejected
    }
}

/// What the device brings to resolution besides the tree.
public struct ForkContext: Sendable {
    /// This device's fingerprint (nil: a reader that is no device, e.g. the CLI with the recovery key).
    public var me: Data?
    /// The device's pinned chain (epoch ids from epoch 1), from its trust record; empty for a joining
    /// device (it starts at epoch 1, which its root vouches for).
    public var pinned: [Data]
    /// The user's answers, from the trust record.
    public var answers: [ForkAnswer]
    /// Authors rejected otherwise (the union of the answers' is added).
    public var rejectedAuthors: Set<Data>
    /// The `addedBy` chain of each device (`EpochChain.Verified.approverChain`): a resolve epoch by a
    /// device that a removed or rejected device added is never followed (rule 4).
    public var approverChains: [Data: [Data]]
    /// Test-only mutations (`EpochForkPropertyTests`): the property test must fail with each.
    var mutations: Set<ForkMutation> = []

    public init(me: Data? = nil, pinned: [Data] = [], answers: [ForkAnswer] = [], rejectedAuthors: Set<Data> = [],
                approverChains: [Data: [Data]] = [:]) {
        self.me = me; self.pinned = pinned; self.answers = answers; self.rejectedAuthors = rejectedAuthors
        self.approverChains = approverChains
    }
}

/// Test-only switches that break one safeguard each.
enum ForkMutation: Hashable, Sendable {
    /// Rule 6 off: epochs by removed or rejected authors are followed like any other.
    case ruleSixOff
    /// At a branch the smallest child is followed without asking.
    case siblingsFollowedAutomatically
    /// Resolve epochs followed without checking their authors.
    case resolvesWithoutAuthorCheck
    /// "No" answers do not reject the author.
    case noAnswersDoNotReject
    /// The chosen side's continuation is not pruned by the re-applied removals (amendment 2).
    case noReapplyPruning
}

/// One side of a branch, as the question shows it.
public struct ForkSide: Hashable, Sendable {
    /// The child at the branch.
    public var child: Data
    /// Its continuation (the child and its descendants that rule 6 does not drop), parents first.
    public var epochs: [Data]
    /// The authors of the continuation the user has not answered for yet, in order of appearance.
    public var authors: [Data]
    /// What the continuation removed.
    public var removals: Set<Data>
}

/// A branch the device cannot settle by itself: "Did you make this change?" per side.
public struct ForkQuestion: Hashable, Sendable {
    /// The epoch with several children: names come from its list.
    public var branch: Data
    /// Every side, in `epochId` order.
    public var sides: [ForkSide]
    /// The child on this device's chain, if the branch is on it.
    public var current: Data?
    /// The suggested default: the side on which more devices continued (distinct authors listed at the
    /// branch and not rejected), then the smaller id; so that devices answered at the same time agree.
    public var suggested: Data
    /// Resolve epochs that leave at this branch for different sides (rule 4(c)).
    public var conflictingResolves: [Data]
}

/// The outcome of resolution.
public struct ForkResolution: Hashable, Sendable {
    /// The device's chain from epoch 1.
    public var keptChain: [Data]
    /// Open questions, in chain order. A question at the chain's end stops it there (a joiner then has
    /// no key and waits); one at an earlier branch does not (amendment 4).
    public var questions: [ForkQuestion]
    /// The branches this device answered and still has to settle with a resolve epoch of its own.
    public var resolveFor: [Data]
    /// The removals that resolve epoch carries (re-application), never a recovery key.
    public var reapply: Set<Data>
    /// The resolve epochs followed (rule 4).
    public var followed: [Data]

    /// The first open question (compatibility with callers that show one at a time).
    public var question: ForkQuestion? { questions.first }
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
        // The tree.
        var byId: [Data: ForkNode] = [:]
        for n in nodes { byId[n.epochId] = n }
        let roots = byId.values.filter { $0.parent == nil }
        guard roots.count == 1, let root = roots.first?.epochId else { throw ForkError.noRoot }
        var children: [Data: [Data]] = [:]
        for n in byId.values {
            guard let p = n.parent else { continue }
            guard byId[p] != nil else { throw ForkError.detached }
            children[p, default: []].append(n.epochId)
        }
        for k in children.keys { children[k]?.sort { $0.lexicographicallyPrecedes($1) } }
        var reached = 0
        var stack = [root]
        while let x = stack.popLast(), reached <= byId.count { reached += 1; stack += children[x] ?? [] }
        guard reached == byId.count else { throw ForkError.detached }
        func node(_ id: Data) -> ForkNode? { byId[id] }
        func author(_ id: Data) -> Data { byId[id]?.author ?? Data() }
        func path(_ id: Data) -> [Data] {
            var out = [id]
            var cur = byId[id]?.parent
            while let c = cur { out.append(c); cur = byId[c]?.parent }
            return out.reversed()
        }
        let recoveryKeys = Set(byId.values.compactMap(\.recovery))
        var removers: [Data: [Data]] = [:]
        for n in byId.values { for r in n.removals { removers[r, default: []].append(n.epochId) } }
        let mut = context.mutations

        // The pinned chain: from epoch 1, each the previous one's child.
        var chain: [Data] = [root]
        for id in context.pinned.dropFirst() where context.pinned.first == root {
            guard byId[id]?.parent == chain.last else { break }
            chain.append(id)
        }
        let answers = Dictionary(context.answers.map { ($0.branch, $0) }, uniquingKeysWith: { a, _ in a })
        var rejected = context.rejectedAuthors
        if !mut.contains(.noAnswersDoNotReject) { for a in context.answers { rejected.formUnion(a.rejected) } }

        // A rejection never drops a rejected author's legitimate history, and amendment 2 never prunes a
        // re-applied author's: an epoch is **from before its author's removal** when an epoch below it
        // removes its author and is by an author not rejected, or is itself a rejected author's epoch
        // kept this way. Such an epoch by a rejected author stays admissible (`protected`); any such
        // epoch is exempt from pruning (`preRemoval`). One pass from the leaves up, each subtree's set
        // of authors removed below it (by epochs that count) merged into its parent's and then dropped,
        // so the work is linear in the tree and the lists.
        var protected: Set<Data> = []
        var preRemoval: Set<Data> = []
        var order: [Data] = []
        var pending = [root]
        while let x = pending.popLast() { order.append(x); pending += children[x] ?? [] }
        var removedBelow: [Data: Set<Data>] = [:]
        for id in order.reversed() {
            var below: Set<Data> = []
            for c in children[id] ?? [] {
                if let cs = removedBelow.removeValue(forKey: c) { below.formUnion(cs) }
                if !rejected.contains(author(c)) || protected.contains(c) { below.formUnion(byId[c]?.removals ?? []) }
            }
            if below.contains(author(id)) {
                preRemoval.insert(id)
                if rejected.contains(author(id)) { protected.insert(id) }
            }
            removedBelow[id] = below
        }
        func removedOn(_ c: [Data]) -> Set<Data> { c.dropFirst().reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.removals ?? []) } }
        /// Rule 6 (and 1): may `child` of `parent` be followed or shown, given the chain's removals?
        func admissible(_ child: Data, under parent: Data, removed: Set<Data>, pruned: Set<Data>) -> Bool {
            let a = author(child)
            if mut.contains(.ruleSixOff) { return byId[parent]?.list.contains(a) ?? false }
            if protected.contains(child) { return byId[parent]?.list.contains(a) ?? false }
            return (byId[parent]?.list.contains(a) ?? false) && !removed.contains(a) && !rejected.contains(a)
                && (!pruned.contains(a) || preRemoval.contains(child))
        }
        /// A side's continuation: the child and its descendants, dropping epochs (and their subtrees)
        /// whose author rule 6 drops, or that the continuation itself removed.
        func continuation(_ child: Data, removed: Set<Data>) -> [Data] {
            var out: [Data] = []
            func walk(_ id: Data, _ removedHere: Set<Data>) {
                out.append(id)
                let r = removedHere.union(byId[id]?.removals ?? [])
                for c in children[id] ?? [] where admissible(c, under: id, removed: r, pruned: []) { walk(c, r) }
            }
            walk(child, removed)
            return out
        }

        var questions: [ForkQuestion] = []
        var followed: [Data] = []
        var answeredBranches: [Data] = []
        var reapplyFrom: Set<Data> = []

        /// The question at `branch` for `sides`, or nil when every side is answered.
        func question(at branch: Data, sides: [Data], current: Data?, removed: Set<Data>,
                      conflicts: [Data]) -> ForkQuestion? {
            let answer = answers[branch]
            var out: [ForkSide] = []
            var open = answer == nil && current == nil
            for c in sides {
                let epochs = continuation(c, removed: removed)
                var authors: [Data] = []
                for e in epochs where !authors.contains(author(e)) { authors.append(author(e)) }
                let isOwn = c == current
                let unanswered = authors.filter { a in
                    !(answer?.confirmed.contains(a) ?? false) && !(answer?.rejected.contains(a) ?? false) && !rejected.contains(a)
                }
                if !isOwn && !unanswered.isEmpty { open = true }
                out.append(ForkSide(child: c, epochs: epochs, authors: isOwn ? [] : unanswered,
                                    removals: epochs.reduce(into: Set<Data>()) { $0.formUnion(byId[$1]?.removals ?? []) }))
            }
            guard open || !conflicts.isEmpty else { return nil }
            let listed = byId[branch]?.list ?? []
            let suggested = out.max { a, b in
                let ca = Set(a.epochs.map(author)).intersection(listed).subtracting(rejected).count
                let cb = Set(b.epochs.map(author)).intersection(listed).subtracting(rejected).count
                return ca != cb ? ca < cb : !a.child.lexicographicallyPrecedes(b.child)
            }?.child ?? sides[0]
            return ForkQuestion(branch: branch, sides: out, current: current, suggested: suggested,
                                conflictingResolves: conflicts)
        }

        /// Rule 4: resolve epochs below branch `chain[k]` (their path shares chain[0...k] and then goes
        /// through a child of it), by a resolver this device can take at its word: not rejected, not
        /// removed by an epoch on this device's chain or by one whose author that chain does not remove
        /// and this device does not reject, and not added
        /// (`addedBy` chain) by a device that anything removed or that is rejected (no puppet). With
        /// `followable`, also: the resolver is not removed on this device's own side (rule 4(a)), and
        /// every author of an epoch on the path below the branch that is not already on this device's
        /// chain is not rejected and is removed (by an epoch that counts) only further down that path
        /// (a device's epoch from before its removal, even if this device's stale side removed it too;
        /// a removed device's fork is not followed this way).
        /// A resolve that is visible but not followable makes its side part of a question instead.
        /// A resolve settles only branches above its own parent: one that is itself a child of the branch
        /// answered nothing there (a device that answered writes below the side it chose), so an
        /// attacker's resolve as a sibling never silences the question of a device pinned through it.
        func resolves(at k: Int, chain: [Data], followable: Bool) -> [Data] {
            let removedHere = removedOn(chain)
            let onChain = Set(chain)
            // A removal counts when it is on this device's chain, or its author is neither removed on
            // that chain nor rejected (a removed device's attack does not void others' resolves).
            func counting(_ a: Data) -> [Data] {
                removers[a, default: []].filter {
                    onChain.contains($0) || (!removedHere.contains(author($0)) && !rejected.contains(author($0)))
                }
            }
            return byId.values.filter { $0.reason == .resolve }.map(\.epochId).sorted { $0.lexicographicallyPrecedes($1) }.filter { r in
                let p = path(r)
                guard p.count > k + 2, Array(p.prefix(k + 1)) == Array(chain.prefix(k + 1)) else { return false }
                if mut.contains(.resolvesWithoutAuthorCheck) { return true }
                let resolver = author(r)
                if !counting(resolver).isEmpty || rejected.contains(resolver) { return false }
                if (context.approverChains[resolver] ?? []).contains(where: { !removers[$0, default: []].isEmpty || rejected.contains($0) }) {
                    return false
                }
                guard followable else { return true }
                let onPath = Set(p)
                let removedOnMySide = removedOn([chain[0]] + chain.filter { !onPath.contains($0) })
                if removedOnMySide.contains(resolver) { return false }
                for i in (k + 1)..<p.count where !onChain.contains(p[i]) {
                    let a = author(p[i])
                    if rejected.contains(a) { return false }
                    let below = Set(p[(i + 1)...])
                    let rs = counting(a)
                    if !rs.isEmpty && !rs.contains(where: { below.contains($0) }) { return false }
                }
                return true
            }
        }

        /// The decision at a branch with children `sides` (the chain's child there is `current`), when the
        /// user has not answered there: a resolve to follow, or a question.
        enum Decision { case stay, take(Data), follow(Data), ask(ForkQuestion) }
        func decide(at k: Int, chain: [Data], sides: [Data], current: Data?, removed: Set<Data>) -> Decision {
            let branch = chain[k]
            if mut.contains(.siblingsFollowedAutomatically) { return current == nil ? .take(sides[0]) : .stay }
            let found = resolves(at: k, chain: chain, followable: true).filter { sides.contains(path($0)[k + 1]) }
            let directions = Set(found.map { path($0)[k + 1] })
            if directions.count == 1, let direction = directions.first {
                // Settled by resolve epochs for one side: on this device's own side nothing changes (the
                // walk reaches them linearly); otherwise follow the deepest one's path.
                if direction == current { return .stay }
                let deepest = found.max { path($0).count < path($1).count } ?? direction
                return .follow(deepest)
            }
            if let q = question(at: branch, sides: sides, current: current, removed: removed,
                                conflicts: directions.count > 1 ? found : []) {
                return .ask(q)
            }
            return .stay
        }

        /// The user's answer at `chain[k]`: recorded (its "yes" removals re-applied), and its chosen child
        /// returned; a question too when authors on the other sides are still unanswered.
        func applyAnswer(at k: Int, chain: [Data], removed: Set<Data>) -> Data? {
            let branch = chain[k]
            guard let answer = answers[branch], (children[branch] ?? []).contains(answer.chosen) else { return nil }
            // A side that a resolve vouches for after the answer (hidden by rule 6 when it was given) is
            // asked about too: the user may change the choice.
            let vouched = Set(resolves(at: k, chain: chain, followable: false).map { path($0)[k + 1] })
            let others = (children[branch] ?? []).filter {
                $0 != answer.chosen && (vouched.contains($0) || admissible($0, under: branch, removed: removed, pruned: []))
            }
            if let q = question(at: branch, sides: [answer.chosen] + others, current: answer.chosen, removed: removed, conflicts: []) {
                questions.append(q)
            }
            answeredBranches.append(branch)
            for side in others {
                for e in continuation(side, removed: removed) where answer.confirmed.contains(author(e)) {
                    reapplyFrom.formUnion(byId[e]?.removals ?? [])
                }
            }
            return answer.chosen
        }

        // The pinned chain: its branches' foreign sides (amendment 4: questions there do not stop the walk).
        var k = 0
        var blocked = false
        while k < chain.count - 1 {
            let removed = removedOn(chain)
            if let chosen = applyAnswer(at: k, chain: chain, removed: removed) {
                if chosen != chain[k + 1] { chain = Array(chain.prefix(k + 1)) + [chosen] }
            } else {
                let vouched = Set(resolves(at: k, chain: chain, followable: false).map { path($0)[k + 1] })
                let sides = (children[chain[k]] ?? []).filter {
                    $0 == chain[k + 1] || vouched.contains($0) || admissible($0, under: chain[k], removed: removed, pruned: [])
                }
                if sides.count > 1 {
                    switch decide(at: k, chain: chain, sides: sides, current: chain[k + 1], removed: removed) {
                    case .stay: break
                    case .take(let c): chain = Array(chain.prefix(k + 1)) + [c]
                    case .follow(let r): followed.append(r); chain = path(r)
                    case .ask(let q): questions.append(q)
                    }
                }
            }
            k += 1
        }
        // Linear extension of the chain's end.
        while !blocked {
            let end = chain[chain.count - 1]
            let removed = removedOn(chain)
            if let chosen = applyAnswer(at: chain.count - 1, chain: chain, removed: removed) {
                chain.append(chosen); continue
            }
            let pruned = mut.contains(.noReapplyPruning) ? Set<Data>() : reapplyFrom
            let vouched = Set(resolves(at: chain.count - 1, chain: chain, followable: false).map { path($0)[chain.count] })
            let sides = (children[end] ?? []).filter { vouched.contains($0) || admissible($0, under: end, removed: removed, pruned: pruned) }
            if sides.isEmpty { break }
            if sides.count == 1 { chain.append(sides[0]); continue }
            switch decide(at: chain.count - 1, chain: chain, sides: sides, current: nil, removed: removed) {
            case .stay: blocked = true
            case .take(let c): chain.append(c)
            case .follow(let r): followed.append(r); chain = path(r)
            case .ask(let q): questions.append(q); blocked = true
            }
        }
        // The resolve this device owes: answered branches not already settled by a resolve epoch below
        // them on its chain.
        let resolveFor = answeredBranches.filter { b in
            guard let i = chain.firstIndex(of: b) else { return false }
            return !chain[(i + 1)...].contains { byId[$0]?.reason == .resolve && byId[$0]?.author == context.me }
        }
        let endList = byId[chain[chain.count - 1]]?.list ?? []
        let reapply = resolveFor.isEmpty ? [] : reapplyFrom.intersection(endList).subtracting(recoveryKeys)
        return ForkResolution(keptChain: chain, questions: questions, resolveFor: resolveFor, reapply: reapply,
                              followed: followed)
    }
}
