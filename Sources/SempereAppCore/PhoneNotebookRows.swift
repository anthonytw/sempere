import Foundation
import Sempere

/// The sidebar's notebook rows on an iPhone: the tree flattened in order with each row's depth, the
/// sub-notebooks of an unfolded notebook only (folding, as the iPad's outline does; its rows' taps only fold
/// on a phone's stack, so the phone draws the rows itself, with a chevron of their own).
public enum PhoneNotebookRows {
    public struct Row: Identifiable {
        public let node: NotebookNode
        public let depth: Int
        /// Its sub-notebooks are listed under it.
        public var unfolded = true
        public var id: String { node.path }
        public var hasChildren: Bool { !node.children.isEmpty }
    }

    /// Every notebook (`unfolded` nil), or the top ones and the sub-notebooks of each unfolded one.
    public static func rows(_ tree: [NotebookNode], unfolded: Set<String>? = nil, depth: Int = 0) -> [Row] {
        tree.flatMap { node -> [Row] in
            let open = unfolded.map { $0.contains(node.path) } ?? true
            let row = Row(node: node, depth: depth, unfolded: open)
            return [row] + (open ? rows(node.children, unfolded: unfolded, depth: depth + 1) : [])
        }
    }

    /// `path` folded if it was unfolded, else unfolded.
    public static func toggled(_ path: String, in unfolded: Set<String>) -> Set<String> {
        unfolded.contains(path) ? unfolded.subtracting([path]) : unfolded.union([path])
    }

    /// `unfolded` with every notebook above `path` unfolded, so `path`'s row is listed (a notebook chosen
    /// elsewhere, e.g. a note's notebook).
    public static func revealing(_ path: String, in unfolded: Set<String>) -> Set<String> {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return unfolded }
        return unfolded.union((1..<parts.count).map { parts[0..<$0].joined(separator: "/") })
    }
}
