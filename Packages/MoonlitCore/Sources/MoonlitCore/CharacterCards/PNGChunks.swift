import Foundation

/// 极简 PNG 读写：只处理文本块（tEXt / iTXt），足够读写 SillyTavern 角色卡。
/// 角色卡把 base64 编码的 JSON 放在关键字为 `chara`（V2）或 `ccv3`（V3）的文本块里。
public enum PNGChunks {
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public struct Chunk: Sendable {
        public var type: String
        public var data: Data
    }

    public enum PNGError: Error, LocalizedError {
        case notPNG
        case truncated
        case badCRC(String)

        public var errorDescription: String? {
            switch self {
            case .notPNG: return "这不是 PNG 文件"
            case .truncated: return "PNG 文件不完整"
            case .badCRC(let type): return "PNG 数据块 \(type) 校验失败"
            }
        }
    }

    public static func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && Array(data.prefix(8)) == signature
    }

    /// 读出全部数据块。`verifyCRC` 为 false 时容忍校验错误（有些工具写坏了 CRC）。
    public static func readChunks(_ data: Data, verifyCRC: Bool = false) throws -> [Chunk] {
        guard isPNG(data) else { throw PNGError.notPNG }
        let bytes = [UInt8](data)
        var offset = 8
        var chunks: [Chunk] = []
        while offset + 12 <= bytes.count {
            let length = Int(readUInt32(bytes, offset))
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            let type = String(decoding: typeBytes, as: UTF8.self)
            let dataStart = offset + 8
            let dataEnd = dataStart + length
            guard length >= 0, dataEnd + 4 <= bytes.count else { throw PNGError.truncated }
            let body = Data(bytes[dataStart..<dataEnd])
            if verifyCRC {
                let stored = readUInt32(bytes, dataEnd)
                let computed = CRC32.checksum(Array(typeBytes) + Array(body))
                if stored != computed { throw PNGError.badCRC(type) }
            }
            chunks.append(Chunk(type: type, data: body))
            offset = dataEnd + 4
            if type == "IEND" { break }
        }
        return chunks
    }

    /// 读出所有文本块：关键字 → 文本。
    public static func textEntries(_ data: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        for chunk in try readChunks(data) {
            switch chunk.type {
            case "tEXt":
                let bytes = [UInt8](chunk.data)
                guard let zero = bytes.firstIndex(of: 0) else { continue }
                let keyword = String(decoding: bytes[0..<zero], as: UTF8.self)
                // tEXt 规范上是 Latin-1，但角色卡里是 base64，按 UTF-8 解码即可。
                let text = String(decoding: bytes[(zero + 1)...], as: UTF8.self)
                result[keyword] = text
            case "iTXt":
                if let (keyword, text) = parseITXt([UInt8](chunk.data)) {
                    result[keyword] = text
                }
            default:
                continue
            }
        }
        return result
    }

    private static func parseITXt(_ bytes: [UInt8]) -> (String, String)? {
        // keyword \0 compressionFlag compressionMethod languageTag \0 translatedKeyword \0 text
        guard let k = bytes.firstIndex(of: 0), k + 2 < bytes.count else { return nil }
        let keyword = String(decoding: bytes[0..<k], as: UTF8.self)
        let compressed = bytes[k + 1] != 0
        if compressed { return nil } // 压缩的 iTXt 需要 zlib，角色卡不使用
        var idx = k + 3
        guard let langEnd = bytes[idx...].firstIndex(of: 0) else { return nil }
        idx = langEnd + 1
        guard let transEnd = bytes[idx...].firstIndex(of: 0) else { return nil }
        idx = transEnd + 1
        let text = String(decoding: bytes[idx...], as: UTF8.self)
        return (keyword, text)
    }

    /// 写入（或替换）一组 tEXt 块，放在 IEND 之前。原有同关键字的文本块会被移除。
    public static func writingTextEntries(_ entries: [(keyword: String, text: String)], into png: Data) throws -> Data {
        let chunks = try readChunks(png)
        let keywords = Set(entries.map(\.keyword))
        var output = Data(signature)
        for chunk in chunks {
            if chunk.type == "IEND" {
                for entry in entries {
                    var body = Data(entry.keyword.utf8)
                    body.append(0)
                    body.append(Data(entry.text.utf8))
                    output.append(encodeChunk(type: "tEXt", data: body))
                }
                output.append(encodeChunk(type: "IEND", data: Data()))
                continue
            }
            if chunk.type == "tEXt" || chunk.type == "iTXt" {
                let bytes = [UInt8](chunk.data)
                if let zero = bytes.firstIndex(of: 0) {
                    let keyword = String(decoding: bytes[0..<zero], as: UTF8.self)
                    if keywords.contains(keyword) { continue }
                }
            }
            output.append(encodeChunk(type: chunk.type, data: chunk.data))
        }
        return output
    }

    public static func encodeChunk(type: String, data: Data) -> Data {
        var out = Data()
        appendUInt32(&out, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(data)
        appendUInt32(&out, CRC32.checksum(typeBytes + [UInt8](data)))
        return out
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// 生成纯色 PNG（无压缩 deflate 存储块）。
/// 用途：没有头像的角色导出 PNG 角色卡时，提供一张占位图承载元数据。
public enum SolidPNG {
    public static func make(width: Int = 256, height: Int = 256, r: UInt8, g: UInt8, b: UInt8) -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((width * 3 + 1) * height)
        for _ in 0..<height {
            raw.append(0) // 过滤类型：None
            for _ in 0..<width {
                raw.append(r); raw.append(g); raw.append(b)
            }
        }
        var ihdr = Data()
        PNGChunks.appendUInt32(&ihdr, UInt32(width))
        PNGChunks.appendUInt32(&ihdr, UInt32(height))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8 位 RGB
        var png = Data(PNGChunks.signature)
        png.append(PNGChunks.encodeChunk(type: "IHDR", data: ihdr))
        png.append(PNGChunks.encodeChunk(type: "IDAT", data: zlibStored(raw)))
        png.append(PNGChunks.encodeChunk(type: "IEND", data: Data()))
        return png
    }

    static func zlibStored(_ input: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let blockSize = min(65_535, input.count - offset)
            let isLast = offset + blockSize >= input.count
            out.append(isLast ? 1 : 0)
            let len = UInt16(blockSize)
            out.append(UInt8(len & 0xFF)); out.append(UInt8(len >> 8))
            let nlen = ~len
            out.append(UInt8(nlen & 0xFF)); out.append(UInt8(nlen >> 8))
            out.append(contentsOf: input[offset..<(offset + blockSize)])
            offset += blockSize
        } while offset < input.count
        // Adler-32
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        PNGChunks.appendUInt32(&out, (b << 16) | a)
        return out
    }
}
