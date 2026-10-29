import Foundation

/// 解析单独生成的候选剧情行动。只返回简短的用户可选行动，不混入角色正文。
public enum ActionSuggestionParser {
    public static func parse(_ text: String, maxCount: Int = 4) -> [String] {
        var result: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // 兼容 "1. ..."、"1、..."、"- ..."、"• ..."。
            if let range = line.range(of: #"^\s*(?:[1-9][0-9]*[.、．)）:]\s*|[-•]\s+)"#, options: .regularExpression) {
                line.removeSubrange(range)
            } else {
                continue
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            guard !line.isEmpty, line.count <= 80 else { continue }
            guard !result.contains(line) else { continue }
            result.append(line)
            if result.count >= maxCount { break }
        }
        return result
    }
}
