import Foundation

/// 计 token 的接口。加载了本地模型时用模型自己的分词器（精确）；
/// 否则用 `HeuristicTokenCounter` 估算。
public protocol TokenCounter: Sendable {
    func count(_ text: String) -> Int
}

/// 粗略估算：中日韩字符约 0.75 token/字，其余按约 3.6 字符/token。
/// 只在没有加载模型（例如云端模式）时使用；会略微高估，留出安全余量。
public struct HeuristicTokenCounter: TokenCounter {
    public init() {}

    public func count(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isCJKLike {
                cjk += 1
            } else {
                other += 1
            }
        }
        let estimate = Double(cjk) * 0.75 + Double(other) / 3.6
        return Int(estimate.rounded(.up))
    }
}

extension Unicode.Scalar {
    /// 汉字、假名、谚文及全角标点。
    var isCJKLike: Bool {
        switch value {
        case 0x3000...0x303F, // CJK 标点
             0x3040...0x30FF, // 假名
             0x3400...0x4DBF, // 扩展 A
             0x4E00...0x9FFF, // 基本汉字
             0xAC00...0xD7AF, // 谚文
             0xF900...0xFAFF, // 兼容汉字
             0xFF00...0xFFEF, // 全角符号
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

/// SillyTavern 风格的宏替换：{{char}}、{{user}}、<USER>、<BOT> 等。
public struct MacroContext: Sendable {
    public var characterName: String
    public var userName: String
    public var originalSystemPrompt: String
    /// 群聊里其他角色的名字，用于 {{group}}。
    public var groupNames: [String]

    public init(characterName: String, userName: String, originalSystemPrompt: String = "", groupNames: [String] = []) {
        self.characterName = characterName
        self.userName = userName
        self.originalSystemPrompt = originalSystemPrompt
        self.groupNames = groupNames
    }

    public func expand(_ text: String) -> String {
        guard text.contains("{{") || text.contains("<") else { return text }
        var result = text
        let pairs: [(String, String)] = [
            ("{{original}}", originalSystemPrompt),
            ("{{char}}", characterName),
            ("{{Char}}", characterName),
            ("{{CHAR}}", characterName),
            ("{{user}}", userName),
            ("{{User}}", userName),
            ("{{USER}}", userName),
            ("<BOT>", characterName),
            ("<bot>", characterName),
            ("<USER>", userName),
            ("<user>", userName),
            ("{{group}}", groupNames.joined(separator: "、")),
            ("{{newline}}", "\n")
        ]
        for (macro, value) in pairs where result.contains(macro) {
            result = result.replacingOccurrences(of: macro, with: value)
        }
        return result
    }
}

public extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}

public extension String {

    /// 去掉成对出现的 <think>...</think> 段落，以及没有闭合的尾部思考段。
    func strippingThinkBlocks() -> String {
        var text = self
        while let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        // 只出现闭合标签的情况（模板里已预填 <think>）
        if let end = text.range(of: "</think>") {
            text.removeSubrange(text.startIndex..<end.upperBound)
        }
        return text
    }
}
