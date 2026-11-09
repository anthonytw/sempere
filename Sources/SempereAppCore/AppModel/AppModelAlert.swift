import Foundation
import Sempere

/// What the model's alert says (`AppModelCore.alert`, cleared by the view that shows it): a typed value each front end
/// words (the app's `AppModelAlert.text`, docs/design/thin-app.md "Rules"). Comparable, so tests assert the reason.
public enum AppModelAlert: Sendable, Equatable {
    /// A thrown error (`report`, a listing nobody awaits): the front end words it as any error.
    case error(any Error)
    /// One of the model's own notices (a recording, the inbox, the device list).
    case notice(AppModelNotice)
    /// An image, a PDF, a clip or an opened file that could not be added.
    case insert(InsertNotice)
    /// A sentence the front end already worded itself (the app's own failures, such as a paste or a photo pick):
    /// the model only carries it to the alert.
    case worded(String)

    public static func == (a: AppModelAlert, b: AppModelAlert) -> Bool {
        switch (a, b) {
        case let (.error(x), .error(y)): return sameError(x, y)
        case let (.notice(x), .notice(y)): return x == y
        case let (.insert(x), .insert(y)): return x == y
        case let (.worded(x), .worded(y)): return x == y
        default: return false
        }
    }
}

/// Why the selected note could not be shown (`AppModelCore.editorFailure`), worded by the detail pane.
public enum EditorFailure: Sendable, Equatable {
    /// Its read failed before it was shown: the editor's read-only reason (nil: it gave none).
    case unreadable(NoteReadOnly?)
    /// Opening it, or the read that completes an editor opened from the cache, failed with this error.
    case failed(any Error)

    public static func == (a: EditorFailure, b: EditorFailure) -> Bool {
        switch (a, b) {
        case let (.unreadable(x), .unreadable(y)): return x == y
        case let (.failed(x), .failed(y)): return sameError(x, y)
        default: return false
        }
    }
}

/// Why an image, a PDF, a clip or a file opened with the app could not be added, with the error (typed, worded by
/// the app; reported as `AppModelAlert.insert`). Equal when the reason and the error are (`sameError`), so a test can
/// expect `.pdfNotImported(AttachmentOpsError.pagelessNote)`.
public enum InsertNotice: Sendable, Equatable {
    case imageNotAdded(any Error)
    case imageNotReplaced(any Error)
    case pdfNotImported(any Error)
    case videoNotAdded(any Error)
    /// A file the system opened the app with could not be copied in (its name as opened).
    case fileNotOpened(name: String, any Error)

    /// The error it carries.
    var error: any Error {
        switch self {
        case .imageNotAdded(let e), .imageNotReplaced(let e), .pdfNotImported(let e), .videoNotAdded(let e),
             .fileNotOpened(_, let e):
            return e
        }
    }

    public static func == (a: InsertNotice, b: InsertNotice) -> Bool {
        switch (a, b) {
        case (.imageNotAdded, .imageNotAdded), (.imageNotReplaced, .imageNotReplaced),
             (.pdfNotImported, .pdfNotImported), (.videoNotAdded, .videoNotAdded):
            return sameError(a.error, b.error)
        case let (.fileNotOpened(x, _), .fileNotOpened(y, _)):
            return x == y && sameError(a.error, b.error)
        default:
            return false
        }
    }
}

/// Whether two errors are the same: equal values of one `Equatable` type (`AttachmentOpsError.pagelessNote`,
/// `PDFLocked.needsPassword`), else the same type with the same `String(reflecting:)`, the type's own debug text (an
/// `NSError`'s domain and code show in it); never the app's `AppModel.describe`.
///
/// The `Equatable` of `AppModelAlert`, `EditorFailure`, `InsertNotice` and `EmptyListReason` is for tests (they assert
/// the reason) and for change suppression (setting an equal value publishes nothing new). It is not identity: two
/// separate failures of the same kind compare equal, so never use it to tell whether an alert is "the same one" as
/// before, only whether its content changed.
func sameError(_ a: any Error, _ b: any Error) -> Bool {
    if let x = a as? any Equatable { return equals(x, b) }
    return type(of: a) == type(of: b) && String(reflecting: a) == String(reflecting: b)
}

private func equals<E: Equatable>(_ a: E, _ b: Any) -> Bool {
    guard let b = b as? E else { return false }
    return a == b
}
