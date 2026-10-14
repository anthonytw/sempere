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
