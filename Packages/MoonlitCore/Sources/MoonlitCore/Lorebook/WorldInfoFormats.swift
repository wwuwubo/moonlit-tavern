import Foundation

/// 世界书格式转换：
/// - TavernCharacter Card V2 内嵌的 `character_book`
/// - SillyTavern 独立世界书文件（`{"entries": {"0": {...}}}`）
/// - 本应用格式（直接 Codable）
public enum WorldInfoFormats {
    public enum FormatError: Error, LocalizedError {
        case unrecognized
        public var errorDescription: String? { "无法识别的世界书格式" }
    }

    static let moonlitKey = "moonlit"

    // MARK: - 导入

    /// 自动识别并导入世界书 JSON。
    public static func importLorebook(from data: Data, fallbackName: String = "导入的世界书") throws -> Lorebook {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = root.objectValue else { throw FormatError.unrecognized }

        // 本应用格式：驼峰字段名（V2 用下划线 scan_depth）
        if object["entries"]?.arrayValue != nil, object["scanDepth"] != nil || object["recursiveScanning"] != nil {
            var book = try JSONDecoder().decode(Lorebook.self, from: data)
            book.id = UUID() // 导入视为新世界书，避免覆盖已有的同 id 数据
            return book
        }
        // V2 character_book：entries 是数组
        if object["entries"]?.arrayValue != nil {
            return fromCharacterBook(object, fallbackName: fallbackName)
        }
        // SillyTavern 世界书：entries 是以字符串编号为键的对象
        if let entries = object["entries"]?.objectValue {
            return fromSillyTavernWorld(object, entries: entries, fallbackName: fallbackName)
        }
        // 角色卡里套着的 character_book
        if let book = object["data"]?["character_book"]?.objectValue {
            return fromCharacterBook(book, fallbackName: fallbackName)
        }
        throw FormatError.unrecognized
    }

    public static func fromCharacterBook(_ book: [String: JSONValue], fallbackName: String) -> Lorebook {
        var lorebook = Lorebook(name: book.string("name").flatMap { $0.isBlank ? nil : $0 } ?? fallbackName)
        lorebook.description = book.string("description") ?? ""
        lorebook.scanDepth = book.int("scan_depth") ?? 4
        lorebook.tokenBudget = book.int("token_budget") ?? 0
        lorebook.recursiveScanning = book.bool("recursive_scanning") ?? true
        lorebook.extensions = book["extensions"]?.objectValue ?? [:]
        let entries = book["entries"]?.arrayValue ?? []
        lorebook.entries = entries.enumerated().compactMap { index, value in
            guard let e = value.objectValue else { return nil }
            return entryFromCharacterBook(e, index: index)
        }
        return lorebook
    }

    static func entryFromCharacterBook(_ e: [String: JSONValue], index: Int) -> LoreEntry {
        let ext = e["extensions"]?.objectValue ?? [:]
        var entry = LoreEntry()
        entry.uid = e.int("id") ?? ext.int("uid") ?? index
        entry.comment = e.string("comment") ?? e.string("name") ?? ""
        entry.keys = e.strings("keys") ?? e.strings("key") ?? []
        entry.secondaryKeys = e.strings("secondary_keys") ?? []
        entry.selective = e.bool("selective") ?? !entry.secondaryKeys.isEmpty
        entry.selectiveLogic = SelectiveLogic(rawValue: ext.int("selectiveLogic") ?? 0) ?? .andAny
        entry.content = e.string("content") ?? ""
        entry.enabled = e.bool("enabled") ?? true
        entry.constant = e.bool("constant") ?? false
        entry.caseSensitive = e.bool("case_sensitive") ?? ext.bool("case_sensitive") ?? false
        entry.matchWholeWords = ext.bool("match_whole_words") ?? false
        entry.insertionOrder = e.int("insertion_order") ?? 100
        entry.priority = e.int("priority") ?? 10
        if let stPosition = ext.int("position") {
            entry.position = position(fromSillyTavern: stPosition)
        } else {
            entry.position = (e.string("position") == "before_char") ? .beforeCharacter : .afterCharacter
        }
        entry.depth = ext.int("depth") ?? 4
        entry.probability = (ext.bool("useProbability") ?? true) ? (ext.int("probability") ?? 100) : 100
        entry.group = ext.string("group") ?? ""
        entry.excludeRecursion = ext.bool("exclude_recursion") ?? false
        entry.preventRecursion = ext.bool("prevent_recursion") ?? false
        entry.sticky = ext.int("sticky") ?? 0
        entry.cooldown = ext.int("cooldown") ?? 0
        entry.delay = ext.int("delay") ?? 0
        entry.scanDepth = ext.int("scan_depth")
        applyMoonlitExtension(ext[moonlitKey]?.objectValue, to: &entry)
        var remaining = ext
        remaining.removeValue(forKey: moonlitKey)
        entry.extensions = remaining
        return entry
    }

    public static func fromSillyTavernWorld(_ object: [String: JSONValue], entries: [String: JSONValue], fallbackName: String) -> Lorebook {
        var lorebook = Lorebook(name: object.string("name").flatMap { $0.isBlank ? nil : $0 } ?? fallbackName)
        lorebook.description = object.string("description") ?? ""
        let sorted = entries.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
        lorebook.entries = sorted.compactMap { key, value in
            guard let e = value.objectValue else { return nil }
            var entry = LoreEntry()
            entry.uid = e.int("uid") ?? Int(key) ?? 0
            entry.comment = e.string("comment") ?? ""
            entry.keys = e.strings("key") ?? []
            entry.secondaryKeys = e.strings("keysecondary") ?? []
            entry.selective = e.bool("selective") ?? !entry.secondaryKeys.isEmpty
            entry.selectiveLogic = SelectiveLogic(rawValue: e.int("selectiveLogic") ?? 0) ?? .andAny
            entry.content = e.string("content") ?? ""
            entry.enabled = !(e.bool("disable") ?? false)
            entry.constant = e.bool("constant") ?? false
            entry.caseSensitive = e.bool("caseSensitive") ?? false
            entry.matchWholeWords = e.bool("matchWholeWords") ?? false
            entry.insertionOrder = e.int("order") ?? 100
            entry.priority = e.int("groupWeight") ?? 10
            entry.position = position(fromSillyTavern: e.int("position") ?? 1)
            entry.depth = e.int("depth") ?? 4
            entry.probability = (e.bool("useProbability") ?? true) ? (e.int("probability") ?? 100) : 100
            entry.group = e.string("group") ?? ""
            entry.excludeRecursion = e.bool("excludeRecursion") ?? false
            entry.preventRecursion = e.bool("preventRecursion") ?? false
            entry.sticky = e.int("sticky") ?? 0
            entry.cooldown = e.int("cooldown") ?? 0
            entry.delay = e.int("delay") ?? 0
            entry.scanDepth = e.int("scanDepth")
            if let filter = e["characterFilter"]?.objectValue {
                entry.characterFilter = filter.strings("names") ?? []
                entry.characterFilterExclude = filter.bool("isExclude") ?? false
            }
            applyMoonlitExtension(e[moonlitKey]?.objectValue, to: &entry)
            // 其余字段原样保存，导出时写回
            let known: Set<String> = [
                "uid", "comment", "key", "keysecondary", "selective", "selectiveLogic", "content", "disable",
                "constant", "caseSensitive", "matchWholeWords", "order", "groupWeight", "position", "depth",
                "probability", "useProbability", "group", "excludeRecursion", "preventRecursion", "sticky",
                "cooldown", "delay", "scanDepth", "characterFilter", moonlitKey
            ]
            entry.extensions = e.filter { !known.contains($0.key) }
            if let st = e.int("position") { entry.extensions["st_position"] = .number(Double(st)) }
            return entry
        }
        return lorebook
    }

    static func position(fromSillyTavern value: Int) -> LorePosition {
        switch value {
        case 0: return .beforeCharacter
        case 4: return .atDepth
        default: return .afterCharacter // 1 以及作者注释 / 示例对话附近的位置，归到角色设定之后
        }
    }

    static func sillyTavernPosition(_ entry: LoreEntry) -> Int {
        switch entry.position {
        case .beforeCharacter: return 0
        case .atDepth: return 4
        case .afterCharacter:
            if let original = entry.extensions["st_position"]?.intValue, ![0, 4].contains(original) { return original }
            return 1
        }
    }

    static func applyMoonlitExtension(_ ext: [String: JSONValue]?, to entry: inout LoreEntry) {
        guard let ext else { return }
        if let raw = ext.string("category"), let category = LoreCategory(rawValue: raw) {
            entry.category = category
        }
        if let priority = ext.int("priority") { entry.priority = priority }
        if let conditions = ext["conditions"]?.arrayValue {
            entry.conditions = conditions.compactMap { value in
                guard let c = value.objectValue, let key = c.string("key"),
                      let op = c.string("op").flatMap(StateCondition.Operator.init(rawValue:)) else { return nil }
                return StateCondition(key: key, op: op, value: c.string("value") ?? "")
            }
        }
    }

    static func moonlitExtension(for entry: LoreEntry) -> JSONValue {
        .object([
            "category": .string(entry.category.rawValue),
            "priority": .number(Double(entry.priority)),
            "conditions": .array(entry.conditions.map {
                .object(["key": .string($0.key), "op": .string($0.op.rawValue), "value": .string($0.value)])
            })
        ])
    }

    // MARK: - 导出

    /// 导出为 V2 `character_book` 对象。
    public static func characterBookObject(_ book: Lorebook) -> JSONValue {
        let entries: [JSONValue] = book.entries.map { entry in
            var ext = entry.extensions
            ext.removeValue(forKey: "st_position")
            ext["position"] = .number(Double(sillyTavernPosition(entry)))
            ext["depth"] = .number(Double(entry.depth))
            ext["probability"] = .number(Double(entry.probability))
            ext["useProbability"] = .bool(entry.probability < 100)
            ext["selectiveLogic"] = .number(Double(entry.selectiveLogic.rawValue))
            ext["group"] = .string(entry.group)
            ext["exclude_recursion"] = .bool(entry.excludeRecursion)
            ext["prevent_recursion"] = .bool(entry.preventRecursion)
            ext["match_whole_words"] = .bool(entry.matchWholeWords)
            ext["case_sensitive"] = .bool(entry.caseSensitive)
            ext["sticky"] = .number(Double(entry.sticky))
            ext["cooldown"] = .number(Double(entry.cooldown))
            ext["delay"] = .number(Double(entry.delay))
            if let depth = entry.scanDepth { ext["scan_depth"] = .number(Double(depth)) }
            ext[moonlitKey] = moonlitExtension(for: entry)
            return .object([
                "id": .number(Double(entry.uid)),
                "keys": .array(entry.keys.map(JSONValue.string)),
                "secondary_keys": .array(entry.secondaryKeys.map(JSONValue.string)),
                "comment": .string(entry.comment),
                "name": .string(entry.comment),
                "content": .string(entry.content),
                "constant": .bool(entry.constant),
                "selective": .bool(entry.selective),
                "insertion_order": .number(Double(entry.insertionOrder)),
                "enabled": .bool(entry.enabled),
                "position": .string(entry.position == .beforeCharacter ? "before_char" : "after_char"),
                "priority": .number(Double(entry.priority)),
                "case_sensitive": .bool(entry.caseSensitive),
                "extensions": .object(ext)
            ])
        }
        return .object([
            "name": .string(book.name),
            "description": .string(book.description),
            "scan_depth": .number(Double(book.scanDepth)),
            "token_budget": .number(Double(book.tokenBudget)),
            "recursive_scanning": .bool(book.recursiveScanning),
            "extensions": .object(book.extensions),
            "entries": .array(entries)
        ])
    }

    /// 导出为 SillyTavern 独立世界书文件。
    public static func sillyTavernWorldData(_ book: Lorebook) throws -> Data {
        var entries: [String: JSONValue] = [:]
        for (index, entry) in book.entries.enumerated() {
            var object = entry.extensions
            object.removeValue(forKey: "st_position")
            object["uid"] = .number(Double(index))
            object["key"] = .array(entry.keys.map(JSONValue.string))
            object["keysecondary"] = .array(entry.secondaryKeys.map(JSONValue.string))
            object["comment"] = .string(entry.comment)
            object["content"] = .string(entry.content)
            object["constant"] = .bool(entry.constant)
            object["selective"] = .bool(entry.selective)
            object["selectiveLogic"] = .number(Double(entry.selectiveLogic.rawValue))
            object["order"] = .number(Double(entry.insertionOrder))
            object["position"] = .number(Double(sillyTavernPosition(entry)))
            object["disable"] = .bool(!entry.enabled)
            object["probability"] = .number(Double(entry.probability))
            object["useProbability"] = .bool(entry.probability < 100)
            object["depth"] = .number(Double(entry.depth))
            object["group"] = .string(entry.group)
            object["groupWeight"] = .number(Double(entry.priority))
            object["excludeRecursion"] = .bool(entry.excludeRecursion)
            object["preventRecursion"] = .bool(entry.preventRecursion)
            object["caseSensitive"] = .bool(entry.caseSensitive)
            object["matchWholeWords"] = .bool(entry.matchWholeWords)
            object["sticky"] = .number(Double(entry.sticky))
            object["cooldown"] = .number(Double(entry.cooldown))
            object["delay"] = .number(Double(entry.delay))
            object["displayIndex"] = .number(Double(index))
            if let depth = entry.scanDepth { object["scanDepth"] = .number(Double(depth)) }
            object["characterFilter"] = .object([
                "isExclude": .bool(entry.characterFilterExclude),
                "names": .array(entry.characterFilter.map(JSONValue.string)),
                "tags": .array([])
            ])
            object[moonlitKey] = moonlitExtension(for: entry)
            entries[String(index)] = .object(object)
        }
        let root: JSONValue = .object(["name": .string(book.name), "entries": .object(entries)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root)
    }
}
