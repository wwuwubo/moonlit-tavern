import Foundation

/// 角色卡导入导出。
///
/// 支持的输入：
/// - TavernCharacter Card V2 JSON（`spec: chara_card_v2`）
/// - TavernCharacter Card V3 JSON（`spec: chara_card_v3`）
/// - V1 / TavernAI / Pygmalion 风格的扁平 JSON
/// - 内嵌上述 JSON 的 PNG（tEXt/iTXt 块，关键字 `ccv3` 优先，其次 `chara`）
///
/// 导出：V2 JSON；PNG 同时写入 `chara`(V2) 与 `ccv3`(V3) 两个块，兼容新旧客户端。
public enum CharacterCardCodec {
    public struct ImportResult: Sendable {
        public var character: TavernCharacter
        /// 卡片版本："v1" / "v2" / "v3"
        public var specVersion: String
        /// PNG 卡的图片本身（可作为头像）。JSON 卡为空。
        public var avatarPNG: Data?
        /// 导入时的提示（例如字段缺失）。
        public var warnings: [String]
    }

    public enum CardError: Error, LocalizedError {
        case noCardData
        case invalidBase64
        case invalidJSON(String)
        case missingName

        public var errorDescription: String? {
            switch self {
            case .noCardData: return "这张 PNG 里没有角色卡数据（缺少 chara / ccv3 文本块）"
            case .invalidBase64: return "角色卡数据不是有效的 base64"
            case .invalidJSON(let detail): return "角色卡 JSON 无法解析：\(detail)"
            case .missingName: return "角色卡缺少名字"
            }
        }
    }

    static let moonlitKey = "moonlit"
    static let extraFieldsKey = "moonlit_card_extra"

    // MARK: - 导入

    public static func importCard(from data: Data) throws -> ImportResult {
        if PNGChunks.isPNG(data) {
            let texts = try PNGChunks.textEntries(data)
            guard let payload = texts["ccv3"] ?? texts["chara"] ?? texts["Chara"] else { throw CardError.noCardData }
            guard let jsonData = decodeBase64(payload) else { throw CardError.invalidBase64 }
            var result = try importJSON(jsonData)
            result.avatarPNG = data
            return result
        }
        return try importJSON(data)
    }

    public static func importJSON(_ data: Data) throws -> ImportResult {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw CardError.invalidJSON(String(describing: error))
        }
        guard let object = root.objectValue else { throw CardError.invalidJSON("顶层不是对象") }

        let spec = object.string("spec") ?? ""
        var warnings: [String] = []
        let fields: [String: JSONValue]
        let version: String
        if spec == "chara_card_v3", let data = object["data"]?.objectValue {
            fields = data; version = "v3"
        } else if spec == "chara_card_v2", let data = object["data"]?.objectValue {
            fields = data; version = "v2"
        } else if let data = object["data"]?.objectValue, data["name"] != nil {
            fields = data; version = "v2"
            warnings.append("卡片缺少 spec 字段，按 V2 解析")
        } else {
            fields = object; version = "v1"
        }

        var character = try character(from: fields, warnings: &warnings)
        // 记录卡片里我们没建模的字段（如 V3 的 assets、source），导出时写回
        let known: Set<String> = [
            "name", "description", "personality", "scenario", "first_mes", "mes_example", "creator_notes",
            "system_prompt", "post_history_instructions", "alternate_greetings", "character_book", "tags",
            "creator", "character_version", "extensions", "nickname",
            "char_name", "char_persona", "world_scenario", "char_greeting", "example_dialogue"
        ]
        let extra = fields.filter { !known.contains($0.key) }
        if !extra.isEmpty, version != "v1" {
            character.extensions[extraFieldsKey] = .object(extra)
        }
        return ImportResult(character: character, specVersion: version, avatarPNG: nil, warnings: warnings)
    }

    static func character(from f: [String: JSONValue], warnings: inout [String]) throws -> TavernCharacter {
        guard let name = (f.string("name") ?? f.string("char_name"))?.trimmed, !name.isEmpty else {
            throw CardError.missingName
        }
        var c = TavernCharacter(name: name)
        c.nickname = f.string("nickname") ?? ""
        c.description = f.string("description") ?? f.string("char_persona") ?? ""
        c.personality = f.string("personality") ?? ""
        c.scenario = f.string("scenario") ?? f.string("world_scenario") ?? ""
        c.firstMessage = f.string("first_mes") ?? f.string("char_greeting") ?? ""
        c.exampleDialogue = f.string("mes_example") ?? f.string("example_dialogue") ?? ""
        c.creatorNotes = f.string("creator_notes") ?? ""
        c.systemPrompt = f.string("system_prompt") ?? ""
        c.postHistoryInstructions = f.string("post_history_instructions") ?? ""
        c.alternateGreetings = f.strings("alternate_greetings") ?? []
        c.tags = f.strings("tags") ?? []
        c.creator = f.string("creator") ?? ""
        c.characterVersion = f.string("character_version") ?? ""

        var ext = f["extensions"]?.objectValue ?? [:]
        if let talk = ext.double("talkativeness") {
            c.talkativeness = min(max(talk, 0), 1)
        }
        // 本应用导出的卡：恢复拆开的字段
        if let moonlit = ext[moonlitKey]?.objectValue {
            if let description = moonlit.string("description") { c.description = description }
            c.background = moonlit.string("background") ?? ""
            c.speakingStyle = moonlit.string("speakingStyle") ?? ""
        }
        ext.removeValue(forKey: moonlitKey)
        c.extensions = ext

        if let book = f["character_book"]?.objectValue {
            var lorebook = WorldInfoFormats.fromCharacterBook(book, fallbackName: "\(name) 的世界书")
            if lorebook.entries.isEmpty {
                warnings.append("角色自带世界书为空")
            } else {
                lorebook.name = lorebook.name.isBlank ? "\(name) 的世界书" : lorebook.name
                c.characterBook = lorebook
            }
        }
        if c.description.isBlank && c.personality.isBlank && c.firstMessage.isBlank {
            warnings.append("卡片几乎没有设定内容")
        }
        return c
    }

    static func decodeBase64(_ string: String) -> Data? {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) { return data }
        // 有的工具去掉了 padding
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: padded, options: .ignoreUnknownCharacters)
    }

    // MARK: - 导出

    /// 合并后的 description：把「背景」「说话风格」拼进去，其他客户端也能用上。
    public static func compatibleDescription(_ c: TavernCharacter) -> String {
        var parts: [String] = []
        if !c.description.isBlank { parts.append(c.description.trimmed) }
        if !c.background.isBlank { parts.append("【背景】\n" + c.background.trimmed) }
        if !c.speakingStyle.isBlank { parts.append("【说话风格】\n" + c.speakingStyle.trimmed) }
        return parts.joined(separator: "\n\n")
    }

    static func dataObject(_ c: TavernCharacter, v3: Bool) -> [String: JSONValue] {
        var ext = c.extensions
        let extra = ext.removeValue(forKey: extraFieldsKey)?.objectValue ?? [:]
        ext["talkativeness"] = .number(c.talkativeness)
        ext[moonlitKey] = .object([
            "description": .string(c.description),
            "background": .string(c.background),
            "speakingStyle": .string(c.speakingStyle)
        ])
        var data: [String: JSONValue] = [
            "name": .string(c.name),
            "description": .string(compatibleDescription(c)),
            "personality": .string(c.personality),
            "scenario": .string(c.scenario),
            "first_mes": .string(c.firstMessage),
            "mes_example": .string(c.exampleDialogue),
            "creator_notes": .string(c.creatorNotes),
            "system_prompt": .string(c.systemPrompt),
            "post_history_instructions": .string(c.postHistoryInstructions),
            "alternate_greetings": .array(c.alternateGreetings.map(JSONValue.string)),
            "tags": .array(c.tags.map(JSONValue.string)),
            "creator": .string(c.creator),
            "character_version": .string(c.characterVersion),
            "extensions": .object(ext)
        ]
        if let book = c.characterBook {
            data["character_book"] = WorldInfoFormats.characterBookObject(book)
        }
        if v3 {
            data["nickname"] = .string(c.nickname)
            if data["group_only_greetings"] == nil { data["group_only_greetings"] = .array([]) }
            for (key, value) in extra { data[key] = value }
        } else {
            // V2 中保留 V3 专有字段会让严格的解析器报错，只回写非 V3 的未知字段
            let v3Only: Set<String> = ["assets", "nickname", "creator_notes_multilingual", "source",
                                       "group_only_greetings", "creation_date", "modification_date"]
            for (key, value) in extra where !v3Only.contains(key) { data[key] = value }
        }
        return data
    }

    public static func exportJSON(_ c: TavernCharacter, v3: Bool = false) throws -> Data {
        let root: JSONValue = .object([
            "spec": .string(v3 ? "chara_card_v3" : "chara_card_v2"),
            "spec_version": .string(v3 ? "3.0" : "2.0"),
            "data": .object(dataObject(c, v3: v3))
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root)
    }

    /// 把角色卡写进 PNG。`basePNG` 为空时生成一张纯色占位图。
    public static func exportPNG(_ c: TavernCharacter, basePNG: Data?) throws -> Data {
        let base = basePNG.flatMap { PNGChunks.isPNG($0) ? $0 : nil } ?? SolidPNG.make(r: 0x1B, g: 0x1D, b: 0x2A)
        let compactEncoder = JSONEncoder()
        compactEncoder.outputFormatting = [.sortedKeys]
        let v2: JSONValue = .object([
            "spec": .string("chara_card_v2"), "spec_version": .string("2.0"), "data": .object(dataObject(c, v3: false))
        ])
        let v3: JSONValue = .object([
            "spec": .string("chara_card_v3"), "spec_version": .string("3.0"), "data": .object(dataObject(c, v3: true))
        ])
        let v2Text = try compactEncoder.encode(v2).base64EncodedString()
        let v3Text = try compactEncoder.encode(v3).base64EncodedString()
        return try PNGChunks.writingTextEntries([("chara", v2Text), ("ccv3", v3Text)], into: base)
    }
}
