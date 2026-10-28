import Foundation

/// Any JSON value, kept so that fields this reader does not know are
/// re-emitted unchanged (format.md §7): unknown item kinds, unknown fields on
/// items, recordings, text runs and blob references, and `setItem` /
/// `setRecording` values of unknown fields.
///
/// Numbers are IEEE doubles, as in every JSON implementation the format
/// allows for (integers are exact up to 2^53, §5): a number is re-emitted as
/// the shortest decimal that reads back as the same double, so `1.0` becomes
/// `1` and an integer beyond 2^53 its nearest double. Object keys are written
/// sorted, like every format object (`InkJSON.encoder`).
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    /// Deepest coding path (from the document root) a value may sit at.
    /// Decoding recurses once per level, and the app decodes on threads with
    /// 512 KiB stacks: a hostile unknown field nested a few hundred deep
    /// would overflow them (format.md §9).
    public static let maxDepth = 24
    /// Most values one decoder reads (`InkJSON.decoder`). Every value costs a
    /// few trial decodes, each O(depth): without a budget a large unknown
    /// field would take minutes.
    public static let maxValues = 16_384

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown field nested deeper than \(Self.maxDepth)"))
        }
        if let budget = JSONValueBudget.of(decoder), !budget.take() {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "more than \(Self.maxValues) unknown-field values"))
        }
        let c = try decoder.singleValueContainer()
        // Most likely first: every failed trial builds an error.
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            // Last, so that its error (for example nesting too deep) is the one reported.
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)   // JSONEncoder refuses NaN and infinities
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue {
    /// The value of any `Encodable`, as format JSON would write it
    /// (`InkJSON.encoder`: rounding, lowercase UUIDs, RFC 3339 dates).
    public init(encoding value: some Encodable) throws {
        let data = try InkJSON.encoder().encode(value)
        self = try InkJSON.decoder().decode(JSONValue.self, from: data)
    }

    /// Decodes `T` from this value with the format decoder.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try InkJSON.encoder().encode(self)
        return try InkJSON.decoder().decode(T.self, from: data)
    }

    /// True for `.null`.
    public var isNull: Bool { self == .null }
}

/// How many more `JSONValue`s a decoder may read (`JSONValue.maxValues`),
/// kept in its `userInfo` by `InkJSON.decoder()`.
final class JSONValueBudget: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "sempere.jsonValueBudget")
    private let lock = NSLock()
    private var remaining: Int

    init(_ limit: Int = JSONValue.maxValues) { remaining = limit }

    static func of(_ decoder: Decoder) -> JSONValueBudget? {
        guard let key else { return nil }
        return decoder.userInfo[key] as? JSONValueBudget
    }

    /// Takes one value from the budget; false once it is spent.
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// A coding key for any string: objects whose unknown keys are kept.
struct AnyKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Reading and writing a JSON object that has typed fields plus unknown ones
/// kept verbatim in an `extra` dictionary.
extension KeyedDecodingContainer where K == AnyKey {
    /// Every key not in `known`, with its raw value.
    func extra(excluding known: Set<String>) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return out
    }

    func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        try decode(T.self, forKey: AnyKey(key))
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: AnyKey(key))
    }
}

extension KeyedEncodingContainer where K == AnyKey {
    /// Writes `extra`; a key that is also a typed field of the object would
    /// be written twice, so it is refused.
    mutating func encodeExtra(_ extra: [String: JSONValue], excluding known: Set<String>) throws {
        for (key, value) in extra {
            guard !known.contains(key) else {
                throw EncodingError.invalidValue(value, .init(codingPath: codingPath + [AnyKey(key)],
                                                              debugDescription: "unknown-field store holds the known field \(key)"))
            }
            try encode(value, forKey: AnyKey(key))
        }
    }

    mutating func encode<T: Encodable>(_ value: T, _ key: String) throws {
        try encode(value, forKey: AnyKey(key))
    }

    mutating func encodeIfPresent<T: Encodable>(_ value: T?, _ key: String) throws {
        if let value { try encode(value, forKey: AnyKey(key)) }
    }
}
