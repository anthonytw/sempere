import Foundation

// MARK: - Checkpoints and editing sessions (docs/format.md §5.8.1–§5.8.2)

/// Autosaves grouped into one editing session (format.md §5.8.2).
public struct EditingSessionGroup: Hashable, Sendable {
    /// The session's restore points, oldest first; never empty.
    public var points: [RestorePoint]

    public init(points: [RestorePoint]) {
        precondition(!points.isEmpty, "a session has at least one point")
        self.points = points
    }

    /// The device that wrote every point.
    public var device: DeviceID { points[0].device }
    /// The `session` id every point carries, if any.
    public var session: String? { points[0].session }
    /// `wall` of the first point.
    public var start: Date { points[0].wall }
    /// `wall` of the last point.
    public var end: Date { points[points.count - 1].wall }
    /// Number of saves (restore points) in the session.
    public var count: Int { points.count }
    /// The newest point: the one thinning keeps (format.md §5.8.4).
    public var newest: RestorePoint { points[points.count - 1] }
}

/// One top-level row of a grouped history: a checkpoint, or the autosaves
/// of one editing session.
public enum HistoryGroup: Hashable, Sendable {
    case checkpoint(RestorePoint)
    case session(EditingSessionGroup)

    /// Every restore point in the group, oldest first.
    public var points: [RestorePoint] {
        switch self {
        case .checkpoint(let p): return [p]
        case .session(let s): return s.points
        }
    }

    /// The group's newest restore point.
    public var newest: RestorePoint { points[points.count - 1] }
}

extension NoteHistory {
    /// The gap that starts a new editing session (format.md §5.8.2 rule b): 10 minutes.
    public static let sessionGap: TimeInterval = 10 * 60

    /// Groups restore points (oldest first, as `restorePoints` returns them)
    /// into checkpoints and editing sessions, oldest first (format.md §5.8.2):
    /// a checkpoint stands alone and ends the session before it; a point
    /// starts a new session when its `session` id, or its device, differs
    /// from the previous point's, or its `wall` is `gap` or more after it.
    /// O(points).
    public static func groups(_ points: [RestorePoint], gap: TimeInterval = sessionGap) -> [HistoryGroup] {
        var out: [HistoryGroup] = []
        var current: [RestorePoint] = []
        func close() {
            if !current.isEmpty { out.append(.session(EditingSessionGroup(points: current))) }
            current = []
        }
        for p in points {
            if p.isCheckpoint {
                close()
                out.append(.checkpoint(p))
                continue
            }
            if let prev = current.last,
               prev.session != p.session || prev.device != p.device || p.wall.timeIntervalSince(prev.wall) >= gap {
                close()
            }
            current.append(p)
        }
        close()
        return out
    }
}

extension Vault {
    /// Writes a checkpoint (format.md §5.8.1) for a note as this device: one
    /// delta with no ops and a `checkpoint` named `name` (trimmed, at most
    /// `Checkpoint.maxNameLength` characters; blank is unnamed). Device id and
    /// clock as for `apply(_:to:deviceState:app:wall:)`.
    ///
    /// - Throws: as `apply`.
    @discardableResult
    public func checkpoint(_ noteId: UUID, name: String?, deviceState: URL, app: String,
                           wall: Date = Date()) throws -> Revision {
        guard canRead else { throw isLocked ? VaultError.locked : VaultError.noIdentities }
        return try writeDelta([], to: noteId, loaded: try loadNote(noteId), deviceState: deviceState, app: app, wall: wall,
                              checkpoint: Checkpoint(name: name))
    }
}
