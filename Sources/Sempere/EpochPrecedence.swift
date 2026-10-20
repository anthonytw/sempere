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
// stolen), the device stays on the one its pinned chain holds, and otherwise
// stops there until a takeover settles it. Pure function.

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
    /// For a takeover: its `recoverySig` verified under the parent's recovery key.
    public var recoverySigned: Bool

    public init(epochId: Data, parent: Data?, signer: Data, reason: EpochReason, home: Data, list: Set<Data>,
                recovery: Data, recoverySigned: Bool = false) {
        self.epochId = epochId; self.parent = parent; self.signer = signer; self.reason = reason; self.home = home
        self.list = list; self.recovery = recovery; self.recoverySigned = recoverySigned
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
    /// Epochs with more than one valid home-signed child and no takeover below (the home key signed
    /// twice): the device stops there unless its pinned chain goes on, and needs a takeover.
    public var homeConflicts: [Data]
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
    public static func resolve(_ nodes: [EpochNode], pinned: [Data] = []) throws -> PrecedenceResult {
        try resolve(nodes, pinned: pinned, mutations: [])
    }

    static func resolve(_ nodes: [EpochNode], pinned: [Data], mutations mut: Set<PrecedenceMutation>) throws
        -> PrecedenceResult {
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

        // The valid tree: from epoch 1 down, each epoch valid under its parent. `homeBefore` is the home
        // in force before the last takeover above (for the `olderHomeKept` mutation only).
        func valid(_ c: EpochNode, under p: EpochNode, olderHome: Data?) -> Bool {
            guard c.list.contains(c.home) else { return false }
            if c.reason == .takeover {
                if mut.contains(.takeoverIgnored) { return false }
                return c.recoverySigned && c.signer == c.home && c.recovery == p.recovery
                    && c.list.isSubset(of: p.list.union([c.home]))
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
        var todo = [root]
        while let x = todo.popLast() {
            guard let p = byId[x] else { continue }
            for c in children[x] ?? [] {
                guard let n = byId[c], valid(n, under: p, olderHome: olderHome[x] ?? nil) else { continue }
                validSet.insert(c)
                olderHome[c] = n.reason == .takeover ? p.home : olderHome[x] ?? nil
                todo.append(c)
            }
        }
        let ignored = byId.keys.filter { !validSet.contains($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        func validChildren(_ x: Data) -> [Data] { (children[x] ?? []).filter { validSet.contains($0) } }
        func path(_ id: Data) -> [Data] {
            var out = [id]
            var cur = byId[id]?.parent
            while let c = cur { out.append(c); cur = byId[c]?.parent }
            return out.reversed()
        }
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
        var conflicts: [Data] = []
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
            // The home key signed two children: the pinned chain decides, or the device stops.
            if let onPin = next.first(where: { pinSet.contains($0) }) {
                conflicts.append(x); chain.append(onPin); continue
            }
            conflicts.append(x)
            break
        }
        let kept = Set(chain)
        return PrecedenceResult(keptChain: chain, dropped: pin.filter { !kept.contains($0) }, ignored: ignored,
                                homeConflicts: conflicts)
    }
}
