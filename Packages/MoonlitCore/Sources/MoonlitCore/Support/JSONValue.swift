import Foundation

/// 任意 JSON 值。用来原样保存角色卡、世界书里我们不认识的字段，
/// 导入后再导出时不丢信息。
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v):
            if v.rounded() == v, abs(v) < 9_007_199_254_740_992 {
                try container.encode(Int64(v))
            } else {
                try container.encode(v)
            }
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 字符串数组；也接受逗号分隔的单个字符串（部分旧卡这样写关键词）。
    public var stringArrayValue: [String]? {
        switch self {
        case .array(let items):
            return items.compactMap { $0.stringValue }
        case .string(let s):
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return nil
        }
    }

    public static func from(any value: Any) -> JSONValue {
        switch value {
        case let v as JSONValue: return v
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as [Any]: return .array(v.map { from(any: $0) })
        case let v as [String: Any]: return .object(v.mapValues { from(any: $0) })
        default: return .null
        }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func strings(_ key: String) -> [String]? { self[key]?.stringArrayValue }
}
