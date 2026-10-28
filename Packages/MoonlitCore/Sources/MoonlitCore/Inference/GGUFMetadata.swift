import Foundation

/// 只读 GGUF 文件头里的元数据，不加载权重。
/// 用途：加载前就能显示架构、层数、训练上下文、聊天模板，并估算内存占用。
public struct GGUFMetadata: Sendable {
    public var version: UInt32
    public var tensorCount: UInt64
    public var values: [String: GGUFValue]

    public var architecture: String? { values["general.architecture"]?.string }
    public var name: String? { values["general.name"]?.string }
    public var chatTemplate: String? { values["tokenizer.chat_template"]?.string }
    public var fileType: Int? { values["general.file_type"]?.int }

    public func archInt(_ key: String) -> Int? {
        guard let arch = architecture else { return nil }
        return values["\(arch).\(key)"]?.int
    }

    public var blockCount: Int? { archInt("block_count") }
    public var contextLength: Int? { archInt("context_length") }
    public var embeddingLength: Int? { archInt("embedding_length") }
    public var headCount: Int? { archInt("attention.head_count") }

    /// KV 头数可能是逐层数组（混合架构）。
    public var headCountKV: [Int]? {
        guard let arch = architecture, let v = values["\(arch).attention.head_count_kv"] else { return nil }
        if let n = v.int { return [n] }
        return v.intArray
    }

    public var keyLength: Int? { archInt("attention.key_length") }
    public var valueLength: Int? { archInt("attention.value_length") }
    /// Qwen3.5 / Qwen3-Next 等混合架构：每隔多少层有一层完整注意力。
    public var fullAttentionInterval: Int? { archInt("full_attention_interval") }
    public var slidingWindow: Int? { archInt("attention.sliding_window") }

    /// 量化类型的可读名称（general.file_type）。
    public var quantizationLabel: String {
        guard let t = fileType else { return "未知" }
        let names: [Int: String] = [
            0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1",
            10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M",
            16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S",
            22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL", 26: "IQ3_S", 27: "IQ3_M",
            28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M", 32: "BF16"
        ]
        return names[t] ?? "类型 \(t)"
    }
}

public enum GGUFValue: Sendable {
    case uint(UInt64)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case array([GGUFValue])
    /// 太大的数组（例如词表）只记录长度，不读内容。
    case skippedArray(count: UInt64)

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var int: Int? {
        switch self {
        case .uint(let v): return Int(clamping: v)
        case .int(let v): return Int(clamping: v)
        case .float(let v): return Int(v)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var intArray: [Int]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.int)
    }
}

public enum GGUFReader {
    public enum ReadError: Error, LocalizedError {
        case notGGUF
        case unsupportedVersion(UInt32)
        case truncated
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .notGGUF: return "不是 GGUF 模型文件"
            case .unsupportedVersion(let v): return "不支持的 GGUF 版本 \(v)"
            case .truncated: return "GGUF 文件头不完整"
            case .invalid(let d): return "GGUF 元数据异常：\(d)"
            }
        }
    }

    /// 从文件读取。只读取文件头（最多 64 MB，聊天模板和小数组都在这里）。
    public static func read(url: URL, maxHeaderBytes: Int = 64 * 1024 * 1024) throws -> GGUFMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxHeaderBytes)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> GGUFMetadata {
        var reader = ByteReader(data: data)
        guard try reader.readBytes(4) == Array("GGUF".utf8) else { throw ReadError.notGGUF }
        let version = try reader.u32()
        guard version == 2 || version == 3 else { throw ReadError.unsupportedVersion(version) }
        let tensorCount = try reader.u64()
        let kvCount = try reader.u64()
        guard kvCount < 100_000 else { throw ReadError.invalid("键值对数量异常 \(kvCount)") }
        var values: [String: GGUFValue] = [:]
        for _ in 0..<kvCount {
            let key = try reader.string()
            let type = try reader.u32()
            values[key] = try readValue(&reader, type: type)
        }
        return GGUFMetadata(version: version, tensorCount: tensorCount, values: values)
    }

    static func readValue(_ r: inout ByteReader, type: UInt32) throws -> GGUFValue {
        switch type {
        case 0: return .uint(UInt64(try r.u8()))
        case 1: return .int(Int64(Int8(bitPattern: try r.u8())))
        case 2: return .uint(UInt64(try r.u16()))
        case 3: return .int(Int64(Int16(bitPattern: try r.u16())))
        case 4: return .uint(UInt64(try r.u32()))
        case 5: return .int(Int64(Int32(bitPattern: try r.u32())))
        case 6: return .float(Double(Float(bitPattern: try r.u32())))
        case 7: return .bool(try r.u8() != 0)
        case 8: return .string(try r.string())
        case 9:
            let elementType = try r.u32()
            let count = try r.u64()
            // 词表、合并表这类大数组跳过内容
            if count > 4096 {
                try skipArray(&r, elementType: elementType, count: count)
                return .skippedArray(count: count)
            }
            var items: [GGUFValue] = []
            items.reserveCapacity(Int(count))
            for _ in 0..<count { items.append(try readValue(&r, type: elementType)) }
            return .array(items)
        case 10: return .uint(try r.u64())
        case 11: return .int(Int64(bitPattern: try r.u64()))
        case 12: return .float(Double(bitPattern: try r.u64()))
        default: throw ReadError.invalid("未知值类型 \(type)")
        }
    }

    static func skipArray(_ r: inout ByteReader, elementType: UInt32, count: UInt64) throws {
        let fixedSizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        if let size = fixedSizes[elementType] {
            try r.skip(Int(count) * size)
        } else if elementType == 8 {
            for _ in 0..<count {
                let len = try r.u64()
                try r.skip(Int(len))
            }
        } else {
            for _ in 0..<count { _ = try readValue(&r, type: elementType) }
        }
    }

    struct ByteReader {
        let data: Data
        var offset = 0

        mutating func readBytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset + n <= data.count else { throw ReadError.truncated }
            let start = data.startIndex + offset
            let bytes = [UInt8](data[start..<(start + n)])
            offset += n
            return bytes
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0, offset + n <= data.count else { throw ReadError.truncated }
            offset += n
        }

        mutating func u8() throws -> UInt8 { try readBytes(1)[0] }

        mutating func u16() throws -> UInt16 {
            let b = try readBytes(2)
            return UInt16(b[0]) | UInt16(b[1]) << 8
        }

        mutating func u32() throws -> UInt32 {
            let b = try readBytes(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        mutating func u64() throws -> UInt64 {
            let lo = UInt64(try u32())
            let hi = UInt64(try u32())
            return lo | hi << 32
        }

        mutating func string() throws -> String {
            let len = try u64()
            guard len < 16 * 1024 * 1024 else { throw ReadError.invalid("字符串过长") }
            return String(decoding: try readBytes(Int(len)), as: UTF8.self)
        }
    }
}
