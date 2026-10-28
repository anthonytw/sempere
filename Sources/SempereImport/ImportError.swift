import Foundation

/// Errors from the import layer: zip containers, keyed archives, and
/// importable packages.
public enum ImportError: Error, Hashable, Sendable {
    /// The zip container is malformed, truncated or uses an unsupported
    /// feature (encryption, a compression method other than stored/deflate,
    /// multi-disk archives). The detail says which.
    case zip(String)
    /// A property list does not parse, or an `NSKeyedArchiver` archive is
    /// malformed (bad `$top`, dangling `CF$UID`, unexpected shape).
    case archive(String)
    /// A package or bundle is missing a required part or holds data that
    /// contradicts itself (e.g. stroke arrays of inconsistent lengths).
    case package(String)
    /// A filesystem read or write failed.
    case io(String)
}

extension ImportError: CustomStringConvertible {
    /// A human sentence for each case: the detail alone for an I/O failure ("no such file: …").
    public var description: String {
        switch self {
        case .zip(let d): return "not a readable zip file: \(d)"
        case .archive(let d): return "unreadable archive: \(d)"
        case .package(let d): return "unreadable package: \(d)"
        case .io(let d): return d
        }
    }
}
