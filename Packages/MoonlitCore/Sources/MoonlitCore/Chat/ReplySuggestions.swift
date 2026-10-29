import Foundation

/// 剧情选项：角色回复后，替用户想几个接下来可以说或做的选择。
public enum ReplySuggestions {
    public static let defaultCount = 3

    /// 生成选项的请求。
    /// 沿用回复用的提示词（系统设定 + 聊天历史，到刚才那条回复为止），只在末尾追加一条说明。
    /// 这样本地模型能复用已经算好的上下文缓存，不用把整段提示词重读一遍。
    public static func request(
        plan: PromptPlan,
        userName: String,
        characterNames: [String],
        count: Int = defaultCount,
        sampling: SamplingParams
    ) -> GenerationRequest {
        let n = min(max(count, 2), 4)
        var messages = Array(plan.messages.dropLast(min(plan.tailCount, max(plan.messages.count - 1, 0))))
        messages.append(PromptMessage(role: .user, content: instruction(userName: userName, characterNames: characterNames, count: n)))
        var s = sampling
        s.temperature = max(s.temperature, 0.85)
        s.seed = nil
        return GenerationRequest(
            messages: messages,
            prefill: "1. ",
            sampling: s,
            maxNewTokens: 48 * n + 32,
            stopSequences: ["\n\(n + 1).", "\n\(n + 1)．", "\n\(n + 1)、", "\n\n\n"],
            purpose: .suggestions
        )
    }

    public static func instruction(userName: String, characterNames: [String], count: Int) -> String {
        let others = characterNames.isEmpty ? "其他角色" : characterNames.joined(separator: "、")
        let numbering = (1...count).map { "「\($0). 」" }.joined()
        return """
        【剧情选项】暂停扮演。请站在\(userName)的角度，为接下来的剧情写 \(count) 个不同的选择，供\(userName)挑选下一步怎么说或怎么做。
        要求：每个选择单独一行，依次编号\(numbering)；每个 6 到 30 个字，写\(userName)要说的话或要做的动作；几个选择的方向要明显不同，比如推进剧情、追问细节、采取行动；只写\(userName)这一方，不要写\(others)的反应，不要解释。
        """
    }

    private static let numbering = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:\d{1,2}|[一二三四五六七八九十])\s*[\.．、\)）:：]|[-•·]\s|\*\s)\s*"#
    )

    /// 从模型输出里取出选项。output 是模型生成的文字，不含预填的「1. 」。
    public static func parse(_ output: String, userName: String, characterNames: [String], limit: Int = defaultCount) -> [String] {
        let text = "1. " + output.replacingOccurrences(of: "\r", with: "")
        var results: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmed
            if line.isEmpty || line.contains("剧情选项") { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let m = numbering.firstMatch(in: line, range: range), let r = Range(m.range, in: line) {
                line = String(line[r.upperBound...]).trimmed
            }
            line = stripWrappingQuotes(line)
            for name in [userName, "我"] where !name.isEmpty {
                for sep in ["：", ":"] where line.hasPrefix(name + sep) {
                    line = String(line.dropFirst(name.count + sep.count)).trimmed
                }
            }
            line = stripWrappingQuotes(line)
            // 写成了别的角色的台词，或是一句说明：跳过
            if characterNames.contains(where: { line.hasPrefix($0 + "：") || line.hasPrefix($0 + ":") }) { continue }
            if line.hasSuffix("：") || line.hasSuffix(":") { continue }
            if line.count < 2 { continue }
            if line.count > 80 { line = String(line.prefix(80)) }
            if results.contains(line) { continue }
            results.append(line)
            if results.count == limit { break }
        }
        return results
    }

    private static func stripWrappingQuotes(_ s: String) -> String {
        let pairs: [(Character, Character)] = [("「", "」"), ("“", "”"), ("\"", "\""), ("『", "』"), ("‘", "’")]
        var line = s
        for (open, close) in pairs where line.count >= 2 && line.first == open && line.last == close {
            line = String(line.dropFirst().dropLast()).trimmed
        }
        return line
    }
}
