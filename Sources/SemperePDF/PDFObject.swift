import Foundation

/// An indirect reference `num gen R`.
public struct PDFRef: Hashable, Sendable, CustomStringConvertible {
    /// Object number.
    public var num: Int
    /// Generation number.
    public var gen: Int

    /// Creates a reference.
    public init(_ num: Int, _ gen: Int = 0) { self.num = num; self.gen = gen }

    public var description: String { "\(num) \(gen) R" }
}

/// A PDF name, as its decoded bytes (`/A#20B` is the three bytes `A B`).
public struct PDFName: Hashable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The name's bytes after `#xx` decoding, without the leading `/`.
    public var bytes: [UInt8]

    /// A name from its decoded bytes.
    public init(bytes: [UInt8]) { self.bytes = bytes }
    /// A name from ASCII text.
    public init(_ s: String) { bytes = Array(s.utf8) }
    public init(stringLiteral s: String) { self.init(s) }

    public static func < (l: PDFName, r: PDFName) -> Bool { l.bytes.lexicographicallyPrecedes(r.bytes) }

    public var description: String { "/" + String(decoding: bytes, as: UTF8.self) }
}

/// A dictionary. Keys are kept in a hash map; serialisation sorts them, so
/// output is deterministic.
public struct PDFDict: Sendable, Equatable {
    /// The entries.
    public var entries: [PDFName: PDFObject]

    /// Creates a dictionary.
    public init(_ entries: [PDFName: PDFObject] = [:]) { self.entries = entries }

    /// The value for `key`; nil when absent (a `null` value is returned as `.null`).
    public subscript(key: PDFName) -> PDFObject? {
        get { entries[key] }
        set { entries[key] = newValue }
    }
}

/// A stream: its dictionary and its bytes exactly as stored (still encoded).
public struct PDFStream: Sendable, Equatable {
    /// The stream dictionary (`/Length` as found, possibly indirect).
    public var dict: PDFDict
    /// The encoded bytes between `stream` and `endstream`.
    public var raw: Data

    /// Creates a stream.
    public init(dict: PDFDict, raw: Data) { self.dict = dict; self.raw = raw }
}

/// Any PDF object (ISO 32000-1 §7.3).
public indirect enum PDFObject: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    /// A literal or hexadecimal string, as its bytes.
    case string([UInt8])
    case name(PDFName)
    case array([PDFObject])
    case dict(PDFDict)
    case ref(PDFRef)
    case stream(PDFStream)

    /// The dictionary of a dictionary or a stream.
    public var dictValue: PDFDict? {
        switch self {
        case .dict(let d): return d
        case .stream(let s): return s.dict
        default: return nil
        }
    }

    /// The value of a number (integer or real).
    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .real(let r): return r
        default: return nil
        }
    }

    /// The value of an integer.
    public var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }

    /// The name of a name object.
    public var nameValue: PDFName? { if case .name(let n) = self { return n } else { return nil } }

    /// The elements of an array.
    public var arrayValue: [PDFObject]? { if case .array(let a) = self { return a } else { return nil } }

    /// The reference of an indirect reference.
    public var refValue: PDFRef? { if case .ref(let r) = self { return r } else { return nil } }

    /// The stream of a stream object.
    public var streamValue: PDFStream? { if case .stream(let s) = self { return s } else { return nil } }
}
