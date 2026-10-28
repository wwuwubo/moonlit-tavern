import Foundation

/// 自动摘要：把掉出上下文窗口的旧消息交给模型压缩成「摘要 + 关键事件 + 关系变化 + 剧情状态」。
/// 本地模型同样能完成这件事，不需要联网。
public enum Summarizer {
    public struct Result: Equatable, Sendable {
        public var summary: String
        public var events: [String]
        public var relationships: [Relationship]
        public var stateUpdates: [String: String]

        public struct Relationship: Equatable, Sendable {
            public var subject: String
            public var object: String
            public var state: String
        }

        public var isEmpty: Bool {
            summary.isBlank && events.isEmpty && relationships.isEmpty && stateUpdates.isEmpty
        }
    }

    /// 摘要请求的消息。
    public static func prompt(
        messages: [ChatMessage],
        previousSummary: String?,
        characterNames: [String],
        userName: String
    ) -> [PromptMessage] {
        let transcript = messages.map { "\($0.speakerName)：\($0.content.trimmed)" }.joined(separator: "\n")
        var system = """
        你是一名严谨的剧情记录员。阅读角色扮演对话片段，提炼需要长期记住的信息。只依据原文，不要编造。
        严格按以下格式输出，不要输出其他内容：
        摘要：（两到四句话，概括这段剧情，使用第三人称）
        事件：
        - （关键事件，每行一条，最多五条；没有就写「无」）
        关系：
        - 甲→乙：关系或态度的变化（最多四条；没有就写「无」）
        状态：
        - 键=值（剧情状态，例如 地点=王都酒馆、时间=深夜；没有就写「无」）
        """
        system += "\n出场角色：\(characterNames.joined(separator: "、"))；用户扮演：\(userName)。"
        var user = ""
        if let previous = previousSummary, !previous.isBlank {
            user += "此前的摘要（供参考，不要重复）：\n\(previous.trimmed)\n\n"
        }
        user += "需要整理的对话：\n\(transcript)"
        return [PromptMessage(role: .system, content: system), PromptMessage(role: .user, content: user)]
    }

    /// 解析模型输出。格式不规范时尽量容错：没有任何标签时，整段作为摘要。
    public static func parse(_ raw: String) -> Result {
        let text = raw.strippingThinkBlocks()
        var result = Result(summary: "", events: [], relationships: [], stateUpdates: [:])
        enum Section { case none, summary, events, relations, state }
        var section = Section.none
        var summaryLines: [String] = []
        var sawLabel = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmed
            guard !line.isEmpty else { continue }
            if let rest = stripLabel(line, labels: ["摘要", "Summary", "总结"]) {
                section = .summary; sawLabel = true
                if !rest.isEmpty { summaryLines.append(rest) }
                continue
            }
            if let rest = stripLabel(line, labels: ["事件", "关键事件", "Events"]) {
                section = .events; sawLabel = true
                if !rest.isEmpty, !isNone(rest) { result.events.append(rest) }
                continue
            }
            if let rest = stripLabel(line, labels: ["关系", "关系变化", "Relationships"]) {
                section = .relations; sawLabel = true
                if !rest.isEmpty, !isNone(rest), let rel = parseRelationship(rest) { result.relationships.append(rel) }
                continue
            }
            if let rest = stripLabel(line, labels: ["状态", "剧情状态", "State"]) {
                section = .state; sawLabel = true
                if !rest.isEmpty, !isNone(rest) { parseState(rest, into: &result.stateUpdates) }
                continue
            }
            let item = stripBullet(line)
            if isNone(item) { continue }
            switch section {
            case .none, .summary: summaryLines.append(item)
            case .events: result.events.append(item)
            case .relations: if let rel = parseRelationship(item) { result.relationships.append(rel) }
            case .state: parseState(item, into: &result.stateUpdates)
            }
        }
        result.summary = summaryLines.joined(separator: sawLabel ? "" : "\n").trimmed
        return result
    }

    /// 转成记忆条目。
    public static func memoryItems(from result: Result, messageIndex: Int) -> [MemoryItem] {
        var items: [MemoryItem] = []
        if !result.summary.isBlank {
            items.append(MemoryItem(kind: .summary, content: result.summary, importance: 4, source: .automatic, messageIndex: messageIndex))
        }
        for event in result.events {
            items.append(MemoryItem(kind: .event, content: event, importance: 3, source: .automatic, messageIndex: messageIndex))
        }
        for rel in result.relationships {
            items.append(MemoryItem(kind: .relationship, content: rel.state, importance: 3,
                                    subject: rel.subject, object: rel.object, source: .automatic, messageIndex: messageIndex))
        }
        return items
    }

    /// 合并关系记忆：同一对角色只保留最新状态，避免关系条目越积越多、互相矛盾。
    public static func merge(_ newItems: [MemoryItem], into memory: inout ChatMemory) {
        for item in newItems {
            if item.kind == .relationship,
               let idx = memory.items.firstIndex(where: {
                   $0.kind == .relationship && $0.source == .automatic && $0.subject == item.subject && $0.object == item.object
               }) {
                memory.items[idx].content = item.content
                memory.items[idx].messageIndex = item.messageIndex
                memory.items[idx].updatedAt = Date()
            } else {
                memory.items.append(item)
            }
        }
    }

    static func stripLabel(_ line: String, labels: [String]) -> String? {
        // 模型常把标签写成 **摘要**：、## 摘要、【摘要】
        let cleaned = line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "【", with: "").replacingOccurrences(of: "】", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*[] "))
        for label in labels {
            for sep in ["：", ":"] {
                if cleaned.hasPrefix(label + sep) {
                    return String(cleaned.dropFirst(label.count + sep.count)).trimmed
                }
            }
            if cleaned == label { return "" }
        }
        return nil
    }

    static func stripBullet(_ line: String) -> String {
        var s = Substring(line)
        while let first = s.first, "-•*·".contains(first) { s = s.dropFirst() }
        // 「1.」「2、」形式
        if let dot = s.firstIndex(where: { $0 == "." || $0 == "、" }), s[s.startIndex..<dot].allSatisfy(\.isNumber), dot != s.startIndex {
            s = s[s.index(after: dot)...]
        }
        return String(s).trimmed
    }

    static func isNone(_ s: String) -> Bool {
        ["无", "无。", "暂无", "none", "None", "N/A", "-"].contains(s.trimmed)
    }

    static func parseRelationship(_ s: String) -> Result.Relationship? {
        let line = stripBullet(s)
        let arrows = ["→", "->", "=>", "对"]
        for arrow in arrows {
            guard let arrowRange = line.range(of: arrow) else { continue }
            let subject = String(line[..<arrowRange.lowerBound]).trimmed
            let rest = String(line[arrowRange.upperBound...])
            let sepRange = rest.range(of: "：") ?? rest.range(of: ":")
            guard let sep = sepRange else { continue }
            let object = String(rest[..<sep.lowerBound]).trimmed
            let state = String(rest[sep.upperBound...]).trimmed
            if !subject.isEmpty, !object.isEmpty, !state.isEmpty {
                return Result.Relationship(subject: subject, object: object, state: state)
            }
        }
        return nil
    }

    static func parseState(_ s: String, into dict: inout [String: String]) {
        for part in stripBullet(s).components(separatedBy: CharacterSet(charactersIn: "，,；;")) {
            let pair = part.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            if pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty {
                dict[pair[0]] = pair[1]
            }
        }
    }
}
