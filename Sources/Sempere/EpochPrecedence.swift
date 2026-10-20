import Foundation

// Which epoch a device follows when it has seen more than one child of an
// epoch (docs/design/key-hierarchy.md §5.6; format.md §15.9): the single-writer
// precedence rule. Only the home device signs epochs, so there is no fork to
// resolve and nothing to ask:
//
// 1. A device follows epochs that extend its chain linearly and are signed by
//    the home of their parent (handing off names a new home).
// 2. A takeover (signed by the recovery key and by its new home) beats every
//    home-signed epoch that is not among its own ancestors: the device switches
//    to it and drops the home-signed epochs after its parent.
// 3. Of two takeovers that are not ancestors of each other (both the user's),
//    the one with the smaller epochId wins.
// 4. Any other epoch is ignored with everything below it.
//
// If the home key itself signed two children of one epoch (it was copied or
// stolen, or a former home signs under an epoch where it was home), the device
// stays on the one its pinned chain holds, or on the one the user picks, and
// otherwise stops there until a takeover settles it. Pure function.
//
// A malformed epoch 1 yields an empty chain with every epoch ignored: callers
// treat that as tampering, never as an empty vault.

/// The takeover rules shared by the chain check, `vault.json`'s check and the precedence rule (design
/// §5.6), so each is stated once.
public enum TakeoverRule {
    /// One epoch of a verifier's pinned chain: its id and recovery fingerprint.
    public struct PinnedEpoch: Hashable, Sendable {
        public var epochId: Data
        public var recovery: Data
        public init(epochId: Data, recovery: Data) { self.epochId = epochId; self.recovery = recovery }
    }

    /// The recovery key (its fingerprint) a takeover under `parent` must be signed by, for a verifier
    /// whose pinned chain is `pinned` (owner decision, round 7 C1): the recovery key **current at the
    /// verifier's pinned frontier**. That is the parent's recovery key, unless the verifier's pinned chain
    /// replaced it after the point where the takeover's ancestry (`parentPath`, from epoch 1) leaves the
    /// pinned chain: then nil, and no takeover there is valid. A kit's retirement is final for every
    /// device that has seen it; a device that has not (unpinned, or pinned before it) still takes an
    /// old kit's takeover (design §5.6 residual). This is the one place the rule is decided.
    public static func recoveryKey(parentRecovery: Data, parentPath: [Data] = [], pinned: [PinnedEpoch] = []) -> Data? {
        guard let frontier = pinned.last else { return parentRecovery }
        var common = 0
        while common < min(parentPath.count, pinned.count), parentPath[common] == pinned[common].epochId { common += 1 }
        // The takeover's ancestry leaves the pinned chain after `common` shared epochs (none shared: a
        // different vault; refuse).
        guard common > 0 else { return nil }
        let meeting = pinned[common - 1]
        if common == pinned.count { return parentRecovery }   // the parent is on or below the frontier
        return frontier.recovery == meeting.recovery ? parentRecovery : nil
    }

    /// May a takeover list `list` with new home `home`, under a parent whose ancestry (the parent
    /// included) listed `ancestorLists`? Only the new home is new; every other device must have been
    /// on a list of the takeover's own ancestry (round 7, M2: the user may re-admit a device a stolen
    /// home removed; the takeover screen leaves it unchecked by default).
    public static func listAllowed(_ list: Set<Data>, home: Data, ancestorLists: Set<Data>) -> Bool {
        list.subtracting([home]).isSubset(of: ancestorLists)
    }
}

/// One epoch as the precedence rule sees it, its signatures already verified (design §4.3).
public struct EpochNode: Hashable, Sendable {
    public var epochId: Data
    /// The parent's `epochId`; nil for epoch 1.
    public var parent: Data?
    /// The device whose `epochSig` verified (for a takeover, the new home).
    public var signer: Data
    public var reason: EpochReason
    /// The home device after this epoch.
    public var home: Data
    /// The epoch's list (first list plus admitted additions).
    public var list: Set<Data>
    /// The recovery fingerprint of this epoch.
    public var recovery: Data
    /// For a takeover: the recovery fingerprint whose signing keys its `recoverySig` verified under
    /// (nil when it did not verify).
    public var recoverySigner: Data?

    public init(epochId: Data, parent: Data?, signer: Data, reason: EpochReason, home: Data, list: Set<Data>,
                recovery: Data, recoverySigner: Data? = nil) {
        self.epochId = epochId; self.parent = parent; self.signer = signer; self.reason = reason; self.home = home
        self.list = list; self.recovery = recovery; self.recoverySigner = recoverySigner
    }
}

/// Test-only switches that break one safeguard each.
enum PrecedenceMutation: Hashable, Sendable {
    /// A home-signed epoch by any device of the parent's list is accepted.
    case nonHomeSignerAccepted
    /// Takeovers are never followed.
    case takeoverIgnored
    /// After a takeover, the home before it may still sign (as if the takeover had not changed home).
    case olderHomeKept
    /// A home conflict that neither the pin nor the user settles goes to the smaller id.
    case conflictSettledById
    /// A takeover by a kit the verifier's pinned chain retired is accepted.
    case retiredKitAccepted
}

/// Epochs with more than one valid home-signed child and no takeover below (the home key signed twice).
public struct HomeConflict: Hashable, Sendable {
    /// The epoch with the children.
    public var epoch: Data
    /// Its valid children, sorted by id: the branches the takeover screen shows.
    public var children: [Data]
    /// The child followed: the pinned one or the user's pick; nil when the device stopped.
    public var followed: Data?
}

/// The outcome.
public struct PrecedenceResult: Hashable, Sendable {
    /// The device's chain from epoch 1.
    public var keptChain: [Data]
    /// Epochs of the pinned chain that a takeover dropped (home-signed epochs after its parent).
    public var dropped: [Data]
    /// Epochs ignored with their subtrees: not signed by the home of their parent, or a takeover
    /// without the recovery key's signature.
    public var ignored: [Data]
    /// Home conflicts on the way: settled by the pinned chain or the user's pick, or where the device
    /// stopped (then a takeover, or the user's pick, goes on).
    public var homeConflicts: [HomeConflict]
}

/// Why the tree cannot be read.
public enum EpochTreeError: Error, Hashable, Sendable {
    /// Not exactly one epoch without a parent.
    case noRoot
    /// A parent that is not in the tree, or a cycle.
    case detached
}

/// The precedence rule (design §5.6).
public enum EpochPrecedence {
    /// - Parameters:
    ///   - pinned: the device's pinned chain (empty for a joiner).
    ///   - picked: at a home conflict the pin does not settle, the child the user picked (conflict epoch →
    ///     child; round 7, M2). Nothing stores it: once followed, it is on the pinned chain.
    public static func resolve(_ nodes: [EpochNode], pinned: [Data] = [], picked: [Data: Data] = [:]) throws
        -> PrecedenceResult {
        try resolve(nodes, pinned: pinned, picked: picked, mutations: [])
    }

    static func resolve(_ nodes: [EpochNode], pinned: [Data], picked: [Data: Data] = [:],
                        mutations mut: Set<PrecedenceMutation>) throws -> PrecedenceResult {
        var byId: [Data: EpochNode] = [:]
        for n in nodes { byId[n.epochId] = n }
        let roots = byId.values.filter { $0.parent == nil }
        guard roots.count == 1, let root = roots.first?.epochId else { throw EpochTreeError.noRoot }
        var children: [Data: [Data]] = [:]
        for n in byId.values {
            guard let p = n.parent else { continue }
            guard byId[p] != nil else { throw EpochTreeError.detached }
            children[p, default: []].append(n.epochId)
        }
        for k in children.keys { children[k]?.sort { $0.lexicographicallyPrecedes($1) } }
        func path(_ id: Data) -> [Data] {
            var out = [id]
            var cur = byId[id]?.parent
            while let c = cur { out.append(c); cur = byId[c]?.parent }
            return out.reversed()
        }
        // The verifier's pinned chain as far as the tree holds it, with each epoch's recovery key.
        var pinnedEpochs: [TakeoverRule.PinnedEpoch] = []
        for id in pinned {
            guard let n = byId[id], n.parent == pinnedEpochs.last?.epochId else { break }
            pinnedEpochs.append(.init(epochId: id, recovery: n.recovery))
        }

        // The valid tree: from epoch 1 down, each epoch valid under its parent. `homeBefore` is the home
        // in force before the last takeover above (for the `olderHomeKept` mutation only).
        func valid(_ c: EpochNode, under p: EpochNode, olderHome: Data?, ancestorLists: Set<Data>) -> Bool {
            guard c.list.contains(c.home), c.home != c.recovery else { return false }
            if c.reason == .takeover {
                if mut.contains(.takeoverIgnored) { return false }
                let required = mut.contains(.retiredKitAccepted) ? p.recovery
                    : TakeoverRule.recoveryKey(parentRecovery: p.recovery, parentPath: path(p.epochId), pinned: pinnedEpochs)
                return required != nil && c.recoverySigner == required && c.signer == c.home
                    && c.recovery == p.recovery && TakeoverRule.listAllowed(c.list, home: c.home, ancestorLists: ancestorLists)
            }
            let signerOK = c.signer == p.home || (mut.contains(.nonHomeSignerAccepted) && p.list.contains(c.signer))
                || (mut.contains(.olderHomeKept) && olderHome == c.signer)
            guard signerOK, c.reason != .create else { return false }
            if c.reason == .handoff { return c.home != c.signer }
            return c.home == c.signer
        }
        let rootNode = byId[root]
        guard let rootNode, rootNode.reason == .create, rootNode.signer == rootNode.home, rootNode.list.contains(rootNode.home) else {
            return PrecedenceResult(keptChain: [], dropped: pinned, ignored: byId.keys.sorted { $0.lexicographicallyPrecedes($1) },
                                    homeConflicts: [])
        }
        var validSet: Set<Data> = [root]
        var olderHome: [Data: Data?] = [root: nil]
        var lists: [Data: Set<Data>] = [root: rootNode.list]   // the union of the lists of an epoch's ancestry, itself included
        var todo = [root]
        while let x = todo.popLast() {
            guard let p = byId[x] else { continue }
            for c in children[x] ?? [] {
                guard let n = byId[c], valid(n, under: p, olderHome: olderHome[x] ?? nil, ancestorLists: lists[x] ?? []) else {
                    continue
                }
                validSet.insert(c)
                olderHome[c] = n.reason == .takeover ? p.home : olderHome[x] ?? nil
                lists[c] = (lists[x] ?? []).union(n.list)
                todo.append(c)
            }
        }
        let ignored = byId.keys.filter { !validSet.contains($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        func validChildren(_ x: Data) -> [Data] { (children[x] ?? []).filter { validSet.contains($0) } }
        /// The takeovers below `x` with no takeover between `x` and them.
        func topTakeovers(below x: Data) -> [Data] {
            var out: [Data] = []
            var stack = validChildren(x)
            while let c = stack.popLast() {
                if byId[c]?.reason == .takeover { out.append(c) } else { stack += validChildren(c) }
            }
            return out
        }

        // The pinned chain as far as it stays valid.
        var pin: [Data] = []
        if pinned.first == root {
            for (i, id) in pinned.enumerated() {
                guard validSet.contains(id), i == 0 || byId[id]?.parent == pin.last else { break }
                pin.append(id)
            }
        }
        let pinSet = Set(pin)

        var chain: [Data] = [root]
        var conflicts: [HomeConflict] = []
        while let x = chain.last {
            let takeovers = topTakeovers(below: x)
            if let t = takeovers.min(by: { $0.lexicographicallyPrecedes($1) }) {
                let p = path(t)
                guard let i = p.firstIndex(of: x) else { break }
                chain += p[(i + 1)...]
                continue
            }
            let next = validChildren(x)
            if next.count == 1 { chain.append(next[0]); continue }
            if next.isEmpty { break }
            // The home key signed two children: the pinned chain decides, or the user's pick, or the device
            // stops.
            let choice = next.first(where: { pinSet.contains($0) })
                ?? picked[x].flatMap { next.contains($0) ? $0 : nil }
                ?? (mut.contains(.conflictSettledById) ? next.first : nil)
            conflicts.append(HomeConflict(epoch: x, children: next, followed: choice))
            guard let choice else { break }
            chain.append(choice)
        }
        let kept = Set(chain)
        return PrecedenceResult(keptChain: chain, dropped: pin.filter { !kept.contains($0) }, ignored: ignored,
                                homeConflicts: conflicts)
    }
}

/// The write ledger's rules that depend on the precedence rule (design §5.4, round 7, H1). The ledger
/// itself is KH3's; these are its pure parts.
public enum LedgerRule {
    /// One ledger entry or set-aside file: a path, the SHA-256 of its exact bytes, and the epoch it was
    /// written under.
    public struct FileRef: Hashable, Sendable {
        public var path: String
        public var sha256: Data
        public var epochId: Data

        public init(path: String, sha256: Data, epochId: Data) { self.path = path; self.sha256 = sha256; self.epochId = epochId }
    }

    /// May a ledger entry be pruned because the epoch record `sealer` sealed it? Only when `sealer` is
    /// on the pinned chain and a later pinned epoch sits above it: a takeover that drops the sealer then
    /// leaves the entry in the ledger, so the device re-encrypts its own file instead of stranding it.
    public static func sealIsFinal(sealer: Data, pinned: [Data]) -> Bool {
        guard let i = pinned.firstIndex(of: sealer) else { return false }
        return i + 1 < pinned.count
    }

    /// Repair's "Keep every file from the dropped epochs that this device's ledger wrote": the set-aside
    /// files written under a dropped epoch whose path and bytes this device's ledger holds.
    public static func keepable(setAside: [FileRef], ledger: [FileRef], dropped: Set<Data>) -> [FileRef] {
        let mine = Set(ledger)
        return setAside.filter { dropped.contains($0.epochId) && mine.contains($0) }
    }
}
