import Foundation

/// Notebook names as display paths (`format.md` §5.4): a notebook is a free
/// string, `/` separates levels of a display hierarchy, and leading,
/// trailing and empty segments (after trimming whitespace) are ignored, so
/// `" A//B / "` shows as `A` › `B`.
public enum NotebookPath {
    /// The display segments of a notebook name; empty when it names no
    /// notebook at all (nil, blank, or only separators).
    public static func components(_ name: String?) -> [String] {
        guard let name else { return [] }
        return name.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The canonical form of a notebook name (segments joined by `/`), nil
    /// when it names no notebook. Two names with the same canonical form are
    /// the same notebook for display and filtering.
    public static func canonical(_ name: String?) -> String? {
        let parts = components(name)
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// True when `name` is the notebook `path` or lies anywhere below it.
    /// Compares whole segments: `A/Bc` is not inside `A/B`.
    public static func name(_ name: String?, isWithin path: String) -> Bool {
        let parts = components(name)
        let prefix = components(path)
        return !prefix.isEmpty && parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    /// The path notebook `path` gets when it is moved into `parent` (nil or
    /// blank: the top level): `parent` plus the last level of `path`, so
    /// `School/Math` moved into `Archive` is `Archive/Math`, and moved into the
    /// top level is `Math`. Nil when that is impossible: `path` names no
    /// notebook, or `parent` is `path` itself or lies inside it (a notebook
    /// cannot become its own descendant). The result can equal `path` (it is
    /// already there), and it may name a notebook that exists: moving merges
    /// them, since a notebook is only the prefix its notes carry.
    public static func moved(_ path: String, into parent: String?) -> String? {
        let from = components(path)
        guard let last = from.last else { return nil }
        let to = components(parent)
        if to.count >= from.count, Array(to.prefix(from.count)) == from { return nil }
        return (to + [last]).joined(separator: "/")
    }

    /// The new name of `name` when the notebook `old` (and everything below
    /// it) is renamed or moved to `new`: the `old` prefix is replaced by
    /// `new`. An empty `new` drops the prefix, so notes directly in `old`
    /// leave every notebook and sub-notebooks move to the top level.
    /// Returns `name` unchanged when it is not within `old`.
    public static func renamed(_ name: String?, from old: String, to new: String?) -> String? {
        guard Self.name(name, isWithin: old) else { return name }
        let rest = components(name).dropFirst(components(old).count)
        return canonical((components(new) + rest).joined(separator: "/"))
    }
}

extension NotebookPath {
    /// Existing notebooks to offer while `typed` is being entered in a
    /// notebook field (a combo box: type a new `/`-separated path or pick one).
    ///
    /// `notebooks` are the names notes carry; every level above them counts
    /// as a notebook too (`A/B/C` offers `A` and `A/B`). Matching ignores case,
    /// accents and width, and compares canonical paths. Typed text ending in
    /// `/` offers what lies below that notebook. Order: the notebook typed
    /// exactly, then paths starting with the text, then paths with a level
    /// starting with it, then paths containing it; ties by depth, then name.
    /// Blank text offers everything. Cost: O(n log n) in the notebooks.
    ///
    /// - Parameters:
    ///   - excluding: a notebook never offered (the note's own, when moving).
    ///   - excludingSubtree: a notebook and everything below it never offered
    ///     (the destinations a notebook cannot be moved into: itself and its descendants).
    ///   - limit: at most this many results.
    public static func suggestions(matching typed: String, among notebooks: [String?],
                                   excluding: String? = nil, excludingSubtree: String? = nil,
                                   limit: Int = 50) -> [String] {
        let all = NotebookNode.flatten(NotebookNode.tree(notebooks))
        let skip = canonical(excluding).map(fold)
        let candidates = all.filter { path in
            if let skip, fold(path) == skip { return false }
            if let tree = excludingSubtree, name(fold(path), isWithin: fold(tree)) { return false }
            return true
        }
        let query = canonical(typed).map(fold)
        let below = typed.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        guard let query else { return Array(candidates.prefix(max(limit, 0))) }
        var ranked: [(rank: Int, depth: Int, path: String)] = []
        for path in candidates {
            let f = fold(path)
            let rank: Int
            if f == query {
                if below { continue }
                rank = 0
            } else if f.hasPrefix(query + "/") {
                rank = 1
            } else if below {
                continue   // "A/" offers what is inside A, not other paths containing "a"
            } else if f.hasPrefix(query) {
                rank = 2
            } else if f.contains("/" + query) {
                rank = 3
            } else if f.contains(query) {
                rank = 4
            } else {
                continue
            }
            ranked.append((rank, components(path).count, path))
        }
        ranked.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return NotebookNode.ascending($0.path, $1.path)
        }
        return ranked.prefix(max(limit, 0)).map(\.path)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// One notebook in the sidebar's hierarchy.
public struct NotebookNode: Hashable, Sendable, Identifiable {
    /// The last segment, for display.
    public var name: String
    /// The canonical path (`NotebookPath.canonical`), which is also the id.
    public var path: String
    /// Sub-notebooks, sorted by name.
    public var children: [NotebookNode]

    public var id: String { path }

    /// `children`, or nil for a leaf (what `OutlineGroup` expects).
    public var childrenOrNil: [NotebookNode]? { children.isEmpty ? nil : children }

    public init(name: String, path: String, children: [NotebookNode] = []) {
        self.name = name; self.path = path; self.children = children
    }

    /// The forest of notebooks named by `names` (nil and blank names are
    /// skipped). Intermediate levels exist even when no note sits directly in
    /// them: `A/B/C` alone yields `A` › `B` › `C`. Siblings sort with
    /// `localizedStandardCompare`.
    public static func tree(_ names: [String?]) -> [NotebookNode] {
        // A name comes from a note's JSON; its levels below `maxDepth` are not
        // shown (building recurses once per level).
        let paths = names.map { Array(NotebookPath.components($0).prefix(maxDepth)) }.filter { !$0.isEmpty }
        return build(Set(paths), depth: 0, prefix: [])
    }

    /// Deepest level `tree` shows; deeper levels are folded into this one.
    public static let maxDepth = 64

    private static func build(_ paths: Set<[String]>, depth: Int, prefix: [String]) -> [NotebookNode] {
        let below = paths.filter { $0.count > depth && Array($0.prefix(depth)) == prefix }
        let names = Set(below.map { $0[depth] })
        return names.sorted(by: NotebookNode.ascending).map { name in
            let path = prefix + [name]
            return NotebookNode(name: name, path: path.joined(separator: "/"),
                                children: build(below, depth: depth + 1, prefix: path))
        }
    }

    /// Every path in a forest, depth first, parents before children.
    public static func flatten(_ nodes: [NotebookNode]) -> [String] {
        nodes.flatMap { [$0.path] + flatten($0.children) }
    }

    static func ascending(_ a: String, _ b: String) -> Bool {
        let c = a.localizedStandardCompare(b)
        return c == .orderedSame ? a < b : c == .orderedAscending
    }
}
