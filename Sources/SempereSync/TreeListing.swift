import Foundation
import Sempere

// MARK: - One listing for every note folder (`WebDAVSyncOptions.deepListing`)
//
// A run lists every note folder on the server, and each `att/`, one PROPFIND
// (`Depth: 1`) each: ~685 requests for a vault of 640 notes, every run, even
// when nothing changed. `PROPFIND` with `Depth: infinity` on `notes/` gives
// the same entries in one request, where the server allows it. Many do not
// (Apache's default is to refuse it), and some answer it as if it were
// `Depth: 1` (Sabre/Nextcloud with infinite depth off), so it is only
// trusted where it is seen to work, like the folder ETags of
// `skipUnchangedNotes`:
//
// - a run that has not seen it work lists the note folders and their `att/`
//   one by one as before and also asks for the whole tree once
//   (`verify`). When every folder and `att/` listed holds exactly what the
//   tree says, the server is recorded as giving whole trees
//   (`SyncState.treeListing`); a refusal (a 4xx such as 403
//   `propfind-finite-depth`, a 501, or an answer with nothing below the
//   note folders) is recorded as for good; any other difference (another
//   device writing between the two listings) records nothing, and the next
//   run checks again;
// - a run within `fullListingInterval` of the last check takes every note
//   folder and `att/` from the tree (`use`): three PROPFINDs in all (the
//   root, `notes/`, the tree). One that is older checks again.
//
// The tree is used only between `deepListingNotes` note folders (below, the
// per-folder listings cost little; above, the answer would near the 16 MiB
// listing bound). A tree request that fails (a 5xx, a cut connection, too
// large) falls back to the per-folder listings for that run. A listing that
// missed files would not lose data: the server is untrusted, and the sync
// already treats a file it does not list as one the server dropped (it is
// uploaded again, or, for a revision, deleted here only when a snapshot the
// server lists covers it and compaction allows it).

extension WebDAVSync {
    /// How a run lists the note folders.
    enum TreeMode: Equatable {
        /// One by one (`Depth: 1`).
        case none
        /// One by one, and the tree too, to compare.
        case verify
        /// From the tree.
        case use
    }

    /// Note folder counts for which the tree is used (or checked).
    static let deepListingNotes = 8...5_000

    /// Decides how this run lists the `noteDirs` note folders.
    func treeMode(noteDirs: Int) -> TreeMode {
        guard options.deepListing, Self.deepListingNotes.contains(noteDirs) else { return .none }
        guard let record = state.treeListing else { return .verify }
        guard record.supported else { return .none }
        if let at = record.verifiedAt, options.now >= at, options.now.timeIntervalSince(at) < options.fullListingInterval {
            return .use
        }
        return .verify
    }

    /// Asks for the tree below `notes/`, counted against the run's bounds;
    /// records a refusal. Nil when it cannot be used this run. `dirs` are
    /// the note folders the `notes/` listing just showed: a tree without any
    /// of them is a refusal (the server answered as `Depth: 0`), one that
    /// lacks some is not used (a folder went away between the two requests).
    func fetchNotesTree(dirs: [String]) throws -> [[String]: [RemoteEntry]]? {
        try checkCancelled()
        try budget.checkTime()
        do {
            switch try transport.listTree([Vault.notesName]) {
            case .listed(let tree)?:
                try budget.list(tree.values.reduce(0) { $0 + $1.count })
                let top = Set((tree[[]] ?? []).filter(\.isCollection).map(\.name))
                if top.isEmpty {
                    if !options.dryRun { state.treeListing = .init(supported: false, verifiedAt: nil) }
                    return nil
                }
                return dirs.allSatisfy(top.contains) ? tree : nil
            case .refused?:
                if !options.dryRun { state.treeListing = .init(supported: false, verifiedAt: nil) }
                return nil
            case nil:
                return nil
            }
        } catch {
            try rethrowRunLimit(error)
            // Transient (5xx, a cut connection, too large): one by one this run.
            return nil
        }
    }

    /// After a `verify` run's listings: records the tree as trusted when it
    /// held exactly what every note folder and `att/` listed one by one held.
    func settleTreeCheck(_ tree: [[String]: [RemoteEntry]], listed: [String: [RemoteEntry]]) {
        guard !options.dryRun, notesNotReadable.isEmpty, !listed.isEmpty else { return }
        func same(_ a: [RemoteEntry], _ b: [RemoteEntry]?) -> Bool {
            let x = a.sorted { $0.name < $1.name }, y = (b ?? []).sorted { $0.name < $1.name }
            return x == y
        }
        for (id, entries) in listed {
            guard same(entries, tree[[id]]) else { return }
            guard entries.contains(where: { $0.name == Vault.attachmentsName && $0.isCollection }) else { continue }
            guard case .success(let att)? = attListings[id] else { return }
            guard same(att ?? [], tree[[id, Vault.attachmentsName]]) else { return }
        }
        state.treeListing = .init(supported: true, verifiedAt: options.now)
    }
}
