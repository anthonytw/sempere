import Foundation

/// A property-list value with `NSKeyedArchiver` UIDs made explicit.
///
/// `parse` reads binary plists with SempereImport's own reader (`BinaryPlist`),
/// which yields UIDs as `.uid(n)` directly. `init(any:)` converts a
/// `PropertyListSerialization` result for trusted callers: UIDs (`CF$UID`)
/// arrive there differently per platform, on Darwin as an opaque
/// `CFKeyedArchiverUID` object, on Linux as the internal
/// `_NSKeyedArchiverUID` class, and from hand-built values as a one-key
/// dictionary `["CF$UID": n]`. All become `.uid(n)`.
public indirect enum PlistValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dict([String: PlistValue])
    /// An `NSKeyedArchiver` object reference: an index into `$objects`.
    case uid(Int)

    /// Converts a `PropertyListSerialization` result.
    ///
    /// - Throws: `ImportError.archive` for a value of an unexpected type.
    public init(any value: Any) throws {
        if let uid = PlistValue.uid(from: value) { self = .uid(uid); return }
        switch value {
        case let s as String: self = .string(s)
        case let d as Data: self = .data(d)
        case let d as Date: self = .date(d)
        case let a as [Any]: self = .array(try a.map(PlistValue.init(any:)))
        case let d as [String: Any]:
            var out: [String: PlistValue] = [:]
            for (k, v) in d { out[k] = try PlistValue(any: v) }
            self = .dict(out)
        case let n as NSNumber: self = PlistValue.number(n)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(Int64(i))
        case let i as Int64: self = .int(i)
        case let i as UInt64: self = .int(Int64(bitPattern: i))
        case let x as Double: self = .real(x)
        default:
            throw ImportError.archive("unexpected property-list value of type \(type(of: value))")
        }
    }

    private static func number(_ n: NSNumber) -> PlistValue {
        // "c" (char) is how CFBoolean reports itself; "f"/"d" are reals.
        switch String(cString: n.objCType) {
        case "c", "B": return .bool(n.boolValue)
        case "f", "d": return .real(n.doubleValue)
        default: return .int(n.int64Value)
        }
    }

    /// The UID of a `CF$UID` reference in either platform representation.
    static func uid(from value: Any) -> Int? {
        if let d = value as? [String: Any], d.count == 1, let n = d["CF$UID"] {
            if let i = n as? Int { return i }
            if let i = n as? NSNumber { return i.intValue }
            return nil
        }
        // An opaque UID object: `CFKeyedArchiverUID` on Darwin (described as
        // "<CFKeyedArchiverUID 0x...>{value = 5}"), `_NSKeyedArchiverUID` in
        // swift-corelibs-foundation (a stored `value: UInt32`).
        let typeName = String(describing: type(of: value))
        guard typeName.contains("UID") || typeName.contains("CFType") else { return nil }
        for child in Mirror(reflecting: value).children where child.label == "value" {
            switch child.value {
            case let v as UInt32: return Int(v)
            case let v as Int: return v
            case let v as UInt64: return Int(exactly: v)
            case let v as Int32: return Int(v)
            default: break
            }
        }
        let text = String(describing: value)
        guard let r = text.range(of: "value = ") else { return nil }
        let digits = text[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Integer view of a numeric value (bools are 0/1, reals truncate).
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .real(let x): return x.isFinite && abs(x) < 9e18 ? Int64(x) : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Floating-point view of a numeric value.
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .real(let x): return x
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// The string, if this is one.
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    /// The bytes, if this is data.
    public var data: Data? { if case .data(let d) = self { return d }; return nil }
}

extension PlistValue {
    /// Parses a binary property list (`bplist00`), or with `allowXML` also an
    /// XML one. OpenStep plists are refused. Apps write binary plists
    /// (every keyed archive is one), except for a few small XML ones such as
    /// `Recordings/library.plist`, which callers read with `allowXML`.
    ///
    /// - Throws: `ImportError.archive` when the bytes are not a well-formed
    ///   property list of an accepted format (see `BinaryPlist`, `XMLPlist`).
    public static func parse(_ bytes: Data, allowXML: Bool = false) throws -> PlistValue {
        // SempereImport's own readers: PropertyListSerialization crashes on
        // some hostile binary plists on Linux.
        if BinaryPlist.isBinaryPlist(bytes) { return try BinaryPlist.parse(bytes) }
        if allowXML, XMLPlist.isXMLPlist(bytes) { return try XMLPlist.parse(bytes) }
        throw ImportError.archive(allowXML ? "not a binary or XML property list" : "not a binary property list")
    }
}

/// An `NSKeyedArchiver` archive: `$objects`, a `$top` dictionary of root
/// references, and the class table, resolved on demand.
///
/// Objects decode by class name: `NSDictionary`/`NSMutableDictionary`
/// (`NS.keys`/`NS.objects`), `NSArray`/`NSSet` and mutable kinds
/// (`NS.objects`), `NSString` (`NS.string` or UTF-8 `NS.bytes`), `NSData`
/// (`NS.data`), `NSDate` (`NS.time`, seconds since 2001-01-01). Any other
/// class decodes as `.object` with its raw fields, which callers read with
/// `field(_:)`.
public struct KeyedArchive: Sendable {
    /// One decoded node.
    public indirect enum Node: Sendable {
        case null
        case string(String)
        case int(Int64)
        case real(Double)
        case bool(Bool)
        case date(Date)
        case data(Data)
        case array([PlistValue])
        case dict([String: PlistValue])
        /// An object of a class not decoded natively; fields unresolved.
        case object(className: String, fields: [String: PlistValue])
    }

    /// The raw `$objects` table.
    public let objects: [PlistValue]
    /// `$top`: root name → reference (usually `.uid`).
    public let top: [String: PlistValue]

    /// Maximum nesting followed by `resolveDeep` and the decoders.
    static let maxDepth = 64
    /// Longest dictionary key accepted, UTF-8 bytes (real keys are short; a
    /// long key repeated many times would cost its length at every insert).
    static let maxKeyBytes = 1024

    /// Each archived object of `$objects` (a dictionary with `$class`)
    /// decoded once, at init: an archive can reference one object any number
    /// of times, and decoding a dictionary or an object copies all its fields,
    /// so decoding on every reference would cost (references × size), not the
    /// input's size (format.md §9). Nil for entries that are plain values.
    private let decoded: [Decoded?]

    private enum Decoded: Sendable {
        case node(Node)
        case failure(ImportError)
    }

    /// Parses an archive from property-list bytes.
    ///
    /// - Throws: `ImportError.archive` if the bytes are not a keyed archive.
    public init(data: Data) throws {
        guard case .dict(let root) = try PlistValue.parse(data) else {
            throw ImportError.archive("keyed archive root is not a dictionary")
        }
        guard case .array(let objects)? = root["$objects"] else { throw ImportError.archive("no $objects") }
        guard case .dict(let top)? = root["$top"] else { throw ImportError.archive("no $top") }
        self.objects = objects
        self.top = top
        self.decoded = Self.decodeAll(objects)
    }

    /// Decodes every archived object once: other classes first, then
    /// dictionaries, whose keys are strings decoded in the first pass.
    private static func decodeAll(_ objects: [PlistValue]) -> [Decoded?] {
        var out = [Decoded?](repeating: nil, count: objects.count)
        var dictionaries: [(Int, String, [String: PlistValue])] = []
        for (i, o) in objects.enumerated() {
            guard case .dict(let fields) = o, let cls = fields["$class"] else { continue }
            do {
                let name = try className(cls, objects)
                if name == "NSDictionary" || name == "NSMutableDictionary" {
                    dictionaries.append((i, name, fields))
                } else {
                    out[i] = .node(try decodeOther(className: name, fields: fields))
                }
            } catch let e as ImportError {
                out[i] = .failure(e)
            } catch {
                out[i] = .failure(.archive("\(error)"))
            }
        }
        for (i, name, fields) in dictionaries {
            do {
                guard case .array(let keys)? = fields["NS.keys"], case .array(let vals)? = fields["NS.objects"],
                      keys.count == vals.count else { throw ImportError.archive("malformed \(name)") }
                var dict: [String: PlistValue] = [:]
                dict.reserveCapacity(keys.count)
                for (k, v) in zip(keys, vals) {
                    let key: String
                    switch k {
                    case .string(let s) where s != "$null": key = s
                    case .int(let n): key = String(n)
                    case .uid(let j) where j >= 0 && j < objects.count:
                        if case .string(let s) = objects[j], s != "$null" { key = s }
                        else if case .node(.string(let s))? = out[j] { key = s }
                        else if case .int(let n) = objects[j] { key = String(n) }
                        else { throw ImportError.archive("\(name) key is not a string or number") }
                    case .uid(let j): throw ImportError.archive("dangling CF$UID \(j)")
                    default: throw ImportError.archive("\(name) key is not a string or number")
                    }
                    guard key.utf8.count <= maxKeyBytes else { throw ImportError.archive("\(name) key longer than \(maxKeyBytes) bytes") }
                    dict[key] = v
                }
                out[i] = .node(.dict(dict))
            } catch let e as ImportError {
                out[i] = .failure(e)
            } catch {
                out[i] = .failure(.archive("\(error)"))
            }
        }
        return out
    }

    /// The root object named `key` in `$top` (`root` or `$0` in practice).
    public func root(_ key: String) throws -> Node {
        guard let ref = top[key] else { throw ImportError.archive("no $top entry \(key)") }
        return try node(ref)
    }

    /// The first root present among `keys`.
    public func root(anyOf keys: [String]) throws -> Node {
        for k in keys where top[k] != nil { return try root(k) }
        throw ImportError.archive("no $top entry among \(keys)")
    }

    /// Resolves a value: follows a UID into `$objects` and decodes it.
    ///
    /// - Throws: `ImportError.archive` for a dangling UID or a malformed
    ///   Foundation object.
    public func node(_ value: PlistValue) throws -> Node {
        try node(value, depth: 0)
    }

    private func node(_ value: PlistValue, depth: Int) throws -> Node {
        guard depth < Self.maxDepth else { throw ImportError.archive("reference chain too deep") }
        switch value {
        case .uid(let i):
            guard i >= 0, i < objects.count else { throw ImportError.archive("dangling CF$UID \(i)") }
            switch decoded[i] {
            case .node(let n)?: return n
            case .failure(let e)?: throw e
            case nil: return try node(objects[i], depth: depth + 1)
            }
        case .string(let s): return s == "$null" ? .null : .string(s)
        case .int(let i): return .int(i)
        case .real(let x): return .real(x)
        case .bool(let b): return .bool(b)
        case .date(let d): return .date(d)
        case .data(let d): return .data(d)
        case .array(let a): return .array(a)
        case .dict(let d):
            guard let cls = d["$class"] else { return .dict(d) }
            let name = try className(cls)
            return try decode(className: name, fields: d, depth: depth)
        }
    }

    private func className(_ ref: PlistValue) throws -> String {
        try Self.className(ref, objects)
    }

    private static func className(_ ref: PlistValue, _ objects: [PlistValue]) throws -> String {
        guard case .uid(let i) = ref, i >= 0, i < objects.count,
              case .dict(let cls) = objects[i], let name = cls["$classname"]?.string else {
            throw ImportError.archive("bad $class reference")
        }
        return name
    }

    /// An archived object found inline rather than in `$objects` (not cached).
    private func decode(className: String, fields: [String: PlistValue], depth: Int) throws -> Node {
        switch className {
        case "NSDictionary", "NSMutableDictionary":
            guard case .array(let keys)? = fields["NS.keys"], case .array(let vals)? = fields["NS.objects"],
                  keys.count == vals.count else { throw ImportError.archive("malformed \(className)") }
            var out: [String: PlistValue] = [:]
            for (k, v) in zip(keys, vals) {
                switch try node(k, depth: depth + 1) {
                case .string(let s) where s.utf8.count <= Self.maxKeyBytes: out[s] = v
                case .int(let i): out[String(i)] = v
                default: throw ImportError.archive("\(className) key is not a string or number")
                }
            }
            return .dict(out)
        default:
            return try Self.decodeOther(className: className, fields: fields)
        }
    }

    /// Any class but the dictionaries; reads nothing outside `fields`.
    private static func decodeOther(className: String, fields: [String: PlistValue]) throws -> Node {
        switch className {
        case "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSOrderedSet", "NSMutableOrderedSet":
            guard case .array(let vals)? = fields["NS.objects"] else { throw ImportError.archive("malformed \(className)") }
            return .array(vals)
        case "NSString", "NSMutableString":
            if let s = fields["NS.string"]?.string { return .string(s) }
            if let b = fields["NS.bytes"]?.data { return .string(String(decoding: b, as: UTF8.self)) }
            throw ImportError.archive("malformed \(className)")
        case "NSData", "NSMutableData":
            guard let d = fields["NS.data"]?.data else { throw ImportError.archive("malformed \(className)") }
            return .data(d)
        case "NSDate":
            guard let t = fields["NS.time"]?.double else { throw ImportError.archive("malformed NSDate") }
            return .date(Date(timeIntervalSinceReferenceDate: t))
        default:
            var f = fields
            f["$class"] = nil
            return .object(className: className, fields: f)
        }
    }
}

extension KeyedArchive.Node {
    /// Class name for `.object`, nil otherwise.
    public var className: String? { if case .object(let c, _) = self { return c }; return nil }

    /// Raw field (object) or value (dictionary) for `key`.
    public func raw(_ key: String) -> PlistValue? {
        switch self {
        case .object(_, let f): return f[key]
        case .dict(let d): return d[key]
        default: return nil
        }
    }

    /// True for `$null`.
    public var isNull: Bool { if case .null = self { return true }; return false }
    /// The string, if this decodes to one. `NSData` holding UTF-8 counts too
    /// (some apps store names that way).
    public var string: String? {
        switch self {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }
    /// Integer view of a numeric node.
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .real(let x): return x.isFinite && abs(x) < 9e18 ? Int64(x) : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    /// Floating-point view of a numeric node.
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .real(let x): return x
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    /// Bytes of a data node.
    public var data: Data? { if case .data(let d) = self { return d }; return nil }
    /// Date of a date node.
    public var date: Date? { if case .date(let d) = self { return d }; return nil }
}

extension KeyedArchive {
    /// Decoded field `key` of an object or dictionary node; `.null` when absent.
    public func field(_ n: Node, _ key: String) throws -> Node {
        guard let v = n.raw(key) else { return .null }
        return try node(v)
    }

    /// Decoded elements of an array node (empty for anything else).
    public func elements(_ n: Node) throws -> [Node] {
        guard case .array(let a) = n else { return [] }
        return try a.map { try node($0) }
    }
}
